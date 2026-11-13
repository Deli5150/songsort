import Foundation

/// Everything that knows YouTube Music's (WEB_REMIX) response shapes. If YouTube changes a
/// shape, this file and MusicClient.swift are the only places that should need to change.
enum Parsers {
    // MARK: - Errors

    /// YouTube reports soft failures as alert renderers inside a 200 response.
    static func alertError(_ json: J) -> String? {
        for alert in json["alerts"].array {
            let renderer = alert["alertRenderer"].exists ? alert["alertRenderer"] : alert["alertWithButtonRenderer"]
            if renderer["type"].string == "ERROR", let text = renderer["text"].text { return text }
        }
        return nil
    }

    // MARK: - Playlist songs

    struct SongPage {
        var songs: [Song]
        var continuation: String?
    }

    /// First page of a playlist browse (`VL<id>`, `VLLM` for Liked Songs). Only the playlist
    /// shelf counts: owned playlists also carry a "Suggestions" shelf that isn't part of it.
    static func playlistPage(_ json: J) -> SongPage {
        let shelf = json.first("musicPlaylistShelfRenderer") ?? J(nil)
        var items = shelf["contents"].array
        if items.isEmpty {
            // Older shape: a plain musicShelfRenderer holds the tracks.
            items = (json.first("musicShelfRenderer") ?? J(nil))["contents"].array
        }
        var continuation = continuationToken(in: items)
        if continuation == nil {
            continuation = shelf["continuations"][0]["nextContinuationData"]["continuation"].string
        }
        return SongPage(songs: items.compactMap(song), continuation: continuation)
    }

    /// A playlist continuation page (`browse` with `continuation`).
    static func playlistContinuation(_ json: J) -> SongPage {
        var items: [J] = []
        for action in json["onResponseReceivedActions"].array {
            items += action["appendContinuationItemsAction"]["continuationItems"].array
        }
        var continuation = continuationToken(in: items)
        if items.isEmpty {
            let legacy = json["continuationContents"]["musicPlaylistShelfContinuation"]
            items = legacy["contents"].array
            continuation = legacy["continuations"][0]["nextContinuationData"]["continuation"].string
        }
        return SongPage(songs: items.compactMap(song), continuation: continuation)
    }

    static func continuationToken(in items: [J]) -> String? {
        for item in items.reversed() {
            let c = item["continuationItemRenderer"]
            if c.exists {
                return c["continuationEndpoint"]["continuationCommand"]["token"].string
                    ?? c.first("token")?.string
            }
        }
        return nil
    }

    static func song(_ item: J) -> Song? {
        let r = item["musicResponsiveListItemRenderer"]
        guard r.exists else { return nil }
        let flex = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        let videoId = r["playlistItemData"]["videoId"].string
            ?? r["overlay"].first("watchEndpoint")?["videoId"].string
            ?? flex.first?.first("watchEndpoint")?["videoId"].string
        guard let videoId, let title = flex.first?.text else { return nil }

        // Column 1 is "Artist & Artist" for tracks, sometimes followed by " • 1.2M plays".
        let artistText = flex.count > 1 ? flex[1].text : nil
        let artists = artistText?.components(separatedBy: " • ").first?.trimmingCharacters(in: .whitespaces)
        let album = flex.count > 2 ? flex[2].text : nil
        let duration = r["fixedColumns"][0]["musicResponsiveListItemFixedColumnRenderer"]["text"].text

        return Song(
            videoId: videoId,
            setVideoId: r["playlistItemData"]["playlistSetVideoId"].string,
            title: title,
            artists: (artists?.isEmpty == false ? artists : nil) ?? "Unknown artist",
            album: album,
            thumbnailURL: bestThumbnail(r["thumbnail"]),
            duration: duration
        )
    }

    // MARK: - Library playlists

    struct PlaylistPage {
        var playlists: [Playlist]
        var continuation: String?
    }

