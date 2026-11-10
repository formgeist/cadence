import Foundation

// MARK: - Results

/// Why one artist or album was suggested next to another. The strongest
/// signal behind a suggestion becomes its caption, so a suggestion never
/// arrives without a reason the listener can check against the record.
public enum SimilarityReason: Hashable, Sendable {
    /// The same person is credited on both: a producer, an engineer, a
    /// session player. `name` is the person, as the tags spell it.
    case sharedCredit(role: Credit.Role, name: String)
    /// One features on the other's record, or both appear on one compilation.
    case collaboration
    /// Both sit in the same playlists — groupings the listener made.
    case playlists(Int)
    /// Played in the same listening sessions.
    case listenedTogether
    /// Last.fm lists them as similar.
    case lastFM
    /// Only the genre tag is shared. The weakest reason, used to fill a list
    /// that has nothing better.
    case genre(String)
    /// Same genre and released within a few years of each other.
    case genreAndEra(String)

    public var text: String {
        switch self {
        case .sharedCredit(let role, let name):
            switch role {
            case .composer: "Also composed by \(name)"
            case .lyricist, .writer: "Also written by \(name)"
            case .arranger: "Also arranged by \(name)"
            case .conductor: "Also conducted by \(name)"
            case .ensemble, .performer: "Also features \(name)"
            case .producer: "Also produced by \(name)"
            case .engineer: "Also engineered by \(name)"
            case .mixer: "Also mixed by \(name)"
            case .remixer: "Also remixed by \(name)"
            }
        case .collaboration: "Collaborators"
        case .playlists(let count):
            count == 1 ? "In a playlist together" : "In \(count) playlists together"
        case .listenedTogether: "Often played together"
        case .lastFM: "Similar on Last.fm"
        case .genre(let name): "Also \(name)"
        case .genreAndEra(let name): "\(name), same era"
        }
    }
}

public struct SimilarArtist: Identifiable, Hashable, Sendable {
    /// The artist's name as the library shows it, so it opens their page.
    public var name: String
    public var score: Double
    public var reason: SimilarityReason
    public var id: String { name }

    public init(name: String, score: Double, reason: SimilarityReason) {
        self.name = name
        self.score = score
        self.reason = reason
    }
}

public struct SimilarAlbum: Identifiable, Hashable, Sendable {
    public var key: Album.Key
    public var score: Double
    public var reason: SimilarityReason
    public var id: Album.Key { key }

    public init(key: Album.Key, score: Double, reason: SimilarityReason) {
        self.key = key
        self.score = score
        self.reason = reason
    }
}

/// One entry from an outside service's similar-artists list. `match` is the
/// service's own 0…1 strength.
public struct ExternalSimilarArtist: Codable, Hashable, Sendable {
    public var name: String
    public var match: Double

    public init(name: String, match: Double) {
        self.name = name
        self.match = match
    }
}

// MARK: - Index

/// "More like this" from what the library already knows: who is credited on
/// what, who features on whose records, what the listener puts in playlists
/// together and plays in the same sitting, and the genre tags. An outside
/// list — Last.fm's — can be folded in per query.
///
/// Built once from the whole library and then queried per screen. Every
/// signal is kept as an inverted index (person → artists, playlist →
/// artists, …), so a query only visits the artists that share something with
/// the one asked about instead of comparing every pair.
///
/// Signals are weighted by how specific they are: a mastering engineer on
/// half the library, or a 400-artist playlist, says little about any one
/// pair, so each shared item counts `1 / log2(1 + n)` where `n` is how many
/// artists (or albums) it touches.
public struct SimilarityIndex: Sendable {

    // Artist-level postings. Artists are keyed by `Similarity.key(for:)`.
    private var displayNames: [String: String] = [:]
    private var artistPeople: [String: [String: Credit.Role]] = [:]
    private var personArtists: [String: Set<String>] = [:]
    private var personNames: [String: String] = [:]
    private var collaborations: [String: [String: Double]] = [:]
    private var artistPlaylists: [String: Set<Int>] = [:]
    private var playlistArtists: [Set<String>] = []
    private var artistSessions: [String: Set<Int>] = [:]
    private var sessionArtists: [Set<String>] = []
    private var artistGenre: [String: String] = [:]
    private var genreArtists: [String: Set<String>] = [:]

