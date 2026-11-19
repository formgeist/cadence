import Foundation
import CadenceCore
import CadenceLibrary

/// What an agent changed, so the app can re-read that part and say so.
public struct LibraryChange: Sendable, Equatable {
    public enum Part: Sendable, Hashable {
        case playlists, folders, catalogs, memories, likes
    }

    public var parts: Set<Part>
    /// One line for the window, like `Created the playlist “Late night”`.
    public var summary: String

    public init(_ parts: Set<Part>, _ summary: String) {
        self.parts = parts
        self.summary = summary
    }
}

/// The write tools: playlists, folders, catalogs, memories and likes.
///
/// They write `SQLiteLibraryStore` and then report a `LibraryChange`, which
/// the app answers by re-reading what changed. That keeps this type free of
/// the app and testable here, and it means the window shows an agent's edit
/// as soon as it lands.
///
/// What they cannot do is as deliberate as what they can: remove a track
/// from the library, touch music folders, rescan, or reach pairing and
/// sharing. Every delete takes an id, never a name.
public struct LibraryWriteTools: MCPToolHandler {

    private let library: SQLiteLibraryStore
    private let onChange: @Sendable (LibraryChange) async -> Void
    private let now: @Sendable () -> Date

    /// The most ids one call takes. A playlist of a whole library is not
    /// what an agent should be building in one step.
    static let maximumTrackIDs = 1000
    static let maximumNameLength = 200

    public init(library: SQLiteLibraryStore,
                now: @escaping @Sendable () -> Date = Date.init,
                onChange: @escaping @Sendable (LibraryChange) async -> Void) {
        self.library = library
        self.now = now
        self.onChange = onChange
    }

    // MARK: - Descriptions

    private static let trackIDs = JSONValue.object([
        "type": "array", "items": ["type": "string"],
        "minItems": 1, "maxItems": .integer(maximumTrackIDs),
        "description": "Track ids, from search_tracks, get_album and the other read tools.",
    ])
    private static let positions = JSONValue.object([
        "type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 1,
        "description": "Positions in the playlist, from get_playlist, counting from 0.",
    ])
    private static let edit = MCPTool.Annotations()
    private static let idempotentEdit = MCPTool.Annotations(idempotent: true)
    private static let delete = MCPTool.Annotations(destructive: true, idempotent: true)

