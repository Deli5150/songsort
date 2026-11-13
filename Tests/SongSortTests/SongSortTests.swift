import Foundation
import SQLite3
import Testing
@testable import SongSort

private func fixture(_ name: String) throws -> J {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try J(data: Data(contentsOf: url))
}

@Suite struct ParserTests {
    @Test func playlistFirstPage() throws {
        let page = Parsers.playlistPage(try fixture("playlist"))
        #expect(page.songs.count == 100)
        #expect(page.continuation?.isEmpty == false)
        let first = try #require(page.songs.first)
        #expect(!first.videoId.isEmpty)
        #expect(first.setVideoId?.isEmpty == false)
        #expect(!first.title.isEmpty)
        #expect(first.artists != "Unknown artist")
        #expect(first.duration?.contains(":") == true)
        #expect(first.thumbnailURL?.hasPrefix("https://") == true)
    }

    @Test func playlistContinuation() throws {
        let page = Parsers.playlistContinuation(try fixture("playlist_cont"))
        #expect(page.songs.count == 100)
        #expect(page.continuation?.isEmpty == false)
        let firstPage = Parsers.playlistPage(try fixture("playlist"))
        #expect(Set(page.songs.map(\.videoId)).isDisjoint(with: firstPage.songs.map(\.videoId)))
    }

    @Test func artistsDropTrailingStats() {
        let item = J(["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": "abc", "playlistSetVideoId": "S1"],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "A"], ["text": " & "], ["text": "B"], ["text": " • "], ["text": "1.2M plays"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album"]]]]],
            ],
        ]])
        let song = Parsers.song(item)
        #expect(song?.artists == "A & B")
        #expect(song?.album == "Album")
        #expect(song?.setVideoId == "S1")
    }

    @Test func libraryPlaylistsSkipSystemTiles() {
        func tile(_ browseId: String?, _ title: String) -> [String: Any] {
            var r: [String: Any] = ["title": ["runs": [["text": title]]], "subtitle": ["runs": [["text": "Me • 3 tracks"]]]]
            if let browseId { r["navigationEndpoint"] = ["browseEndpoint": ["browseId": browseId]] }
            return ["musicTwoRowItemRenderer": r]
        }
        let json = J(["contents": ["gridRenderer": ["items": [
            tile(nil, "New playlist"), tile("VLLM", "Liked Music"), tile("VLSE", "Episodes for Later"),
            tile("VLPLabc", "Road Trip"), tile("VLPLabc", "Road Trip"), tile("MPREb_album", "An Album"),
        ], "continuations": [["nextContinuationData": ["continuation": "TOKEN"]]]]]])
        let page = Parsers.libraryPlaylists(json)
        #expect(page.playlists.map(\.id) == ["PLabc"])
        #expect(page.playlists.first?.subtitle == "Me • 3 tracks")
        #expect(page.continuation == "TOKEN")
    }

    @Test func alerts() {
        let json = J(["alerts": [["alertRenderer": ["type": "ERROR", "text": ["simpleText": "The playlist does not exist."]]]]])
        #expect(Parsers.alertError(json) == "The playlist does not exist.")
    }

    @Test func thumbnailUpgrades() {
        #expect(Parsers.upgradeThumbnail("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj")
                == "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj")
        #expect(Parsers.upgradeThumbnail("https://yt3.ggpht.com/abc=s88-c-k") == "https://yt3.ggpht.com/abc=w1200-h1200-c-k")
        #expect(Parsers.upgradeThumbnail("https://i.ytimg.com/vi/xyz/hqdefault.jpg?sqp=abc") == "https://i.ytimg.com/vi/xyz/sddefault.jpg")
        #expect(Parsers.upgradeThumbnail("//lh3.googleusercontent.com/x=s120") == "https://lh3.googleusercontent.com/x=w1200-h1200")
    }
}

@Suite struct ProgressTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "songsort-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A WebKit-style localStorage database: values are UTF-16LE blobs.
    private func makeGlazeDB(in dir: URL, _ rows: [String: [String]]) throws -> URL {
        let url = dir.appending(path: "localstorage.sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE PRIMARY KEY NOT NULL, value BLOB NOT NULL)", nil, nil, nil)
        for (key, ids) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES (?, ?)", -1, &stmt, nil)
            let value = String(data: try JSONEncoder().encode(ids), encoding: .utf8)!.data(using: .utf16LittleEndian)!
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(value.count), transient) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return url
    }

    @Test func importsGlazeProgress() throws {
        let dir = try tempDir()
        let db = try makeGlazeDB(in: dir, [
            "playlistsort:sorted:LM": ["a", "b"],
            "playlistsort:sorted:PLx": ["c"],
            "unrelated": ["z"],
        ])
        let store = ProgressStore(directory: dir, glazeImport: db)
        #expect(store.ids(for: "LM") == ["a", "b"])
        #expect(store.ids(for: "PLx") == ["c"])
        // Persisted: a second load reads progress.json, not Glaze.
        let reloaded = ProgressStore(directory: dir, glazeImport: nil)
        #expect(reloaded.ids(for: "LM") == ["a", "b"])
    }

    @Test func markAndReset() throws {
        let dir = try tempDir()
        var store = ProgressStore(directory: dir, glazeImport: nil)
        store.markSorted("v1", in: "LM")
        store.markSorted("v1", in: "LM")
        store.markSorted("v2", in: "PL1")
        #expect(store.ids(for: "LM") == ["v1"])
        store.reset("LM")
        #expect(store.ids(for: "LM").isEmpty)
        #expect(ProgressStore(directory: dir, glazeImport: nil).ids(for: "PL1") == ["v2"])
    }
}

@Suite struct UpdaterTests {
    @Test func versionCompare() {
        #expect(Updater.compare("1.0.1", "1.0.0") > 0)
        #expect(Updater.compare("v1.2.10", "1.2.9") > 0)
        #expect(Updater.compare("1.0", "1.0.0") == 0)
        #expect(Updater.compare("0.9.0", "1.0.0") < 0)
    }

    @Test func parsesRelease() throws {
        let json = """
        {"tag_name":"v1.1.0","html_url":"https://github.com/Deli5150/songsort/releases/tag/v1.1.0","body":"Notes",
         "draft":false,"prerelease":false,
         "assets":[{"name":"SongSort-1.1.0.dmg","browser_download_url":"https://example.com/SongSort-1.1.0.dmg","size":123,"digest":"sha256:abc"}]}
        """
        let release = try #require(Updater.parse(Data(json.utf8)))
        #expect(release.version == "1.1.0")
        #expect(release.sha256 == "abc")
    }
}