    // Album-level postings.
    private var albumsByKey: [Album.Key: Album] = [:]
    private var albumArtistKey: [Album.Key: String] = [:]
    private var albumPeople: [Album.Key: [String: Credit.Role]] = [:]
    private var personAlbums: [String: Set<Album.Key>] = [:]
    private var albumPlaylists: [Album.Key: Set<Int>] = [:]
    private var playlistAlbums: [Set<Album.Key>] = []
    private var albumSessions: [Album.Key: Set<Int>] = [:]
    private var sessionAlbums: [Set<Album.Key>] = []
    private var albumGenre: [Album.Key: String] = [:]
    private var genreAlbums: [String: Set<Album.Key>] = [:]
    private var genreNames: [String: String] = [:]

    /// How much of each artist and album the listener has: plays count five
    /// times a track. Breaks ties between equally similar candidates — common
    /// when the only link is one big playlist or a shared genre — in favour of
    /// what the listener actually reaches for, rather than alphabetically.
    private var artistWeight: [String: Int] = [:]
    private var albumWeight: [Album.Key: Int] = [:]

    /// A new listening session starts after this long without a play.
    public static let sessionGap: TimeInterval = 45 * 60

    public init(albums: [Album], playlists: [Playlist], plays: [PlayRecord]) {
        var trackOwner: [Track.ID: (artist: String, album: Album.Key)] = [:]

        for album in albums {
            let artistKey = Similarity.key(for: album.albumArtist)
            guard !artistKey.isEmpty else { continue }
            albumsByKey[album.key] = album
            albumArtistKey[album.key] = artistKey
            // A compilation is "Various Artists", not an artist anyone means.
            if !album.isCompilation {
                displayNames[artistKey] = displayNames[artistKey] ?? album.albumArtist
            }
            for track in album.tracks {
                trackOwner[track.id] = (artistKey, album.key)
            }
            artistWeight[artistKey, default: 0] += album.tracks.count
            if let genre = album.genreKey {
                albumGenre[album.key] = genre
                genreAlbums[genre, default: []].insert(album.key)
                if genreNames[genre] == nil,
                   let tag = album.tracks.lazy.compactMap(\.genre)
                    .first(where: { Genre.key(for: $0) == genre }) {
                    genreNames[genre] = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Credits, features and compilations need the full artist list, so
        // they run once every album has registered its artist.
        for album in albums {
            guard let artistKey = albumArtistKey[album.key] else { continue }
            var people: [String: Credit.Role] = [:]
            var compilationArtists: Set<String> = []
            for track in album.tracks {
                for credit in track.allCredits {
                    let person = Similarity.key(for: credit.name)
                    guard !person.isEmpty, person != artistKey else { continue }
                    // A credited person who is also an artist in the library
                    // is a collaboration, not just a shared studio hand.
                    if displayNames[person] != nil, !album.isCompilation {
                        addCollaboration(artistKey, person, weight: 1)
                    }
                    people[person] = Similarity.strongerRole(people[person], credit.role)
                    personNames[person] = personNames[person] ?? credit.name
                }
                for other in Similarity.artistKeys(in: track.artist) {
                    guard other != artistKey, displayNames[other] != nil else { continue }
                    if album.isCompilation {
                        compilationArtists.insert(other)
                    } else {
                        addCollaboration(artistKey, other, weight: 1)
                    }
                }
            }
            // Sharing a twenty-artist compilation is a much weaker link than
            // a feature, so each pair gets a share of one.
            if compilationArtists.count > 1 {
                let weight = 1 / Double(compilationArtists.count - 1)
                let list = Array(compilationArtists)
                for i in list.indices {
                    for j in list.indices where j > i {
                        addCollaboration(list[i], list[j], weight: weight)
                    }
                }
            }
            albumPeople[album.key] = people
            for person in people.keys {
                personAlbums[person, default: []].insert(album.key)
                if !album.isCompilation {
                    artistPeople[artistKey, default: [:]][person] =
                        Similarity.strongerRole(artistPeople[artistKey]?[person], people[person]!)
                    personArtists[person, default: []].insert(artistKey)
                }
            }
        }

        // An artist's genre is the one most of their albums carry.
        var genreCounts: [String: [String: Int]] = [:]
        for album in albums where !album.isCompilation {
            guard let artistKey = albumArtistKey[album.key],
                  let genre = albumGenre[album.key] else { continue }
            genreCounts[artistKey, default: [:]][genre, default: 0] += 1
        }
        for (artistKey, counts) in genreCounts {
            guard let genre = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
            else { continue }
            artistGenre[artistKey] = genre
            genreArtists[genre, default: []].insert(artistKey)
        }

        for playlist in playlists {
            var artistSet: Set<String> = []
            var albumSet: Set<Album.Key> = []
            for id in playlist.trackIDs {
                guard let owner = trackOwner[id] else { continue }
                if displayNames[owner.artist] != nil { artistSet.insert(owner.artist) }
                albumSet.insert(owner.album)
            }
            let index = playlistArtists.count
            playlistArtists.append(artistSet)
            playlistAlbums.append(albumSet)
            for artist in artistSet { artistPlaylists[artist, default: []].insert(index) }
            for album in albumSet { albumPlaylists[album, default: []].insert(index) }
        }

        var sessionArtistSet: Set<String> = []
        var sessionAlbumSet: Set<Album.Key> = []
        var previous: Date?
        func closeSession() {
            let index = sessionArtists.count
            if sessionArtistSet.count > 1 {
                sessionArtists.append(sessionArtistSet)
                for artist in sessionArtistSet { artistSessions[artist, default: []].insert(index) }
            } else {
                sessionArtists.append([])
            }
            if sessionAlbumSet.count > 1 {
                sessionAlbums.append(sessionAlbumSet)
                for album in sessionAlbumSet { albumSessions[album, default: []].insert(index) }
            } else {
                sessionAlbums.append([])
            }
            sessionArtistSet = []
            sessionAlbumSet = []
        }
        for play in plays.sorted(by: { $0.playedAt < $1.playedAt }) {
            if let previous, play.playedAt.timeIntervalSince(previous) > Self.sessionGap {
                closeSession()
            }
            previous = play.playedAt
            let artist = Similarity.key(for: play.albumArtist)
            artistWeight[artist, default: 0] += 5
            albumWeight[play.albumKey, default: 0] += 5
            if displayNames[artist] != nil { sessionArtistSet.insert(artist) }
            if albumsByKey[play.albumKey] != nil { sessionAlbumSet.insert(play.albumKey) }
        }
        closeSession()
    }

    private mutating func addCollaboration(_ a: String, _ b: String, weight: Double) {
        guard a != b else { return }
        collaborations[a, default: [:]][b, default: 0] += weight
        collaborations[b, default: [:]][a, default: 0] += weight
    }

    /// Whether the library knows this artist at all.
    public func contains(artist name: String) -> Bool {
        displayNames[Similarity.key(for: name)] != nil
    }

    /// The library's own spelling for a name from somewhere else, if the
    /// artist is in the library under any capitalisation or accenting.
    public func libraryName(for name: String) -> String? {
        displayNames[Similarity.key(for: name)]
    }

    // MARK: Artists

    /// The artists most like `name`, strongest first. `external` is an
    /// outside similar-artists list for the same artist; entries the library
    /// has no artist for are ignored here — the caller can show them apart.
    public func artists(similarTo name: String,
                        external: [ExternalSimilarArtist] = [],
                        limit: Int = 10) -> [SimilarArtist] {
        let subject = Similarity.key(for: name)
        guard displayNames[subject] != nil else { return [] }
        var signals: [String: Signals] = [:]
        let artistCount = displayNames.count

        for (person, role) in artistPeople[subject] ?? [:] {
            guard let postings = personArtists[person], postings.count > 1,
                  !Similarity.isUbiquitous(postings.count, of: artistCount) else { continue }
            let weight = Similarity.roleWeight(role) * Similarity.specificity(postings.count)
            for other in postings where other != subject {
                signals[other, default: Signals()].addCredit(
                    weight, role: artistPeople[other]?[person] ?? role,
                    name: personNames[person] ?? person)
            }
        }

        for (other, weight) in collaborations[subject] ?? [:] {
            signals[other, default: Signals()].collaboration += weight
        }

        for index in artistPlaylists[subject] ?? [] {
            let members = playlistArtists[index]
            guard members.count > 1 else { continue }
            let weight = Similarity.specificity(members.count)
            for other in members where other != subject {
                signals[other, default: Signals()].playlists += weight
                signals[other, default: Signals()].playlistCount += 1
            }
        }

        for index in artistSessions[subject] ?? [] {
            let members = sessionArtists[index]
            let weight = Similarity.specificity(members.count)
            for other in members where other != subject {
                signals[other, default: Signals()].sessions += weight
            }
        }

        for entry in external {
            let other = Similarity.key(for: entry.name)
            guard other != subject, displayNames[other] != nil else { continue }
            signals[other, default: Signals()].lastFM =
                max(signals[other]?.lastFM ?? 0, min(max(entry.match, 0), 1))
        }

        if let genre = artistGenre[subject] {
            for other in genreArtists[genre] ?? [] where other != subject {
                signals[other, default: Signals()].genre = genreNames[genre] ?? genre
            }
        }

        return signals
            .compactMap { key, signal -> SimilarArtist? in
                guard let display = displayNames[key] else { return nil }
                let (score, reason) = signal.resolve()
                return SimilarArtist(name: display, score: score, reason: reason)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let (a, b) = (artistWeight[Similarity.key(for: lhs.name)] ?? 0,
                              artistWeight[Similarity.key(for: rhs.name)] ?? 0)
                if a != b { return a > b }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Albums

    /// Records by other artists most like the album at `key`. The album's
    /// own artist is left out — the album page already lists their other
    /// records. `artists` is the result of `artists(similarTo:)` for the
    /// album's artist, so an outside list reaches albums through it.
    public func albums(similarTo key: Album.Key,
                       artists: [SimilarArtist] = [],
                       limit: Int = 10,
                       perArtist: Int = 2) -> [SimilarAlbum] {
        guard let album = albumsByKey[key], let subjectArtist = albumArtistKey[key] else {
            return []
        }
        var signals: [Album.Key: Signals] = [:]
        let albumCount = albumsByKey.count
        func isCandidate(_ other: Album.Key) -> Bool {
            other != key && albumArtistKey[other] != subjectArtist
        }

        for (person, role) in albumPeople[key] ?? [:] {
            guard let postings = personAlbums[person], postings.count > 1,
                  !Similarity.isUbiquitous(postings.count, of: albumCount) else { continue }
            let weight = Similarity.roleWeight(role) * Similarity.specificity(postings.count)
            for other in postings where isCandidate(other) {
                signals[other, default: Signals()].addCredit(
                    weight, role: albumPeople[other]?[person] ?? role,
                    name: personNames[person] ?? person)
            }
        }

        for index in albumPlaylists[key] ?? [] {
            let members = playlistAlbums[index]
            guard members.count > 1 else { continue }
            let weight = Similarity.specificity(members.count)
            for other in members where isCandidate(other) {
                signals[other, default: Signals()].playlists += weight
                signals[other, default: Signals()].playlistCount += 1
            }
        }

        for index in albumSessions[key] ?? [] {
            let members = sessionAlbums[index]
            let weight = Similarity.specificity(members.count)
            for other in members where isCandidate(other) {
                signals[other, default: Signals()].sessions += weight
            }
        }

        // An album inherits a share of its artist's likeness, and the reason
        // that came with it.
        let byArtist = Dictionary(artists.map { (Similarity.key(for: $0.name), $0) }) { a, _ in a }
        if !byArtist.isEmpty {
            for (other, otherArtist) in albumArtistKey where isCandidate(other) {
                guard let similar = byArtist[otherArtist] else { continue }
                signals[other, default: Signals()].inherit(similar)
            }
        }

        if let genre = albumGenre[key] {
            let name = genreNames[genre] ?? genre
            for other in genreAlbums[genre] ?? [] where isCandidate(other) {
                signals[other, default: Signals()].genre = name
                if let year = album.year, let otherYear = albumsByKey[other]?.year,
                   abs(year - otherYear) <= 5 {
                    signals[other, default: Signals()].era = 1 - Double(abs(year - otherYear)) / 6
                }
            }
        }

        func weight(_ key: Album.Key) -> Int {
            (albumWeight[key] ?? 0) + (artistWeight[albumArtistKey[key] ?? ""] ?? 0)
        }
        var perArtistCount: [String: Int] = [:]
        var results: [SimilarAlbum] = []
        let ranked = signals
            .map { key, signal -> SimilarAlbum in
                let (score, reason) = signal.resolve()
                return SimilarAlbum(key: key, score: score, reason: reason)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let (a, b) = (weight(lhs.key), weight(rhs.key))
                if a != b { return a > b }
                return (lhs.key.albumArtist, lhs.key.title) < (rhs.key.albumArtist, rhs.key.title)
            }
        // A handful from one prolific artist would crowd everyone else out.
        for candidate in ranked {
            let artist = albumArtistKey[candidate.key] ?? ""
            guard perArtistCount[artist, default: 0] < perArtist else { continue }
            perArtistCount[artist, default: 0] += 1
            results.append(candidate)
            if results.count == limit { break }
        }
        return results
    }
}

// MARK: - Scoring

/// Every signal collected for one candidate, before they are combined.
struct Signals {
    var credit: Double = 0
    var bestCredit: (weight: Double, role: Credit.Role, name: String)?
    var collaboration: Double = 0
    var playlists: Double = 0
    var playlistCount = 0
    var sessions: Double = 0
    var lastFM: Double = 0
    var genre: String?
    var era: Double = 0
    /// For albums: the share they take from their artist's similarity.
    var inherited: Double = 0
    var inheritedReason: SimilarityReason?

    mutating func addCredit(_ weight: Double, role: Credit.Role, name: String) {
        credit += weight
        if weight > bestCredit?.weight ?? 0 { bestCredit = (weight, role, name) }
    }

    mutating func inherit(_ artist: SimilarArtist) {
        let share = 0.6 * artist.score
        guard share > inherited else { return }
        inherited = share
        inheritedReason = artist.reason
    }

    /// Each signal saturates — `x / (x + k)` — so one very strong kind of
    /// evidence cannot drown out the rest, and the weights say how much each
    /// kind is worth at full strength. The caption is whichever contributed
    /// most; the genre only speaks when nothing else does.
    func resolve() -> (score: Double, reason: SimilarityReason) {
        func saturate(_ x: Double, _ k: Double) -> Double { x <= 0 ? 0 : x / (x + k) }
        var contributions: [(Double, SimilarityReason)] = []
        if let best = bestCredit {
            contributions.append((1.0 * saturate(credit, 0.8),
                                  .sharedCredit(role: best.role, name: best.name)))
        }
        contributions.append((1.2 * saturate(collaboration, 0.5), .collaboration))
        contributions.append((1.0 * saturate(playlists, 1.0), .playlists(playlistCount)))
        contributions.append((0.8 * saturate(sessions, 1.5), .listenedTogether))
        contributions.append((1.2 * lastFM, .lastFM))
        if let inheritedReason {
            contributions.append((inherited, inheritedReason))
        }
        var score = contributions.reduce(0) { $0 + $1.0 }
        var reason = contributions.max { $0.0 < $1.0 }.flatMap { $0.0 > 0 ? $0.1 : nil }
        if let genre {
            score += 0.25 + 0.15 * era
            if reason == nil { reason = era > 0 ? .genreAndEra(genre) : .genre(genre) }
        }
        return (score, reason ?? .collaboration)
    }
}

// MARK: - Helpers

public enum Similarity {
    /// The identity two spellings of one name share: case, accents and
    /// surrounding space folded, and a leading "The" dropped, so
    /// "The Beatles", "beatles" and "Beatles " are one artist.
    public static func key(for name: String) -> String {
        var folded = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded
    }

    /// The artist keys named in one artist field: "A feat. B", "A & B",
    /// "A, B and C". The whole field comes first, so a name that contains a
    /// separator — "Simon & Garfunkel" — still matches as itself. Splits the
    /// folded field, so "Feat." and "FEAT" are caught too.
    static func artistKeys(in field: String) -> [String] {
        let whole = key(for: field)
        var pieces = [whole]
        for separator in [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " with ",
                          " & ", " and ", " x ", " vs. ", " vs ", ", ", "; ", " / "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        let parts = pieces.map { key(for: $0) }.filter { !$0.isEmpty && $0 != whole }
        return [whole] + parts
    }

    /// How much one shared item says about a pair, given it touches `n`
    /// things: 1 for a pair, falling slowly as the item gets more common.
    static func specificity(_ n: Int) -> Double {
        1 / log2(1 + Double(max(n, 1)))
    }

    /// A credit on more than a quarter of a sizeable library — the mastering
    /// engineer everyone uses — is noise, not a link.
    static func isUbiquitous(_ count: Int, of total: Int) -> Bool {
        total >= 20 && Double(count) > Double(total) * 0.25
    }

    /// Whose name on two records best predicts they sound alike. The producer
    /// shapes the sound; a composer credit is weaker because covers and
    /// standards spread it widely.
    static func roleWeight(_ role: Credit.Role) -> Double {
        switch role {
        case .producer: 1.0
        case .performer, .ensemble, .arranger, .conductor: 0.85
        case .mixer, .remixer: 0.7
        case .engineer: 0.6
        case .composer, .writer, .lyricist: 0.55
        }
    }

    static func strongerRole(_ current: Credit.Role?, _ new: Credit.Role) -> Credit.Role {
        guard let current else { return new }
        return roleWeight(new) > roleWeight(current) ? new : current
    }
}
