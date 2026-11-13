import Foundation

/// Every YouTube Music endpoint SongSort uses, plus the in-memory caches the deck relies on
/// (playlist songs, the library list, and per-playlist membership sets).
actor MusicClient {
    static let shared = MusicClient()

    private let api = InnerTube.shared
    private var songsCache: [String: [Song]] = [:]
    private var playlistsCache: [Playlist]?
    /// playlistId → (videoId → setVideoId). Membership "is this song in that playlist" checks.
    private var membership: [String: [String: String]] = [:]
    private var membershipInFlight: [String: Task<[String: String], Error>] = [:]
    private var playlistsInFlight: Task<[Playlist], Error>?

    static let maxPages = 60

    func clearCaches() {
        songsCache = [:]
        playlistsCache = nil
        membership = [:]
        membershipInFlight = [:]
        playlistsInFlight = nil
    }

    // MARK: - Account

    func accountName() async -> String? {
        guard let json = try? await api.call("account/account_menu", [:], priority: true) else { return nil }
        return Parsers.accountName(json)
    }

    // MARK: - Songs

    /// All songs in a playlist (or Liked Songs), following continuations.
    func songs(in playlistId: String, force: Bool = false) async throws -> [Song] {
        if !force, let cached = songsCache[playlistId] { return cached }
        let songs = try await fetchSongs(playlistId, priority: true)
        songsCache[playlistId] = songs
        membership[playlistId] = Dictionary(songs.map { ($0.videoId, $0.setVideoId ?? "") }, uniquingKeysWith: { a, _ in a })
        Diagnostics.write("songs: \(playlistId) → \(songs.count)")
        return songs
    }

    private func fetchSongs(_ playlistId: String, priority: Bool) async throws -> [Song] {
        let first = try await api.call("browse", ["browseId": "VL\(playlistId)"], priority: priority)
        var page = Parsers.playlistPage(first)
        var songs = page.songs
        var pages = 0
        while let token = page.continuation, pages < Self.maxPages {
            let next = try await api.call("browse", ["continuation": token], priority: priority)
            page = Parsers.playlistContinuation(next)
            songs += page.songs
            pages += 1
        }
        var seen = Set<String>()
        return songs.filter { seen.insert($0.videoId).inserted }
    }

    // MARK: - Library playlists

    func playlists(force: Bool = false) async throws -> [Playlist] {
        if !force, let playlistsCache { return playlistsCache }
        if let playlistsInFlight { return try await playlistsInFlight.value }
        let task = Task { try await self.fetchPlaylists() }
        playlistsInFlight = task
        defer { playlistsInFlight = nil }
        let result = try await task.value
        playlistsCache = result
        return result
    }

    private func fetchPlaylists() async throws -> [Playlist] {
        let first = try await api.call("browse", ["browseId": "FEmusic_liked_playlists"], priority: true)
        var page = Parsers.libraryPlaylists(first)
        var playlists = page.playlists
        var pages = 0
        while let token = page.continuation, pages < 10 {
            let next = try await api.call("browse", ["continuation": token], priority: true)
            page = Parsers.libraryPlaylists(next)
            for p in page.playlists where !playlists.contains(where: { $0.id == p.id }) { playlists.append(p) }
            pages += 1
        }
        Diagnostics.write("playlists: \(playlists.count)")
        return playlists.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Membership

    private func members(of playlistId: String) async throws -> [String: String] {
        if let cached = membership[playlistId] { return cached }
        if let task = membershipInFlight[playlistId] { return try await task.value }
        let task = Task { () throws -> [String: String] in
            let songs = try await self.fetchSongs(playlistId, priority: false)
            return Dictionary(songs.map { ($0.videoId, $0.setVideoId ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        membershipInFlight[playlistId] = task
        defer { membershipInFlight[playlistId] = nil }
        let ids = try await task.value
        membership[playlistId] = ids
        return ids
    }

    /// Cached membership only — no network. Lets the deck show what's already known instantly.
    func knownMemberships(of videoId: String) -> Set<String> {
        Set(membership.compactMap { $0.value[videoId] != nil ? $0.key : nil })
    }

    /// Every library playlist, flagged with whether it already holds `videoId`.
    /// Already-containing playlists sort first, then A–Z.
    func playlistsForSong(_ videoId: String) async throws -> [PlaylistMembership] {
        let playlists = try await playlists()
        let sets = await loadMembership(playlists)
        let result = playlists.map { PlaylistMembership(playlist: $0, containsSong: sets[$0.id]?[videoId] != nil) }
        return result.sorted { a, b in
            if a.containsSong != b.containsSong { return a.containsSong }
            return a.playlist.title.localizedCaseInsensitiveCompare(b.playlist.title) == .orderedAscending
        }
    }

    /// Union of video ids across every library playlist (Liked Songs excluded).
    func videoIdsInAnyPlaylist() async throws -> Set<String> {
        let sets = await loadMembership(try await playlists())
        return sets.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
    }

    /// Load membership for many playlists concurrently (the gate paces it). A playlist that
    /// fails to load counts as not containing anything rather than failing the whole check.
    private func loadMembership(_ playlists: [Playlist]) async -> [String: [String: String]] {
        await withTaskGroup(of: (String, [String: String]?).self) { group in
            for p in playlists {
                group.addTask {
                    do { return (p.id, try await self.members(of: p.id)) } catch {
                        Diagnostics.write("membership: \(p.id) failed: \(error.localizedDescription)")
                        return (p.id, nil)
                    }
                }
            }
            var out: [String: [String: String]] = [:]
            for await (id, ids) in group { if let ids { out[id] = ids } }
            return out
        }
    }

    /// Warm a handful of playlists after sign-in so the first add sheet is quick.
    func prefetchMembership(limit: Int = 8) async {
        guard let playlists = try? await playlists() else { return }
        _ = await loadMembership(Array(playlists.prefix(limit)))
    }

    // MARK: - Edits

    func add(_ videoId: String, to playlistId: String) async throws {
        let json = try await api.call("browse/edit_playlist", [
            "playlistId": playlistId,
            "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId, "dedupeOption": "DEDUPE_OPTION_SKIP"]],
        ], priority: true)
        guard Parsers.editSucceeded(json) else { throw YouTubeError.other("YouTube Music didn't accept the change.") }
        // The song may have given an empty playlist its first cover, so the list is stale too.
        // Only patch a fully loaded set; a partial one would pass for the whole playlist.
        if membership[playlistId] != nil, membership[playlistId]?[videoId] == nil {
            membership[playlistId]?[videoId] = ""
        }
        songsCache[playlistId] = nil
        playlistsCache = nil
        Diagnostics.write("add: \(videoId) → \(playlistId)")
    }

    func remove(_ song: Song, from playlistId: String) async throws {
        guard playlistId != SongSource.likedID else { throw YouTubeError.other("Liked Songs can't be edited this way.") }
        var setVideoId = song.setVideoId ?? membership[playlistId]?[song.videoId]
        if setVideoId?.isEmpty != false {
            membership[playlistId] = nil
            setVideoId = try await members(of: playlistId)[song.videoId]
        }
        guard let setVideoId, !setVideoId.isEmpty else { throw YouTubeError.other("The song isn't in that playlist anymore.") }
        let json = try await api.call("browse/edit_playlist", [
            "playlistId": playlistId,
            "actions": [["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": song.videoId]],
        ], priority: true)
        guard Parsers.editSucceeded(json) else { throw YouTubeError.other("YouTube Music didn't accept the change.") }
        membership[playlistId]?[song.videoId] = nil
        songsCache[playlistId]?.removeAll { $0.videoId == song.videoId }
        playlistsCache = nil
        Diagnostics.write("remove: \(song.videoId) ✕ \(playlistId)")
    }

    /// Creates a private playlist holding `videoId`; returns its id.
    func createPlaylist(title: String, with videoId: String) async throws -> String {
        let json = try await api.call("playlist/create", [
            "title": title, "description": "", "privacyStatus": "PRIVATE", "videoIds": [videoId],
        ], priority: true)
        guard let id = Parsers.createdPlaylistID(json) else { throw YouTubeError.other("Couldn't create the playlist.") }
        membership[id] = [videoId: ""]
        playlistsCache = nil
        Diagnostics.write("create: \(id)")
        return id
    }
}
