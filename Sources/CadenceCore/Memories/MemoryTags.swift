import Foundation

/// A word marked with `#` in a memory — `#Axel`, `#Bristol` — that gathers
/// every note carrying it. Nothing is stored: tags are read out of the notes'
/// own text, so writing one is all it takes, and editing it out removes it.
public struct MemoryTag: Hashable, Sendable, Identifiable {
    /// The folded spelling: `#axel` and `#Axel` are one tag.
    public var key: String
    /// How the notes spell it, without the `#` — the commonest spelling.
    public var name: String
    /// How many notes carry it.
    public var count: Int
    public var id: String { key }

    public init(key: String, name: String, count: Int) {
        self.key = key
        self.name = name
        self.count = count
    }
}

extension Memory {
    /// `#` and then letters, digits, `_` or inner hyphens — in any script, so
    /// `#Ærø` and `#Malmö` are tags. Not mid-word: `C#minor` carries none.
    /// Immutable once built and only ever matched against, which
    /// `NSRegularExpression` documents as safe from any thread.
    nonisolated(unsafe) private static let tagPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_#])#([\\p{L}\\p{N}_]+(?:-[\\p{L}\\p{N}_]+)*)")

    /// Where each tag sits in `text`, `#` included — for highlighting.
    public static func tagRanges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        return tagPattern.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
    }

    /// The tags `text` carries, without their `#`, in the order written, each
    /// once however often it repeats.
    public static func tagNames(in text: String) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return tagPattern.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let name = String(text[range])
            return seen.insert(tagKey(name)).inserted ? name : nil
        }
    }

    /// The identity a tag is filed under: case and diacritics folded, like a
    /// genre — with or without its `#`.
    public static func tagKey(_ name: String) -> String {
        let bare = name.hasPrefix("#") ? String(name.dropFirst()) : name
        return bare.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// This note's tags, without their `#`.
    public var tags: [String] { Self.tagNames(in: text) }

    public var tagKeys: Set<String> { Set(tags.map(Self.tagKey)) }

    /// Every tag across `memories`, A–Z, each under its commonest spelling,
    /// with how many notes carry it.
    public static func tags(in memories: [Memory]) -> [MemoryTag] {
        var spellings: [String: [String: Int]] = [:]
        var counts: [String: Int] = [:]
        for memory in memories {
            for name in memory.tags {
                let key = tagKey(name)
                spellings[key, default: [:]][name, default: 0] += 1
                counts[key, default: 0] += 1
            }
        }
        return counts.map { key, count in
            // Commonest spelling; ties to the first alphabetically, so the
            // chip does not flip between loads.
            let name = spellings[key]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
            return MemoryTag(key: key, name: name, count: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether every word of `query` appears in the note or in what it is
    /// about — the song, its artist, the record and the record's artist.
    /// Case and diacritics are ignored, and a leading `#` on a word is too,
    /// so `#axel` finds a note that says `#Axel`. An empty query matches all.
    public func matches(query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { word in
            Self.fold(word.hasPrefix("#") ? String(word.dropFirst()) : String(word))
        }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        var haystack = [text, subject.albumKey.title, subject.albumKey.albumArtist]
        if case .track(let title, let artist, _) = subject { haystack += [title, artist] }
        let folded = Self.fold(haystack.joined(separator: "\n"))
        return words.allSatisfy { folded.contains($0) }
    }

    /// The notes that carry `tag` (a key from `tags(in:)`, or nil for all)
    /// and match `query`, in the order given.
    public static func filter(_ memories: [Memory], query: String, tag: String?) -> [Memory] {
        memories.filter { memory in
            (tag.map { memory.tagKeys.contains($0) } ?? true) && memory.matches(query: query)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
