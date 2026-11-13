import AppKit
import SwiftUI

/// The main screen once signed in: a deck state (loading / error / empty / all sorted) or the
/// swipeable card deck.
struct DeckScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.songsState {
            case .idle, .loading where app.songs.isEmpty:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading \(app.source.title)…").foregroundStyle(.secondary)
                    Text("Large playlists can take a moment").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where app.songs.isEmpty:
                ContentUnavailableView {
                    Label("Couldn't load \(app.source.title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await app.loadSongs(force: true) } }
                        .buttonStyle(.glassProminent)
                    Button("Sign Out") { Task { await app.signOut() } }
                }
            default:
                if app.songs.isEmpty {
                    ContentUnavailableView {
                        Label(app.source.isLiked ? "No liked songs" : "Empty playlist", systemImage: "music.note")
                    } description: {
                        Text(app.source.isLiked
                             ? "Like songs in YouTube Music, then come back to sort them."
                             : "\(app.source.title) has no songs yet.")
                    } actions: {
                        if !app.source.isLiked {
                            Button("Switch Playlist") { app.sheet = .pickSource }.buttonStyle(.glassProminent)
                        }
                    }
                } else if app.queue.isEmpty {
                    ContentUnavailableView {
                        Label("All sorted for now", systemImage: "checkmark.seal")
                    } description: {
                        Text(app.skippedIds.isEmpty
                             ? "You've filed every song in \(app.source.title)."
                             : "Skipped songs come back next launch. Reset progress to revisit sorted ones.")
                    } actions: {
                        if !app.sortedIds.isEmpty || !app.skippedIds.isEmpty {
                            Button { app.resetProgress() } label: { Label("Reset Progress", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    CardDeck()
                }
            }
        }
        .onChange(of: app.activeSong?.videoId, initial: true) { app.activeSongChanged() }
    }
}

// MARK: - Deck

struct CardDeck: View {
    @Environment(AppModel.self) private var app
    @State private var dragX: CGFloat = 0
    @State private var exiting = false
    @State private var keyMonitor: Any?

    private static let swipeThreshold: CGFloat = 110
    private static let exitDistance: CGFloat = 640

    var body: some View {
        let queue = app.queue
        VStack(spacing: 0) {
            ZStack {
                if queue.count > 1 {
                    SongCard(song: queue[1], memberships: [])
                        .scaleEffect(0.95)
                        .offset(y: 10)
                        .opacity(0.6)
                        .allowsHitTesting(false)
                        .id(queue[1].videoId)
                }
                if let song = queue.first {
                    topCard(song)
                        .id(song.videoId)
                }
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ActionBar(onSkip: { swipe(right: false) }, onAdd: { swipe(right: true) }, exiting: exiting)
                .padding(.bottom, 10)

            Text("Swipe · ← skip · → add · Space play · \(queue.count) left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .padding(.bottom, 12)
        }
        .onChange(of: app.activeSong?.videoId) {
            withTransaction(Transaction(animation: nil)) {
                dragX = 0
                exiting = false
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func topCard(_ song: Song) -> some View {
        let like = max(0, min(1, dragX / Self.swipeThreshold))
        let skip = max(0, min(1, -dragX / Self.swipeThreshold))
        return SongCard(song: song, memberships: app.otherPlaylists(containing: song))
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: SongCard.radius).fill(.green.opacity(0.28 * like))
                    RoundedRectangle(cornerRadius: SongCard.radius).fill(.red.opacity(0.28 * skip))
                    Stamp(text: "ADD", systemImage: "checkmark", color: .green, angle: -6)
                        .opacity(like)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 18)
                    Stamp(text: "SKIP", systemImage: "xmark", color: .red, angle: 6)
                        .opacity(skip)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 18)
                }
                .allowsHitTesting(false)
            }
            .offset(x: dragX)
            .rotationEffect(.degrees(Double(max(-14, min(14, dragX / 18)))), anchor: .bottom)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard !exiting else { return }
                        dragX = value.translation.width
                    }
                    .onEnded { _ in
                        guard !exiting else { return }
                        if dragX >= Self.swipeThreshold { swipe(right: true) }
                        else if dragX <= -Self.swipeThreshold { swipe(right: false) }
                        else { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { dragX = 0 } }
                    }
            )
    }

    /// Fling the top card off, then skip it or open the add sheet. The add path snaps the
    /// card back first, so dismissing the sheet leaves the song on the deck.
    private func swipe(right: Bool) {
        guard let song = app.activeSong, !exiting else { return }
        exiting = true
        withAnimation(.easeOut(duration: 0.22)) { dragX = right ? Self.exitDistance : -Self.exitDistance }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if right {
                withTransaction(Transaction(animation: nil)) { dragX = 0 }
                exiting = false
                app.requestAdd(song)
            } else {
                app.skip(song)
            }
        }
    }

    // MARK: Keyboard (← skip, → add, Space play)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText), app.sheet == nil else { return event }
            switch event.keyCode {
            case 123: swipe(right: false); return nil
            case 124: swipe(right: true); return nil
            case 49:
                if let song = app.activeSong { app.player.toggle(song.videoId) }
                return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct Stamp: View {
    let text: String
    let systemImage: String
    let color: Color
    let angle: Double

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.title2.weight(.heavy))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8, y: 3)
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Card

