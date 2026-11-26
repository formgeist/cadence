import Foundation
import CadenceCore
import CadenceLibrary

/// How library values look to an agent.
///
/// Ids are the ones the tools take back: a track's UUID, `al-…` for an album
/// and `ar-…` for an artist (`StableID`). Paths, fingerprints and artwork
/// ids never leave: an agent has no use for them, and a path says more about
/// the Mac than the library.
enum LibraryJSON {

    static func date(_ date: Date) -> JSONValue {
        .string(date.formatted(.iso8601))
    }

    static func seconds(_ duration: TimeInterval) -> JSONValue {
        .integer(Int(duration.rounded()))
    }

    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func optional(_ value: Int?) -> JSONValue { value.map(JSONValue.integer) ?? .null }

    static func format(_ format: AudioFormat) -> JSONValue {
        [
            "codec": .string(format.codec.name),
            "lossless": .bool(format.isLossless),
            "sampleRate": .integer(Int(format.sampleRate.rounded())),
            "bitDepth": optional(format.bitDepth),
            "description": .string(format.badgeDescription),
        ]
    }

    static func track(_ track: Track, liked: Bool? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(track.id.uuidString),
            "title": .string(track.title),
            "artist": .string(track.artist),
            "album": .string(track.albumTitle),
            "albumArtist": .string(track.albumArtist),
            "albumID": .string(track.albumKey.stableID),
            "year": optional(track.year),
            "genre": optional(track.genre),
            "duration": seconds(track.duration),
            "format": .string(track.format.badgeDescription),
        ]
        if let number = track.trackNumber { object["trackNumber"] = .integer(number) }
        if let disc = track.discNumber { object["discNumber"] = .integer(disc) }
        if let composer = track.composer { object["composer"] = .string(composer) }
        if let liked { object["liked"] = .bool(liked) }
        return .object(object)
    }

    static func album(_ summary: SQLiteLibraryStore.AlbumSummary) -> JSONValue {
        [
            "id": .string(summary.key.stableID),
            "title": .string(summary.key.title),
            "albumArtist": .string(summary.key.albumArtist),
            "artistID": .string(StableID.artist(named: summary.key.albumArtist)),
            "year": optional(summary.key.year),
            "genres": .array(summary.genres.map(JSONValue.string)),
            "trackCount": .integer(summary.trackCount),
            "duration": seconds(summary.duration),
            "dateAdded": date(summary.dateAdded),
        ]
    }

    static func album(_ album: Album) -> JSONValue {
        [
            "id": .string(album.stableID),
            "title": .string(album.title),
            "albumArtist": .string(album.albumArtist),
            "artistID": .string(StableID.artist(named: album.albumArtist)),
            "year": optional(album.year),
            "trackCount": .integer(album.trackCount),
            "duration": seconds(album.duration),
        ]
    }

    static func artist(_ artist: Artist) -> JSONValue {
        [
            "id": .string(artist.stableID),
            "name": .string(artist.name),
            "albumCount": .integer(artist.albumCount),
            "trackCount": .integer(artist.trackCount),
            "formats": .array(artist.formats.map(JSONValue.string)),
        ]
    }

    static func playlist(_ playlist: Playlist) -> JSONValue {
        [
            "id": .string(playlist.id.uuidString),
            "name": .string(playlist.name),
            "trackCount": .integer(playlist.trackIDs.count),
            "duration": seconds(playlist.duration),
            "folderID": optional(playlist.folderID?.uuidString),
            "updatedAt": playlist.updatedAt.map(date) ?? .null,
        ]
    }

    static func folder(_ folder: PlaylistFolder) -> JSONValue {
        ["id": .string(folder.id.uuidString), "name": .string(folder.name)]
    }

    static func rule(_ rule: CatalogRule) -> JSONValue {
        var object: [String: JSONValue] = [
            "field": .string(rule.field.rawValue),
            "op": .string(rule.op.rawValue),
        ]
        if !rule.text.isEmpty { object["text"] = .string(rule.text) }
        if let number = rule.number { object["number"] = .integer(number) }
        if let upper = rule.upperNumber { object["upperNumber"] = .integer(upper) }
        return .object(object)
    }

    static func definition(_ definition: Catalog.Definition,
                           context: Catalog.Context = .empty) -> JSONValue {
        [
            "match": .string(definition.match.rawValue),
            "rules": .array(definition.rules.map(rule)),
            "sort": .string(definition.sort.rawValue),
            "summary": .string(definition.summary(in: context)),
        ]
    }

    static func catalog(_ catalog: Catalog, albumCount: Int,
                        context: Catalog.Context = .empty) -> JSONValue {
        [
            "id": .string(catalog.id.uuidString),
            "name": .string(catalog.name),
            "definition": definition(catalog.definition, context: context),
            "albumCount": .integer(albumCount),
            "createdAt": date(catalog.createdAt),
            "updatedAt": date(catalog.updatedAt),
        ]
    }

    static func memory(_ memory: Memory) -> JSONValue {
        let album = memory.subject.albumKey
        var object: [String: JSONValue] = [
            "id": .string(memory.id.uuidString),
            "albumID": .string(album.stableID),
            "album": .string(album.title),
            "albumArtist": .string(album.albumArtist),
            "text": .string(memory.text),
            "createdAt": date(memory.createdAt),
            "updatedAt": date(memory.updatedAt),
        ]
        if case .track(let title, let artist, _) = memory.subject {
            object["trackTitle"] = .string(title)
            object["trackArtist"] = .string(artist)
        }
        return .object(object)
    }
}

