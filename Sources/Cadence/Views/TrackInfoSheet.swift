import SwiftUI
import CadenceCore

/// Read-only. Everything shown here is already sitting in the database —
/// this just says it out loud, the way the album header's badge does for one
/// line of it. Editing tags is a different, much larger question: it means
/// writing to the user's files, which is an entitlement change rather than a
/// display one — the same line #6 draws for ReplayGain.
struct TrackInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(track.title)
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(2)
                Text("\(track.artist) — \(track.albumTitle)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                row("Format", track.format.badgeDescription)
                row("Channels", channelDescription)
                row("Duration", DurationFormat.clock(track.duration))
                replayGainRows
                row("Location", track.url.path)
            }

            HStack {
                Spacer(minLength: 0)
                CapsuleButton(title: "Done", kind: .filled) { dismiss() }
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 420)
        .background(Tokens.Palette.popover)
        .onExitCommand { dismiss() }
    }

    private var channelDescription: String {
        switch track.format.channelCount {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(track.format.channelCount) channels"
        }
    }

    @ViewBuilder
    private var replayGainRows: some View {
        let gain = track.replayGain
        if gain?.trackGain == nil, gain?.albumGain == nil {
            row("ReplayGain", "Not tagged")
        } else {
            if let trackGain = gain?.trackGain { row("Track Gain", Self.decibels(trackGain)) }
            if let trackPeak = gain?.trackPeak { row("Track Peak", Self.peak(trackPeak)) }
            if let albumGain = gain?.albumGain { row("Album Gain", Self.decibels(albumGain)) }
            if let albumPeak = gain?.albumPeak { row("Album Peak", Self.peak(albumPeak)) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            Text(label.uppercased())
                .font(Tokens.Typography.monoLabel)
                .tracking(Tokens.Typography.Tracking.label)
                .foregroundStyle(Tokens.Palette.textMuted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(Tokens.Typography.monoValue)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func decibels(_ value: Double) -> String {
        String(format: "%.2f dB", value)
    }

    private static func peak(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
