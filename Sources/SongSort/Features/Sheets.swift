import SwiftUI

struct SheetHost: View {
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .add(let song): AddToPlaylistSheet(song: song)
        case .pickSource: SourcePickerSheet()
        }
    }
}

// MARK: - Add to playlist

/// Multi-select: check any number of playlists, then add (or move) to all of them at once.
/// Playlists that already hold the song are shown checked and locked.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var rows: [PlaylistMembership]?
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var creating = false
    @State private var newName = ""
    @State private var filter = ""
    @FocusState private var nameFocused: Bool

    private var move: Bool { app.effectiveMoveMode }
    private var visibleRows: [PlaylistMembership] {
        guard let rows else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? rows : rows.filter { $0.playlist.title.localizedCaseInsensitiveContains(q) }
    }
    private var targets: [Playlist] {
        (rows ?? []).filter { selected.contains($0.id) && !$0.containsSong }.map(\.playlist)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RemoteImage(url: song.thumbnailURL, maxPixel: 120) { Rectangle().fill(.quaternary) }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(move ? "Move to playlist" : "Add to playlist").font(.headline)
                Text(song.title).lineLimit(1)
                Text(song.artists).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if move {
                    Text("Will remove from \(app.source.title) after adding").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if creating {
            VStack(alignment: .leading, spacing: 12) {
                Text("New playlist").font(.headline)
                TextField("Playlist name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { Task { await create() } }
                Text("New playlists are private. You can change that in YouTube Music.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .onAppear { nameFocused = true }
        } else if let loadError {
            ContentUnavailableView {
                Label("Couldn't load playlists", systemImage: "exclamationmark.triangle")
            } description: { Text(loadError) } actions: {
                Button("Try Again") { Task { await load(force: true) } }
            }
            .frame(maxHeight: .infinity)
        } else if rows == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading playlists…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows?.isEmpty == true {
            ContentUnavailableView {
                Label("No playlists yet", systemImage: "music.note.list")
            } actions: {
                Button("New Playlist") { creating = true }.buttonStyle(.glassProminent)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if (rows?.count ?? 0) > 8 {
                    TextField("Filter playlists", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                List(visibleRows) { row in
                    PlaylistRow(row: row, checked: row.containsSong || selected.contains(row.id)) {
                        guard !row.containsSong, !busy else { return }
                        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
                    }
                    .disabled(busy)
                }
                .listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack {
            if creating {
                Button("Back") { creating = false; newName = "" }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(move ? "Create & Move" : "Create & Add") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            } else {
                Button { creating = true } label: { Label("New Playlist", systemImage: "plus") }
                    .disabled(busy)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if busy { ProgressView().controlSize(.small) }
                Button(confirmLabel) { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(targets.isEmpty || busy)
            }
        }
        .padding(16)
    }

    private var confirmLabel: String {
        let verb = move ? "Move" : "Add"
        switch targets.count {
        case 0: return verb
        case 1: return "\(verb) to 1 Playlist"
        default: return "\(verb) to \(targets.count) Playlists"
        }
    }

    private func load(force: Bool = false) async {
        loadError = nil
        if let result = await app.loadMemberships(for: song, force: force) {
            rows = result
        } else {
            loadError = "YouTube Music didn't respond. Check your connection and try again."
        }
    }

    private func confirm() async {
        busy = true
        let ok = await app.add(song, to: targets)
        busy = false
        if ok { dismiss() }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !busy else { return }
        busy = true
        let ok = await app.create(name, with: song)
        busy = false
        if ok { dismiss() }
    }
}

private struct PlaylistRow: View {
    let row: PlaylistMembership
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                PlaylistArtwork(url: row.playlist.thumbnailURL, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.playlist.title).lineLimit(1)
                    if row.containsSong {
                        Text("Already in playlist").font(.caption).foregroundStyle(.secondary)
                    } else if let subtitle = row.playlist.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? (row.containsSong ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.containsSong ? 0.7 : 1)
        .accessibilityLabel(row.containsSong ? "\(row.playlist.title), already in playlist" : row.playlist.title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

// MARK: - Source picker

struct SourcePickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filtered: [Playlist] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? app.playlists : app.playlists.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Organize playlist").font(.headline)
                Spacer()
                Button { Task { await app.loadPlaylists(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload playlists")
                    .disabled(app.playlistsState == .loading)
            }
            .padding([.horizontal, .top], 16)
            TextField("Filter playlists", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(16)
            Divider()
            List {
                row(id: SongSource.likedID, title: SongSource.liked.title, subtitle: "Your liked tracks") {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.pink.gradient, in: RoundedRectangle(cornerRadius: 6))
                }
                switch app.playlistsState {
                case .failed(let message):
                    Text(message).foregroundStyle(.red).font(.callout)
                case .loaded:
                    ForEach(filtered) { playlist in
                        row(id: playlist.id, title: playlist.title, subtitle: playlist.subtitle) {
                            PlaylistArtwork(url: playlist.thumbnailURL, size: 36)
                        }
                    }
                default:
                    HStack { Spacer(); ProgressView().controlSize(.small); Text("Loading playlists…").foregroundStyle(.secondary); Spacer() }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 420, height: 540)
        .task { await app.loadPlaylists() }
    }

    private func row(id: String, title: String, subtitle: String?, @ViewBuilder icon: () -> some View) -> some View {
        Button {
            app.selectSource(SongSource(id: id, title: title))
            dismiss()
        } label: {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if id == app.source.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Currently organizing")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
