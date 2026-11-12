import SwiftUI
import CadenceCore

/// The landing screen: a suggestion for today — an album, or one of your own
/// memories brought back — a short row of what was played
/// last, and Cadence's own listening numbers. The full recents history is one
/// "Show all" away.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayLogController.self) private var playLog
    @Environment(PlaybackController.self) private var playback
    @State private var showAll = false
    @State private var period: StatsPeriod = .week
    @State private var stats: ListeningStats?
    @State private var dailyPick: DailyPick?

    /// What the derived figures depend on.
    private struct InputKey: Hashable {
        var period: StatsPeriod
        var albums: Int
        var plays: Int
        /// Whole notes, not ids, so an edited note's new text reaches the
        /// hero the moment it is saved.
        var memories: [Memory]
    }

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - Tokens.Space.contentInset * 2
            let columns = GridMetrics.columnCount(for: available, minimum: model.albumColumnWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.xxl + Tokens.Space.l) {
                    switch dailyPick {
                    case .album(let pick): AlbumOfTheDayCard(pick: pick)
                    case .memory(let memory): MemoryOfTheDayCard(memory: memory)
                    case nil: EmptyView()
                    }
                    recentlyPlayed(columns: columns)
                    listening
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.vertical, Tokens.Space.xxl)
            }
            .scrollContentBackground(.hidden)
        }
        .task(id: InputKey(period: period, albums: model.albums.count, plays: playLog.plays.count,
                           memories: model.memories)) {
            let now = Date()
            stats = ListeningStats.compute(from: playLog.plays, period: period, now: now)
            let album = AlbumOfTheDay.pick(from: model.albums, history: playLog.plays, now: now)
            dailyPick = DailyPick.choose(album: album, memories: model.showableMemories, now: now)
        }
    }

    // MARK: Recently played

    @ViewBuilder
    private func recentlyPlayed(columns: Int) -> some View {
        let all = model.recentPlays
        let shown = showAll ? all : Array(all.prefix(columns))

        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack {
                SectionLabel("Recently played")
                Spacer()
                if all.count > columns {
                    CapsuleButton(title: showAll ? "Show less" : "Show all",
                                  systemImage: showAll ? nil : "arrow.right") {
                        showAll.toggle()
                    }
                }
            }

            if all.isEmpty {
                Text("Play an album or a playlist and it turns up here, newest first.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.xl),
                                   count: columns),
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .album(let album):
                            AlbumCard(album: album, subtitle: .artist, index: index)
                                .equatable()
                        case .playlist:
                            RecentCard(item: item)
                        }
                    }
                }
            }
        }
    }

    // MARK: Listening stats

    private var listening: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack {
                SectionLabel("Your listening")
                Spacer()
                SegmentedPicker(selection: $period, options: StatsPeriod.allCases, label: \.rawValue)
            }
            if let stats, !stats.isEmpty {
                StatsPanel(stats: stats)
            } else {
                Text(playLog.plays.isEmpty
                     ? "Listen to some music and your top artists, albums and tracks build up here."
                     : "Nothing played in this period.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }
}

// MARK: - Album of the day

private struct AlbumOfTheDayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var pick: AlbumOfTheDay

    var body: some View {
        HStack(spacing: Tokens.Space.xl) {
            Button { model.show(.album(pick.album.key)) } label: {
                ArtworkView(artworkID: pick.album.artworkID,
                            cornerRadius: Tokens.Radius.control,
                            caption: "COVER ART")
                    .frame(width: 96, height: 96)
            }
            .plainControl()
            .accessibilityLabel("Open \(pick.album.title)")

            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                SectionLabel("Album of the day", color: Tokens.Palette.accent)
                Text(pick.album.title)
                    .font(Tokens.Typography.sans(22, .heavy))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(pick.album.albumArtist)
                    .font(Tokens.Typography.rowTitle)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                Text("\(pick.headline) · \(pick.detail)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 2)
                // The newest note on the record, if there is one: the album
                // of the day is exactly when a memory is worth seeing again.
                if let memory = model.memories(aboutAlbum: pick.album.key).first {
                    Button { model.editingMemory = .edit(memory) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            CadenceIcon("text.bubble", size: 10)
                                .foregroundStyle(Tokens.Palette.accent)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text(memoryLine(memory))
                                .font(Tokens.Typography.sans(12.5, .medium))
                                .italic()
                                .foregroundStyle(Color(hex: 0xC8C8D0))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .plainControl()
                    .padding(.top, Tokens.Space.xs)
                    .accessibilityLabel("Memory: \(memoryLine(memory)), \(memory.dateDescription)")
                    .accessibilityHint("Edits this memory")
                }
            }
            Spacer(minLength: Tokens.Space.l)

            HStack(spacing: Tokens.Space.m) {
                CapsuleButton(title: "Open") { model.show(.album(pick.album.key)) }
                CapsuleButton(title: "Play", systemImage: "play.fill", kind: .filled) {
                    playback.play(pick.album)
                }
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelBackground()
        .accessibilityElement(children: .contain)
    }

    /// `“The note.”`, or `“Anhedonia” — the note.` for a song on the record.
    private func memoryLine(_ memory: Memory) -> String {
        if let title = memory.subject.trackTitle {
            return "“\(title)” — \(memory.text)"
        }
        return "“\(memory.text)”"
    }
}

// MARK: - Memory of the day

/// The hero on a day it brings back one of your own notes instead of an
/// album: the record's cover, what the note is about, the note itself, and
/// the same two verbs — open the record, or play the song (or record) the
/// note is about.
private struct MemoryOfTheDayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var memory: Memory

    private var key: Album.Key { memory.subject.albumKey }
    private var album: Album? { model.album(for: key) }
    /// The song, when the note is about one that is still on the record.
    private var track: Track? { model.track(for: memory.subject) }

    var body: some View {
        HStack(spacing: Tokens.Space.xl) {
            Button { model.show(.album(key)) } label: {
                ArtworkView(artworkID: album?.artworkID,
                            cornerRadius: Tokens.Radius.control,
                            caption: "COVER ART")
                    .frame(width: 96, height: 96)
            }
            .plainControl()
            .accessibilityLabel("Open \(key.title)")

            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                HStack(spacing: 6) {
                    CadenceIcon(PlaylistMenu.Symbol.memory, size: 10)
                    SectionLabel("A memory", color: Tokens.Palette.accent)
                }
                .foregroundStyle(Tokens.Palette.accent)
                Text(model.title(of: memory.subject))
                    .font(Tokens.Typography.sans(22, .heavy))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Typography.rowTitle)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                // The note is the point of the card; clicking it edits it.
                Button { model.editingMemory = .edit(memory) } label: {
                    Text(MemoryText.styled("“\(memory.text)”"))
                        .font(Tokens.Typography.sans(13.5, .medium))
                        .italic()
                        .foregroundStyle(Color(hex: 0xD6D6DD))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .plainControl()
                .padding(.top, Tokens.Space.xs)
                .accessibilityLabel("Memory: \(memory.text)")
                .accessibilityHint("Edits this memory")
                Text("Written \(memory.dateDescription)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            Spacer(minLength: Tokens.Space.l)

            HStack(spacing: Tokens.Space.m) {
                CapsuleButton(title: "Open") { model.show(.album(key)) }
                CapsuleButton(title: "Play", systemImage: "play.fill", kind: .filled,
                              accessibilityLabel: "Play \(playSubject)", action: play)
                    .disabled(album == nil)
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelBackground()
        .accessibilityElement(children: .contain)
    }

    /// `Artist · Record` for a song's note, the artist alone for a record's.
    private var subtitle: String {
        memory.subject.trackTitle == nil ? key.albumArtist : "\(key.albumArtist) · \(key.title)"
    }

    private var playSubject: String { track?.title ?? key.title }

    private func play() { model.play(memory, on: playback) }
}

// MARK: - Stats

/// Headline figures above three short top-five lists.
private struct StatsPanel: View {
    var stats: ListeningStats

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(spacing: Tokens.Space.l) {
                StatTile(label: "Plays", value: stats.plays.formatted(),
                         series: stats.trend.plays)
                StatTile(label: "Listening time", value: Self.duration(stats.listeningTime),
                         series: stats.trend.seconds)
                StatTile(label: "Artists", value: stats.artistCount.formatted(),
                         series: stats.trend.artists)
            }
            HStack(alignment: .top, spacing: Tokens.Space.l) {
                TopList(title: "Top artists", entries: stats.topArtists)
                TopList(title: "Top albums", entries: stats.topAlbums)
                TopList(title: "Top tracks", entries: stats.topTracks)
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct StatTile: View {
    var label: String
    var value: String
    /// One value per slice of the period, oldest first.
    var series: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(value)
                    .font(Tokens.Typography.sans(26, .heavy))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                SectionLabel(label)
            }
            BarSparkline(values: series)
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.l)
        .panelBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Bars on a shared baseline, no axes: the shape of the period at a glance, with
/// the current slice in red. The
/// tile's figure and label carry the numbers, so this is decoration to
/// VoiceOver.
private struct BarSparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let peak = max(values.max() ?? 0, 1)
            let gap: CGFloat = values.count > 14 ? 2 : 4
            let barWidth = max(1, (geometry.size.width - gap * CGFloat(values.count - 1))
                               / CGFloat(max(values.count, 1)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    // The last slice is the current one — today, or the window
                    // ending now — so it carries the accent; the rest recede.
                    RoundedRectangle(cornerRadius: min(2, barWidth / 2), style: .continuous)
                        .fill(index == values.count - 1 ? Tokens.Palette.accent
                              : (value > 0 ? Color(hex: 0x55555F) : Tokens.Palette.borderStrong))
                        .frame(width: barWidth,
                               height: value > 0
                                   ? max(3, geometry.size.height * CGFloat(value / peak)) : 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .accessibilityHidden(true)
    }
}

private struct TopList: View {
    @Environment(AppModel.self) private var model
    var title: String
    var entries: [ListeningStats.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionLabel(title)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(index: index, entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(Tokens.Space.l)
        .panelBackground()
    }

    @ViewBuilder
    private func row(index: Int, entry: ListeningStats.Entry) -> some View {
        let content = HStack(spacing: Tokens.Space.m) {
            Text("\(index + 1)")
                .font(Tokens.Typography.monoSmall)
                .foregroundStyle(Tokens.Palette.textFaint)
                .frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                if let artist = entry.artist {
                    Text(artist)
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.s)
            Text("\(entry.plays)")
                .font(Tokens.Typography.monoValue)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .contentShape(Rectangle())

        let label = "\(index + 1). \(entry.name)\(entry.artist.map { ", \($0)" } ?? ""), \(entry.plays) plays"

        if let key = entry.albumKey, model.album(for: key) != nil {
            Button { model.show(.album(key)) } label: { content }
                .plainControl()
                .accessibilityLabel(label)
        } else if entry.artist == nil, model.artists.contains(where: { $0.name == entry.name }) {
            Button { model.show(.artist(entry.name)) } label: { content }
                .plainControl()
                .accessibilityLabel(label)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}

private extension View {
    func panelBackground() -> some View {
        background(Tokens.Palette.card,
                   in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
    }
}
