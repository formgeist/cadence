import Foundation

// MARK: - Catalog

/// A named shelf of albums picked out by rules — every ECM record from the
/// seventies, say, or everything lossless added this month.
///
/// Only the rules are stored. The albums are worked out from the library each
/// time it loads, so a catalog keeps itself current: a new record that fits
/// turns up in it without anyone filing it there.
public struct Catalog: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var definition: Definition
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, definition: Definition,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.definition = definition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Everything about a catalog except its name and dates — what the store
    /// keeps as one JSON column, so a new kind of rule needs no migration.
    public struct Definition: Hashable, Sendable, Codable {
        public var match: Match
        public var rules: [CatalogRule]
        public var sort: CatalogSort

        public init(match: Match = .all, rules: [CatalogRule] = [], sort: CatalogSort = .artist) {
            self.match = match
            self.rules = rules
            self.sort = sort
        }

        /// The rules that say enough to test an album against. A rule still
        /// being filled in — a label with no name yet — is left out rather
        /// than matching everything or nothing.
        public var completeRules: [CatalogRule] { rules.filter(\.isComplete) }

        /// Whether one album belongs. Never true for a definition with no
        /// complete rules: an empty catalog is a clearer answer than one that
        /// quietly holds the whole library.
        public func matches(_ album: Album, now: Date = Date()) -> Bool {
            let rules = completeRules
            guard !rules.isEmpty else { return false }
            switch match {
            case .all: return rules.allSatisfy { $0.matches(album, now: now) }
            case .any: return rules.contains { $0.matches(album, now: now) }
            }
        }

        /// The albums from `albums` that belong, in the catalog's own order.
        public func albums(from albums: [Album], now: Date = Date()) -> [Album] {
            sort.sorted(albums.filter { matches($0, now: now) })
        }

        /// `Label is ECM and Decade is 1970s` — the rules as one line, for the
        /// catalog page header.
        public var summary: String {
            completeRules.map(\.summary)
                .joined(separator: match == .all ? " and " : " or ")
        }
    }

    /// Whether an album has to pass every rule or just one.
    public enum Match: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
        case all, any
        public var id: String { rawValue }
    }

    /// Up to four distinct covers among `albums`, for a card to tile.
    public static func covers(of albums: [Album]) -> [Artwork.ID] {
        var covers: [Artwork.ID] = []
        for album in albums {
            guard let id = album.artworkID, !covers.contains(id) else { continue }
            covers.append(id)
            if covers.count == 4 { break }
        }
        return covers
    }
}

// MARK: - Sort

/// How one catalog orders its albums. Kept per catalog: a label's catalogue
/// reads best by year, a "recently added" catalog by date added.
public enum CatalogSort: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case artist, title, yearOldest, yearNewest, recentlyAdded

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .artist: "Artist"
        case .title: "Title"
        case .yearOldest: "Year, Oldest First"
        case .yearNewest: "Year, Newest First"
        case .recentlyAdded: "Recently Added"
        }
    }

    public func sorted(_ albums: [Album]) -> [Album] {
        func byArtist(_ a: Album, _ b: Album) -> Bool {
            let order = Artist.stripArticle(a.albumArtist)
                .localizedStandardCompare(Artist.stripArticle(b.albumArtist))
            if order != .orderedSame { return order == .orderedAscending }
            return (a.year ?? 0, a.title.localizedLowercase) < (b.year ?? 0, b.title.localizedLowercase)
        }
        switch self {
        case .artist:
            return albums.sorted(by: byArtist)
        case .title:
            return albums.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? byArtist($0, $1) : order == .orderedAscending
            }
        case .yearOldest, .yearNewest:
            // Undated records go last either way: they belong to no end of
            // the timeline.
            let newestFirst = self == .yearNewest
            return albums.sorted {
                switch ($0.year, $1.year) {
                case let (a?, b?) where a != b: return newestFirst ? a > b : a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byArtist($0, $1)
                }
            }
        case .recentlyAdded:
            return albums.sorted {
                $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : byArtist($0, $1)
            }
        }
    }
}

// MARK: - Rule

