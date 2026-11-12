import Foundation

/// What Home's hero shows today: the album of the day, or one of your own
/// memories brought back. Seeded by the date like both of those, so the hero
/// is the same all day and may be the other kind tomorrow.
public enum DailyPick: Equatable, Sendable {
    case album(AlbumOfTheDay)
    case memory(Memory)

    /// One day in this many is a memory's, when there is one to show; the
    /// rest go to the album of the day.
    public static let memoryOdds: UInt64 = 3

    /// Chooses between today's album and today's memory. Either can be
    /// missing — a library with no notes always gets the album, and one whose
    /// album pick failed still gets a memory. When both exist the date decides,
    /// leaning to the album: a memory is a treat, and one every other day
    /// would stop feeling like one.
    ///
    /// `memories` should already be the ones that can be shown (their record
    /// is in the library); the memory is drawn from them with
    /// `Memory.resurfaced`, so notes written today wait their turn.
    public static func choose(album: AlbumOfTheDay?, memories: [Memory], now: Date,
                              calendar: Calendar = .current) -> DailyPick? {
        let memory = Memory.resurfaced(from: memories, now: now, limit: 1,
                                       calendar: calendar).first
        switch (album, memory) {
        case (nil, nil): return nil
        case (let album?, nil): return .album(album)
        case (nil, let memory?): return .memory(memory)
        case (let album?, let memory?):
            let parts = calendar.dateComponents([.year, .month, .day], from: now)
            let seed = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
            // A different stream from the album and memory picks, so the coin
            // is not correlated with which album or note they drew.
            var rng = SplitMix64(seed: UInt64(seed) &+ 0x6865_726F)
            return rng.next() % memoryOdds == 0 ? .memory(memory) : .album(album)
        }
    }
}
