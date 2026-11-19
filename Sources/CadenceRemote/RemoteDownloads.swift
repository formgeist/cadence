import Foundation

/// The songs kept on this device on purpose, so they play without the Mac.
///
/// `RemoteTrackSource` keeps a cache as well, but the cache is there to make
/// playback work and is allowed to forget: it lives in Caches, which the
/// system may empty when space runs short, and it removes the files used
/// longest ago once it passes its budget. A kept song is different. The
/// listener chose it, and it is gone only when they remove it:
///
/// - **The folder belongs in Application Support,** which the system never
///   empties. The caller chooses it; this type does not look it up.
/// - **It has no budget.** Nothing is removed except by `remove(songID:)` or
///   `removeAll()`.
/// - **It is excluded from backups.** Every file can be downloaded again from
///   the Mac, and a library's worth of music would fill an iCloud backup.
///
/// Files are named as the cache names them, `<song id>.<suffix>`, so a kept
/// song is found from its track's location alone. Song ids are made only of
/// letters, digits and hyphens (`RemoteTrackLocation.parse` refuses anything
/// else), so the part before the first dot is always the id.
///
/// Songs are put here by `RemoteTrackSource.keep(_:)`, which shares its
/// downloads with playback. This type only reads, lists and removes songs,
/// and is safe to use from any thread: everything it does is a single
/// file-system call, and a file appears here only by an atomic rename.
///
/// **What was downloaded is kept too.** A Downloaded screen has to work with
/// the Mac away, for albums never opened offline, and the metadata cache can
/// be emptied. So the albums and playlists the listener downloaded are
/// stored here as well, with their songs, in `albums/` and `playlists/`, and
/// their covers in `covers/`. Removing an album removes only the songs no
/// other kept album or playlist lists.
public struct RemoteDownloads: Sendable {

    public let directory: URL

    /// - Parameter directory: A folder of its own in Application Support, per
    ///   paired Mac. It is created when the first song is kept.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The kept file for a track's location, or nil when that song is not
    /// kept or the location is not a remote track's.
    public func file(for location: URL) -> URL? {
        guard let (songID, suffix) = RemoteTrackLocation.parse(location) else { return nil }
        return existingFile(songID: songID, suffix: suffix)
    }

    /// The id of every kept song.
    public func songIDs() -> Set<String> {
        Set(files().map(Self.songID(of:)))
    }

