import SwiftUI
import AppKit
import CadenceCore
import CadenceLibrary

/// Marketing screenshots for the website:
///
/// ```bash
/// swift run Cadence --snapshot ~/Desktop/cadence-showcase --showcase
/// ```
///
/// `Snapshot` renders `PreviewData`, which is built to break layouts — one
/// genre, awkward titles, no covers. That is the right library for design QA
/// and the wrong one for a landing page. This renders the same views against
/// an invented library that spans genres, with generated cover art, so the
/// screenshots show what a real collection looks like without showing anyone's
/// real collection or anyone else's artwork.
@MainActor
enum Showcase {

    // MARK: - Library

    struct Record {
        var artist: String
        var title: String
        var year: Int
        var genre: String
        var format: AudioFormat
        var cover: ShowcaseCover.Spec
        var tracks: [(String, TimeInterval)]
        var composer: String? = nil
    }

    private static let flac16 = AudioFormat.cd
    private static let flac24 = AudioFormat.hiRes
    private static let flac192 = AudioFormat(codec: .flac, sampleRate: 192_000, bitDepth: 24)
    private static let flac48 = AudioFormat(codec: .flac, sampleRate: 48_000, bitDepth: 24)
    private static let alac = AudioFormat(codec: .alac, sampleRate: 44_100, bitDepth: 16)
    private static let mp3 = AudioFormat(codec: .mp3, sampleRate: 44_100, bitRate: 320)
    private static let aac = AudioFormat(codec: .aac, sampleRate: 44_100, bitRate: 256)

    private static func spec(_ style: ShowcaseCover.Style, _ seed: UInt64, _ hex: UInt32...) -> ShowcaseCover.Spec {
        ShowcaseCover.Spec(style: style, colors: hex.map(NSColor.init(rgb:)), seed: seed)
    }