    public var tools: [MCPTool] {
        [
            MCPTool(
                name: "create_playlist", title: "Create playlist",
                description: "Makes a playlist, optionally with tracks and filed in a folder. Returns it.",
                inputSchema: Schema.object([
                    "name": Schema.string("The playlist's name."),
                    "trackIDs": Self.trackIDs,
                    "folderID": Schema.string("A folder id from list_playlists."),
                ], required: ["name"]),
                annotations: Self.edit),
            MCPTool(
                name: "add_tracks_to_playlist", title: "Add to playlist",
                description: "Adds tracks to the end of a playlist, in the order given.",
                inputSchema: Schema.object([
                    "playlistID": Schema.string("A playlist id."),
                    "trackIDs": Self.trackIDs,
                ], required: ["playlistID", "trackIDs"]),
                annotations: Self.edit),
            MCPTool(
                name: "remove_tracks_from_playlist", title: "Remove from playlist",
                description: """
                    Takes tracks out of a playlist by position. The tracks stay in the library.
                    """,
                inputSchema: Schema.object([
                    "playlistID": Schema.string("A playlist id."),
                    "positions": Self.positions,
                ], required: ["playlistID", "positions"]),
                annotations: Self.delete),
            MCPTool(
                name: "move_tracks_in_playlist", title: "Reorder playlist",
                description: """
                    Moves the tracks at positions so they sit before the track now at \
                    toPosition, keeping their order. toPosition equal to the track count \
                    moves them to the end. Both count the playlist as it is before the move.
                    """,
                inputSchema: Schema.object([
                    "playlistID": Schema.string("A playlist id."),
                    "positions": Self.positions,
                    "toPosition": Schema.integer("Where they go, from 0 to the track count.", minimum: 0),
                ], required: ["playlistID", "positions", "toPosition"]),
                annotations: Self.edit),
            MCPTool(
                name: "rename_playlist", title: "Rename playlist",
                description: "Gives a playlist a new name.",
                inputSchema: Schema.object([
                    "playlistID": Schema.string("A playlist id."),
                    "name": Schema.string("The new name."),
                ], required: ["playlistID", "name"]),
                annotations: Self.idempotentEdit),
            MCPTool(
                name: "delete_playlist", title: "Delete playlist",
                description: "Deletes a playlist. Its tracks stay in the library.",
                inputSchema: Schema.object(["playlistID": Schema.string("A playlist id.")],
                                           required: ["playlistID"]),
                annotations: Self.delete),
            MCPTool(
                name: "create_playlist_folder", title: "Create folder",
                description: "Makes a sidebar folder for playlists. Returns it.",
                inputSchema: Schema.object(["name": Schema.string("The folder's name.")],
                                           required: ["name"]),
                annotations: Self.edit),
            MCPTool(
                name: "rename_playlist_folder", title: "Rename folder",
                description: "Gives a playlist folder a new name.",
                inputSchema: Schema.object([
                    "folderID": Schema.string("A folder id."),
                    "name": Schema.string("The new name."),
                ], required: ["folderID", "name"]),
                annotations: Self.idempotentEdit),
            MCPTool(
                name: "delete_playlist_folder", title: "Delete folder",
                description: "Deletes a folder. Its playlists are kept and move to the top level.",
                inputSchema: Schema.object(["folderID": Schema.string("A folder id.")],
                                           required: ["folderID"]),
                annotations: Self.delete),
            MCPTool(
                name: "move_playlist_to_folder", title: "Move playlist to folder",
                description: "Files a playlist in a folder, or at the top level without folderID.",
                inputSchema: Schema.object([
                    "playlistID": Schema.string("A playlist id."),
                    "folderID": Schema.string("A folder id. Leave out for the top level."),
                ], required: ["playlistID"]),
                annotations: Self.idempotentEdit),
            MCPTool(
                name: "save_catalog", title: "Save catalog",
                description: """
                    Creates a catalog, or with catalogID replaces an existing one's name and \
                    rules. Check the rules with preview_catalog first. Returns the catalog \
                    and how many albums it holds.
                    """,
                inputSchema: Schema.object([
                    "catalogID": Schema.string("A catalog id, to change that catalog."),
                    "name": Schema.string("The catalog's name."),
                    "definition": CatalogInput.schema,
                ], required: ["name", "definition"]),
                annotations: Self.idempotentEdit),
            MCPTool(
                name: "delete_catalog", title: "Delete catalog",
                description: "Deletes a catalog. Its albums stay in the library.",
                inputSchema: Schema.object(["catalogID": Schema.string("A catalog id.")],
                                           required: ["catalogID"]),
                annotations: Self.delete),
            MCPTool(
                name: "save_memory", title: "Save memory",
                description: """
                    Keeps a short note, at most \(Memory.maximumLength) characters, on an \
                    album (albumID) or a song (trackID). With memoryID, changes that \
                    memory's text instead. Memories are the user's own words: write one \
                    only when the user asked for it.
                    """,
                inputSchema: Schema.object([
                    "memoryID": Schema.string("A memory id, to change its text."),
                    "albumID": Schema.string("An al-… album id, for a note on the album."),
                    "trackID": Schema.string("A track id, for a note on one song."),
                    "text": Schema.string("The note."),
                ], required: ["text"]),
                annotations: Self.edit),
            MCPTool(
                name: "delete_memory", title: "Delete memory",
                description: "Deletes a memory. It cannot be brought back.",
                inputSchema: Schema.object(["memoryID": Schema.string("A memory id.")],
                                           required: ["memoryID"]),
                annotations: Self.delete),
            MCPTool(
                name: "set_liked", title: "Like or unlike",
                description: "Adds tracks to Liked Songs, or with liked false takes them out.",
                inputSchema: Schema.object([
                    "trackIDs": Self.trackIDs,
                    "liked": ["type": "boolean", "description": "True to like, false to unlike."],
                ], required: ["trackIDs", "liked"]),
                annotations: Self.idempotentEdit),
        ]
    }

    // MARK: - Calls

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let allowed = Set(tools.first { $0.name == name }?
            .inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let arguments = try MCPArguments(arguments, allowed: allowed)
        switch name {
        case "create_playlist": return try await createPlaylist(arguments)
        case "add_tracks_to_playlist": return try await addTracks(arguments)
        case "remove_tracks_from_playlist": return try await removeTracks(arguments)
        case "move_tracks_in_playlist": return try await moveTracks(arguments)
        case "rename_playlist": return try await renamePlaylist(arguments)
        case "delete_playlist": return try await deletePlaylist(arguments)
        case "create_playlist_folder": return try await createFolder(arguments)
        case "rename_playlist_folder": return try await renameFolder(arguments)
        case "delete_playlist_folder": return try await deleteFolder(arguments)
        case "move_playlist_to_folder": return try await movePlaylist(arguments)
        case "save_catalog": return try await saveCatalog(arguments)
        case "delete_catalog": return try await deleteCatalog(arguments)
        case "save_memory": return try await saveMemory(arguments)
        case "delete_memory": return try await deleteMemory(arguments)
        case "set_liked": return try await setLiked(arguments)
        default: throw MCPToolError("Unknown tool.")
        }
    }

