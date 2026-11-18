import SwiftUI
import CadenceDesign
import CadenceCore
import CadenceRemote

/// The top of Preferences › Library: which library is showing, the paired
/// Mac, and pairing with one.
///
/// A Mac has no camera, so pairing is by the link the other Mac's Sharing
/// pane copies: opened from Messages or Safari, which lands here to be
/// confirmed, or pasted into the field.
struct LibrarySourceSettings: View {
    @Environment(LibrarySourceController.self) private var library: LibrarySourceController?

    var body: some View {
        if let library {
            Content(library: library)
        }
    }

    private struct Content: View {
        @Bindable var library: LibrarySourceController

        @State private var isEnteringLink = false
        @State private var linkText = ""
        @State private var linkError: String?
        @State private var confirmsForget = false
        @FocusState private var isFieldFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                showingRow
                if let session = library.session {
                    ConnectionLine(session: session)
                }
                if let name = library.pairedMacName {
                    pairedRow(name)
                }
                pairingRows
            }
            .confirmationDialog(
                "Forget \(library.pairedMacName ?? "the paired Mac")?",
                isPresented: $confirmsForget
            ) {
                Button("Forget", role: .destructive) { library.forget() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(library.isShowingPairedMac
                     ? "Cadence reopens on this Mac's library. Downloaded music and the history "
                        + "kept for that library are removed. To pair again you need a new link."
                     : "Downloaded music and the history kept for that library are removed. "
                        + "To pair again you need a new link.")
            }
        }

        // MARK: Which library

        @ViewBuilder
        private var showingRow: some View {
            if library.isShowingPairedMac, let name = library.pairedMacName {
                SettingsRow(
                    "Showing \(name)'s library",
                    caption: "Over the network. You can browse and play it here but not change it: "
                        + "playlists and likes are edited on \(name)."
                ) {
                    CapsuleButton(title: "Use This Mac's Library") { library.use(.thisMac) }
                }
            } else if let name = library.pairedMacName {
                SettingsRow(
                    "Showing this Mac's library",
                    caption: "Switch to \(name)'s library to play the music stored there. "
                        + "Cadence reopens to switch."
                ) {
                    CapsuleButton(title: "Use \(name)'s Library") { library.use(.pairedMac) }
                }
            }
        }

        private func pairedRow(_ name: String) -> some View {
            SettingsRow("Paired with \(name)") {
                CapsuleButton(title: "Forget…") { confirmsForget = true }
            }
        }

        // MARK: Pairing