    static let records: [Record] = [
        Record(artist: "Theo Marsh Quartet", title: "Blue Hour Sessions", year: 1962, genre: "Jazz",
               format: flac192, cover: spec(.jazz, 1, 0x1C4E80, 0x0B1E33, 0xE8A33D),
               tracks: [("Blue Hour", 412), ("Lanterns on Lenox", 356), ("Soft Shoe for Ada", 298),
                        ("The Long Way Home", 521), ("Brass & Rain", 344), ("Minor Confessions", 389),
                        ("Last Set at the Vanguard", 604)]),
        Record(artist: "Juniper Vale", title: "Glow Season", year: 2023, genre: "Pop",
               format: flac48, cover: spec(.orbs, 2, 0x2A0F3D, 0xFF5FA2, 0xFFB86B, 0x7B61FF, 0x38D6C4),
               tracks: [("Glow Season", 203), ("Paper Planes", 188), ("Neon Lullaby", 214),
                        ("Say It Louder", 176), ("Summer in Reverse", 231), ("Honey Static", 197),
                        ("Cherry Skyline", 222), ("Goodnight, Satellite", 245)]),
        Record(artist: "The Velvet Arcade", title: "Neon Cathedral", year: 2019, genre: "Rock",
               format: flac24, cover: spec(.bands, 3, 0x111111, 0xE8483F, 0xF2E8D5, 0x3A3A3A),
               tracks: [("Cathedral", 264), ("Wire & Bone", 231), ("Burn the Map", 248),
                        ("Night Drive Hymn", 302), ("Glass Teeth", 219), ("Holy Static", 276),
                        ("Afterparty in the Nave", 341)]),
        Record(artist: "Fernwood Sisters", title: "Pine & Paper", year: 2015, genre: "Folk",
               format: flac16, cover: spec(.hills, 4, 0xE9D8B4, 0x7A8F5C, 0x4E6B4A, 0x2F4336, 0xC8553D),
               tracks: [("Pine & Paper", 221), ("Wren Song", 187), ("The River Keeps", 254),
                        ("Letters from Harlan", 238), ("Woodsmoke", 199), ("Hollow Oak", 263),
                        ("Carry Me North", 281)]),
        Record(artist: "Soft Circuit", title: "Parallel Lines", year: 2021, genre: "Electronic",
               format: flac48, cover: spec(.dots, 5, 0x0A0F1F, 0x38D6C4, 0x6B7CFF, 0xFF4F9A),
               tracks: [("Boot Sequence", 312), ("Parallel Lines", 398), ("Cold Start", 344),
                        ("Signal / Noise", 421), ("Low Orbit", 367), ("Handshake", 289),
                        ("Afterimage", 455)]),
        Record(artist: "Kora Blaze", title: "Concrete Garden", year: 2020, genre: "Hip-Hop",
               format: mp3, cover: spec(.halftone, 6, 0x151515, 0xE8483F, 0xF5D547),
               tracks: [("Intro (Seeds)", 94), ("Concrete Garden", 211), ("Block Party Physics", 198),
                        ("Rent Due", 226), ("Mama's Kitchen", 243), ("Streetlight Sermon", 205),
                        ("Roots", 232), ("Outro (Bloom)", 128)]),
        Record(artist: "Elena Varga", title: "Bach: Cello Suites", year: 2017, genre: "Classical",
               format: flac24, cover: spec(.classical, 7, 0xF3EBDD, 0x2B2420, 0xB5543B),
               tracks: [("Suite No. 1 in G Major: I. Prélude", 152), ("Suite No. 1: II. Allemande", 268),
                        ("Suite No. 1: III. Courante", 162), ("Suite No. 1: IV. Sarabande", 176),
                        ("Suite No. 1: V. Menuet I & II", 204), ("Suite No. 1: VI. Gigue", 104),
                        ("Suite No. 2 in D Minor: I. Prélude", 238)],
               composer: "Johann Sebastian Bach"),
        Record(artist: "Delphine Moss", title: "Velvet Hours", year: 2022, genre: "Soul",
               format: flac24, cover: spec(.sunburst, 8, 0x3B1020, 0x6E1F35, 0xF2A541, 0x1E0810),
               tracks: [("Velvet Hours", 246), ("Slow Burn", 231), ("Tell Me Twice", 214),
                        ("Sugar in the Morning", 198), ("Lay It Down", 262), ("Golden Ache", 239),
                        ("Home Before Midnight", 284)]),
        Record(artist: "Iron Meridian", title: "Cold Furnace", year: 2018, genre: "Metal",
               format: flac16, cover: spec(.peaks, 9, 0x0C0C0E, 0x1E1E24, 0x2C2C34, 0x3A3A44, 0xD9D9E0),
               tracks: [("Forge", 312), ("Cold Furnace", 388), ("Ash Crown", 341),
                        ("Meridian", 421), ("Anvil Sky", 297), ("Molten Hymn", 468)]),
        Record(artist: "Sol de Marzo", title: "Cumbia Eléctrica", year: 2023, genre: "Latin",
               format: alac, cover: spec(.sunburst, 10, 0x0E6E6A, 0x14908A, 0xFFC93C, 0xE8483F),
               tracks: [("Cumbia Eléctrica", 234), ("Río Lento", 256), ("La Madrugada", 221),
                        ("Baila Conmigo", 208), ("Palmeras de Neón", 247), ("Marzo", 263)]),
        Record(artist: "Harbor Lights", title: "Salt & Static", year: 2014, genre: "Rock",
               format: flac16, cover: spec(.bands, 11, 0x0F2A3D, 0x5FA8D3, 0xF2E8D5, 0x1B4965),
               tracks: [("Salt & Static", 243), ("Lighthouse", 268), ("Undertow Blues", 229),
                        ("Northbound", 254), ("Rust Belt Radio", 237), ("Anchor", 312)]),
        Record(artist: "Ines Calloway", title: "After the Rain", year: 2018, genre: "Jazz",
               format: flac24, cover: spec(.jazz, 12, 0xC8553D, 0x2B1B17, 0xF2D0A4),
               tracks: [("After the Rain", 347), ("Velvet Avenue", 298), ("Moon over Montmartre", 332),
                        ("Rainy Day Waltz", 276), ("Stardust Revisited", 361), ("Nightcap", 254)]),
        Record(artist: "Mona Reyes", title: "Satellite Heart", year: 2021, genre: "Pop",
               format: aac, cover: spec(.orbs, 13, 0x0D1B2A, 0x4CC9F0, 0xF72585, 0x7209B7),
               tracks: [("Satellite Heart", 198), ("Gravity Games", 207), ("Out of Orbit", 186),
                        ("Pink Noise", 213), ("Weightless", 224), ("Mission Control", 201)]),
        Record(artist: "Polaris Drift", title: "Afterglow Protocol", year: 2025, genre: "Electronic",
               format: flac24, cover: spec(.dots, 14, 0x1A0B2E, 0xFF7A45, 0xE8483F, 0xFFD166),
               tracks: [("Protocol", 356), ("Afterglow", 412), ("Night Bus", 334),
                        ("Warm Reset", 389), ("Polaris", 447), ("Drift", 502)]),
        Record(artist: "Marcus Oyelaran Trio", title: "Lagos Standard Time", year: 2016, genre: "Jazz",
               format: flac16, cover: spec(.jazz, 15, 0x2D6A4F, 0x081C15, 0xF4A261),
               tracks: [("Lagos Standard Time", 398), ("Harmattan", 342), ("Yaba Nights", 367),
                        ("Third Mainland", 421), ("Highlife Suite", 488)]),
        Record(artist: "Callum Reid", title: "Harbour Songs", year: 2019, genre: "Folk",
               format: flac16, cover: spec(.hills, 16, 0xCFE0E8, 0x6C8EA4, 0x3E5C76, 0x1D3557, 0xF4F1DE),
               tracks: [("Harbour Songs", 214), ("The Crossing", 238), ("Kelp & Kin", 197),
                        ("Old Man Tide", 261), ("Winter Ferry", 229), ("Lantern Row", 244)]),
        Record(artist: "Lyric Vance", title: "Midnight Transit", year: 2024, genre: "Hip-Hop",
               format: flac16, cover: spec(.halftone, 17, 0x0B132B, 0x5BC0BE, 0xFFFFFF),
               tracks: [("Last Train", 187), ("Midnight Transit", 214), ("Fare Evasion", 196),
                        ("Platform 9", 221), ("Transfer", 203), ("Terminal", 245)]),
        Record(artist: "Aurelio Conti", title: "Debussy: Préludes", year: 2020, genre: "Classical",
               format: flac192, cover: spec(.classical, 18, 0x1D2A38, 0xEDE6D6, 0x8FA9C2),
               tracks: [("Danseuses de Delphes", 214), ("Voiles", 232), ("Le vent dans la plaine", 124),
                        ("Des pas sur la neige", 258), ("La fille aux cheveux de lin", 147),
                        ("La cathédrale engloutie", 382)],
               composer: "Claude Debussy"),
        Record(artist: "The Sundial Revue", title: "Sweet Machinery", year: 1972, genre: "Funk",
               format: flac16, cover: spec(.sunburst, 19, 0xF2C14E, 0xF78154, 0xFFF1D0, 0x5B2333),
               tracks: [("Sweet Machinery", 264), ("Get On Up (The Clock)", 298), ("Sunday Strut", 243),
                        ("Brass Section Blues", 276), ("Groove Theory", 312), ("Sundial", 354)]),
        Record(artist: "Kestrel Row", title: "Loud Weather", year: 2022, genre: "Rock",
               format: alac, cover: spec(.bands, 20, 0xE9E4D8, 0x2B2D42, 0xEF233C, 0x8D99AE),
               tracks: [("Loud Weather", 219), ("Pressure Front", 236), ("Hail Mary", 204),
                        ("Barometer", 251), ("Eye of It", 278), ("Clear Skies (Eventually)", 296)]),
        Record(artist: "Vera Lindqvist", title: "Sound of the Slow Hours", year: 2023, genre: "Ambient",
               format: flac24, cover: spec(.hills, 21, 0x2E1F27, 0x854D27, 0xDD7230, 0xF4C95D, 0xE7E393),
               tracks: [("Morning Static", 252), ("Slow Hours", 338), ("Anhedonia", 234),
                        ("Cassette Sunlight", 362), ("Undertow", 287), ("Paper Radio", 311)]),
    ]