    // MARK: Playlists

    private func createPlaylist(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let name = try Self.name(arguments)
        let trackIDs = try await existingTracks(arguments, required: false)
        let folder = try await optionalFolder(arguments)

        let created = try await library.createPlaylist(named: name)
        if !trackIDs.isEmpty { try await library.addTracks(trackIDs, to: created.id) }
        if let folder { try await library.movePlaylist(created.id, toFolder: folder.id) }
        var parts: Set<LibraryChange.Part> = [.playlists]
        if folder != nil { parts.insert(.folders) }
        await onChange(.init(parts, "Created the playlist “\(name)”"))
        return try await playlistResult(created.id, "Created “\(name)” with \(Self.count(trackIDs.count)).")
    }

    private func addTracks(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        let trackIDs = try await existingTracks(arguments, required: true)
        try await library.addTracks(trackIDs, to: playlist.id)
        await onChange(.init([.playlists], "Added \(Self.count(trackIDs.count)) to “\(playlist.name)”"))
        return try await playlistResult(playlist.id, "Added \(Self.count(trackIDs.count)) to “\(playlist.name)”.")
    }

    private func removeTracks(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        let offsets = try Self.positions(arguments, in: playlist)
        try await library.removeTracks(atOffsets: offsets, from: playlist.id)
        await onChange(.init([.playlists], "Removed \(Self.count(offsets.count)) from “\(playlist.name)”"))
        return try await playlistResult(playlist.id, "Removed \(Self.count(offsets.count)) from “\(playlist.name)”.")
    }

    private func moveTracks(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        let offsets = try Self.positions(arguments, in: playlist)
        guard let destination = try arguments.int("toPosition", in: 0...playlist.trackIDs.count) else {
            throw MCPToolError("“toPosition” is required.")
        }
        try await library.moveTracks(fromOffsets: offsets, toOffset: destination, in: playlist.id)
        await onChange(.init([.playlists], "Reordered “\(playlist.name)”"))
        return try await playlistResult(playlist.id, "Moved \(Self.count(offsets.count)) in “\(playlist.name)”.")
    }

    private func renamePlaylist(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        let name = try Self.name(arguments)
        try await library.renamePlaylist(playlist.id, to: name)
        await onChange(.init([.playlists], "Renamed “\(playlist.name)” to “\(name)”"))
        return try await playlistResult(playlist.id, "Renamed “\(playlist.name)” to “\(name)”.")
    }

    private func deletePlaylist(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        try await library.deletePlaylist(playlist.id)
        await onChange(.init([.playlists], "Deleted the playlist “\(playlist.name)”"))
        return MCPToolResult(text: "Deleted “\(playlist.name)”.",
                             structured: ["deleted": .string(playlist.id.uuidString)])
    }

    // MARK: Folders

    private func createFolder(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let name = try Self.name(arguments)
        let folder = try await library.createPlaylistFolder(named: name)
        await onChange(.init([.folders], "Created the folder “\(name)”"))
        return MCPToolResult(text: "Created the folder “\(name)”.", structured: LibraryJSON.folder(folder))
    }

    private func renameFolder(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let folder = try await existingFolder(arguments.requiredUUID("folderID"))
        let name = try Self.name(arguments)
        try await library.renamePlaylistFolder(folder.id, to: name)
        await onChange(.init([.folders], "Renamed the folder “\(folder.name)” to “\(name)”"))
        return MCPToolResult(text: "Renamed “\(folder.name)” to “\(name)”.",
                             structured: LibraryJSON.folder(PlaylistFolder(id: folder.id, name: name)))
    }

    private func deleteFolder(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let folder = try await existingFolder(arguments.requiredUUID("folderID"))
        try await library.deletePlaylistFolder(folder.id)
        // Its playlists moved to the top level, so both lists change.
        await onChange(.init([.folders, .playlists], "Deleted the folder “\(folder.name)”"))
        return MCPToolResult(text: "Deleted the folder “\(folder.name)”; its playlists are at the top level.",
                             structured: ["deleted": .string(folder.id.uuidString)])
    }

    private func movePlaylist(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let playlist = try await existingPlaylist(arguments)
        let folder = try await optionalFolder(arguments)
        try await library.movePlaylist(playlist.id, toFolder: folder?.id)
        let place = folder.map { "“\($0.name)”" } ?? "the top level"
        await onChange(.init([.playlists, .folders], "Moved “\(playlist.name)” to \(place)"))
        return try await playlistResult(playlist.id, "Moved “\(playlist.name)” to \(place).")
    }

