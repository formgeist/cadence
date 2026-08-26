import SwiftUI
import AppKit
import QuartzCore
import Foundation
import CadenceCore
import CadenceLibrary

/// `Cadence --bench [--tracks N]` — answers PLAN.md §3's last open question.
///
/// The plan asks whether SwiftUI `Table` stays smooth at library size. The
/// design uses `LazyVStack` and `LazyVGrid` instead, so the question stands but
/// against different views: does the artists grid, the album grid, or an album
/// of thousands of rows stay responsive once the library is large?
///
/// Store timings are straightforward. Scrolling is measured on a real, visible
/// window with a display link, because the obvious alternative is wrong:
/// `cacheDisplay(in:to:)` rasterises on the CPU, where a blur costs orders of
/// magnitude more than it does on the GPU. Measured that way, a drop shadow
/// looked like a 1.6-second frame; measured honestly it is nearly free. The
/// window appears briefly while the benchmark runs.
@MainActor
enum BenchHarness {

    /// How far each scroll step travels. Roughly a fifth of an album card, so
    /// a row takes several frames to cross the viewport the way it does under
    /// a trackpad — see the scroll loop in `measureScrolling`.
    private static let pointsPerScrollStep: Double = 40

    struct Options {
        var trackCount: Int
        /// Give every album cover art. Without this every card draws the
        /// placeholder, which is the worst case rather than the usual one.
        var withArtwork: Bool
    }

    static func parse(_ arguments: [String]) -> Options? {
        guard arguments.contains("--bench") else { return nil }
        var count = 30_000
        if let flag = arguments.firstIndex(of: "--tracks"),
           arguments.indices.contains(flag + 1),
           let parsed = Int(arguments[flag + 1]) {
            count = parsed
        }
        return Options(trackCount: count,
                       withArtwork: arguments.contains("--with-artwork"))
    }

    static func run(_ options: Options) async throws -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteLibraryStore(url: root.appendingPathComponent("bench.sqlite"))

        print("Generating \(formatted(options.trackCount)) tracks"
            + (options.withArtwork ? " with artwork…" : "…"))

        let artworkStore = try DiskArtworkStore(root: root.appendingPathComponent("art"))
        var artworkID: Artwork.ID?
        if options.withArtwork {
            artworkID = try await artworkStore.store(coverImageData())
        }

        var tracks = syntheticTracks(count: options.trackCount)
        if let artworkID {
            for index in tracks.indices { tracks[index].artworkID = artworkID }
        }

        try await time("insert + index") { try await store.upsert(tracks) }

        print("")
        let all = try await time("allTracks") { try await store.allTracks() }
        let albums = try await time("albums (grouped)") { try await store.albums() }
        let artists = try await time("artists (aggregated)") { try await store.artists() }
        _ = try await time("search \"slow\"") { try await store.tracks(matching: "slow") }
        _ = try await time("search \"a\" (broad)") { try await store.tracks(matching: "a") }

        print("\n\(formatted(all.count)) tracks · \(formatted(albums.count)) albums "
            + "· \(formatted(artists.count)) artists")

        let model = AppModel(store: store)
        try await time("AppModel.load()") { await model.load() }

        print("")
        let loader = ArtworkLoader(store: options.withArtwork ? artworkStore : nil)
        try await measureScrolling(model: model, tab: .artists,
                                   label: "Artists grid", loader: loader)
        try await measureScrolling(model: model, tab: .albums,
                                   label: "Albums grid", loader: loader)

