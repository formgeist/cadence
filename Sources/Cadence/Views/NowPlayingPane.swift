import SwiftUI
import CadenceCore

struct NowPlayingPane: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(\.isSilentPlayback) private var isSilentPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Now playing")
                Spacer()
                Button { model.isImmersive = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x6C6C76))
                        .padding(4)
                }
                .plainControl()
                .disabled(playback.currentTrack == nil)
                .accessibilityLabel("Full-screen artwork")
            }
            .padding(.horizontal, Tokens.Space.paneInset)
            .padding(.top, Tokens.Space.xl)

            if let track = playback.currentTrack {
                content(for: track)
            } else {
                idle
            }
        }
        .frame(width: Tokens.Layout.nowPlayingWidth)
        .background(Tokens.Palette.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Tokens.Palette.border).frame(width: 1)
        }
    }

    // MARK: Playing

    @ViewBuilder
    private func content(for track: Track) -> some View {
        Button { model.isImmersive = true } label: {
            ArtworkView(artworkID: track.artworkID,
                        cornerRadius: Tokens.Radius.card,
                        caption: "ARTWORK",
                        stripe: 7,
                        displaySize: 320)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 9)
        }
        .plainControl()
        .accessibilityLabel("Artwork for \(track.albumTitle)")
        .accessibilityHint("Opens full-screen artwork")
        .padding(.horizontal, Tokens.Space.paneInset)
        .padding(.top, Tokens.Space.l)

        VStack(alignment: .leading, spacing: 5) {
            Text(track.title)
                .font(Tokens.Typography.paneTitle)
                .foregroundStyle(Color(hex: 0xF1F1F5))
                .lineLimit(2)
            InlineLink(text: track.artist, font: Tokens.Typography.sans(12.5, .semibold),
                       color: Tokens.Palette.textSecondary) {
                model.show(.artist(track.artist))
            }
            InlineLink(text: track.albumTitle, font: Tokens.Typography.caption,
                       color: Color(hex: 0x64646E)) {
                model.show(.album(track.albumKey))
            }
        }
        // Three separate stops for one fact; one is enough. `.combine` also
        // swallows the two links' own button semantics, so they come back as
        // named rotor actions rather than disappearing from VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing: \(track.title), \(track.artist), \(track.albumTitle)")
        .accessibilityAction(named: "Go to artist") { model.show(.artist(track.artist)) }
        .accessibilityAction(named: "Go to album") { model.show(.album(track.albumKey)) }
        .padding(.horizontal, Tokens.Space.paneInset)
        .padding(.top, 18)

        VStack(spacing: 7) {
            ScrubBar(
                fraction: playback.progress.fraction,
                height: 3,
                accessibilityValue: Self.spokenPosition(playback.progress)
            ) { fraction in
                playback.seek(toFraction: fraction)
            }
            HStack {
                Text(playback.progress.elapsedText)
                Spacer()
                Text(playback.progress.remainingText)
            }
            .font(Tokens.Typography.mono(10.5))
            .foregroundStyle(Color(hex: 0x5E5E68))
            // The scrubber already announces the position; these would repeat it.
            .accessibilityHidden(true)
            // Times jitter in width as digits change; a fixed-width font plus
            // a monospaced-digit hint keeps the row from twitching.
            .monospacedDigit()
        }
        .padding(.horizontal, Tokens.Space.paneInset)
        .padding(.top, 18)

        TransportControls(size: .compact)
            .padding(.top, 14)
            .frame(maxWidth: .infinity)

        HStack {
            HStack(spacing: 7) {
                Circle().fill(Tokens.Palette.accent).frame(width: 5, height: 5)
                Text(track.format.badgeDescription)
                    .font(Tokens.Typography.mono(9.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: 0x7C7C86))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Format: \(Self.spokenFormat(track.format))")
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(hex: 0x2A2A32), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Tokens.Space.l)

        PlaybackOptions()
            .padding(.horizontal, Tokens.Space.paneInset)
            .padding(.top, Tokens.Space.l)

        if isSilentPlayback {
            // The transport moves but nothing is decoded. Saying so beats
            // letting it look like broken audio.
            Text("Silent preview — audio engine not built yet")
                .font(Tokens.Typography.sans(10, .medium))
                .foregroundStyle(Tokens.Palette.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, Tokens.Space.s)
        }

        upNext
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Up next")
                Spacer()
                if !playback.upNext.isEmpty {
                    Text("\(playback.upNext.count)")
                        .font(Tokens.Typography.mono(10))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
            }
            .padding(.horizontal, Tokens.Space.paneInset)
            .padding(.bottom, 10)

            if playback.upNext.isEmpty {
                Text("End of queue")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textFaint)
                    .padding(.top, 2)
                    .padding(.horizontal, Tokens.Space.paneInset)
            } else {
                QueueList()
                    // The List brings its own inset; the label above keeps the
                    // pane's.
                    .padding(.horizontal, Tokens.Space.paneInset - 5)
            }
            skippedSummary
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 14)
        .padding(.top, Tokens.Space.xl)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
                .padding(.top, Tokens.Space.xl)
        }
    }

    /// What the queue could not play. The banner that announced each skip is
    /// gone by the next action, and a record that quietly dropped four tracks
    /// is barely better than one that stopped on the first — so the count stays
    /// here, under the queue it happened to, until playback starts again.
    @ViewBuilder
    private var skippedSummary: some View {
        let skipped = playback.skipped

        if !skipped.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.Palette.accent)
                        .accessibilityHidden(true)
                    Text(skipped.count == 1
                         ? "1 track skipped"
                         : "\(skipped.count) tracks skipped")
                        .font(Tokens.Typography.sans(11, .semibold))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                    Spacer(minLength: Tokens.Space.s)
                    Button("Clear") { playback.clearSkipped() }
                        .plainControl()
                        .font(Tokens.Typography.sans(10.5, .medium))
                        .foregroundStyle(Tokens.Palette.textMuted)
                }

                // Named, not just counted: "which one did it?" is the question
                // a bare number leaves the user to answer by ear.
                ForEach(skipped.prefix(3)) { skip in
                    Text("\(skip.track.title) — \(skip.reason.reasonPhrase)")
                        .font(Tokens.Typography.sans(10.5, .medium))
                        .foregroundStyle(Tokens.Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if skipped.count > 3 {
                    Text("and \(skipped.count - 3) more")
                        .font(Tokens.Typography.sans(10.5, .medium))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
            }
            .padding(.horizontal, Tokens.Space.paneInset)
            .padding(.top, Tokens.Space.m)
        }
    }

    /// "1 minute 28 seconds of 5 minutes 38 seconds" — a clock face read aloud
    /// as "one twenty-eight" is ambiguous.
    static func spokenPosition(_ progress: PlaybackProgress) -> String {
        "\(spokenDuration(progress.elapsed)) of \(spokenDuration(progress.duration))"
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "zero seconds" }
        let total = Int(seconds.rounded())
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = total >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .spellOut
        return formatter.string(from: Double(total)) ?? "\(total) seconds"
    }

    /// "FLAC, 24 bit, 96 kilohertz" rather than "FLAC · 24-bit / 96 kHz", which
    /// a screen reader turns into punctuation soup.
    static func spokenFormat(_ format: AudioFormat) -> String {
        var parts = [format.codec.name]
        if let depth = format.bitDepth { parts.append("\(depth) bit") }
        parts.append("\(format.kilohertz) kilohertz")
        return parts.joined(separator: ", ")
    }

    // MARK: Nothing playing

    private var idle: some View {
        VStack(spacing: Tokens.Space.m) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Tokens.Palette.textMuted)
            Text("Nothing playing")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
            Text("Pick a track to start the queue")
                .font(Tokens.Typography.sans(11, .medium))
                .foregroundStyle(Tokens.Palette.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transport

struct TransportControls: View {
    enum Size { case compact, immersive }

    @Environment(PlaybackController.self) private var playback
    var size: Size

    private var buttonSize: CGFloat { size == .compact ? 44 : 56 }
    private var glyphSize: CGFloat { size == .compact ? 14 : 18 }
    private var sideSize: CGFloat { size == .compact ? 15 : 17 }

    var body: some View {
        HStack(spacing: size == .compact ? 20 : 22) {
            if size == .immersive {
                ModeButton(
                    systemImage: "shuffle",
                    isOn: playback.shuffleMode.isOn,
                    label: "Shuffle"
                ) { playback.toggleShuffle() }
            }

            TransportButton(systemImage: "backward.fill", size: sideSize,
                            label: "Previous track") {
                playback.previous()
            }

            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Tokens.Palette.accent)
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: glyphSize, weight: .bold))
                        .foregroundStyle(.white)
                        // The play triangle is optically left-heavy; nudging it
                        // right centres it in the circle.
                        .offset(x: playback.isPlaying ? 0 : 1.5)
                }
                .frame(width: buttonSize, height: buttonSize)
                .shadow(color: Tokens.Palette.accent.opacity(0.32),
                        radius: size == .compact ? 9 : 16,
                        y: size == .compact ? 6 : 12)
            }
            .plainControl()
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            TransportButton(systemImage: "forward.fill", size: sideSize,
                            label: "Next track") {
                playback.next()
            }

            if size == .immersive {
                ModeButton(
                    systemImage: playback.repeatMode == .one ? "repeat.1" : "repeat",
                    isOn: playback.repeatMode != .off,
                    label: "Repeat"
                ) { playback.cycleRepeat() }
            }
        }
    }
}

private struct TransportButton: View {
    var systemImage: String
    var size: CGFloat
    var label: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isHovering ? .white : Color(hex: 0x9B9BA5))
                .frame(width: 26)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct ModeButton: View {
    var systemImage: String
    var isOn: Bool
    var label: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn
                                 ? Tokens.Palette.accent
                                 : (isHovering ? .white : Color(hex: 0x71717B)))
                .frame(width: 26)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
