import Foundation
import SQLite3

/// Songs already filed, per source playlist ("sorted" — they stay out of the deck across
/// launches). Skips are session-only and live in AppModel. Stored as JSON in Application Support;
/// on first launch it imports what the Glaze version kept in its WebKit localStorage.
struct ProgressStore {
    let fileURL: URL
    private(set) var sorted: [String: [String]]

    init(directory: URL = AppPaths.supportDir, glazeImport: URL? = ProgressStore.glazeLocalStorage) {
        fileURL = directory.appending(path: "progress.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            sorted = decoded
        } else {
            sorted = glazeImport.map(Self.importGlaze) ?? [:]
            if !sorted.isEmpty {
                Diagnostics.write("progress: imported \(sorted.mapValues(\.count)) from Glaze")
            }
            persist()
        }
    }

    func ids(for playlistId: String) -> Set<String> { Set(sorted[playlistId] ?? []) }

    mutating func markSorted(_ videoId: String, in playlistId: String) {
        var list = sorted[playlistId] ?? []
        guard !list.contains(videoId) else { return }
        list.append(videoId)
        sorted[playlistId] = list
        persist()
    }

    mutating func reset(_ playlistId: String) {
        sorted[playlistId] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Glaze import

    /// The Glaze app's WebKit localStorage database (keys `playlistsort:sorted:<playlistId>`).
    static var glazeLocalStorage: URL? {
        let root = URL.libraryDirectory.appending(path: "WebKit/app.glaze.macos.26m4bxft-local/WebsiteData/Default")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "localstorage.sqlite3" {
            return url
        }
        return nil
    }

    /// Reads a copy (with its WAL) so the live Glaze database is never touched.
    static func importGlaze(_ db: URL) -> [String: [String]] {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "songsort-glaze-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: db.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: tmp.appending(path: "ls.sqlite3" + suffix))
                }
            }
        } catch { return [:] }

        var handle: OpaquePointer?
        guard sqlite3_open(tmp.appending(path: "ls.sqlite3").path, &handle) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key, value FROM ItemTable WHERE key LIKE 'playlistsort:%'", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let key = String(cString: keyPtr)
            // WebKit stores values as UTF-16LE.
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
            guard let text = String(data: data, encoding: .utf16LittleEndian),
                  let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { continue }
            let playlistId: String
            if key.hasPrefix("playlistsort:sorted:") {
                playlistId = String(key.dropFirst("playlistsort:sorted:".count))
            } else if key == "playlistsort:sorted-video-ids" {
                playlistId = SongSource.likedID // pre-multi-playlist key
            } else { continue }
            result[playlistId, default: []] += ids.filter { !(result[playlistId] ?? []).contains($0) }
        }
        return result
    }
}