        return 0
    }

    // MARK: - Scrolling

    private static func measureScrolling(
        model: AppModel, tab: AppModel.Tab, label: String, loader: ArtworkLoader
    ) async throws {
        model.tab = tab
        model.show(.library)

        let container = AppContainer(mode: .preview)
        let view = LibraryView()
            .environment(model)
            .environment(container.playback)
            .environment(container.importer)
            .environment(loader)
            .preferredColorScheme(.dark)

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80),
                                size: Tokens.Layout.defaultWindow),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Cadence benchmark"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        // Genuinely on screen: an ordered-out window is not composited, and
        // measuring one would report the cost of nothing being drawn.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(16)) }

        guard let scrollView = findScrollView(in: window.contentView),
              let contentView = window.contentView else {
            print("\(label): no scroll view found — cannot measure")
            return
        }

        let count = model.tab == .artists ? model.artists.count : model.albums.count
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let travel = max(0, documentHeight - scrollView.contentSize.height)
        guard travel > 0 else {
            print("\(label) — \(formatted(count)) rows: nothing to scroll")
            return
        }

        let recorder = FrameRecorder()
        let link = contentView.displayLink(target: recorder, selector: #selector(FrameRecorder.tick))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }

        // Scroll the way a trackpad does — many small steps, not a few jumps —
        // so every frame has new rows to materialise.
        //
        // The step is a fixed *distance*, not a fixed step count. A fixed
        // count makes every list take the same number of frames to cross,
        // so a long one is scrolled proportionally faster: at 180 steps the
        // album grid moved 638pt per frame against the artists grid's 42pt,
        // and reported 49ms a frame for what is a fling no trackpad
        // produces. Measured at the same 40pt per step, the same grid sits
        // at 9ms. Holding velocity constant is what makes two lists — or the
        // same list before and after a change — comparable at all.
        let steps = max(60, min(4000, Int(travel / Self.pointsPerScrollStep)))
        for step in 1...steps {
            let y = travel * Double(step) / Double(steps)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(100))

        let intervals = recorder.intervals
        guard intervals.count > 10 else {
            print("\(label): too few frames sampled")
            return
        }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        // The display link fires at the screen's rate; anything meaningfully
        // longer than the median is a frame that missed.
        let budget = median * 1.7
        let dropped = intervals.filter { $0 > budget }.count

        print("""
            \(label) — \(formatted(count)) rows over \(formatted(Int(travel)))pt
              frames:       \(intervals.count) sampled
              median:       \(ms(median))   p95: \(ms(p95))
              long frames:  \(dropped) (\(String(format: "%.1f", Double(dropped) / Double(intervals.count) * 100))%)
              \(verdict(median: median, worst: p95))
            """)
    }

    /// SwiftUI's ScrollView is an NSScrollView underneath; the benchmark needs
    /// the real thing to make scrolling cost what it costs.
    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// One layout + draw, timed. `settle` gives SwiftUI time to react to the
    /// state change before the clock starts. Used only for the first draw,
    /// which is a one-off cost rather than a per-frame one.
    private static func draw(_ window: NSWindow, settle: Int) async throws -> Double {
        for _ in 0..<settle { try await Task.sleep(for: .milliseconds(16)) }
        guard let view = window.contentView else { return 0 }

        let clock = ContinuousClock()
        let started = clock.now
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let elapsed = clock.now - started
        return Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
    }

    /// Frame intervals from a display link on a composited window. 60 fps is a
    /// 16.7 ms budget; a ProMotion display may report ~8 ms.
    private static func verdict(median: Double, worst: Double) -> String {
        if worst <= 0.0185 { return "→ holds the display's frame rate" }
        if median <= 0.0185 { return "→ median on rate; occasional long frames" }
        if median < 0.033 { return "→ between 30 and 60 fps — noticeable" }
        return "→ too slow; this view needs an NSCollectionView bridge"
    }

    /// A plain PNG standing in for a cover, big enough that thumbnailing does
    /// real work.
    private static func coverImageData() -> Data {
        let size = NSSize(width: 600, height: 600)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.2, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.91, green: 0.28, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 140, dy: 140)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    // MARK: - Data

    private static func syntheticTracks(count: Int) -> [Track] {
        let artists = (0..<max(1, count / 120)).map { "Artist \(String(format: "%04d", $0))" }
        let words = ["Slow", "Hollow", "Paper", "Static", "Undertow", "Northerly",
                     "Quiet", "Halo", "Glacier", "Nocturne", "Bells", "Cassette"]

        return (0..<count).map { index in
            // The artist belongs to the album, not the track — otherwise every
            // track lands in its own album, since Album.Key is
            // (albumArtist, title, year).
            let albumIndex = index / 12
            let artist = artists[albumIndex % artists.count]
            return Track(
                url: URL(fileURLWithPath: "/bench/\(index).flac"),
                title: "\(words[index % words.count]) \(index % 12 + 1)",
                artist: artist,
                albumArtist: artist,
                albumTitle: "\(words[albumIndex % words.count]) Album \(albumIndex)",
                year: 1970 + (albumIndex % 55),
                trackNumber: index % 12 + 1,
                duration: Double(180 + index % 240),
                format: index.isMultiple(of: 3) ? .hiRes : .cd)
        }
    }

    // MARK: - Output

    @discardableResult
    private static func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await body()
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(ms(seconds))")
        return result
    }

    private static func ms(_ seconds: Double) -> String {
        seconds >= 1
            ? String(format: "%.2f s", seconds)
            : String(format: "%6.1f ms", seconds * 1000)
    }

    private static func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}


/// Records intervals between composited frames.
final class FrameRecorder: NSObject {
    private var last: CFTimeInterval?
    private var samples: [Double] = []

    @objc func tick() {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard let last else { return }
        samples.append(now - last)
    }

    var intervals: [Double] { samples }
}
