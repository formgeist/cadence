import SwiftUI
import CadenceCore

/// Up Next, with drag to reorder.
///
/// A `List` rather than the `LazyVStack` the rest of the app uses, because
/// `onMove` is the only reordering that behaves the way macOS users expect —
/// grab anywhere, autoscroll at the edges, drop where the insertion line shows.
/// Reimplementing that on a stack to keep the container consistent would be
/// worse than styling a List to match.
struct QueueList: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    /// The row a single click put under the cursor, as on the album screen:
    /// playback needs a second click, so something has to show what the first
    /// one did. Not wired up as the `List`'s own `selection`, which resolves a
    /// click the moment it lands — before a `.onTapGesture(count: 2)` on the
    /// same row gets a chance to see whether a second one is coming, so every
    /// click jumps instead of only the second.
    @State private var selectedTrack: Track.ID?

    var body: some View {
        let upNext = Array(playback.upNext)

        List {
            ForEach(upNext) { track in
                QueueRow(track: track, isSelected: selectedTrack == track.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(track.title), \(track.artist), "
                        + NowPlayingPane.spokenDuration(track.duration))
                    .accessibilityHint("Plays this track. Drag to reorder.")
                    // `.ignore` above also swallows the row's own artist
                    // link; this stands in for it on the rotor.
                    .accessibilityAction(named: "Go to artist") {
                        model.show(.artist(track.artist))
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { playback.jump(to: track) }
                    .onTapGesture { selectedTrack = track.id }
                    .cadenceContextMenu(onOpen: { selectedTrack = track.id }) {
                        PlaylistMenu.queued(track, playback: playback)
                    }
            }
            .onMove { source, destination in
                playback.moveUpNext(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                for index in offsets where upNext.indices.contains(index) {
                    playback.removeFromUpNext(upNext[index])
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 40)
    }
}

struct QueueRow: View {
    @Environment(AppModel.self) private var model

    var track: Track
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(artworkID: track.artworkID, cornerRadius: Tokens.Radius.thumb,
                        stripe: 4, displaySize: 40)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(Tokens.Typography.sans(12, .semibold))
                    .foregroundStyle(Color(hex: 0xD6D6DE))
                    .lineLimit(1)
                InlineLink(text: track.artist, font: Tokens.Typography.sans(10.5, .medium),
                           color: Color(hex: 0x63636D)) {
                    model.show(.artist(track.artist))
                }
            }
            Spacer(minLength: Tokens.Space.s)
            Text(DurationFormat.clock(track.duration))
                .font(Tokens.Typography.mono(10))
                .foregroundStyle(Tokens.Palette.textFaint)
        }
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, 6)
        .hoverHighlight(isActive: isSelected, hoverColor: Tokens.Palette.navHover)
    }
}

/// Volume and ReplayGain. Shuffle and repeat live in `TransportControls` now,
/// flanking the play controls, rather than duplicated down here.
struct PlaybackOptions: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var playback = playback

        VStack(spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.m) {
                Spacer()

                MenuAnchor {
                    ReplayGainMode.allCases.map { mode in
                        MenuItem.choice(mode.label,
                                        isOn: playback.replayGainMode == mode) {
                            playback.replayGainMode = mode
                        }
                    }
                } label: { isOpen, toggle in
                    Button(action: toggle) {
                        Text("RG · \(playback.replayGainMode.label)")
                            .font(Tokens.Typography.mono(9.5, .medium))
                            .tracking(0.6)
                            .foregroundStyle(replayGainTint(isOpen: isOpen))
                    }
                    .plainControl()
                    .accessibilityLabel("ReplayGain")
                    .accessibilityValue(playback.replayGainMode.label)
                    .help("How loudness is levelled between tracks")
                }
            }

            HStack(spacing: Tokens.Space.s) {
                Button {
                    playback.isMuted.toggle()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        // The icon changes width with the number of waves; a
                        // fixed box stops the slider shifting as it does.
                        .frame(width: 16, alignment: .leading)
                }
                .plainControl()
                .help(playback.isMuted ? "Unmute" : "Mute")
                // The speaker symbol announces itself as "Volume High"
                // otherwise, which describes the icon rather than the action.
                .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")

                VolumeSlider(value: $playback.volume)
            }
        }
    }

    /// Lit while its menu is open, the way every other trigger in the app now
    /// is — this one has no bezel to carry the accent, so the text does.
    private func replayGainTint(isOpen: Bool) -> Color {
        if isOpen { return Tokens.Palette.accent }
        return playback.replayGainMode == .off
            ? Tokens.Palette.textMuted
            : Tokens.Palette.textSecondary
    }

    private var volumeIcon: String {
        if playback.isMuted || playback.volume <= 0.001 { return "speaker.slash.fill" }
        if playback.volume < 0.34 { return "speaker.fill" }
        if playback.volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

/// The design's scrub bar, reused for volume: a bare capsule that only grows a
/// knob under the pointer.
private struct VolumeSlider: View {
    @Binding var value: Double
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.trackGroove)
                Capsule()
                    .fill(isHovering ? Tokens.Palette.accent : Color(hex: 0x6A6A74))
                    .frame(width: max(0, min(1, value)) * width)
                if isHovering {
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .offset(x: max(0, min(1, value)) * width - 4.5)
                }
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value = min(max(0, $0.location.x / width), 1) }
            )
        }
        .frame(height: 14)
        // Same reason as the scrubber: a custom-drawn control needs to be
        // represented as a real Slider or it reaches assistive technology with
        // no role at all.
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1, step: 0.05)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
        }
    }
}
