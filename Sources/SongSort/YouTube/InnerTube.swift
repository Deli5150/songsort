import CryptoKit
import Foundation
import OSLog

let log = Logger(subsystem: "com.delvison.songsort", category: "ytmusic")

enum AppPaths {
    static var supportDir: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "SongSort", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cacheDir: URL {
        let dir = URL.cachesDirectory.appending(path: "com.delvison.songsort", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Plain-text diagnostics in Application Support (unified logging drops info-level messages).
enum Diagnostics {
    private static let queue = DispatchQueue(label: "diagnostics")
    static var url: URL { AppPaths.supportDir.appending(path: "diagnostics.log") }

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct YouTubeError: LocalizedError, Sendable {
    enum Kind: Sendable { case notSignedIn, rateLimited, http, youtube, network, other }
    var kind: Kind
    var message: String
    var errorDescription: String? { message }

    static func other(_ message: String) -> YouTubeError { YouTubeError(kind: .other, message: message) }

    /// Failures worth retrying: rate-limiting, throttled responses, flaky network.
    var isTransient: Bool {
        switch kind {
        case .rateLimited, .network: return true
        case .http: return message.contains("status 5")
        case .youtube: return message.lowercased().contains("does not exist")
        default: return false
        }
    }
}

/// InnerTube request gate. YouTube's unofficial endpoints rate-limit (HTTP 429) when the app
/// fires a burst of calls at once, so every network call funnels through this limiter. It runs
/// at a brisk pace until the first 429, then pauses everything for a cooldown and drops to a
/// conservative pace for a while. User-initiated calls (adds, the deck's songs) use the
/// priority lane so they don't queue behind background membership loads.
actor RequestGate {
    struct Pace { var concurrency: Int; var spacing: Duration }
    static let fast = Pace(concurrency: 4, spacing: .milliseconds(100))
    static let safe = Pace(concurrency: 2, spacing: .milliseconds(300))
    static let rateLimitCooldown: Duration = .seconds(30)
    static let safeModeDuration: Duration = .seconds(600)

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextStart = ContinuousClock.now
    private var rateLimitedUntil = ContinuousClock.now
    private var safeUntil = ContinuousClock.now

    private var pace: Pace { ContinuousClock.now < safeUntil ? Self.safe : Self.fast }

    func acquire(priority: Bool = false) async {
        if active >= pace.concurrency {
            await withCheckedContinuation { c in
                if priority { priorityWaiters.append(c) } else { waiters.append(c) }
            }
        } else {
            active += 1
        }
        let now = ContinuousClock.now
        let start = max(now, nextStart, rateLimitedUntil)
        nextStart = start + pace.spacing
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    func release() {
        active = max(0, active - 1)
        while active < pace.concurrency, !(priorityWaiters.isEmpty && waiters.isEmpty) {
            active += 1
            (priorityWaiters.isEmpty ? waiters.removeFirst() : priorityWaiters.removeFirst()).resume()
        }
    }

    func noteRateLimited() {
        let now = ContinuousClock.now
        if now >= safeUntil { Diagnostics.write("gate: 429 — cooling down, then safe pace for 10 min") }
        rateLimitedUntil = now + Self.rateLimitCooldown
        safeUntil = now + Self.rateLimitCooldown + Self.safeModeDuration
    }
}

/// Raw InnerTube transport for YouTube Music: WEB_REMIX client context, cookie + SAPISIDHASH auth.
actor InnerTube {
    static let shared = InnerTube()

    static let origin = "https://music.youtube.com"
    /// Fallback when the live client version can't be scraped (seen 2026-11-13).
    private static let fallbackClientVersion = "1.20261110.04.00"

    let gate = RequestGate()
    private let urlSession: URLSession
    private var clientVersion: String?
    private var visitorData: String?
    /// SAPISID the scraped config belongs to. Other cookies rotate between calls, so the whole
    /// header isn't a usable "same session" key.
    private var configSession: String?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config)
    }

    func reset() {
        clientVersion = nil
        visitorData = nil
        configSession = nil
    }

    private func cookie() async throws -> String {
        let cookie = await YouTubeSession.shared.cookieHeader()
        guard !cookie.isEmpty else {
            throw YouTubeError(kind: .notSignedIn, message: "Not signed in to YouTube Music. Sign in first.")
        }
        return cookie
    }

    static func cookieValue(_ header: String, _ name: String) -> String? {
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix(name + "=") { return String(kv.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// GFEEDBACK `logged_in` tracking param: whether YouTube treated the request as signed in.
    static func loggedInFlag(_ json: J) -> String? {
        for service in json["responseContext"]["serviceTrackingParams"].array {
            for param in service["params"].array where param["key"].string == "logged_in" {
                return param["value"].string
            }
        }
        return nil
    }

    static func sapisidHash(_ sapisid: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let input = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    /// Scrape the live YouTube Music client version + visitor data once per session, so
    /// authenticated calls aren't rejected for a stale version.
    private func ensureConfig(cookie: String) async {
        let session = Self.cookieValue(cookie, "SAPISID") ?? Self.cookieValue(cookie, "__Secure-3PAPISID") ?? ""
        if configSession == session { return }
        configSession = session
        var request = URLRequest(url: URL(string: "\(Self.origin)/?hl=en")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(YouTubeSession.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await urlSession.data(for: request), let html = String(data: data, encoding: .utf8) {
            clientVersion = html.firstMatch(of: /"INNERTUBE_CLIENT_VERSION":"([^"]+)"/).map { String($0.1) }
            visitorData = html.firstMatch(of: /"VISITOR_DATA":"([^"]+)"/).map { String($0.1) }
        }
        if clientVersion == nil { clientVersion = Self.fallbackClientVersion }
        let hasSapisid = Self.cookieValue(cookie, "SAPISID") != nil
        Diagnostics.write("session: clientVersion=\(clientVersion ?? "?") visitorData=\(visitorData != nil) SAPISID=\(hasSapisid)")
    }

    /// POST youtubei/v1/<endpoint> through the gate, retrying transient failures.
    func call(_ endpoint: String, _ body: [String: Any], priority: Bool = false) async throws -> J {
        let maxAttempts = 3
        var lastError: Error = YouTubeError.other("Request failed")
        for attempt in 1...maxAttempts {
            await gate.acquire(priority: priority)
            do {
                let result = try await perform(endpoint, body)
                await gate.release()
                return result
            } catch let error as YouTubeError {
                await gate.release()
                lastError = error
                if error.kind == .rateLimited { await gate.noteRateLimited() }
                if attempt >= maxAttempts || !error.isTransient { throw error }
                log.warning("\(endpoint, privacy: .public) transient failure (attempt \(attempt)): \(error.message, privacy: .public)")
                if error.kind != .rateLimited {
                    let backoff = 500 * (1 << (attempt - 1)) + Int.random(in: 0..<250)
                    try? await Task.sleep(for: .milliseconds(backoff))
                }
            } catch {
                await gate.release()
                throw error
            }
        }
        throw lastError
    }

    private func perform(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        let cookie = try await cookie()
        await ensureConfig(cookie: cookie)
        let version = clientVersion ?? Self.fallbackClientVersion

        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en", "gl": "US"]
        if let visitorData { client["visitorData"] = visitorData }
        var payload = body
        payload["context"] = ["client": client, "user": [String: Any]()]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(YouTubeSession.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let sapisid = Self.cookieValue(cookie, "SAPISID") ?? Self.cookieValue(cookie, "__Secure-3PAPISID") {
            request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw YouTubeError(kind: .network, message: "Network error: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            throw YouTubeError(kind: .rateLimited, message: "YouTube Music is temporarily rate-limiting requests (429).")
        }
        let json = (try? J(data: data)) ?? J(nil)
        if !(200..<300).contains(status) {
            let detail = json["error"]["message"].string ?? HTTPURLResponse.localizedString(forStatusCode: status)
            Diagnostics.write("\(endpoint) HTTP \(status): \(detail)")
            throw YouTubeError(kind: .http, message: "\(endpoint) failed with status \(status): \(detail)")
        }
        if let alert = Parsers.alertError(json) {
            Diagnostics.write("\(endpoint) \(body["browseId"] ?? "") alert: \(alert) logged_in=\(Self.loggedInFlag(json) ?? "?")")
            throw YouTubeError(kind: .youtube, message: alert)
        }
        return json
    }
}
