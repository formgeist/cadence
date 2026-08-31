import SwiftUI
import AppKit
import CadenceCore
import CadenceLibrary
import CadenceAudio
import MediaPlayer

/// The composition root. Everything the app depends on is built here and handed
/// down through the environment, so no view ever reaches for a concrete type —
/// see PLAN.md §5.
@MainActor
final class AppContainer {
    enum Mode {
        /// The real database and artwork cache, in their usual locations.
        case live
        /// PreviewData in memory — design review and snapshots.
        case preview
    }

    let playback: PlaybackController
    let model: AppModel
    let importer: LibraryImporter
    let artworkLoader: ArtworkLoader
    /// Scrobbles what gets listened to — issue #95. Observes `playback`; the
    /// controller stays unaware of it, same as `nowPlaying`.
    let scrobble: ScrobbleController
    /// Whether a text field has the keyboard, so the menu bar can get out of
    /// its way — see `TextEntryMonitor`.
    let textEntry: TextEntryMonitor
    /// The other direction: lets ⌘K ask the search field to take the
    /// keyboard — see `SearchFocusRequester`.
    let searchFocus = SearchFocusRequester()
    /// Held for the process lifetime: access must stay open for playback, not
    /// just for the import that first granted it.
    let folders: SecurityScopedFolders

    /// Publishes to Control Center and takes the media keys. Held for the
    /// process lifetime; releasing it would hand the keys back.
    private(set) var nowPlaying: NowPlayingCoordinator?

    /// Feeds the scanner from FSEvents instead of waiting for ⌘R — issue #5.
    /// Held for the process lifetime, same reasoning as `nowPlaying`: an
    /// FSEventStream that gets released stops reporting.
    private(set) var watcher: FolderWatchCoordinator?

    /// True while playback is the mock clock rather than a decoder. The
    /// interface says so rather than pretending, because a transport that
    /// moves in silence otherwise looks like a bug.
    let isSilentPlayback: Bool

    /// FLAC goes to the pure-Swift reader, which is faster and needs no audio
    /// library; everything else SFB can decode goes to SFB. Layering in that
    /// order means the FLAC reader wins where both could serve.
    static var metadataRouter: MetadataRouter {
        MetadataRouter(SFBMetadataReader(),
                       extensions: SFBMetadataReader.supportedExtensions)
            .merging(LibraryScanner.flacOnly)
    }