    /// Builds tracks, writes covers into `artwork`, and returns the store.
    static func makeLibrary(artwork: DiskArtworkStore) async throws -> (tracks: [Track], playlists: [Playlist]) {
        var tracks: [Track] = []
        for record in records {
            guard let png = ShowcaseCover.png(record.cover, artist: record.artist, title: record.title)
            else { continue }
            let artworkID = try await artwork.store(png)
            for (index, song) in record.tracks.enumerated() {
                tracks.append(Track(
                    url: URL(fileURLWithPath: "/Users/showcase/Music/\(record.artist)/\(record.title)/\(index + 1) \(song.0).flac"),
                    title: song.0,
                    artist: record.artist,
                    albumTitle: record.title,
                    composer: record.composer,
                    genre: record.genre,
                    year: record.year,
                    trackNumber: index + 1,
                    trackCount: record.tracks.count,
                    duration: song.1,
                    format: record.format,
                    artworkID: artworkID,
                    replayGain: ReplayGain(trackGain: -6.2, albumGain: -5.9)
                ))
            }
        }

        func pick(_ artists: [String], each: Int) -> [Track] {
            artists.flatMap { name in tracks.filter { $0.artist == name }.prefix(each) }
        }
        func playlist(_ name: String, _ picked: [Track]) -> Playlist {
            Playlist(name: name, trackIDs: picked.map(\.id),
                     duration: picked.reduce(0) { $0 + $1.duration })
        }
        let playlists = [
            playlist("Friday Night", pick(["Lyric Vance", "Sol de Marzo", "Juniper Vale", "The Velvet Arcade", "Mona Reyes"], each: 3)),
            playlist("Sunday Morning Jazz", pick(["Theo Marsh Quartet", "Ines Calloway", "Marcus Oyelaran Trio"], each: 4)),
            playlist("Deep Focus", pick(["Soft Circuit", "Polaris Drift", "Vera Lindqvist", "Elena Varga"], each: 4)),
            playlist("Road Trip", pick(["Harbor Lights", "Kestrel Row", "Fernwood Sisters", "Callum Reid", "The Sundial Revue"], each: 3)),
            playlist("Hi-Res Showcase", pick(["Theo Marsh Quartet", "Aurelio Conti", "Delphine Moss", "Polaris Drift"], each: 2)),
        ]
        return (tracks, playlists)
    }

