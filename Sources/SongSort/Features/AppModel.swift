import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum LoginState { case checking, signedOut, signedIn }
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    enum Sheet: Identifiable {
        case add(Song)
        case pickSource
        var id: String {
            switch self {
            case .add(let song): "add-\(song.videoId)"
            case .pickSource: "pick-source"
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    let client = MusicClient.shared
    let player = PreviewPlayer()
    let updater = Updater()

    private(set) var loginState: LoginState = .checking
    private(set) var accountName: String?
    var sheet: Sheet?
    private(set) var toasts: [Toast] = []

    // MARK: Deck state

    private(set) var source: SongSource = .liked
    private(set) var songs: [Song] = []
    private(set) var songsState: LoadState = .idle
    private(set) var sortedIds: Set<String> = []
    /// Session-only: skipped songs come back on relaunch, a playlist switch, or "N skipped".
    private(set) var skippedIds: Set<String> = []
    @ObservationIgnored private var progress = ProgressStore()

    // MARK: Sort options

    /// Auto-play each card's preview as soon as it's on top. Sticks across playlists.
    var autoPlay: Bool = UserDefaults.standard.bool(forKey: "autoPlay") {
        didSet {
            UserDefaults.standard.set(autoPlay, forKey: "autoPlay")
            if autoPlay, let song = activeSong, !player.isActive { player.play(song.videoId) }
        }
    }
    /// Liked Songs only: hide songs already saved to another playlist.
    var hideFiled = false {
        didSet { if hideFiled && filedIds == nil { Task { await loadFiledIds() } } }
    }
    /// Regular playlists only: adding a song elsewhere removes it from the source playlist.
    var moveMode = false
    private(set) var filedIds: Set<String>?
    private(set) var filedLoading = false

    // MARK: Library

    private(set) var playlists: [Playlist] = []
    private(set) var playlistsState: LoadState = .idle
    /// videoId → membership of every library playlist (shared by the card and the add sheet).
    private(set) var memberships: [String: [PlaylistMembership]] = [:]

    var effectiveMoveMode: Bool { moveMode && !source.isLiked }

    var queue: [Song] {
        songs.filter { song in
            if sortedIds.contains(song.videoId) || skippedIds.contains(song.videoId) { return false }
            // Only filter once membership is known, so the deck doesn't flash empty.
            if hideFiled, source.isLiked, let filedIds, filedIds.contains(song.videoId) { return false }
            return true
        }
    }

    var activeSong: Song? { queue.first }

    /// Other playlists the song is already in (the source playlist itself is left out).
    func otherPlaylists(containing song: Song) -> [Playlist] {
        (memberships[song.videoId] ?? []).filter { $0.containsSong && $0.playlist.id != source.id }.map(\.playlist)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        // Test hooks never make sound (auto-play would otherwise start a preview).
        let env = ProcessInfo.processInfo.environment
        player.muted = env["SONGSORT_SCREENSHOT"] != nil || env["SONGSORT_SELFTEST"] == "1"
        updater.start()
        if await YouTubeSession.shared.isLoggedIn() {
            await didSignIn()
        } else {
            loginState = .signedOut
        }
    }

    func signIn() async {
        guard await YouTubeSession.shared.openLogin() else { return }
        await InnerTube.shared.reset()
        await didSignIn()
        toast("Connected to YouTube Music")
    }

    private func didSignIn() async {
        loginState = .signedIn
        sortedIds = progress.ids(for: source.id)
        Task { accountName = await client.accountName() }
        await loadSongs()
        player.warmUp()
        Task { await client.prefetchMembership() }
        if ProcessInfo.processInfo.environment["SONGSORT_SELFTEST"] == "1" { Task { await selfTest() } }
        // README screenshots without UI input: open a sheet once the deck is up.
        let screenshot = ProcessInfo.processInfo.environment["SONGSORT_SCREENSHOT"]
        switch screenshot {
        case "add": if let song = activeSong { requestAdd(song) }
        case "sources": sheet = .pickSource
        default: break
        }
    }

    /// Read-only end-to-end check (see CLAUDE.md): membership for the top card, then a muted
    /// preview, all written to diagnostics.log.
    private func selfTest() async {
        guard let song = activeSong else { Diagnostics.write("selftest: no active song"); return }
        let rows = await loadMemberships(for: song) ?? []
        Diagnostics.write("selftest: \(song.videoId) “\(song.title)” in \(rows.filter(\.containsSong).map(\.playlist.title))")
        player.muted = true
        player.play(song.videoId)
        let started = ContinuousClock.now
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            Diagnostics.write("selftest: player \(player.status) progress=\(String(format: "%.2f", player.progress)) t+\(ContinuousClock.now - started)")
            if player.progress > 0.15 { break }
        }
        player.stop()
    }

    func signOut() async {
        player.teardown()
        await YouTubeSession.shared.logout()
        await InnerTube.shared.reset()
        await client.clearCaches()
        loginState = .signedOut
        accountName = nil
        songs = []
        songsState = .idle
        playlists = []
        playlistsState = .idle
        memberships = [:]
        filedIds = nil
        skippedIds = []
        sheet = nil
        selectSourceState(.liked)
        toast("Signed out")
    }

    // MARK: - Songs

    func loadSongs(force: Bool = false) async {
        let id = source.id
        songsState = .loading
        do {
            let loaded = try await client.songs(in: id, force: force)
            guard source.id == id else { return }
            songs = loaded
            songsState = .loaded
        } catch {
            guard source.id == id else { return }
            songsState = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        memberships = [:]
        filedIds = nil
        await client.clearCaches()
        await loadSongs(force: true)
        if hideFiled { await loadFiledIds() }
    }

    func selectSource(_ next: SongSource) {
        guard next.id != source.id else { return }
        selectSourceState(next)
        songs = []
        Task { await loadSongs() }
    }

    private func selectSourceState(_ next: SongSource) {
        source = next
        sortedIds = progress.ids(for: next.id)
        skippedIds = []
        moveMode = false
        hideFiled = false
    }

    private func loadFiledIds() async {
        filedLoading = true
        defer { filedLoading = false }
        do {
            filedIds = try await client.videoIdsInAnyPlaylist()
        } catch {
            hideFiled = false
            toast("Couldn't check your playlists: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Deck actions

    func skip(_ song: Song) {
        skippedIds.insert(song.videoId)
    }

    func restoreSkipped() {
        let count = skippedIds.count
        guard count > 0 else { return }
        skippedIds = []
        toast(count == 1 ? "Restored 1 skipped song" : "Restored \(count) skipped songs")
    }

    func resetProgress() {
        progress.reset(source.id)
        sortedIds = []
        skippedIds = []
        toast("Progress reset")
    }

    func requestAdd(_ song: Song) {
        sheet = .add(song)
    }

    /// Called when the top card changes: stop the old preview, maybe auto-play the new one,
    /// and fetch its playlist membership for the corner avatars.
    func activeSongChanged() {
        player.stop()
        guard let song = activeSong else { return }
        if autoPlay { player.play(song.videoId) }
        Task { await loadMemberships(for: song) }
    }

    // MARK: - Playlists

    func loadPlaylists(force: Bool = false) async {
        if playlistsState == .loading { return }
        if !force, playlistsState == .loaded { return }
        playlistsState = .loading
        do {
            playlists = try await client.playlists(force: force)
            playlistsState = .loaded
        } catch {
            playlistsState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func loadMemberships(for song: Song, force: Bool = false) async -> [PlaylistMembership]? {
        if !force, let cached = memberships[song.videoId] { return cached }
        do {
            let result = try await client.playlistsForSong(song.videoId)
            memberships[song.videoId] = result
            playlists = result.map(\.playlist).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            playlistsState = .loaded
            return result
        } catch {
            Diagnostics.write("memberships: \(song.videoId) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Adds `song` to every selected playlist (one at a time, so a failure doesn't stop the
    /// rest), then — in move mode — removes it from the source once. Returns true if any add worked.
    func add(_ song: Song, to targets: [Playlist]) async -> Bool {
        var added: [Playlist] = []
        var failed: [(Playlist, String)] = []
        for playlist in targets {
            do {
                try await client.add(song.videoId, to: playlist.id)
                added.append(playlist)
            } catch {
                failed.append((playlist, error.localizedDescription))
            }
        }
        guard !added.isEmpty else {
            toast(failed.first?.1 ?? "Couldn't add to playlist", isError: true)
            return false
        }
        let moved = await moveFromSourceIfNeeded(song)
        let verb = moved == true ? "Moved" : "Added"
        toast(added.count == 1 ? "\(verb) to \(added[0].title)" : "\(verb) to \(added.count) playlists")
        for (playlist, message) in failed { toast("\(playlist.title): \(message)", isError: true) }
        didFile(song)
        return true
    }

    func create(_ title: String, with song: Song) async -> Bool {
        do {
            _ = try await client.createPlaylist(title: title, with: song.videoId)
        } catch {
            toast(error.localizedDescription, isError: true)
            return false
        }
        let moved = await moveFromSourceIfNeeded(song)
        toast(moved == true ? "Created “\(title)” and moved the song" : "Created “\(title)” and added the song")
        playlistsState = .idle
        didFile(song)
        return true
    }

    /// nil = not in move mode; false = the removal failed (the add is kept, with a warning).
    private func moveFromSourceIfNeeded(_ song: Song) async -> Bool? {
        guard effectiveMoveMode else { return nil }
        do {
            try await client.remove(song, from: source.id)
            songs.removeAll { $0.videoId == song.videoId }
            return true
        } catch {
            toast("Couldn't remove from \(source.title): \(error.localizedDescription)", isError: true)
            return false
        }
    }

    private func didFile(_ song: Song) {
        progress.markSorted(song.videoId, in: source.id)
        sortedIds = progress.ids(for: source.id)
        memberships[song.videoId] = nil
        if filedIds != nil { filedIds?.insert(song.videoId) }
        playlistsState = .idle
    }

    // MARK: - Toasts

    func toast(_ message: String, isError: Bool = false) {
        let toast = Toast(message: message, isError: isError)
        withAnimation(.snappy) { toasts.append(toast) }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            withAnimation(.snappy) { toasts.removeAll { $0.id == toast.id } }
        }
    }
}
