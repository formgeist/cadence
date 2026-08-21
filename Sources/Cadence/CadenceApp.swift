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
    /// Held for the process lifetime: access must stay open for playback, not
    /// just for the import that first granted it.
    let folders: SecurityScopedFolders

    /// Publishes to Control Center and takes the media keys. Held for the
    /// process lifetime; releasing it would hand the keys back.
    private(set) var nowPlaying: NowPlayingCoordinator?

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
        // The line PLAN.md §4 was written around: swapping the engine touches
        // nothing above this point. Preview mode keeps the mock so snapshots
        // and design review never open an audio device.
        switch mode {
        case .live:
            playback = PlaybackController(engine: SFBPlayerEngine())
            isSilentPlayback = false
        case .preview:
            playback = PlaybackController(engine: MockPlayerEngine())
            isSilentPlayback = true
        }

        switch mode {
        case .live:
            // A database that cannot be opened must not take the app down with
            // it; falling back to the preview library keeps the window usable
            // and puts the reason on screen.
            let scoped = SecurityScopedFolders()
            folders = scoped
            do {
                let store = try SQLiteLibraryStore(url: try Self.libraryURL())
                let artwork = try DiskArtworkStore(root: try DiskArtworkStore.defaultURL())
                model = AppModel(store: store)
                importer = LibraryImporter(
                    scanner: LibraryScanner(
                        store: store, artwork: artwork, router: Self.metadataRouter),
                    bookmarks: scoped)
                artworkLoader = ArtworkLoader(store: artwork)
                nowPlaying = NowPlayingCoordinator(playback: playback, artwork: artwork)
            } catch {
                model = AppModel(store: PreviewData.store())
                model.storeFailure = error.localizedDescription
                importer = LibraryImporter(scanner: nil, bookmarks: scoped)
                artworkLoader = ArtworkLoader(store: nil)
            }

        case .preview:
            folders = SecurityScopedFolders(defaultsKey: "CadencePreviewBookmarks")
            model = AppModel(store: previewStore ?? PreviewData.store())
            importer = LibraryImporter(scanner: nil, bookmarks: folders)
            artworkLoader = ArtworkLoader(store: nil)
        }
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
                .environment(\.isSilentPlayback, container.isSilentPlayback)
                .frame(minWidth: Tokens.Layout.minWindow.width,
                       minHeight: Tokens.Layout.minWindow.height)
                .preferredColorScheme(.dark)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Tokens.Layout.defaultWindow)
        .commands { CadenceCommands(container: container) }
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
        }

        CommandMenu("Playback") {
            Button(container.playback.isPlaying ? "Pause" : "Play") {
                container.playback.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

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
}