    // MARK: - Shots

    struct Shot {
        var name: String
        var size: CGSize
        var configure: (AppContainer, [Track]) -> Void
    }

    private static func album(_ container: AppContainer, _ title: String) -> Album? {
        container.model.albums.first { $0.title == title }
    }

    private static func play(_ container: AppContainer, _ title: String, track index: Int, at seconds: TimeInterval) {
        guard let album = album(container, title) else { return }
        let tracks = album.discs.flatMap(\.tracks)
        guard tracks.indices.contains(index) else { return }
        container.playback.play(tracks[index], in: tracks)
        container.playback.seek(to: seconds)
    }

    static let shots: [Shot] = [
        // Website hero: the album wall with something playing. 16:10.
        Shot(name: "hero-library-albums", size: CGSize(width: 1_440, height: 900)) { container, _ in
            play(container, "Blue Hour Sessions", track: 1, at: 131)
            container.model.tab = .albums
        },
        // Playback feature: an album open, format badge and track list.
        Shot(name: "feature-album", size: CGSize(width: 1_280, height: 960)) { container, _ in
            if let album = album(container, "Velvet Hours") {
                container.model.show(.album(album.key))
            }
            play(container, "Velvet Hours", track: 2, at: 74)
        },
        // Library feature: the search palette over the artist grid.
        Shot(name: "feature-search", size: CGSize(width: 1_280, height: 960)) { container, _ in
            play(container, "Parallel Lines", track: 1, at: 190)
            container.model.tab = .artists
            container.model.isSearching = true
            container.model.searchText = "velvet"
        },
        // Everyday listening: Recents, albums and playlists mixed.
        Shot(name: "feature-recents", size: CGSize(width: 1_280, height: 960)) { container, _ in
            let order = ["Neon Cathedral", "Glow Season", "Concrete Garden", "Bach: Cello Suites",
                         "Pine & Paper", "Cumbia Eléctrica", "After the Rain", "Cold Furnace",
                         "Satellite Heart", "Afterglow Protocol", "Sweet Machinery"]
            for title in order.reversed() {
                if let track = album(container, title)?.discs.first?.tracks.first {
                    container.model.recordPlayed(track)
                }
            }
            for playlist in container.model.playlists.prefix(2) {
                if let id = playlist.trackIDs.first,
                   let track = container.model.albums.lazy.flatMap({ $0.discs.flatMap(\.tracks) }).first(where: { $0.id == id }) {
                    container.model.recordPlayed(track, from: playlist.id)
                }
            }
            play(container, "Glow Season", track: 0, at: 58)
            container.model.tab = .recents
        },
        // Spare: full-screen artwork.
        Shot(name: "extra-immersive", size: CGSize(width: 1_440, height: 900)) { container, _ in
            play(container, "Cumbia Eléctrica", track: 0, at: 96)
            container.model.isImmersive = true
        },
    ]