    /// Library playlists (`FEmusic_liked_playlists`) — grid of two-row items, or a list.
    /// Liked Music, Episodes for Later and the "New playlist" tile are left out.
    static func libraryPlaylists(_ json: J) -> PlaylistPage {
        var playlists: [Playlist] = []
        var seen = Set<String>()
        func add(_ p: Playlist?) {
            guard let p, !seen.contains(p.id) else { return }
            seen.insert(p.id)
            playlists.append(p)
        }
        for item in json.all("musicTwoRowItemRenderer") { add(twoRowPlaylist(item)) }
        for item in json.all("musicResponsiveListItemRenderer") { add(listPlaylist(item)) }

        let grid = json.first("gridRenderer") ?? json.first("gridContinuation") ?? J(nil)
        var continuation = grid["continuations"][0]["nextContinuationData"]["continuation"].string
        if continuation == nil, let c = json.first("continuationItemRenderer") {
            continuation = c.first("token")?.string
        }
        return PlaylistPage(playlists: playlists, continuation: continuation)
    }

    private static func playlistID(fromBrowseId browseId: String?) -> String? {
        guard let browseId, browseId.hasPrefix("VL") else { return nil }
        let id = String(browseId.dropFirst(2))
        return (id == SongSource.likedID || id == "SE" || id.isEmpty) ? nil : id
    }

    static func twoRowPlaylist(_ r: J) -> Playlist? {
        guard let id = playlistID(fromBrowseId: r["navigationEndpoint"]["browseEndpoint"]["browseId"].string),
              let title = r["title"].text else { return nil }
        return Playlist(id: id, title: title,
                        thumbnailURL: bestThumbnail(r["thumbnailRenderer"]),
                        subtitle: r["subtitle"].text)
    }

    static func listPlaylist(_ r: J) -> Playlist? {
        guard let id = playlistID(fromBrowseId: r["navigationEndpoint"]["browseEndpoint"]["browseId"].string) else { return nil }
        let flex = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        guard let title = flex.first?.text else { return nil }
        return Playlist(id: id, title: title, thumbnailURL: bestThumbnail(r["thumbnail"]),
                        subtitle: flex.count > 1 ? flex[1].text : nil)
    }

    // MARK: - Misc

    static func accountName(_ json: J) -> String? {
        json.first("activeAccountHeaderRenderer")?["accountName"].text ?? json.first("accountName")?.text
    }

    static func createdPlaylistID(_ json: J) -> String? {
        json["playlistId"].string
    }

    static func editSucceeded(_ json: J) -> Bool {
        json["status"].string == "STATUS_SUCCEEDED"
    }

    // MARK: - Thumbnails

    /// Largest thumbnail under `node` (any musicThumbnailRenderer nesting), upgraded to cover size.
    static func bestThumbnail(_ node: J) -> String? {
        let thumbs = node.first("thumbnails")?.array ?? []
        let best = thumbs.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        return best?["url"].string.map { upgradeThumbnail($0) }
    }

    /// Target size for cover art — exceeds a Retina card width with headroom.
    static let coverSize = 1200

    static func upgradeThumbnail(_ url: String) -> String {
        var url = url
        if url.hasPrefix("//") { url = "https:" + url }
        // googleusercontent / ggpht square token (=s120-c, =s88 …), keeping trailing flags.
        if let m = url.firstMatch(of: /=s\d+((?:-[^\/?#]*)?)/) {
            return url.replacingCharacters(in: m.range, with: "=w\(coverSize)-h\(coverSize)\(m.1)")
        }
        // width×height token (=w60-h60-l90-rj …).
        if let m = url.firstMatch(of: /=w\d+-h\d+/) {
            return url.replacingCharacters(in: m.range, with: "=w\(coverSize)-h\(coverSize)")
        }
        // i.ytimg.com video thumbs: sddefault exists for every video; maxres 404s on many.
        if url.contains("i.ytimg.com/"),
           let m = url.firstMatch(of: /\/(default|mqdefault|hqdefault|sddefault|hq720|maxresdefault)(\.[a-z]+)(?:[?#].*)?$/.ignoresCase()) {
            return url.replacingCharacters(in: m.range, with: "/sddefault\(m.2)")
        }
        return url
    }
}
