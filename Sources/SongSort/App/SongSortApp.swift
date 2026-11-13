import SwiftUI

@main
struct SongSortApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("SongSort", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 400, minHeight: 620)
                .task { await app.bootstrap() }
        }
        .defaultSize(width: 460, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await app.updater.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Sort") {
                let signedIn = app.loginState == .signedIn
                Button("Switch Playlist…") { app.sheet = .pickSource }
                    .keyboardShortcut("o")
                    .disabled(!signedIn)
                Button("Refresh") { Task { await app.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!signedIn)
                Divider()
                Button("Add to Playlist…") { if let song = app.activeSong { app.requestAdd(song) } }
                    .keyboardShortcut(.return)
                    .disabled(app.activeSong == nil || app.sheet != nil)
                Button("Skip Song") { if let song = app.activeSong { app.skip(song) } }
                    .keyboardShortcut(.delete)
                    .disabled(app.activeSong == nil || app.sheet != nil)
                Button("Play/Pause Preview") { if let song = app.activeSong { app.player.toggle(song.videoId) } }
                    .keyboardShortcut("p")
                    .disabled(app.activeSong == nil)
                Divider()
                Button("Bring Back Skipped Songs") { app.restoreSkipped() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(app.skippedIds.isEmpty)
                Button("Reset Progress for \(app.source.title)") { app.resetProgress() }
                    .disabled(app.sortedIds.isEmpty && app.skippedIds.isEmpty)
                Divider()
                Toggle("Auto-play Previews", isOn: $app.autoPlay)
                Toggle("Hide Songs Already in a Playlist", isOn: $app.hideFiled)
                    .disabled(!app.source.isLiked || !signedIn)
                Toggle("Move Instead of Copy", isOn: $app.moveMode)
                    .disabled(app.source.isLiked || !signedIn)
            }
        }

        Settings {
            SettingsView().environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.loginState {
            case .checking:
                ProgressView("Checking connection…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignedOutView()
            case .signedIn:
                MainView()
            }
        }
        .overlay { ToastOverlay() }
        .sheet(item: $app.sheet) { SheetHost(sheet: $0).environment(app) }
        .sheet(isPresented: Binding(get: { app.updater.presentedRelease != nil },
                                    set: { if !$0 { app.updater.presentedRelease = nil } })) {
            if let release = app.updater.presentedRelease { UpdateSheet(release: release).environment(app) }
        }
        .alert("Software Update", isPresented: Binding(get: { app.updater.checkMessage != nil },
                                                       set: { if !$0 { app.updater.checkMessage = nil } })) {
            Button("OK") { app.updater.checkMessage = nil }
        } message: {
            Text(app.updater.checkMessage ?? "")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        DeckScreen()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("SongSort")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { app.sheet = .pickSource } label: {
                        Label(app.source.title, systemImage: app.source.isLiked ? "heart" : "music.note.list")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Switch playlist (⌘O)")
                }
                if !app.skippedIds.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { app.restoreSkipped() } label: {
                            Label("\(app.skippedIds.count) skipped", systemImage: "arrow.uturn.backward")
                                .labelStyle(.titleAndIcon)
                                .monospacedDigit()
                        }
                        .help("Bring skipped songs back")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let name = app.accountName { Text("Signed in as \(name)") }
                        Button("Refresh") { Task { await app.refresh() } }
                        SettingsLink { Text("Settings…") }
                        Divider()
                        Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    .help("Account")
                }
            }
    }

    private var subtitle: String {
        let name = app.accountName ?? "YouTube Music"
        return app.sortedIds.isEmpty ? name : "\(name) · \(app.sortedIds.count) sorted"
    }
}

struct SignedOutView: View {
    @Environment(AppModel.self) private var app
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 18) {
            AppMark(size: 96)
            Text("SongSort").font(.largeTitle.weight(.bold))
            Text("Organize your YouTube Music likes")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Swipe through your liked songs one card at a time — right to file a song into playlists, left to skip it for now.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button {
                signingIn = true
                Task {
                    await app.signIn()
                    signingIn = false
                }
            } label: {
                Label("Sign in to YouTube Music", systemImage: "person.crop.circle")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(signingIn)
            Text("Uses the real Google sign-in page. Your password never touches SongSort.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [.pink.opacity(0.14), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var player = app.player
        Form {
            Section("Account") {
                LabeledContent("YouTube Music") {
                    Text(app.loginState == .signedIn ? (app.accountName ?? "Signed in") : "Signed out")
                }
                if app.loginState == .signedIn {
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                } else {
                    Button("Sign In…") { Task { await app.signIn() } }
                }
            }
            Section {
                Toggle("Auto-play previews", isOn: $app.autoPlay)
                Toggle("Play previews signed out", isOn: $player.signedOut)
            } header: {
                Text("Previews")
            } footer: {
                Text("Previews play through YouTube Music's web player. Signed in, they can show up in your listening history; signed out, YouTube may play ads first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
            Section("Data") {
                Button("Show Data Folder in Finder") { NSWorkspace.shared.open(AppPaths.supportDir) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
