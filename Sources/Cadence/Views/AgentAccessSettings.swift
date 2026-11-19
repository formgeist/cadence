import AppKit
import SwiftUI
import CadenceDesign
import CadenceServer

/// The Agents rows in Preferences: the switch, where the endpoint is, the
/// key, the command that sets up Claude Code, and the last change an agent
/// made.
///
/// The key is never drawn in full unless asked for, never put in an
/// accessibility label, and copied as concealed, the way the pairing link is.
struct AgentAccessSettings: View {
    @Environment(AgentAccessController.self) private var agents: AgentAccessController?

    @State private var isKeyVisible = false
    @State private var copied: Copied?
    @State private var confirmingNewKey = false

    private enum Copied { case key, command }

    var body: some View {
        if let agents {
            content(agents)
        }
    }

    private func content(_ agents: AgentAccessController) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            SettingsRow(
                "Let agents use this library",
                caption: "AI agents on this Mac, such as Claude Code, can read the library and "
                    + "change playlists, catalogs, memories and likes. They cannot remove music "
                    + "or touch your folders. When this is off, nothing is listening."
            ) {
                Toggle("", isOn: Binding(get: { agents.isEnabled },
                                         set: { agents.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Tokens.Palette.accent)
                    .accessibilityLabel("Let agents use this library")
            }

            switch agents.status {
            case .off:
                EmptyView()
            case .starting:
                statusLine("Starting…", icon: "arrow.clockwise")
            case .on:
                if let url = agents.endpointURL {
                    statusLine("Listening at \(url), on this Mac only.", icon: "checkmark")
                    keyRow(agents)
                    commandRow(agents, url: url)
                }
            }

            if let error = agents.lastError {
                statusLine(error, icon: "exclamationmark.triangle")
            }
            if let change = agents.lastChange {
                statusLine(Self.describe(change, now: Date()), icon: "info.circle")
            }
        }
        .confirmationDialog("Make a new key?", isPresented: $confirmingNewKey) {
            Button("New Key", role: .destructive) {
                agents.regenerateKey()
                isKeyVisible = false
                copied = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents set up with the current key stop working at once. "
                 + "Set them up again with the new one.")
        }
    }

    // MARK: - Key

    private func keyRow(_ agents: AgentAccessController) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text("Key")
                .font(Tokens.Typography.sans(13, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text("An agent sends this to prove the user let it in. Anyone with it can "
                 + "change this library, so keep it to your own agents.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            field(isKeyVisible ? agents.key() : Self.masked)
                .accessibilityLabel(isKeyVisible ? "Key, shown" : "Key, hidden")
            HStack(spacing: Tokens.Space.s) {
                CapsuleButton(title: isKeyVisible ? "Hide" : "Show") {
                    isKeyVisible.toggle()
                }
                CapsuleButton(title: copied == .key ? "Copied" : "Copy Key") {
                    Self.copyConcealed(agents.key())
                    copied = .key
                }
                CapsuleButton(title: "New Key…") {
                    confirmingNewKey = true
                }
            }
        }
    }

    // MARK: - Command

    private func commandRow(_ agents: AgentAccessController, url: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text("Add to Claude Code")
                .font(Tokens.Typography.sans(13, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text("Run this in Terminal. Other MCP clients take the same address, with the "
                 + "key as a bearer token.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            field(Self.command(url: url, key: isKeyVisible ? agents.key() : Self.masked))
                .accessibilityLabel("Claude Code command")
            CapsuleButton(title: copied == .command ? "Copied" : "Copy Command") {
                Self.copyConcealed(Self.command(url: url, key: agents.key()))
                copied = .command
            }
        }
    }

    static let masked = String(repeating: "•", count: 24)

    static func command(url: String, key: String) -> String {
        "claude mcp add --transport http cadence \(url) --header \"Authorization: Bearer \(key)\""
    }

    /// Concealed, so clipboard managers that honour the convention keep no
    /// copy of the key.
    static func copyConcealed(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(text, forType: .string)
        board.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    }

    /// "Last change: an agent created the playlist “Drive”, 5 minutes ago."
    static func describe(_ change: AgentAccessController.Change, now: Date) -> String {
        let when: String
        if now.timeIntervalSince(change.date) < 60 {
            when = "just now"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            when = formatter.localizedString(for: change.date, relativeTo: now)
        }
        let what = AgentAccessController.notice(for: change.summary)
        return "Last change: " + what.prefix(1).lowercased() + what.dropFirst() + ", \(when)."
    }

    // MARK: - Pieces

    private func field(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.mono(11))
            .foregroundStyle(Tokens.Palette.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Space.s)
            .padding(.horizontal, Tokens.Space.m)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.fieldBorder, lineWidth: 1)
            }
    }

    private func statusLine(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            CadenceIcon(icon, size: 10)
                .foregroundStyle(Tokens.Palette.textMuted)
            Text(text)
                .font(Tokens.Typography.captionSmall)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
