import SwiftUI
import CadenceCore

/// What every main page shows before its first load finishes, instead of a
/// blank screen — see issue #23. Lifted from `Cadence Skeleton.dc.html`, the
/// design canvas: a shimmering block stands in for whatever is still loading,
/// a flat static bar for whatever is secondary. Each shape below mirrors its
/// real counterpart's geometry exactly — same paddings, same grid math — so
/// nothing jumps when the real content takes its place.
enum SkeletonMotion {
    static let shimmerDuration: Double = 1.5

    /// Staggers a grid of shimmers into a diagonal wave rather than a flat,
    /// uniform flash — the design's own `animation-delay` trick.
    static func delay(for index: Int, columns: Int) -> Double {
        guard columns > 0 else { return 0 }
        return Double(index % columns) * 0.09 + Double(index / columns) * 0.05
    }
}

// MARK: - Primitives

/// A shimmering placeholder — a rounded rect or, for round artwork, a circle.
/// The traveling highlight is a wider gradient sweeping across on a loop;
/// Reduce Motion drops it to the flat base color underneath.
private struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Tokens.Radius.control
    var isCircular: Bool = false
    var delay: Double = 0

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        shape
            .fill(Tokens.Palette.placeholderDark)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, Tokens.Palette.placeholderLight, .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: animate ? geometry.size.width
                                           : -geometry.size.width * 0.6)
                    }
                    .clipShape(shape)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: SkeletonMotion.shimmerDuration)
                    .repeatForever(autoreverses: false).delay(delay)) {
                    animate = true
                }
            }
    }
}

/// A static, non-shimmering bar for secondary text — the design's own way of
/// keeping a skeleton from turning into a wall of equal motion.
private struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Tokens.Palette.placeholderDark)
            .frame(width: width, height: height)
    }
}

extension View {
    /// Loading UI is neither tappable nor worth VoiceOver reading item by
    /// item — one polite announcement stands in for the whole screen.
    fileprivate func skeletonAccessibility(_ label: String) -> some View {
        allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

// MARK: - Artists

private let cardTitleWidths: [CGFloat] = [92, 68, 84, 104, 74, 88, 64, 78, 96, 70]
private let cardSubtitleWidths: [CGFloat] = [58, 44, 66, 50, 40]

private struct SkeletonArtistCard: View {
    var titleWidth: CGFloat
    var subtitleWidth: CGFloat
    var delay: Double
    var opacity: Double

    var body: some View {
        VStack(spacing: 11) {
            SkeletonBlock(isCircular: true, delay: delay)
                .aspectRatio(1, contentMode: .fit)
            VStack(spacing: 6) {
                SkeletonBlock(cornerRadius: 4, delay: delay).frame(width: titleWidth, height: 12)
                SkeletonBar(width: subtitleWidth)
            }
        }
        .opacity(opacity)
    }
}

/// Mirrors `ArtistGrid`'s own column math so the grid underneath lands at
/// the same width the moment it replaces this.
struct SkeletonArtistGrid: View {
    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - Tokens.Space.contentInset * 2
            let columns = GridMetrics.columnCount(for: available,
                                                  minimum: Tokens.Layout.artistColumnWidth)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.xl),
                                   count: columns),
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(0..<(columns * 3), id: \.self) { index in
                        SkeletonArtistCard(
                            titleWidth: cardTitleWidths[index % cardTitleWidths.count],
                            subtitleWidth: cardSubtitleWidths[index % cardSubtitleWidths.count],
                            delay: SkeletonMotion.delay(for: index, columns: columns),
                            opacity: index >= columns * 2 ? 0.45 : 1
                        )
                    }
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.top, Tokens.Space.xl)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
        }
        .skeletonAccessibility("Loading artists")
    }
}

// MARK: - Albums

private struct SkeletonAlbumCard: View {
    var titleWidth: CGFloat
    var subtitleWidth: CGFloat
    var delay: Double
    var opacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SkeletonBlock(cornerRadius: Tokens.Radius.control, delay: delay)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(cornerRadius: 4, delay: delay).frame(width: titleWidth, height: 12)
                SkeletonBar(width: subtitleWidth)
            }
        }
        .opacity(opacity)
    }
}

/// Mirrors `AlbumGrid`'s column math, zoom included, so a resize or a zoom
/// change made while this is still on screen keeps matching.
struct SkeletonAlbumGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - Tokens.Space.contentInset * 2
            let columns = GridMetrics.columnCount(for: available, minimum: model.albumColumnWidth)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.xl),
                                   count: columns),
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(0..<(columns * 3), id: \.self) { index in
                        SkeletonAlbumCard(
                            titleWidth: cardTitleWidths[index % cardTitleWidths.count],
                            subtitleWidth: cardSubtitleWidths[index % cardSubtitleWidths.count],
                            delay: SkeletonMotion.delay(for: index, columns: columns),
                            opacity: index >= columns * 2 ? 0.45 : 1
                        )
                    }
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.vertical, Tokens.Space.xxl)
            }
            .scrollContentBackground(.hidden)
        }
        .skeletonAccessibility("Loading albums")
    }
}