    /// Bytes of kept music.
    public func totalBytes() -> Int64 {
        files().reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Removes a kept song, whatever its suffix. A song that is not kept is
    /// left as it is.
    public func remove(songID: String) {
        for file in files() where Self.songID(of: file) == songID {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every kept song, album, playlist and cover, and the folder.
    /// For when the listener clears their downloads or forgets the Mac.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Albums and playlists

    /// Remembers a downloaded album, with its songs, replacing an earlier
    /// copy.
    public func save(album: RemoteAlbum) throws {
        try write(album, to: record(Self.albums, id: album.id))
    }

    /// Remembers a downloaded playlist, with its songs in order.
    public func save(playlist: RemotePlaylist) throws {
        try write(playlist, to: record(Self.playlists, id: playlist.id))
    }

    /// Every downloaded album, in no particular order.
    public func albums() -> [RemoteAlbum] {
        records(Self.albums)
    }

    public func playlists() -> [RemotePlaylist] {
        records(Self.playlists)
    }

    public func album(id: String) -> RemoteAlbum? {
        record(Self.albums, id: id).flatMap(read)
    }

    public func playlist(id: String) -> RemotePlaylist? {
        record(Self.playlists, id: id).flatMap(read)
    }

    /// Forgets a downloaded album and removes its songs and cover, except
    /// those another downloaded album or playlist still uses.
    public func removeAlbum(id: String) {
        guard let file = record(Self.albums, id: id) else { return }
        let album: RemoteAlbum? = read(file)
        try? FileManager.default.removeItem(at: file)
        removeUnused(songs: (album?.song ?? []).map(\.id), cover: album?.coverArt)
    }

    /// Forgets a downloaded playlist and removes its songs and cover, except
    /// those another downloaded album or playlist still uses.
    public func removePlaylist(id: String) {
        guard let file = record(Self.playlists, id: id) else { return }
        let playlist: RemotePlaylist? = read(file)
        try? FileManager.default.removeItem(at: file)
        removeUnused(songs: (playlist?.entry ?? []).map(\.id), cover: playlist?.coverArt)
    }

    /// Removes kept songs and covers that no downloaded album or playlist
    /// uses any more, and returns the ids of the songs removed.
    ///
    /// For after the records are refreshed from the Mac: a song taken off a
    /// playlist there, or an album retagged into a different one, leaves
    /// files nothing lists.
    @discardableResult
    public func prune() -> Set<String> {
        let (songs, covers) = inUse()
        let orphans = songIDs().subtracting(songs)
        for id in orphans { remove(songID: id) }
        let coverFolder = directory.appendingPathComponent("covers", isDirectory: true)
        let kept = (try? FileManager.default.contentsOfDirectory(
            at: coverFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in kept where !covers.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        return orphans
    }

    // MARK: - Covers

    /// Keeps a cover's image under its artwork id.
    public func save(cover data: Data, id: String) throws {
        guard let file = coverFile(id: id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepare()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// The kept image for an artwork id, or nil when there is none.
    public func cover(id: String) -> URL? {
        guard let file = coverFile(id: id), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    // MARK: - For RemoteTrackSource

    func path(songID: String, suffix: String) -> URL {
        directory.appendingPathComponent(suffix.isEmpty ? songID : "\(songID).\(suffix)")
    }

    func existingFile(songID: String, suffix: String) -> URL? {
        let file = path(songID: songID, suffix: suffix)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Puts a complete file into the folder under the song's name and
    /// returns where it is now.
    ///
    /// - Parameter moving: True to move the file in, false to copy it, for a
    ///   file that something else may still have open. On APFS the copy is a
    ///   clone and costs no space until one of the two changes.
    ///
    /// The file arrives under a hidden name first and is renamed into place,
    /// so nothing reading the folder ever sees half of one.
    func keep(_ file: URL, songID: String, suffix: String, moving: Bool) throws -> URL {
        try prepare()
        let destination = path(songID: songID, suffix: suffix)
        let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            if moving {
                try FileManager.default.moveItem(at: file, to: partial)
            } else {
                try FileManager.default.copyItem(at: file, to: partial)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return destination
    }

    // MARK: - Private

    /// Creates the folder and excludes it from backups. Setting the flag on
    /// the folder covers everything in it.
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// Every kept song file. Hidden files are partial ones still arriving,
    /// and the folders hold albums, playlists and covers.
    private func files() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return found.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static let albums = "albums"
    private static let playlists = "playlists"

    /// The file for an album or playlist record, or nil for an id that could
    /// not be one the server issued and so must never become a file name.
    private func record(_ kind: String, id: String) -> URL? {
        guard Self.isSafe(id) else { return nil }
        return directory.appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(id + ".json")
    }

    private func records<Record: Decodable>(_ kind: String) -> [Record] {
        let folder = directory.appendingPathComponent(kind, isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return found.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    private func read<Record: Decodable>(_ file: URL) -> Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write<Record: Encodable>(_ value: Record, to file: URL?) throws {
        guard let file else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepare()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    /// Removes kept songs, and a cover, that no remaining album or playlist
    /// uses.
    private func removeUnused(songs ids: [String], cover: String?) {
        let (wanted, covers) = inUse()
        for id in Set(ids).subtracting(wanted) { remove(songID: id) }
        if let cover, !covers.contains(cover), let file = coverFile(id: cover) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The song ids and cover ids every downloaded album and playlist lists.
    private func inUse() -> (songs: Set<String>, covers: Set<String>) {
        var songs = Set<String>()
        var covers = Set<String>()
        for album in albums() {
            songs.formUnion((album.song ?? []).map(\.id))
            if let art = album.coverArt { covers.insert(art) }
        }
        for playlist in playlists() {
            songs.formUnion((playlist.entry ?? []).map(\.id))
            if let art = playlist.coverArt { covers.insert(art) }
        }
        return (songs, covers)
    }

    private func coverFile(id: String) -> URL? {
        // Artwork ids are 64 hex characters from the server.
        guard id.count == 64, id.allSatisfy(\.isHexDigit) else { return nil }
        return directory.appendingPathComponent("covers", isDirectory: true)
            .appendingPathComponent(id + ".img")
    }

    /// Letters, digits and hyphens, as the server's ids are.
    private static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    private static func songID(of file: URL) -> String {
        String(file.lastPathComponent.prefix { $0 != "." })
    }
}
