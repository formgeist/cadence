import Foundation

/// Reordering by offsets, for everything that lets the user drag rows around.
///
/// `move(fromOffsets:toOffset:)` lives in SwiftUI, and neither `CadenceCore`
/// nor the store may import it — PLAN.md §1. The queue and playlists both want
/// it, so it lives here rather than as a private helper on whichever of them
/// needed it first.
public enum Ordering {

    /// The semantics are SwiftUI's: `destination` is an index in the
    /// *original* array, before anything is removed.
    public static func move<T>(
        _ array: inout [T], fromOffsets source: IndexSet, toOffset destination: Int
    ) {
        let moving = source.compactMap { array.indices.contains($0) ? array[$0] : nil }
        guard !moving.isEmpty else { return }

        // Removing items ahead of the destination shifts it left by that many.
        let insertion = destination - source.count(where: { $0 < destination })
        for index in source.sorted(by: >) where array.indices.contains(index) {
            array.remove(at: index)
        }
        array.insert(contentsOf: moving, at: min(max(0, insertion), array.count))
    }
}
