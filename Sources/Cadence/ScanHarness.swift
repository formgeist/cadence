import Foundation
import CadenceCore
import CadenceLibrary
import CadenceAudio

/// `Cadence --scan <folder>` — scans a folder and prints the resulting library.
///
/// PLAN.md §6 phase 1 names this as the phase's deliverable, and it earns its
/// place: it exercises reader, artwork cache, scanner and store together with
/// no window in the way, so an import bug shows up as wrong text rather than a
/// wrong-looking screen.
@MainActor
enum ScanHarness {

    struct Options {
        var folder: URL
        /// Defaults to the app's real database. `--library` points it somewhere
        /// disposable instead.
        var libraryPath: URL?
        var showTracks: Bool
    }

    static func parse(_ arguments: [String]) -> Options? {
        guard let flag = arguments.firstIndex(of: "--scan") else { return nil }
        let next = arguments.index(after: flag)
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("--") else {
            FileHandle.standardError.write(Data("--scan needs a folder\n".utf8))
            return nil
        }

        var libraryPath: URL?
        if let libraryFlag = arguments.firstIndex(of: "--library") {
            let value = arguments.index(after: libraryFlag)
            if arguments.indices.contains(value) {
                libraryPath = URL(fileURLWithPath: expand(arguments[value]))
            }
        }

        return Options(
            folder: URL(fileURLWithPath: expand(arguments[next])),
            libraryPath: libraryPath,
            showTracks: arguments.contains("--tracks"))
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func run(_ options: Options) async throws -> Int32 {
        let libraryURL = try options.libraryPath ?? SQLiteLibraryStore.defaultURL()

        let store = try SQLiteLibraryStore(url: libraryURL)
        let artwork = try DiskArtworkStore.makeDefault()
        let scanner = LibraryScanner(store: store, artwork: artwork,
                                     router: AppContainer.metadataRouter)

        print("Scanning \(options.folder.path)")
        print("Library  \(libraryURL.path)\n")

        let clock = ContinuousClock()
        let started = clock.now
        let summary = try await scanner.scan(folder: options.folder)
        let elapsed = clock.now - started

        print("""
            imported \(summary.imported)   skipped \(summary.skipped)   \
            removed \(summary.removed)   failed \(summary.failed)   \
            in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))
            """)

        for failure in summary.failures.prefix(10) {
            print("  ✗ \(failure.line)")
        }
        if summary.failures.count > 10 {
            print("  … and \(summary.failures.count - 10) more")
        }

        try await report(store: store, showTracks: options.showTracks)
        return summary.failed > 0 && summary.imported == 0 ? 1 : 0
    }

    private static func report(store: SQLiteLibraryStore, showTracks: Bool) async throws {
        let albums = try await store.albums()
        let artists = try await store.artists()
        let tracks = try await store.allTracks()
        let size = try await store.librarySize()

        print("""

            \(tracks.count) tracks · \(albums.count) albums · \
            \(artists.count) artists · \(DurationFormat.bytes(size))
            """)

        for artist in artists {
            print("\n\(artist.name)  —  \(artist.summary)  [\(artist.formatSummary)]")
            for album in albums.filter({ $0.albumArtist == artist.name })
                .sorted(by: { ($0.year ?? 0) < ($1.year ?? 0) }) {

                var flags: [String] = []
                if album.hasMultipleDiscs { flags.append("\(album.discCount) discs") }
                if album.isCompilation { flags.append("compilation") }
                if album.artworkID == nil { flags.append("no artwork") }

                print("""
                      \(album.title) (\(album.year.map(String.init) ?? "no year")) · \
                    \(album.trackCount) tracks · \
                    \(DurationFormat.approximate(album.duration)) · \
                    \(album.dominantFormat?.shortDescription ?? "?")\
                    \(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")
                    """)

                guard showTracks else { continue }
                for disc in album.discs {
                    if let number = disc.number { print("      Disc \(number)") }
                    for track in disc.tracks {
                        let number = track.trackNumber.map { String(format: "%02d", $0) } ?? "--"
                        let subtitle = track.rowSubtitle(showingArtist: album.showsTrackArtists)
                        print("""
                                \(number)  \(track.title)\
                            \(subtitle.map { "  — \($0)" } ?? "")  \
                            \(DurationFormat.clock(track.duration))  \
                            \(track.format.shortDescription)
                            """)
                    }
                }
            }
        }
    }
}
