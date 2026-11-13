import SwiftUI
import CadenceDesign
import CadenceCore

/// Every album in one genre, laid out the way an artist's page lays out theirs:
/// a header, then either the cover grid or each record with its tracklist.
struct GenreDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var genre: Genre

    private var albums: [Album] { model.albums(inGenre: genre.id) }

    /// Album order, so Play works through the shelf the way the screen reads.
    private var orderedTracks: [Track] {
        albums.flatMap { $0.discs.flatMap(\.tracks) }
    }

    private var isGenreLoaded: Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return orderedTracks.contains { $0.id == id }
    }

    private var isGenrePlaying: Bool { isGenreLoaded && playback.isPlaying }

    var body: some View {
        @Bindable var model = model

        switch model.genreAlbumLayout {
        case .grid:
            // The artist is the useful second line here: a genre mixes many.
            AlbumGrid(albums: albums, subtitle: .artist,
                      scrollAnchor: $model.genreAlbumGridScrollAnchor) { header }
                .background(Tokens.Palette.surface)
        case .list:
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    ForEach(albums) { album in
                        AlbumSection(album: album, showsArtist: true)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Palette.surface)
        }
    }

    private var header: some View {
        @Bindable var model = model

        return
        HStack(alignment: .bottom, spacing: 32) {
            GenreArtwork(genre: genre, cornerRadius: Tokens.Radius.card, displaySize: 320)
                .frame(width: Tokens.Layout.artistHeaderArt,
                       height: Tokens.Layout.artistHeaderArt)
                .shadow(color: .black.opacity(0.55), radius: 25, y: 12)

            VStack(alignment: .leading, spacing: 12) {
                Text(genre.name)
                    .font(Tokens.Typography.sans(38, .heavy))
                    .tracking(Tokens.Typography.Tracking.display)
                    .foregroundStyle(Color(hex: 0xF4F4F8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(genre.summary) · \(DurationFormat.approximate(genre.duration))")
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0x82828D))

                HStack(spacing: 10) {
                    PlayPauseButton(isPlaying: isGenrePlaying, subject: genre.name, showsTitle: true) {
                        if isGenreLoaded {
                            playback.togglePlayPause()
                        } else if let first = orderedTracks.first {
                            playback.play(first, in: orderedTracks)
                        }
                    }
                    .disabled(orderedTracks.isEmpty)
                    CapsuleButton(systemImage: "shuffle", accessibilityLabel: "Shuffle") {
                        playback.shuffle(orderedTracks)
                    }
                    .help("Shuffle")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AlbumLayoutPicker(layout: $model.genreAlbumLayout)
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Tokens.Palette.immersiveTop, Tokens.Palette.surface],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
        }
    }
}
