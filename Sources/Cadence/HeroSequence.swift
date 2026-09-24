import SwiftUI
import AppKit
import CadenceCore
import CadenceLibrary

/// Keyframes for the website's animated hero:
///
/// ```bash
/// swift run Cadence --snapshot ~/Desktop/cadence-hero --showcase --hero-sequence
/// ```
///
/// The hero video is a walk through one session — search, play, add to a
/// playlist — composited from stills with a pointer drawn on top. Every state
/// the video shows is rendered here from the showcase library, so the frames
/// agree with each other and with the static screenshots beside them.
///
/// Menus are rendered on their own, transparent, because the app presents
/// them in child panels a window capture never sees. `layout.json` records
/// their sizes and row frames so the compositor can hang the submenu off
/// the right row without guessing.
@MainActor
enum HeroSequence {

    static let size = CGSize(width: 1_440, height: 900)
    static let album = "Velvet Hours"
    static let query = "velvet"
    static let playlist = "Friday Night"
    /// Seconds into the first track for each clock frame on the album page.
    static let albumClock = Array(1...8)

    private struct Frame {
        var name: String
        var configure: (AppContainer) -> Void
        /// Where the clock should read at the moment of capture. The mock
        /// engine ticks while the frame settles, so the seek is repeated just
        /// before the capture rather than trusted from setup.
        var clock: TimeInterval?
        /// Runs once the window is up. The search field selects whatever it
        /// holds when it takes focus, so typed text set during setup comes out
        /// highlighted; set after focus, it reads as typed, caret at the end.
        var settled: (AppContainer) -> Void = { _ in }
    }

    private static func tracks(_ container: AppContainer, _ title: String) -> [Track] {
        container.model.albums.first { $0.title == title }?.discs.flatMap(\.tracks) ?? []
    }

    private static func startingState(_ container: AppContainer) {
        let blueHour = tracks(container, "Blue Hour Sessions")
        if blueHour.count > 1 { container.playback.play(blueHour[1], in: blueHour) }
        container.model.tab = .albums
    }

    private static func openAlbum(_ container: AppContainer) {
        startingState(container)
        if let key = container.model.albums.first(where: { $0.title == album })?.key {
            container.model.show(.album(key))
        }
        let velvet = tracks(container, album)
        if let first = velvet.first { container.playback.play(first, in: velvet) }
    }

    private static var frames: [Frame] {
        var frames: [Frame] = [
            Frame(name: "00-albums", configure: startingState, clock: 131),
            Frame(name: "01-search-open", configure: { container in
                startingState(container)
                container.model.isSearching = true
            }, clock: 132),
        ]
        for length in 1...query.count {
            let typed = String(query.prefix(length))
            frames.append(Frame(name: "02-search-\(length)-\(typed)", configure: { container in
                startingState(container)
                container.model.isSearching = true
            }, clock: 132, settled: { $0.model.searchText = typed }))
        }
        for second in albumClock {
            frames.append(Frame(name: String(format: "03-album-%02d", second),
                                configure: openAlbum, clock: TimeInterval(second)))
        }
        frames.append(Frame(name: "04-albums-after", configure: { container in
            openAlbum(container)
            container.model.goBack()
        }, clock: TimeInterval(albumClock.last! + 1)))
        return frames
    }

    // MARK: - Rendering