// MARK: - Playlists

/// Mirrors `PlaylistShelfRow`. A fixed run of rows, not tied to a real
/// count nobody has yet — same idea as the design's eight-row queue mock.
struct SkeletonPlaylistList: View {
    private let titleWidths: [CGFloat] = [148, 176, 118, 160, 104, 184, 132, 140]
    private let subtitleWidths: [CGFloat] = [72, 96, 60, 84, 52, 100, 68, 76]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Tokens.Space.xxs) {
                ForEach(0..<titleWidths.count, id: \.self) { index in
                    row(index: index)
                }
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, 44)
        }
        .scrollContentBackground(.hidden)
        .skeletonAccessibility("Loading playlists")
    }

    private func row(index: Int) -> some View {
        let delay = Double(index) * 0.07
        let opacity = max(0.35, 1 - Double(index) * 0.09)
        return HStack(spacing: Tokens.Space.l) {
            SkeletonBlock(cornerRadius: 5, delay: delay).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBlock(cornerRadius: 4, delay: delay)
                    .frame(width: titleWidths[index], height: 13)
                SkeletonBar(width: subtitleWidths[index])
            }
            Spacer(minLength: Tokens.Space.l)
            SkeletonBar(width: 34, height: 9)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, 10)
        .opacity(opacity)
    }
}

// MARK: - Album detail

/// Mirrors `AlbumDetailView`: the same header proportions and the same
/// track-row grid, so the column headings — which need no data at all —
/// can stay real text under this the whole time.
struct SkeletonAlbumDetail: View {
    private let trackTitleWidths: [CGFloat] = [220, 160, 260, 190, 140, 230, 175, 205, 150, 240]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                trackList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.surface)
        .skeletonAccessibility("Loading album")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            SkeletonBlock(cornerRadius: Tokens.Radius.card, delay: 0)
                .frame(width: Tokens.Layout.albumHeaderArt, height: Tokens.Layout.albumHeaderArt)

            VStack(alignment: .leading, spacing: 14) {
                SkeletonBar(width: 64, height: 10)
                SkeletonBlock(cornerRadius: 6, delay: 0.05).frame(width: 380, height: 44)
                SkeletonBar(width: 280, height: 13)
                HStack(spacing: 8) {
                    SkeletonBar(width: 54, height: 20)
                    SkeletonBar(width: 92, height: 20)
                }
                .padding(.top, 2)
                HStack(spacing: 10) {
                    SkeletonBlock(cornerRadius: 19, delay: 0.1).frame(width: 96, height: 38)
                    SkeletonBlock(cornerRadius: 19, delay: 0.15).frame(width: 108, height: 38)
                    SkeletonBlock(cornerRadius: 19, delay: 0.2).frame(width: 38, height: 38)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.Space.albumInset)
        .padding(.top, 38)
        .padding(.bottom, 30)
        .background {
            LinearGradient(colors: [Tokens.Palette.immersiveTop, Tokens.Palette.surface],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(Array(trackTitleWidths.enumerated()), id: \.offset) { index, width in
                SkeletonTrackRow(titleWidth: width,
                                 delay: SkeletonMotion.delay(for: index, columns: 1))
            }
        }
        .padding(.horizontal, Tokens.Space.albumInset)
        .padding(.top, 22)
        .padding(.bottom, 44)
    }

    /// Identical to `AlbumDetailView.columnHeader` — these labels don't wait
    /// on any load, so they stay real text instead of shimmering for no
    /// reason.
    private var columnHeader: some View {
        HStack(spacing: Tokens.Space.l) {
            Text("#").frame(width: 28, alignment: .leading)
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            Text("QUALITY").frame(width: 90, alignment: .leading)
            Text("TIME").frame(width: 56, alignment: .trailing)
        }
        .accessibilityHidden(true)
        .font(Tokens.Typography.mono(10, .medium))
        .tracking(1.2)
        .foregroundStyle(Tokens.Palette.textMuted)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
        }
    }
}

private struct SkeletonTrackRow: View {
    var titleWidth: CGFloat
    var delay: Double

    var body: some View {
        HStack(spacing: Tokens.Space.l) {
            SkeletonBar(width: 14, height: 10).frame(width: 28, alignment: .leading)
            SkeletonBlock(cornerRadius: 4, delay: delay)
                .frame(width: titleWidth, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            SkeletonBar(width: 46, height: 9).frame(width: 90, alignment: .leading)
            SkeletonBar(width: 32, height: 9).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}