        @ViewBuilder
        private var pairingRows: some View {
            switch library.pairingState {
            case .pairing(let name):
                statusLine("Pairing with \(name)…", icon: "arrow.clockwise")
            case .failed(let message):
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    statusLine(message, icon: "exclamationmark.triangle")
                    CapsuleButton(title: "OK") { library.dismissFailure() }
                }
            case .idle:
                if let pending = library.pendingLink {
                    confirmation(pending)
                } else if isEnteringLink {
                    linkField
                } else {
                    SettingsRow(
                        library.pairedMacName == nil ? "Play another Mac's library"
                                                     : "Pair with a different Mac",
                        caption: "On the Mac with your music, open Cadence's Preferences › Sharing, "
                            + "turn sharing on, show a code and copy its link. Then open the link "
                            + "here, or paste it. Both Macs must be on the same network."
                    ) {
                        CapsuleButton(title: "Paste Link…") {
                            linkError = nil
                            isEnteringLink = true
                            isFieldFocused = true
                        }
                    }
                }
            }
        }

        private func confirmation(_ payload: PairingPayload) -> some View {
            SettingsRow(
                "Pair with \(payload.name)?",
                caption: "This Mac will show \(payload.name)'s library, and Cadence reopens to "
                    + "switch. \(payload.name) lists this Mac as \(LibrarySourceController.deviceName), "
                    + "and can remove it there."
            ) {
                HStack(spacing: Tokens.Space.s) {
                    CapsuleButton(title: "Cancel") { library.pendingLink = nil }
                    CapsuleButton(title: "Pair", kind: .filled) {
                        library.pendingLink = nil
                        Task { await library.pair(payload) }
                    }
                }
            }
        }

        private var linkField: some View {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                TextField("cadence://pair?…", text: $linkText)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.sans(13, .medium))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .focused($isFieldFocused)
                    .textEntryFocus(isFieldFocused)
                    .onSubmit(submitLink)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                            .fill(Tokens.Palette.fieldFocusBackground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                            .strokeBorder(isFieldFocused ? Tokens.Palette.fieldFocusBorder
                                                         : Tokens.Palette.fieldBorder, lineWidth: 1)
                    }
                    .accessibilityLabel("Pairing link")

                if let linkError {
                    statusLine(linkError, icon: "exclamationmark.triangle")
                }

                HStack(spacing: Tokens.Space.s) {
                    CapsuleButton(title: "Cancel") {
                        isEnteringLink = false
                        linkText = ""
                        linkError = nil
                    }
                    CapsuleButton(title: "Continue", kind: .filled, action: submitLink)
                        .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }

        /// Reads the link and asks to confirm it, the same as an opened one.
        private func submitLink() {
            do {
                library.pendingLink = try LibrarySourceController.payload(from: linkText)
                isEnteringLink = false
                linkText = ""
                linkError = nil
            } catch {
                linkError = error.localizedDescription
            }
        }

        private func statusLine(_ text: String, icon: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                CadenceIcon(icon, size: 10)
                    .foregroundStyle(Tokens.Palette.textMuted)
                Text(text)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Whether the paired Mac is answering, in a line, with a way to try again.
private struct ConnectionLine: View {
    let session: RemoteLibrarySession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Circle()
                .fill(isConnected ? Tokens.Palette.accent : Tokens.Palette.textMuted)
                .frame(width: 6, height: 6)
            Text(RemoteConnectionText.sentence(for: session.connection, macName: session.macName))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("Try Again") { session.retry() }
                    .buttonStyle(.link)
                    .font(Tokens.Typography.caption)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = session.connection { return true }
        return false
    }

    private var canRetry: Bool {
        switch session.connection {
        case .unreachable, .needsAttention: true
        default: false
        }
    }
}

/// The title bar's sign that the library is another Mac's, and whether that
/// Mac is answering. Clicking it opens Preferences, where the library is
/// chosen.
struct PairedLibraryIndicator: View {
    @Environment(LibrarySourceController.self) private var library: LibrarySourceController?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = library?.session {
            let connected = RemoteConnectionText.isConnected(session.connection)
            Button {
                if model.screen != .settings { model.show(.settings) }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    Circle()
                        .fill(connected ? Tokens.Palette.accent : Tokens.Palette.textMuted)
                        .frame(width: 6, height: 6)
                    Text(RemoteConnectionText.short(for: session.connection))
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .plainControl()
            .help(RemoteConnectionText.sentence(for: session.connection, macName: session.macName))
            .accessibilityLabel("Library on \(session.macName). "
                + RemoteConnectionText.sentence(for: session.connection, macName: session.macName))
            .accessibilityHint("Opens Preferences")
        }
    }
}

/// The words for the paired Mac's state, shared by Preferences and the title
/// bar.
enum RemoteConnectionText {
    static func sentence(for state: RemoteConnection.State, macName: String) -> String {
        switch state {
        case .idle, .connecting:
            "Connecting to \(macName)…"
        case .connected:
            "Connected to \(macName)."
        case .offline:
            "This Mac is offline. Showing the library as it was last seen."
        case .unreachable:
            "\(macName) is not answering. Showing the library as it was last seen; "
                + "Cadence keeps trying."
        case .needsAttention(let error):
            error.message
        }
    }

    /// One short word for the title bar, which has room for little more
    /// than "Sharing" beside the gear. The tooltip carries the sentence.
    static func short(for state: RemoteConnection.State) -> String {
        switch state {
        case .idle, .connecting, .connected: "Remote"
        case .offline: "Offline"
        case .unreachable: "Away"
        case .needsAttention: "Check"
        }
    }

    static func isConnected(_ state: RemoteConnection.State) -> Bool {
        if case .connected = state { return true }
        return false
    }
}
