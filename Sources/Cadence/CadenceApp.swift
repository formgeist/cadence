import SwiftUI
import AppKit
import CadenceCore

/// The composition root. Everything the app depends on is built here and handed
/// down through the environment, so no view ever reaches for a concrete type —
/// see PLAN.md §5.
@MainActor
final class AppContainer {
    let playback: PlaybackController
    let model: AppModel

    init() {
        // Phase 1 wiring: the mock engine and an in-memory store. Swapping in
        // SFBPlayerEngine and SQLiteLibraryStore is a change to these two
        // lines and nothing else.
        playback = PlaybackController(engine: MockPlayerEngine())
        model = AppModel(store: PreviewData.store())
    }
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
                .frame(minWidth: Tokens.Layout.minWindow.width,
                       minHeight: Tokens.Layout.minWindow.height)
                .preferredColorScheme(.dark)
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

        CommandGroup(after: .windowArrangement) {
            Button("Full-Screen Artwork") { container.model.isImmersive.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An SPM executable is not an app bundle, so it launches as an
        // accessory process with no Dock icon and no key window. Both of these
        // become unnecessary once there is a real .app target.
        if let directory = Snapshot.requestedDirectory {
            // Headless design QA: render every screen and exit without ever
            // showing a window.
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                print("Rendering snapshots into \(directory.path)")
                do {
                    let count = try await Snapshot.run(into: directory)
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
