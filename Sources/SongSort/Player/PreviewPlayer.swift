import AppKit
import Observation
import WebKit

/// 30-second song previews. YouTube's stream URLs are signature-ciphered (and the uncipher-free
/// mobile clients get bot-checked), so instead of fetching audio ourselves this drives YouTube
/// Music's own web player in a hidden WKWebView, signed in with the app's session. The first
/// play loads music.youtube.com (a few seconds); after that `movie_player.loadVideoById`
/// switches tracks instantly.
@MainActor
@Observable
final class PreviewPlayer: NSObject {
    enum Status: Equatable { case idle, loading, playing, paused, ad, failed }

    static let previewSeconds = 30.0
    /// Give up on a track that hasn't started after this long.
    private static let loadTimeout: Duration = .seconds(20)
    /// Free the web view (~150 MB) after this long without playback.
    private static let idleTeardown: TimeInterval = 600

    private(set) var status: Status = .idle
    /// 0…1 through the preview.
    private(set) var progress: Double = 0
    private(set) var videoId: String?

    /// Play previews in a throwaway signed-out session (keeps them out of the account's
    /// history, but YouTube may show ads).
    var signedOut: Bool {
        didSet {
            UserDefaults.standard.set(signedOut, forKey: "previewSignedOut")
            teardown()
        }
    }

    /// Test hook (SONGSORT_SELFTEST): keep the player muted.
    @ObservationIgnored var muted = false
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var loadStarted = ContinuousClock.now
    @ObservationIgnored private var sawPlayback = false

    override init() {
        signedOut = UserDefaults.standard.bool(forKey: "previewSignedOut")
        super.init()
    }

    var isActive: Bool { status == .loading || status == .playing || status == .ad }

    // MARK: - Controls

    /// Play/pause for the given song; a failed song opens in the browser instead.
    func toggle(_ id: String) {
        if videoId == id {
            switch status {
            case .playing, .loading, .ad: pause(); return
            case .failed:
                NSWorkspace.shared.open(URL(string: "https://music.youtube.com/watch?v=\(id)")!)
                return
            case .paused where progress > 0 && progress < 1:
                evaluate("document.getElementById('movie_player').playVideo()")
                status = .playing
                startPolling()
                return
            default: break
            }
        }
        play(id)
    }

    func play(_ id: String) {
        idleTimer?.invalidate()
        videoId = id
        progress = 0
        status = .loading
        sawPlayback = false
        loadStarted = .now
        let webView = ensureWebView()
        let quoted = "'\(id.replacingOccurrences(of: "'", with: ""))'"
        // On a loaded YouTube Music page the player API switches tracks in place; otherwise
        // (first use, or the page navigated away) load the watch page.
        evaluate("""
        (() => { const p = document.getElementById('movie_player');
          if (p && p.loadVideoById && location.host === 'music.youtube.com') { p.loadVideoById(\(quoted)); return true; }
          return false; })()
        """) { [weak self] result in
            guard let self, self.videoId == id, (result as? Bool) != true else { return }
            webView.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(id)")!))
        }
        startPolling()
    }

    func pause() {
        evaluate("document.getElementById('movie_player')?.pauseVideo()")
        if status != .failed { status = .paused }
        stopPolling()
    }

    /// Stop and forget the current song (the top card changed).
    func stop() {
        if webView != nil { evaluate("document.getElementById('movie_player')?.pauseVideo()") }
        videoId = nil
        status = .idle
        progress = 0
        stopPolling()
    }

    /// Load YouTube Music in the background so the first preview starts faster.
    func warmUp() {
        guard webView == nil else { return }
        ensureWebView().load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        scheduleIdleTeardown()
    }

    func teardown() {
        stop()
        webView?.stopLoading()
        webView = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Web view

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = signedOut ? .nonPersistent() : YouTubeSession.shared.dataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: config)
        webView.customUserAgent = YouTubeSession.safariUserAgent
        // WebKit only plays media for a web view that's in a window; keep that window offscreen.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.contentView = webView
        window.orderBack(nil)
        self.webView = webView
        self.window = window
        return webView
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else { completion?(nil); return }
        webView.evaluateJavaScript(script) { result, _ in
            MainActor.assumeIsolated { completion?(result) }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        scheduleIdleTeardown()
    }

    private func scheduleIdleTeardown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTeardown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isActive else { return }
                self.teardown()
            }
        }
    }

    private struct Snapshot: Decodable {
        var api: Bool
        var state: Int?
        var time: Double?
        var vid: String?
        var ad: Bool
        var error: Bool
    }

    private static let pollScript = """
    (() => { const p = document.getElementById('movie_player');
      const ad = !!document.querySelector('#movie_player.ad-showing');
      if (ad) { const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern'); if (skip) skip.click(); }
      const api = !!(p && p.getPlayerState);
      return JSON.stringify({ api, ad,
        state: api ? p.getPlayerState() : null,
        time: api ? p.getCurrentTime() : null,
        vid: api && p.getVideoData ? p.getVideoData().video_id : null,
        error: !!document.querySelector('#movie_player .ytp-error') }); })()
    """

    private func poll() {
        guard let id = videoId else { stopPolling(); return }
        // YouTube persists mute across sessions, so always assert the state we want — a
        // muted test run must not leave real previews silent.
        evaluate(muted
            ? "document.getElementById('movie_player')?.mute()"
            : "(() => { const p = document.getElementById('movie_player'); if (p && p.isMuted && p.isMuted()) p.unMute(); })()")
        evaluate(Self.pollScript) { [weak self] result in
            guard let self, self.videoId == id, self.pollTimer != nil,
                  let json = result as? String,
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) else { return }
            self.apply(snap, for: id)
        }
    }

    private func apply(_ snap: Snapshot, for id: String) {
        let onTrack = snap.vid == id
        if snap.error && onTrack {
            fail("player error")
            return
        }
        if snap.ad {
            status = .ad
            return
        }
        guard snap.api, onTrack, let state = snap.state else {
            if ContinuousClock.now - loadStarted > Self.loadTimeout { fail("timed out loading") }
            return
        }
        let time = snap.time ?? 0
        switch state {
        case 1: // playing
            sawPlayback = true
            status = .playing
            if time >= Self.previewSeconds {
                // Preview over: rewind so the next press replays it from the top.
                evaluate("(() => { const p = document.getElementById('movie_player'); p.pauseVideo(); p.seekTo(0, true); })()")
                progress = 0
                status = .paused
                stopPolling()
                return
            }
            progress = min(1, time / Self.previewSeconds)
        case 2 where sawPlayback: // paused (by us, or by the page)
            status = .paused
            stopPolling()
        case 0: // ended (track shorter than the preview)
            progress = 0
            status = .paused
            stopPolling()
        default: // -1 unstarted, 2 paused before starting (autoplay blocked), 3 buffering, 5 cued
            if !sawPlayback {
                status = .loading
                if state == 5 || state == 2 { evaluate("document.getElementById('movie_player').playVideo()") }
                if ContinuousClock.now - loadStarted > Self.loadTimeout { fail("timed out (state \(state))") }
            }
        }
    }

    private func fail(_ reason: String) {
        Diagnostics.write("preview: \(videoId ?? "?") failed — \(reason)")
        evaluate("document.getElementById('movie_player')?.pauseVideo()")
        status = .failed
        progress = 0
        stopPolling()
    }
}
