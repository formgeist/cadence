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
/// downloads with playback. This type only reads, lists and removes, and is
/// safe to use from any thread: everything it does is a single file-system
/// call, and a file appears here only by an atomic rename.
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

    /// Removes every kept song, and the folder. For when the listener clears
    /// their downloads or forgets the Mac.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
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

    /// Every kept file. Hidden files are partial ones still arriving.
    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private static func songID(of file: URL) -> String {
        String(file.lastPathComponent.prefix { $0 != "." })
    }
}