    /// `--library <path>` points the app at a scratch database instead of the
    /// real one. Useful for trying an import without disturbing your library.
    static func libraryURL() throws -> URL {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--library") {
            let value = arguments.index(after: flag)
            if arguments.indices.contains(value) {
                return URL(fileURLWithPath:
                    (arguments[value] as NSString).expandingTildeInPath)
            }
        }
        return try SQLiteLibraryStore.defaultURL()
    }

    /// `store` stands in for the preview library, so a snapshot can render a
    /// library that is empty — or has no playlists — without a second
    /// composition root.
    init(mode: Mode = .live, store previewStore: (any LibraryStore)? = nil) {
        textEntry = TextEntryMonitor()

        // Preview mode keeps everything in memory, the same way it keeps the
        // mock engine — snapshots and design review should never touch the
        // user's real defaults.
        let settings: any SettingsStore
        switch mode {
        case .live: settings = UserDefaultsSettingsStore()
        case .preview: settings = InMemorySettingsStore()
        }

        // The line PLAN.md §4 was written around: swapping the engine touches
        // nothing above this point. Preview mode keeps the mock so snapshots
        // and design review never open an audio device.
        switch mode {
        case .live:
            playback = PlaybackController(engine: SFBPlayerEngine(), settings: settings)
            isSilentPlayback = false
        case .preview:
            playback = PlaybackController(engine: MockPlayerEngine(), settings: settings)
            isSilentPlayback = true
        }
        // Lets the dock menu drive playback, and lets `applicationWillTerminate`
        // flush the queue's position before quit — see #42.
        AppDelegate.playback = playback

        // Scrobbling — see #95. Preview mode gets a mock so snapshots and
        // design review never reach the network or the keychain.
        let scrobbler: any Scrobbler
        let keychain: any CadenceCore.KeychainStore
        switch mode {
        case .live:
            scrobbler = LastFMScrobbler(apiKey: LastFMCredentials.apiKey,
                                        sharedSecret: LastFMCredentials.sharedSecret)
            keychain = KeychainStore()
        case .preview:
            // Signed in to a fake service, so design review and SwiftUI
            // previews see the connected state rather than "not configured".
            scrobbler = MockScrobbler(serviceName: "Last.fm", configured: true)
            let previewKeychain = InMemoryKeychainStore()
            previewKeychain.set("preview-session", forAccount: "Last.fm")
            keychain = previewKeychain
            settings.set(true, forKey: .scrobblingEnabled)
            settings.set("preview-listener", forKey: .scrobbleUsername)
        }
        scrobble = ScrobbleController(scrobbler: scrobbler, keychain: keychain, settings: settings)
        AppDelegate.scrobble = scrobble

        switch mode {
        case .live:
            // A database that cannot be opened must not take the app down with
            // it; falling back to the preview library keeps the window usable
            // and puts the reason on screen.
            let scoped = SecurityScopedFolders()
            folders = scoped
            do {
                let store = try SQLiteLibraryStore(url: try Self.libraryURL())
                let artwork = try DiskArtworkStore.makeDefault()
                let scanner = LibraryScanner(
                    store: store, artwork: artwork, router: Self.metadataRouter)
                model = AppModel(store: store, settings: settings)
                // Removing a track from the library can orphan its cover the
                // same way a deleted file does — see pruneOrphanedArtwork's
                // own reasoning (#40). AppModel only knows the store
                // protocol, so the scanner that already holds both halves is
                // handed over as a closure rather than widening it.
                model.pruneArtwork = { [scanner] in try? await scanner.pruneOrphanedArtwork() }
                importer = LibraryImporter(scanner: scanner, bookmarks: scoped)
                artworkLoader = ArtworkLoader(store: artwork)
                nowPlaying = NowPlayingCoordinator(playback: playback, artwork: artwork)

                let coordinator = FolderWatchCoordinator(importer: importer, bookmarks: scoped)
                watcher = coordinator
                importer.onFolderAdded = { [weak coordinator] url in coordinator?.folderAdded(url) }
                importer.onFolderForgotten = { [weak coordinator] url in coordinator?.folderRemoved(url) }

                // Lets Preferences drop a folder — the bookmark side is the
                // importer's, the tracks-and-reload side is the model's. See #33.
                model.forgetFolder = { [importer] url in importer.forget(url) }
            } catch {
                model = AppModel(store: PreviewData.store(), settings: settings)
                model.storeFailure = error.localizedDescription
                importer = LibraryImporter(scanner: nil, bookmarks: scoped)
                artworkLoader = ArtworkLoader(store: nil)
            }

        case .preview:
            folders = SecurityScopedFolders(defaultsKey: "CadencePreviewBookmarks")
            model = AppModel(store: previewStore ?? PreviewData.store(), settings: settings)
            importer = LibraryImporter(scanner: nil, bookmarks: folders)
            artworkLoader = ArtworkLoader(store: nil)
        }

        // Play history is recorded here, not inside `PlaybackController`,
        // which knows nothing about `AppModel` or persistence — see #72. The
        // same start event feeds the scrobbler's "now playing" update (#95).
        playback.onTrackStarted = { [weak model = self.model, weak scrobble = self.scrobble] track in
            model?.recordPlayed(track)
            scrobble?.trackStarted(track)
        }

        // Starts the poll loop and retries anything held from last launch.
        scrobble.observe(playback)
    }
}

/// Wraps a closure as a menu item target, since NSMenuItem wants a selector.
@MainActor
final class DockAction: NSObject {
    private let handler: () -> Void
    private static var retained: [DockAction] = []

    private init(handler: @escaping () -> Void) { self.handler = handler }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = DockAction(handler: handler)
        // The menu does not own its targets, so they have to be kept alive.
        retained.append(action)
        if retained.count > 12 { retained.removeFirst(retained.count - 12) }

        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = action
        return item
    }

    @objc private func fire() { handler() }
}

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container.model)
                .environment(container.playback)
                .environment(container.importer)
                .environment(container.artworkLoader)
                .environment(container.textEntry)
                .environment(container.searchFocus)
                .environment(container.scrobble)
                .environment(\.isSilentPlayback, container.isSilentPlayback)
                .frame(minWidth: Tokens.Layout.minWindow.width,
                       minHeight: Tokens.Layout.minWindow.height)
                .preferredColorScheme(.dark)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Tokens.Layout.defaultWindow)
        .commands { CadenceCommands(container: container) }

        // Gives the "Settings…" ⌘, item under the app menu for free — see #71.
        // The window keeps its own standard title bar rather than the main
        // window's chrome, so `WindowChromeConfigurator` is deliberately absent.
        Settings {
            SettingsView()
                .environment(container.model)
                .environment(container.importer)
                .environment(container.playback)
                .environment(container.scrobble)
                .preferredColorScheme(.dark)
        }
    }
}