struct SongCard: View {
    static let radius: CGFloat = 28
    let song: Song
    let memberships: [Playlist]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .overlay {
                    RemoteImage(url: song.thumbnailURL, maxPixel: 900) {
                        Rectangle().fill(.quaternary).overlay {
                            Image(systemName: "music.note").font(.system(size: 48)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if !memberships.isEmpty {
                        MembershipStack(playlists: memberships).padding(12)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(song.artists).foregroundStyle(.secondary).lineLimit(1)
                if let album = song.album {
                    Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let duration = song.duration {
                    Text(duration).font(.caption).foregroundStyle(.tertiary).monospacedDigit().padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .contextMenu {
            Button("Open in YouTube Music") { NSWorkspace.shared.open(song.watchURL) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(song.watchURL.absoluteString, forType: .string)
            }
        }
    }
}

/// Avatars of the other playlists a song is already in; hovering lists all of them.
private struct MembershipStack: View {
    let playlists: [Playlist]
    @State private var hovering = false

    private static let maxVisible = 4

    var body: some View {
        let overflow = playlists.count > Self.maxVisible
        let visible = overflow ? Array(playlists.prefix(Self.maxVisible - 1)) : playlists
        let label = playlists.count == 1 ? "In \(playlists[0].title)" : "In \(playlists.count) playlists"
        ZStack(alignment: .topTrailing) {
            HStack(spacing: -10) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, playlist in
                    PlaylistArtwork(url: playlist.thumbnailURL, size: 28, circle: true)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                        .zIndex(Double(visible.count - index))
                }
                if overflow {
                    Text("+\(playlists.count - visible.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                }
            }
            .opacity(hovering ? 0 : 1)

            if hovering {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(playlists) { playlist in
                                HStack(spacing: 8) {
                                    PlaylistArtwork(url: playlist.thumbnailURL, size: 20, circle: true)
                                    Text(playlist.title).font(.caption).lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(width: 220, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .transition(.scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { hovering = inside } }
        .accessibilityLabel(label)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @Environment(AppModel.self) private var app
    let onSkip: () -> Void
    let onAdd: () -> Void
    let exiting: Bool
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 16) {
            Button { showOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Sort options")
                .popover(isPresented: $showOptions, arrowEdge: .top) { SortOptions().environment(app) }

            Button(action: onSkip) { Image(systemName: "xmark").font(.title2.weight(.semibold)).frame(width: 30, height: 30) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .help("Skip for now (←)")
                .disabled(exiting)

            PlayButton()

            Button(action: onAdd) { Image(systemName: "checkmark").font(.title2.weight(.semibold)).frame(width: 30, height: 30) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .help("Add to playlist (→)")
                .disabled(exiting)

            Button { app.resetProgress() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Reset progress for \(app.source.title)")
                .opacity(app.sortedIds.isEmpty ? 0 : 1)
                .disabled(app.sortedIds.isEmpty)
        }
    }
}

private struct PlayButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let song = app.activeSong
        let current = song != nil && player.videoId == song?.videoId
        let status = current ? player.status : .idle
        let busy = status == .loading || status == .ad
        ZStack {
            if current && (busy || status == .playing || player.progress > 0) {
                ProgressRing(progress: player.progress, spinning: busy)
                    .frame(width: 62, height: 62)
            }
            Button {
                if let song { player.toggle(song.videoId) }
            } label: {
                Image(systemName: icon(status))
                    .font(.title2.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .help(help(status))
        }
        .frame(width: 62, height: 62)
        .overlay(alignment: .bottom) {
            if status == .ad {
                Text("Ad").font(.caption2.weight(.bold)).foregroundStyle(.secondary).offset(y: 14)
            }
        }
    }

    private func icon(_ status: PreviewPlayer.Status) -> String {
        switch status {
        case .playing, .loading, .ad: "pause.fill"
        case .failed: "arrow.up.forward.app"
        default: "play.fill"
        }
    }

    private func help(_ status: PreviewPlayer.Status) -> String {
        switch status {
        case .playing, .loading, .ad: "Pause preview (Space)"
        case .failed: "Couldn't play here — open in YouTube Music"
        default: "Play 30-second preview (Space)"
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    let spinning: Bool
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: spinning ? 0.25 : progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90 + (spinning ? angle : 0)))
                .animation(spinning ? nil : .linear(duration: 0.25), value: progress)
        }
        .onAppear { startSpin() }
        .onChange(of: spinning) { startSpin() }
    }

    private func startSpin() {
        angle = 0
        guard spinning else { return }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
    }
}

// MARK: - Sort options

struct SortOptions: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            Text("Sort options").font(.caption).foregroundStyle(.secondary)
            Toggle("Auto-play preview when the next song appears", isOn: $app.autoPlay)
            if app.source.isLiked {
                HStack {
                    Toggle("Hide songs already in another playlist", isOn: $app.hideFiled)
                    if app.filedLoading { ProgressView().controlSize(.small) }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Remove from this playlist when adding elsewhere", isOn: $app.moveMode)
                    .disabled(app.source.isLiked)
                if app.source.isLiked {
                    Text("Only for regular playlists").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 320)
    }
}