    // MARK: - Rendering

    static func run(into directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-showcase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let artwork = try DiskArtworkStore(root: scratch)
        let (tracks, playlists) = try await makeLibrary(artwork: artwork)

        var written = 0
        var retained: [NSWindow] = []
        for shot in shots {
            let store = InMemoryLibraryStore(tracks: tracks, playlists: playlists)
            let container = AppContainer(mode: .preview, store: store, artwork: artwork)
            await container.model.load()
            shot.configure(container, tracks)

            let view = RootView()
                .environment(container.model)
                .environment(container.playback)
                .environment(container.importer)
                .environment(container.artworkLoader)
                .environment(container.textEntry)
                .environment(container.searchFocus)
                .environment(container.scrobble)
                // The mock engine is silent, but a marketing shot should not say so.
                .environment(\.isSilentPlayback, false)
                .preferredColorScheme(.dark)
                .background(Tokens.Palette.surface)

            let window = NSWindow(contentRect: CGRect(origin: .zero, size: shot.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            retained.append(window)
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()

            // Artwork decodes asynchronously; wait for the covers to land, as
            // `runLive` does, or the wall comes out as placeholders.
            for _ in 0..<14 { try await Task.sleep(for: .milliseconds(120)) }

            guard let contentView = window.contentView else { continue }
            contentView.layoutSubtreeIfNeeded()
            guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
            else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }

            try png.write(to: directory.appendingPathComponent("\(shot.name).png"))
            print("  ✓ \(shot.name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)")
            fflush(stdout)
            written += 1
            window.orderOut(nil)
        }

        // The covers on their own, for use elsewhere on the site.
        let covers = directory.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        for record in records {
            guard let png = ShowcaseCover.png(record.cover, artist: record.artist, title: record.title)
            else { continue }
            let slug = record.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "-")
            try png.write(to: covers.appendingPathComponent("\(slug).png"))
        }
        return written
    }
}
