import Foundation

/// Falls back to a cover image sitting next to the tracks when a file carries
/// no artwork of its own — a rip where the cover was saved once as
/// `cover.jpg` beside the FLACs rather than embedded in every tag.
enum LocalArtworkFinder {

    /// Ordered by how likely a name is to be the front cover. The folder is
    /// walked once and every candidate extension is considered for each name
    /// before moving to the next name, so `folder.png` beats `front.jpg`.
    private static let candidateNames = ["cover", "folder", "front", "album", "albumart", "artwork"]
    private static let candidateExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif"]

    /// The bytes of the best-matching image directly inside `folder`, or `nil`
    /// if nothing there looks like a cover. Never recurses: a subfolder's
    /// cover belongs to a different disc or a different album entirely.
    static func artwork(in folder: URL) -> Data? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        var byName: [String: URL] = [:]
        for entry in entries {
            guard candidateExtensions.contains(entry.pathExtension.lowercased()) else { continue }
            let name = entry.deletingPathExtension().lastPathComponent.lowercased()
            guard candidateNames.contains(name), byName[name] == nil else { continue }
            byName[name] = entry
        }

        for name in candidateNames {
            if let url = byName[name], let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }
}