    static func run(into directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-hero-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let artwork = try DiskArtworkStore(root: scratch)
        let (tracks, playlists) = try await Showcase.makeLibrary(artwork: artwork)
        func makeContainer() async -> AppContainer {
            let store = InMemoryLibraryStore(tracks: tracks, playlists: playlists)
            let container = AppContainer(mode: .preview, store: store, artwork: artwork)
            await container.model.load()
            return container
        }

        var written = 0
        var retained: [NSWindow] = []

        for frame in frames {
            let container = await makeContainer()
            frame.configure(container)
            let (window, rep) = try await capture(root(RootView(), container), size: size) {
                frame.settled(container)
                if let clock = frame.clock { container.playback.seek(to: clock) }
            }
            retained.append(window)
            if try write(rep, to: directory, name: frame.name) { written += 1 }
        }

        // The track row's menu, and the playlist list behind "Add to Playlist",
        // each at rest and with the pointer on the row the video clicks.
        let container = await makeContainer()
        openAlbum(container)
        guard let track = HeroSequence.tracks(container, album).first else { return written }
        let items = PlaylistMenu.track(track, model: container.model,
                                       play: {}, addToQueue: {})
        guard let submenu = items.first(where: {
                  if case .submenu = $0.kind { return true } else { return false }
              }),
              case .submenu(_, _, let destinations) = submenu.kind,
              let target = destinations.first(where: {
                  if case .action(let action) = $0.kind { return action.title == playlist }
                  return false
              })
        else { return written }

        var layout: [String: Any] = [:]
        let menus: [(String, [MenuItem], UUID?)] = [
            ("05-menu-track", items, nil),
            ("05-menu-track-focus", items, submenu.id),
            ("06-menu-playlists", destinations, nil),
            ("06-menu-playlists-focus", destinations, target.id),
        ]
        for (name, menuItems, focused) in menus {
            let state = MenuLevelState()
            state.focused = focused
            if focused == submenu.id { state.openSubmenu = submenu.id }
            let surface = MenuSurface(items: menuItems, state: state,
                                      onFire: { _ in }, onHoverSubmenu: { _ in })
            let (window, rep) = try await capture(root(surface, container), size: nil,
                                                  transparent: true)
            retained.append(window)
            if try write(rep, to: directory, name: name) { written += 1 }

            func rect(_ id: UUID) -> [String: CGFloat]? {
                state.rowFrames[id].map {
                    ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
                }
            }
            let bounds = window.contentView?.bounds.size ?? .zero
            var entry: [String: Any] = ["width": bounds.width, "height": bounds.height]
            if let row = rect(submenu.id), menuItems.count == items.count { entry["submenuRow"] = row }
            if let row = rect(target.id), menuItems.count == destinations.count { entry["targetRow"] = row }
            layout[name] = entry
        }
        layout["window"] = ["width": size.width, "height": size.height]
        layout["submenuGap"] = MenuMetrics.submenuGap
        layout["surfacePadding"] = MenuMetrics.surfacePadding
        let json = try JSONSerialization.data(withJSONObject: layout,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("layout.json"))
        return written
    }

    static var count: Int { frames.count + 4 }

    private static func root(_ view: some View, _ container: AppContainer) -> AnyView {
        AnyView(view
            .environment(container.model)
            .environment(container.playback)
            .environment(container.importer)
            .environment(container.artworkLoader)
            .environment(container.textEntry)
            .environment(container.searchFocus)
            .environment(container.scrobble)
            .environment(\.isSilentPlayback, false)
            .preferredColorScheme(.dark))
    }

    /// Renders `view` in an off-screen window. `size` nil sizes the window to
    /// the view, which is what a menu surface wants.
    private static func capture(_ view: AnyView, size: CGSize?, transparent: Bool = false,
                                beforeCapture: () -> Void = {}) async throws
        -> (NSWindow, NSBitmapImageRep?) {
        let hosting = NSHostingView(rootView: transparent
            ? view
            : AnyView(view.background(Tokens.Palette.surface)))
        let contentSize = size ?? hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .black
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        // Long enough for covers to decode, as in `Showcase.run`.
        for _ in 0..<14 { try await Task.sleep(for: .milliseconds(120)) }
        beforeCapture()
        // Search results arrive asynchronously; give them a few ticks.
        try await Task.sleep(for: .milliseconds(300))

        guard let contentView = window.contentView else { return (window, nil) }
        contentView.layoutSubtreeIfNeeded()
        let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        if let rep { contentView.cacheDisplay(in: contentView.bounds, to: rep) }
        window.orderOut(nil)
        return (window, rep)
    }

    private static func write(_ rep: NSBitmapImageRep?, to directory: URL,
                              name: String) throws -> Bool {
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("  ✗ \(name)\n".utf8))
            return false
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        print("  ✓ \(name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)")
        fflush(stdout)
        return true
    }
}