    // MARK: Catalogs

    private func saveCatalog(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let name = try Self.name(arguments)
        let definition = try CatalogInput.definition(from: arguments.raw("definition"))
        let date = now()
        let catalog: Catalog
        let created: Bool
        if let id = try arguments.uuid("catalogID") {
            guard var existing = try await library.catalogs().first(where: { $0.id == id }) else {
                throw MCPToolError("No catalog has the id \(id.uuidString).")
            }
            existing.name = name
            existing.definition = definition
            existing.updatedAt = date
            catalog = existing
            created = false
        } else {
            catalog = Catalog(name: name, definition: definition, createdAt: date, updatedAt: date)
            created = true
        }
        try await library.saveCatalog(catalog)
        await onChange(.init([.catalogs], "\(created ? "Created" : "Changed") the catalog “\(name)”"))
        let count = definition.albums(from: try await library.albums(), now: date).count
        return MCPToolResult(
            text: "\(created ? "Created" : "Saved") “\(name)”: \(definition.summary), \(count) albums.",
            structured: LibraryJSON.catalog(catalog, albumCount: count))
    }

    private func deleteCatalog(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let id = try arguments.requiredUUID("catalogID")
        guard let catalog = try await library.catalogs().first(where: { $0.id == id }) else {
            throw MCPToolError("No catalog has the id \(id.uuidString).")
        }
        try await library.deleteCatalog(id)
        await onChange(.init([.catalogs], "Deleted the catalog “\(catalog.name)”"))
        return MCPToolResult(text: "Deleted “\(catalog.name)”.", structured: ["deleted": .string(id.uuidString)])
    }

    // MARK: Memories

    private func saveMemory(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let raw = try arguments.requiredString("text")
        // Refused rather than cut: `Memory.cleaned` would trim a long note to
        // fit, and an agent should hear that instead of finding it shortened.
        guard raw.count <= Memory.maximumLength, let text = Memory.cleaned(raw) else {
            throw MCPToolError("A memory is at most \(Memory.maximumLength) characters; this is \(raw.count).")
        }
        let memoryID = try arguments.uuid("memoryID")
        let albumID = try arguments.string("albumID")
        let trackID = try arguments.uuid("trackID")
        let date = now()

        let memory: Memory
        if let memoryID {
            guard albumID == nil, trackID == nil else {
                throw MCPToolError("Give memoryID to change a memory's text, or albumID or trackID for a new one, not both.")
            }
            guard var existing = try await library.memories().first(where: { $0.id == memoryID }) else {
                throw MCPToolError("No memory has the id \(memoryID.uuidString).")
            }
            existing.text = text
            existing.updatedAt = date
            memory = existing
        } else {
            let subject: Memory.Subject
            switch (albumID, trackID) {
            case (let albumID?, nil):
                guard let key = try await library.albumKey(forStableID: albumID),
                      try await library.album(for: key) != nil else {
                    throw MCPToolError("No album has the id \(albumID.prefix(40)).")
                }
                subject = .album(key)
            case (nil, let trackID?):
                guard let track = try await library.track(withID: trackID) else {
                    throw MCPToolError("No track has the id \(trackID.uuidString).")
                }
                subject = Memory.Subject(track: track)
            default:
                throw MCPToolError("Give either albumID or trackID.")
            }
            memory = Memory(subject: subject, text: text, createdAt: date)
        }
        try await library.saveMemory(memory)
        let about = memory.subject.trackTitle ?? memory.subject.albumKey.title
        await onChange(.init([.memories], "\(memoryID == nil ? "Saved" : "Changed") a memory for “\(about)”"))
        return MCPToolResult(text: "\(memoryID == nil ? "Saved" : "Changed") a memory for “\(about)”.",
                             structured: LibraryJSON.memory(memory))
    }

    private func deleteMemory(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let id = try arguments.requiredUUID("memoryID")
        guard let memory = try await library.memories().first(where: { $0.id == id }) else {
            throw MCPToolError("No memory has the id \(id.uuidString).")
        }
        try await library.deleteMemory(id)
        let about = memory.subject.trackTitle ?? memory.subject.albumKey.title
        await onChange(.init([.memories], "Deleted a memory for “\(about)”"))
        return MCPToolResult(text: "Deleted the memory for “\(about)”.",
                             structured: ["deleted": .string(id.uuidString)])
    }

    // MARK: Likes