/// Reads a catalog definition an agent wrote.
///
/// Not `Catalog.Definition`'s own `Decodable`: that wants a UUID on every
/// rule, which an agent has no reason to invent, and it would accept an
/// operator the field does not offer.
enum CatalogInput {

    static let schema: JSONValue = Schema.object([
        "match": Schema.choice("Whether an album must pass every rule (all) or one (any). Default all.",
                               Catalog.Match.allCases.map(\.rawValue)),
        "sort": Schema.choice("Album order. Default artist.", CatalogSort.allCases.map(\.rawValue)),
        "rules": [
            "type": "array",
            "minItems": 1,
            "description": .string("""
                Each rule tests one field. label, artist, genre take text with is, isNot, \
                contains, doesNotContain. year takes number with is, before, after, or \
                number and upperNumber with between. decade takes number, the decade's \
                first year (1970), with is or isNot. format takes text, a codec name \
                (FLAC, ALAC, MP3…) or lossless, lossy, hires, with is or isNot. dateAdded \
                takes number, a count of days, with inLast or notInLast. playlist takes \
                text, a playlist id from list_playlists, with is or isNot; an album \
                matches when any of its tracks is in that playlist.
                """),
            "items": Schema.object([
                "field": Schema.choice("The field to test.", CatalogRule.Field.allCases.map(\.rawValue)),
                "op": Schema.choice("The test.", CatalogRule.Operator.allCases.map(\.rawValue)),
                "text": Schema.string("For label, artist, genre, format, and playlist (its id)."),
                "number": Schema.integer("For year, decade and dateAdded."),
                "upperNumber": Schema.integer("The last year, for year between."),
            ], required: ["field", "op"]),
        ],
    ], required: ["rules"])

    static func definition(from value: JSONValue?) throws -> Catalog.Definition {
        guard let object = value?.objectValue else {
            throw MCPToolError("“definition” must be an object with rules.")
        }
        let arguments = try MCPArguments(object, allowed: ["match", "sort", "rules"])
        let match = try arguments.choice("match", from: Catalog.Match.allCases.map(\.rawValue))
            .flatMap(Catalog.Match.init(rawValue:)) ?? .all
        let sort = try arguments.choice("sort", from: CatalogSort.allCases.map(\.rawValue))
            .flatMap(CatalogSort.init(rawValue:)) ?? .artist
        guard let rawRules = arguments.raw("rules")?.arrayValue, !rawRules.isEmpty else {
            throw MCPToolError("“rules” must be a list with at least one rule.")
        }
        guard rawRules.count <= 20 else { throw MCPToolError("A catalog takes at most 20 rules.") }
        let rules = try rawRules.enumerated().map { index, raw in
            try rule(from: raw, number: index + 1)
        }
        return Catalog.Definition(match: match, rules: rules, sort: sort)
    }

    /// The playlists a definition's rules name, read only when a rule names
    /// one. A playlist id that is not in the library is refused here rather
    /// than saved as a rule that never matches.
    static func context(for definition: Catalog.Definition,
                        in library: SQLiteLibraryStore) async throws -> Catalog.Context {
        guard definition.usesPlaylists else { return .empty }
        let context = Catalog.Context(playlists: try await library.playlists())
        for (index, rule) in definition.rules.enumerated() where rule.field == .playlist {
            guard let id = rule.playlistID, context.playlists[id] != nil else {
                throw MCPToolError("Rule \(index + 1): no playlist has the id “\(rule.text)”.")
            }
        }
        return context
    }

    private static func rule(from value: JSONValue, number: Int) throws -> CatalogRule {
        guard let object = value.objectValue else { throw MCPToolError("Rule \(number) must be an object.") }
        do {
            let arguments = try MCPArguments(
                object, allowed: ["field", "op", "text", "number", "upperNumber"])
            guard let fieldName = try arguments.choice(
                    "field", from: CatalogRule.Field.allCases.map(\.rawValue)),
                  let field = CatalogRule.Field(rawValue: fieldName) else {
                throw MCPToolError("“field” is required.")
            }
            let opName = try arguments.requiredString("op")
            guard let op = CatalogRule.Operator(rawValue: opName), field.operators.contains(op) else {
                throw MCPToolError("“op” for \(field.rawValue) must be one of: "
                    + field.operators.map(\.rawValue).joined(separator: ", ") + ".")
            }
            let rule = CatalogRule(field: field, op: op,
                                   text: try arguments.string("text") ?? "",
                                   number: try arguments.int("number"),
                                   upperNumber: try arguments.int("upperNumber"))
            guard rule.isComplete else {
                throw MCPToolError("It is missing the value \(field.rawValue) \(op.rawValue) needs.")
            }
            return rule
        } catch let error as MCPToolError {
            throw MCPToolError("Rule \(number): \(error.message)")
        }
    }
}
