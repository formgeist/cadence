import SwiftUI
import CadenceCore

/// Everyone the album's tags name, by role. The composer used to sit under
/// every track title, which on most records repeated one name a dozen times;
/// here it is said once, alongside the credits that had nowhere to go at all.
/// Read-only for the same reason `TrackInfoSheet` is.
struct AlbumCreditsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Credits")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text("\(album.albumArtist) — \(album.title)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    ForEach(album.credits) { group in
                        section(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer(minLength: 0)
                CapsuleButton(title: "Done", kind: .filled) { dismiss() }
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 460)
        .background(Tokens.Palette.popover)
        .onExitCommand { dismiss() }
    }

    private func section(_ group: CreditGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
            Text((group.entries.count == 1 ? group.role.title : group.role.pluralTitle)
                    .uppercased())
                .font(Tokens.Typography.monoLabel)
                .tracking(Tokens.Typography.Tracking.label)
                .foregroundStyle(Tokens.Palette.textMuted)
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                ForEach(group.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                        Text(entry.name)
                            .font(Tokens.Typography.sans(13, .medium))
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tracks = entry.tracks {
                            Text(tracks)
                                .font(Tokens.Typography.mono(10.5))
                                .foregroundStyle(Tokens.Palette.textMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private extension Credit.Role {
    var pluralTitle: String { title + "s" }
}