    private func setLiked(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let trackIDs = try await existingTracks(arguments, required: true)
        guard let liked = try arguments.bool("liked") else { throw MCPToolError("“liked” is required.") }
        try await library.setLiked(liked, trackIDs: trackIDs)
        let what = Self.count(Set(trackIDs).count)
        let summary = liked ? "Liked \(what)" : "Unliked \(what)"
        await onChange(.init([.likes], summary))
        return MCPToolResult(text: summary + ".", structured: [
            "liked": .bool(liked),
            "trackIDs": .array(trackIDs.map { .string($0.uuidString) }),
        ])
    }

    // MARK: - Checks

    private static func name(_ arguments: MCPArguments) throws -> String {
        let name = try arguments.requiredString("name")
            .components(separatedBy: .controlCharacters).joined()
        guard !name.isEmpty else { throw MCPToolError("“name” is required.") }
        guard name.count <= maximumNameLength else {
            throw MCPToolError("“name” is at most \(maximumNameLength) characters.")
        }
        return name
    }

    /// The track ids given, in order, every one checked. An id with no track
    /// fails the whole call: the store would skip it quietly, and the agent
    /// would believe it had been added.
    private func existingTracks(_ arguments: MCPArguments, required: Bool) async throws -> [Track.ID] {
        guard let raw = arguments.raw("trackIDs") else {
            if required { throw MCPToolError("“trackIDs” is required.") }
            return []
        }
        guard let values = raw.arrayValue, !values.isEmpty else {
            throw MCPToolError("“trackIDs” must be a list of at least one track id.")
        }
        guard values.count <= Self.maximumTrackIDs else {
            throw MCPToolError("“trackIDs” takes at most \(Self.maximumTrackIDs) ids per call.")
        }
        let ids = try values.map { value -> Track.ID in
            guard let string = value.stringValue, let id = UUID(uuidString: string) else {
                throw MCPToolError("“trackIDs” holds something that is not a track id.")
            }
            return id
        }
        let found = try await library.tracks(withIDs: ids)
        let missing = ids.filter { found[$0] == nil }
        guard missing.isEmpty else {
            let shown = missing.prefix(5).map(\.uuidString).joined(separator: ", ")
            throw MCPToolError("\(Self.count(missing.count)) not in the library: \(shown)"
                + (missing.count > 5 ? ", …" : "") + ". Nothing was changed.")
        }
        return ids
    }

    private func existingPlaylist(_ arguments: MCPArguments) async throws -> Playlist {
        let id = try arguments.requiredUUID("playlistID")
        guard let playlist = try await library.playlists().first(where: { $0.id == id }) else {
            throw MCPToolError("No playlist has the id \(id.uuidString).")
        }
        return playlist
    }

    private func optionalFolder(_ arguments: MCPArguments) async throws -> PlaylistFolder? {
        guard let id = try arguments.uuid("folderID") else { return nil }
        return try await existingFolder(id)
    }

    private func existingFolder(_ id: UUID) async throws -> PlaylistFolder {
        guard let folder = try await library.playlistFolders().first(where: { $0.id == id }) else {
            throw MCPToolError("No folder has the id \(id.uuidString).")
        }
        return folder
    }

    private static func positions(_ arguments: MCPArguments, in playlist: Playlist) throws -> IndexSet {
        guard let values = arguments.raw("positions")?.arrayValue, !values.isEmpty else {
            throw MCPToolError("“positions” must be a list of at least one position.")
        }
        var offsets = IndexSet()
        for value in values {
            guard let position = value.intValue, playlist.trackIDs.indices.contains(position) else {
                throw MCPToolError("“\(playlist.name)” has \(count(playlist.trackIDs.count)); "
                    + "positions run from 0 to \(max(0, playlist.trackIDs.count - 1)).")
            }
            offsets.insert(position)
        }
        return offsets
    }

    private func playlistResult(_ id: Playlist.ID, _ text: String) async throws -> MCPToolResult {
        guard let playlist = try await library.playlists().first(where: { $0.id == id }) else {
            return MCPToolResult(text: text)
        }
        return MCPToolResult(text: text, structured: LibraryJSON.playlist(playlist))
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 track" : "\(n) tracks" }
}

/// Several handlers offered as one: the read tools and the write tools.
public struct MCPToolSet: MCPToolHandler {
    private let handlers: [any MCPToolHandler]

    public init(_ handlers: [any MCPToolHandler]) {
        self.handlers = handlers
    }

    public var tools: [MCPTool] { handlers.flatMap(\.tools) }

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard let handler = handlers.first(where: { $0.tools.contains { $0.name == name } }) else {
            throw MCPToolError("Unknown tool.")
        }
        return try await handler.call(name, arguments: arguments)
    }
}
