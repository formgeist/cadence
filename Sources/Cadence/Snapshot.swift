import SwiftUI
import AppKit
import CadenceCore

/// Renders the interface offscreen to PNGs and exits:
///
/// ```bash
/// swift run Cadence --snapshot ~/Desktop/cadence-shots
/// ```
///
/// This exists because the design is the product. Checking every screen
/// against `PreviewData` — the box set, the compilation, the title long enough
/// to wrap — is something to do on every change, and it should not require
/// clicking through the app to find out that a layout broke.
@MainActor
enum Snapshot {

    /// Each shot names the state it captures, so a diff of the output folder
    /// reads as a list of what changed.
    struct Shot {
        var name: String
        var size: CGSize
        var configure: (AppContainer) -> Void
    }

    static let shots: [Shot] = [
        Shot(name: "01-library-artists", size: Tokens.Layout.defaultWindow) { _ in },

        Shot(name: "02-library-albums", size: Tokens.Layout.defaultWindow) { container in
            container.model.tab = .albums
        },

        Shot(name: "03-library-playlists", size: Tokens.Layout.defaultWindow) { container in
            container.model.tab = .playlists
        },

        // The album the design was drawn against.
        Shot(name: "04-album-design-reference", size: Tokens.Layout.defaultWindow) { container in
            // Year required: the preview library holds a 2025 remaster under
            // the same title, which is the whole point of Album.Key.
            open(container, album: "Sound of the Slow Hours", year: 2023)
        },

        Shot(name: "04b-album-remaster", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Sound of the Slow Hours", year: 2025)
        },

        // Three discs. A flat track list gets this wrong.
        Shot(name: "05-album-box-set", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "The Complete Aldeburgh Recordings")
        },

        // Various Artists: every row needs its own artist line.
        Shot(name: "06-album-compilation", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Nordic Ambient, Vol. 4")
        },

        // A title long enough to wrap at 46pt.
        Shot(name: "07-album-long-title", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Music for Airports, Shipping Forecasts and Other Ambient Transmissions Recorded Between 1978 and 1983")
        },

        // One track, 59 minutes.
        Shot(name: "08-album-longform", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Nocturne for a Long Night")
        },

        // No artwork anywhere.
        Shot(name: "09-album-no-artwork", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Undertow, Vol. II")
        },

        Shot(name: "10-immersive", size: Tokens.Layout.defaultWindow) { container in
            open(container, album: "Sound of the Slow Hours", year: 2023)
            container.model.isImmersive = true
        },

        // Nothing playing — the state the app actually launches in.
        Shot(name: "11-idle", size: Tokens.Layout.defaultWindow) { container in
            container.playback.stop()
        },

        // The smallest window the layout has to survive.
        Shot(name: "12-minimum-window", size: Tokens.Layout.minWindow) { container in
            container.model.tab = .albums
        },
    ]

    private static func open(_ container: AppContainer, album title: String,
                             year: Int? = nil) {
        guard let album = container.model.albums.first(where: {
            $0.title == title && (year == nil || $0.year == year)
        }) else { return }
        container.model.show(.album(album.key))
        container.playback.play(album)
        container.playback.seek(to: 88)
    }

    /// Returns the number of shots written.
    ///
    /// Rendering goes through a real off-screen window rather than
    /// `ImageRenderer`. `ImageRenderer` never lays out `ScrollView` content, so
    /// every scrolling pane — which is to say every list in this app — came out
    /// blank, and a design-QA tool that silently drops the content is worse
    /// than none.
    static func run(into directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var written = 0
        // NSWindow defaults to releasing itself on close, which frees the
        // hosting view out from under SwiftUI's still-live observation and
        // segfaults on the next shot. Hold every window until the run is over
        // and let the process exit clean them up.
        var retained: [NSWindow] = []

        for shot in shots {
            let container = AppContainer()
            await container.model.load()
            container.playback.play(PreviewData.slowHours[2], in: PreviewData.slowHours)
            container.playback.seek(to: 88)
            shot.configure(container)

            let view = RootView()
                .environment(container.model)
                .environment(container.playback)
                .preferredColorScheme(.dark)
                .background(Tokens.Palette.surface)

            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: shot.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            retained.append(window)
            // Far enough off-screen that nothing flashes on the user's display,
            // but still ordered in so AppKit gives it a real layout pass.
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()

            // Let SwiftUI settle: layout, .task bodies, and the engine's
            // `started` event, which is what flips the button to Pause.
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(80))
            }

            guard let contentView = window.contentView else { continue }
            contentView.layoutSubtreeIfNeeded()

            guard let rep = contentView.bitmapImageRepForCachingDisplay(
                    in: contentView.bounds) else {
                FileHandle.standardError.write(Data("  ✗ \(shot.name): no bitmap\n".utf8))
                window.orderOut(nil)
                continue
            }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)

            guard let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("  ✗ \(shot.name): encode failed\n".utf8))
                window.orderOut(nil)
                continue
            }

            let url = directory.appendingPathComponent("\(shot.name).png")
            try png.write(to: url)
            print("  ✓ \(shot.name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)")
            fflush(stdout)
            written += 1
            window.orderOut(nil)
        }
        return written
    }

    /// Parses `--snapshot [directory]` out of the process arguments.
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot") else { return nil }
        let next = args.index(after: flag)
        if args.indices.contains(next), !args[next].hasPrefix("--") {
            return URL(fileURLWithPath: (args[next] as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Snapshots")
    }
}