/// Media keys, Control Center and the dock menu are phase 5. What is here is
/// the part that costs nothing now and is irritating to live without: the
/// transport on the keyboard.
struct CadenceCommands: Commands {
    let container: AppContainer

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // ⇧⌘N rather than Music.app's ⌘N: a WindowGroup gives SwiftUI a
            // free New Window on ⌘N, and it wins the binding, so a New
            // Playlist item claiming it is a menu entry that silently does
            // something else. Taking ⌘N means dropping New Window with
            // `CommandGroup(replacing: .newItem)` — worth doing, since both
            // windows share one AppModel and mirror each other, but that is a
            // decision about the app rather than about playlists.
            Button("New Playlist…") {
                container.model.naming = .create(seed: [])
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Add Music Folder…") {
                guard let folder = container.importer.chooseFolder() else { return }
                container.importer.importFolders([folder]) {
                    Task { await container.model.load() }
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Rescan Library") {
                container.importer.rescanAll {
                    Task { await container.model.load() }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(container.importer.folders.isEmpty)

            // The way back from artwork that is no longer on disk. An ordinary
            // rescan skips every file whose size and mtime are unchanged, which
            // after a lost cover is all of them — so it walks the library and
            // re-reads nothing. Slow enough to be worth its own item rather
            // than being what ⌘R does.
            Button("Rescan Library, Re-reading Every File") {
                container.importer.rescanAllForcingReread {
                    Task { await container.model.load() }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(container.importer.folders.isEmpty)
        }

        CommandMenu("Playback") {
            // The app's only owner of bare Space. A menu key equivalent is
            // dispatched before the key window's responder chain sees the
            // event, so this item would otherwise eat every space typed into
            // the search field or the playlist name sheet. Disabled — not
            // unbound — while one of them has the keyboard: a disabled item
            // does not claim its key equivalent, and the keystroke carries on
            // down to the field.
            Button(container.playback.isPlaying ? "Pause" : "Play") {
                container.playback.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            // An open Cadence menu owns the keyboard for the same reason a
            // focused text field does: the key equivalent is dispatched before
            // any window sees the event, so Space would toggle the transport
            // from behind the menu. A disabled item does not claim its key
            // equivalent, and the keystroke reaches the menu instead.
            .disabled(container.textEntry.isEditing || MenuPresenter.shared.isPresenting)

            Button("Next Track") { container.playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Previous Track") { container.playback.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Volume Up") { container.playback.volume = min(1, container.playback.volume + 0.05) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { container.playback.volume = max(0, container.playback.volume - 0.05) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(container.playback.isMuted ? "Unmute" : "Mute") {
                container.playback.isMuted.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .control])

            Divider()

            Button("Shuffle") { container.playback.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Repeat") { container.playback.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Picker("ReplayGain", selection: Binding(
                get: { container.playback.replayGainMode },
                set: { container.playback.replayGainMode = $0 }
            )) {
                ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }

        CommandGroup(replacing: .toolbar) {
            Button("Artists") { container.model.show(.library); container.model.tab = .artists }
                .keyboardShortcut("1", modifiers: .command)
            Button("Albums") { container.model.show(.library); container.model.tab = .albums }
                .keyboardShortcut("2", modifiers: .command)
            Button("Playlists") { container.model.show(.library); container.model.tab = .playlists }
                .keyboardShortcut("3", modifiers: .command)

            Divider()

            // ⌘K rather than ⌘F: Full-Screen Artwork already sits on ⌃⌘F, and
            // ⌘K is the convention a lot of apps have converged on for
            // "focus search" — unclaimed here otherwise. See #72.
            Button("Search Library") { container.searchFocus.requestFocus() }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Full-Screen Artwork") { container.model.isImmersive.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(container.playback.currentTrack == nil)

            Button("Back") { container.model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!container.model.canGoBack)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the app so the dock menu can drive playback. Main-actor
    /// isolated: AppKit only ever asks for the dock menu on the main thread.
    @MainActor static weak var playback: PlaybackController?

    /// Set by the app so `applicationWillTerminate` can scrobble a track
    /// that's already past the threshold at quit — see #95.
    @MainActor static weak var scrobble: ScrobbleController?

    /// Held for the process lifetime — an unretained monitor is removed
    /// immediately. See `applicationDidFinishLaunching`.
    private var firstClickMonitor: Any?

    /// Play/pause, next and previous without bringing the window forward.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let playback = AppDelegate.playback, playback.currentTrack != nil else {
            return nil
        }
        let menu = NSMenu()

        if let track = playback.currentTrack {
            let heading = NSMenuItem(title: "\(track.title) — \(track.artist)",
                                     action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            menu.addItem(.separator())
        }

        menu.addItem(DockAction.item(
            playback.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() })
        menu.addItem(DockAction.item("Next") { playback.next() })
        menu.addItem(DockAction.item("Previous") { playback.previous() })
        return menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An SPM executable is not an app bundle, so it launches as an
        // accessory process with no Dock icon and no key window. Both of these
        // become unnecessary once there is a real .app target.
        if A11yHarness.parse(CommandLine.arguments) {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do { exit(try await A11yHarness.run()) }
                catch {
                    FileHandle.standardError.write(Data("a11y failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        if let options = BenchHarness.parse(CommandLine.arguments) {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do { exit(try await BenchHarness.run(options)) }
                catch {
                    FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        if let options = PlayHarness.parse(CommandLine.arguments) {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    exit(try await PlayHarness.run(options))
                } catch {
                    FileHandle.standardError.write(Data("Playback failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        if let options = ScanHarness.parse(CommandLine.arguments) {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    exit(try await ScanHarness.run(options))
                } catch {
                    FileHandle.standardError.write(Data("Scan failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        if CommandLine.arguments.contains("--audio-check") {
            NSApp.setActivationPolicy(.prohibited)
            let switchRates = CommandLine.arguments.contains("--switch-rates")

            // `--set-rate <hz>` pins the device, for checking bit-perfect
            // output against one rate — or putting a device back after a
            // switch test.
            if let flag = CommandLine.arguments.firstIndex(of: "--set-rate"),
               CommandLine.arguments.indices.contains(flag + 1),
               let rate = Double(CommandLine.arguments[flag + 1]) {
                do {
                    let deviceID = try OutputDevice.defaultOutputDeviceID()
                    let status = OutputDevice.setSampleRate(rate, on: deviceID)
                    let settled = OutputDevice.waitForSampleRate(rate, on: deviceID)
                    print("set rate:   \(Int(rate)) Hz — "
                        + (settled ? "OK" : "failed (OSStatus \(status))"))
                    exit(settled ? 0 : 1)
                } catch {
                    FileHandle.standardError.write(Data("audio check failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            do {
                let report = try OutputDevice.probe(switchRates: switchRates)
                print("device:     \(report.deviceName)")
                print("sandboxed:  \(report.isSandboxed ? "yes" : "no")")
                print("rate:       \(Int(report.currentRate)) Hz")
                print("available:  \(report.availableRates.map { String(Int($0)) }.joined(separator: ", "))")
                if let status = report.writeStatus {
                    print("set rate:   DENIED (OSStatus \(status))")
                    print("\n→ Bit-perfect output is not available here.")
                } else {
                    if switchRates {
                        print("set rate:   OK (switched, "
                            + (report.restored ? "restored" : "RESTORE FAILED") + ")")
                    } else {
                        print("set rate:   OK (same-rate write)")
                    }
                    print("\n→ Bit-perfect output is available.")
                }
                exit(report.canSetSampleRate ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("audio check failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--fonts") {
            for face in FontLoader.report() {
                print("\(face.available ? "✓" : "✗") \(face.name)")
            }
            exit(FontLoader.warmUp() ? 0 : 1)
        }

        if let directory = Snapshot.requestedDirectory {
            // Headless design QA: render every screen and exit without ever
            // showing a window.
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                print("Rendering snapshots into \(directory.path)")
                do {
                    let live = CommandLine.arguments.contains("--live")
                    let count = live
                        ? try await Snapshot.runLive(into: directory)
                        : try await Snapshot.run(into: directory)
                    if live {
                        print("\(count) written.")
                        exit(count > 0 ? 0 : 1)
                    }
                    print("\(count) of \(Snapshot.shots.count) written.")
                    exit(count == Snapshot.shots.count ? 0 : 1)
                } catch {
                    FileHandle.standardError.write(
                        Data("Snapshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // A trackpad scroll reaches a background window without activating
        // it — standard AppKit behaviour, unlike a click — so scrolling the
        // artist grid, then clicking a card, routinely lands on a window
        // that is not yet key. AppKit's own click-to-activate handling
        // swallows that click for every view SwiftUI hosts here, none of
        // which opt out via `acceptsFirstMouse(for:)`, so the click only
        // raises the window and a second one is needed to actually reach the
        // button. Making the window key before AppKit's own dispatch sees
        // the event sidesteps the swallow rather than opting out of it.
        firstClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window, !window.isKeyWindow {
                window.makeKey()
            }
            return event
        }

        // Window position and size across launches. SwiftUI has no API for
        // this on a WindowGroup, so the frame is autosaved on the NSWindow
        // once it exists.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.setFrameAutosaveName("CadenceMainWindow")
                window.isRestorable = true
            }
        }

        if !FontLoader.warmUp() {
            // Not fatal — Tokens.Typography falls back to the system face.
            FileHandle.standardError.write(Data(
                "Cadence: bundled fonts not found, falling back to the system face.\n".utf8))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A normal quit fires no engine event for `PlaybackController`'s own
    /// persistence to ride along with, so the position at the moment of
    /// quitting is flushed here instead — see #42.
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.playback?.flushQueueState()
        AppDelegate.scrobble?.flushOnTermination()
    }
}
