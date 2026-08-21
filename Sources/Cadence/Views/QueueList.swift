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
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        let upNext = Array(playback.upNext)

        List {
            ForEach(upNext) { track in
                QueueRow(track: track)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(track.title), \(track.artist), "
                        + NowPlayingPane.spokenDuration(track.duration))
                    .accessibilityHint("Plays this track. Drag to reorder.")
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    // Simultaneous for the same reason as the playlist's rows:
                    // an exclusive tap gesture swallows the press `onMove`
                    // needs, and Up Next has had the same never-verified drag
                    // since before the playlist work.
                    .simultaneousGesture(TapGesture().onEnded { playback.jump(to: track) })
                    .contextMenu {
                        Button("Play Now") { playback.jump(to: track) }
                        Button("Remove from Queue") { playback.removeFromUpNext(track) }
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
    var track: Track

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
                Text(track.artist)
                    .font(Tokens.Typography.sans(10.5, .medium))
                    .foregroundStyle(Color(hex: 0x63636D))
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.s)
            Text(DurationFormat.clock(track.duration))
                .font(Tokens.Typography.mono(10))
                .foregroundStyle(Tokens.Palette.textFaint)
        }
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, 6)
        .hoverHighlight(hoverColor: Tokens.Palette.navHover)
    }
}

/// Volume, and the shuffle and repeat toggles the design only ever drew in the
/// immersive view. Phase 3 wants them reachable without going full-screen.
struct PlaybackOptions: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var playback = playback

        VStack(spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.m) {
                ModeToggle(
                    systemImage: "shuffle",
                    isOn: playback.shuffleMode.isOn,
                    help: "Shuffle",
                    spokenLabel: "Shuffle",
                    spokenValue: playback.shuffleMode.isOn ? "On" : "Off"
                ) { playback.toggleShuffle() }

                ModeToggle(
                    systemImage: playback.repeatMode == .one ? "repeat.1" : "repeat",
                    isOn: playback.repeatMode != .off,
                    help: repeatHelp,
                    // Without an explicit label the SF Symbol's own name leaks
                    // through: "repeat.1" was being announced as "Repeat 1".
                    spokenLabel: "Repeat",
                    // The label already says "Repeat"; the value should not
                    // repeat the word back.
                    spokenValue: repeatValue
                ) { playback.cycleRepeat() }

                Spacer()

                Menu {
                    Picker("ReplayGain", selection: $playback.replayGainMode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("RG · \(playback.replayGainMode.label)")
                        .font(Tokens.Typography.mono(9.5, .medium))
                        .tracking(0.6)
                        .foregroundStyle(playback.replayGainMode == .off
                                         ? Tokens.Palette.textMuted
                                         : Tokens.Palette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How loudness is levelled between tracks")
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

    private var repeatValue: String {
        switch playback.repeatMode {
        case .off: "Off"
        case .all: "Whole queue"
        case .one: "This track"
        }
    }

    private var repeatHelp: String {
        switch playback.repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat queue"
        case .one: "Repeat track"
        }
    }

    private var volumeIcon: String {
        if playback.isMuted || playback.volume <= 0.001 { return "speaker.slash.fill" }
        if playback.volume < 0.34 { return "speaker.fill" }
        if playback.volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

private struct ModeToggle: View {
    var systemImage: String
    var isOn: Bool
    var help: String
    var spokenLabel: String
    var spokenValue: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn
                                 ? Tokens.Palette.accent
                                 : (isHovering ? .white : Color(hex: 0x71717B)))
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Tokens.Palette.accentDim : .clear)
                }
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