/// One condition an album is tested against: a field, how to compare, and
/// what to compare with.
///
/// Flat rather than an enum with a payload per field, so the editor can
/// switch a rule from Label to Year without throwing away what was typed —
/// and so a row in the sheet binds to plain properties.
public struct CatalogRule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var field: Field
    public var op: Operator
    /// The label, artist or genre name; or a `FormatChoice` value.
    public var text: String
    /// The year, the decade's first year (`1970`), or a number of days.
    public var number: Int?
    /// The end of a year range, for `between`.
    public var upperNumber: Int?

    public init(id: UUID = UUID(), field: Field, op: Operator? = nil, text: String = "",
                number: Int? = nil, upperNumber: Int? = nil) {
        self.id = id
        self.field = field
        self.op = op ?? field.operators[0]
        self.text = text
        self.number = number
        self.upperNumber = upperNumber
    }

    public enum Field: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
        case label, artist, genre, year, decade, format, dateAdded

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .label: "Label"
            case .artist: "Artist"
            case .genre: "Genre"
            case .year: "Year"
            case .decade: "Decade"
            case .format: "Format"
            case .dateAdded: "Date Added"
            }
        }

        /// What each field can be asked; the first is what a new rule starts
        /// on.
        public var operators: [Operator] {
            switch self {
            case .label, .artist, .genre: [.is, .isNot, .contains, .doesNotContain]
            case .year: [.is, .between, .before, .after]
            case .decade, .format: [.is, .isNot]
            case .dateAdded: [.inLast, .notInLast]
            }
        }

        /// Fields whose value is a name typed (with suggestions) rather than
        /// picked from a closed list.
        public var isText: Bool { [.label, .artist, .genre].contains(self) }
    }

    public enum Operator: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
        case `is`, isNot, contains, doesNotContain
        case between, before, after
        case inLast, notInLast

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .contains: "contains"
            case .doesNotContain: "does not contain"
            case .between: "is between"
            case .before: "is before"
            case .after: "is after"
            case .inLast: "is in the last"
            case .notInLast: "is not in the last"
            }
        }

        /// The negative operators are the positive ones turned round; the
        /// match is worked out for the positive and flipped.
        var positive: Operator {
            switch self {
            case .isNot: .is
            case .doesNotContain: .contains
            case .notInLast: .inLast
            default: self
            }
        }

        var isNegated: Bool { positive != self }
    }

    /// The closed list a Format rule picks from, beyond the codec names.
    public enum FormatChoice {
        public static let lossless = "lossless"
        public static let lossy = "lossy"
        public static let hiRes = "hires"

        public static func title(for value: String) -> String {
            switch value {
            case lossless: "Lossless"
            case lossy: "Lossy"
            case hiRes: "Hi-Res"
            default: value.uppercased()
            }
        }
    }

    /// The spans a Date Added rule offers, in days.
    public static let dateAddedSpans: [Int] = [7, 30, 90, 180, 365]

    public static func spanTitle(days: Int) -> String {
        switch days {
        case 7: "week"
        case 30: "month"
        case 90: "3 months"
        case 180: "6 months"
        case 365: "year"
        default: days == 1 ? "day" : "\(days) days"
        }
    }

    // MARK: Completeness and description

    /// Whether the rule says enough to test an album against.
    public var isComplete: Bool {
        switch field {
        case .label, .artist, .genre, .format:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .year:
            return op == .between ? number != nil && upperNumber != nil : number != nil
        case .decade:
            return number != nil
        case .dateAdded:
            return (number ?? 0) > 0
        }
    }

    /// `Label is ECM`, `Year is between 1965 and 1975`.
    public var summary: String {
        "\(field.title) \(op.title) \(valueDescription)"
    }

    public var valueDescription: String {
        switch field {
        case .label, .artist, .genre:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .format:
            return FormatChoice.title(for: text)
        case .year:
            let first = number.map(String.init) ?? "…"
            guard op == .between else { return first }
            return "\(first) and \(upperNumber.map(String.init) ?? "…")"
        case .decade:
            return number.map { "\($0)s" } ?? "…"
        case .dateAdded:
            return Self.spanTitle(days: number ?? 0)
        }
    }

    /// Moves the rule to another field, keeping the operator when the new
    /// field has it and clearing values the new field reads differently.
    public mutating func change(to field: Field) {
        guard field != self.field else { return }
        let wasText = self.field.isText
        self.field = field
        if !field.operators.contains(op) { op = field.operators[0] }
        if !(wasText && field.isText) { text = "" }
        if field == .decade, let year = number { number = year / 10 * 10 }
        if field == .dateAdded { number = Self.dateAddedSpans[1] }
        if [.label, .artist, .genre, .format].contains(field) { number = nil; upperNumber = nil }
    }

    // MARK: Matching

    /// `Rock`, ` rock ` and `Röck` are one value — the same folding genres use.
    static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    public func matches(_ album: Album, now: Date = Date()) -> Bool {
        let result = matchesPositive(album, now: now)
        return op.isNegated ? !result : result
    }

    private func matchesPositive(_ album: Album, now: Date) -> Bool {
        switch field {
        case .label:
            return matchesText(album.tracks.compactMap(\.label))
        case .artist:
            // The album artist and anyone on a track: "artist is Miles Davis"
            // should find his guest spot on a compilation too.
            return matchesText([album.albumArtist] + album.tracks.map(\.artist))
        case .genre:
            return matchesText(album.tracks.compactMap(\.genre))
        case .year:
            guard let year = album.year, let number else { return false }
            switch op.positive {
            case .between:
                guard let upper = upperNumber else { return false }
                return (min(number, upper)...max(number, upper)).contains(year)
            case .before: return year < number
            case .after: return year > number
            default: return year == number
            }
        case .decade:
            guard let year = album.year, let number else { return false }
            return year / 10 * 10 == number
        case .format:
            return Self.matchesFormat(text, album: album)
        case .dateAdded:
            guard let days = number else { return false }
            return album.dateAdded >= now.addingTimeInterval(-Double(days) * 86_400)
        }
    }

    private func matchesText(_ values: [String]) -> Bool {
        let needle = Self.fold(text)
        guard !needle.isEmpty else { return false }
        let contains = op.positive == .contains
        return values.contains { value in
            let folded = Self.fold(value)
            return contains ? folded.contains(needle) : folded == needle
        }
    }

    /// Lossless means every track is; one lossy track makes the record lossy.
    /// Hi-res is any lossless track above CD resolution.
    static func matchesFormat(_ choice: String, album: Album) -> Bool {
        let formats = album.tracks.map(\.format)
        guard !formats.isEmpty else { return false }
        switch choice {
        case FormatChoice.lossless:
            return formats.allSatisfy(\.isLossless)
        case FormatChoice.lossy:
            return formats.contains { !$0.isLossless }
        case FormatChoice.hiRes:
            return formats.contains { $0.isLossless && ($0.sampleRate > 48_000 || ($0.bitDepth ?? 0) > 16) }
        default:
            return formats.contains { $0.codec.name.caseInsensitiveCompare(choice) == .orderedSame }
        }
    }
}
