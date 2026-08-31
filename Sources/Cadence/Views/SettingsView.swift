import SwiftUI
import AppKit
import CadenceCore
import CadenceLibrary

/// The Preferences window — issue #71. `CadenceApp` had only a `WindowGroup`, so
/// there was nowhere for a setting to live even once one existed. This is the
/// window and its wiring; each row's own behaviour is the concern of the issue
/// that adds it.
///
/// Built from `Tokens` rather than a stock `Form`: the app is one custom dark
/// surface end to end, and a system-drawn settings pane reads as a different
/// program. The shape follows `TrackInfoSheet` and `PlaylistNameSheet`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(ScrobbleController.self) private var scrobble
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var playback = playback
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            Text("Preferences")
                .font(Tokens.Typography.sans(16, .bold))
                .foregroundStyle(Tokens.Palette.textPrimary)

            SettingsSection("Library") {
                LibrarySettings()
            }

            SettingsSection("Playback") {
                SettingsRow(
                    "ReplayGain",
                    caption: "Even out loudness differences between tracks and albums."
                ) {
                    SegmentedPicker(
                        selection: $playback.replayGainMode,
                        options: ReplayGainMode.allCases,
                        label: \.label
                    )
                }
            }

            SettingsSection("Scrobbling") {
                ScrobbleSettings()
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 460, alignment: .leading)
        .background(Tokens.Palette.surface)
        .preferredColorScheme(.dark)
        // `connect()` asks for a browser via this property; open it and clear.
        .onChange(of: scrobble.pendingAuthorizationURL) { _, url in
            guard let url else { return }
            openURL(url)
            scrobble.pendingAuthorizationURL = nil
        }
        .confirmationDialog(
            folderRemovalPrompt,
            isPresented: Binding(get: { model.folderPendingRemoval != nil },
                                 set: { if !$0 { model.folderPendingRemoval = nil } }),
            presenting: model.folderPendingRemoval
        ) { folder in
            Button("Remove Folder", role: .destructive) {
                model.folderPendingRemoval = nil
                Task { await model.removeFolder(folder) }
            }
            Button("Cancel", role: .cancel) { model.folderPendingRemoval = nil }
        } message: { folder in
            let count = model.tracks(under: folder).count
            Text(count == 0
                 ? "The files stay on disk."
                 : "\(count == 1 ? "1 track" : "\(count) tracks") "
                    + "will leave your library and any playlists. The files stay on disk.")
        }
    }

    private var folderRemovalPrompt: String {
        guard let folder = model.folderPendingRemoval else { return "Remove folder?" }
        return "Remove “\(folder.lastPathComponent)” from your library?"
    }
}

/// The music folders that have been added, each with a way out — issue #33.
/// Adding is here too, so this row is the whole story of what the library is
/// built from rather than a list you can only shrink.
private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryImporter.self) private var importer

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            if importer.folders.isEmpty {
                Text("No music folders have been added yet.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(importer.folders, id: \.self) { folder in
                        folderRow(folder)
                    }
                }
            }

            CapsuleButton(title: "Add Music Folder…", systemImage: "plus") {
                guard let folder = importer.chooseFolder() else { return }
                importer.importFolders([folder]) {
                    Task { await model.load() }
                }
            }

            if let error = importer.errorMessage {
                HStack(spacing: Tokens.Space.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.Palette.textMuted)
                    Text(error)
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
            }

            if !importer.scanFailures.isEmpty {
                UnreadableFiles(failures: importer.scanFailures) {
                    importer.rescanAll { Task { await model.load() } }
                }
            }
        }
    }

    private func folderRow(_ folder: URL) -> some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(folder.lastPathComponent)
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(Tokens.Typography.captionSmall)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Space.m)
            Button {
                model.folderPendingRemoval = folder
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .plainControl()
            .help("Remove this folder from the library")
            .accessibilityLabel("Remove \(folder.lastPathComponent)")
        }
        .padding(.vertical, Tokens.Space.xs)
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
}

/// The files a scan found but couldn't turn into tracks — what the "N files
/// couldn't be read" banner was counting, with no way through to the list
/// itself. Each row names the file, says why, and reveals it in Finder;
/// "Rescan" re-checks them all once the underlying files have been fixed.
private struct UnreadableFiles: View {
    var failures: [LibraryScanner.ScanFailure]
    var onRescan: () -> Void

    @Environment(LibraryImporter.self) private var importer

    private var countLabel: String {
        failures.count == 1 ? "1 file couldn’t be read"
                            : "\(failures.count) files couldn’t be read"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.Palette.accent)
                Text(countLabel)
                    .font(Tokens.Typography.sans(12, .semibold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: Tokens.Space.m)
                Button(action: onRescan) {
                    Text("Rescan")
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(importer.isImporting
                                         ? Tokens.Palette.textMuted : Tokens.Palette.accent)
                }
                .plainControl()
                .disabled(importer.isImporting)
            }

            Group {
                if failures.count > Self.maxInlineRows {
                    ScrollView {
                        rows
                    }
                    .frame(height: CGFloat(Self.maxInlineRows) * Self.rowHeight)
                } else {
                    rows
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.fieldBorder, lineWidth: 1)
            }

            Text("The files are still on disk — nothing was removed. "
                 + "Re-tag or replace them, then rescan.")
                .font(Tokens.Typography.captionSmall)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Show a few rows in full; past that, scroll rather than run the window long.
    private static let maxInlineRows = 5
    private static let rowHeight: CGFloat = 44

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(failures, id: \.path) { failure in
                row(failure)
            }
        }
    }

    private func row(_ failure: LibraryScanner.ScanFailure) -> some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(failure.fileName)
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    // Middle: keeps both the artist at the front and the track
                    // number and title at the end, dropping only the album in
                    // between when the name can't fit.
                    .truncationMode(.middle)
                Text(failure.reason)
                    .font(Tokens.Typography.captionSmall)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.s)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: failure.path)])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .plainControl()
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(failure.fileName) in Finder")
        }
        .padding(.vertical, Tokens.Space.s)
        .padding(.horizontal, Tokens.Space.m)
    }
}

/// The Last.fm rows — issue #95. Enable, connect / sign out, and whatever the
/// offline queue and the last error have to say.
private struct ScrobbleSettings: View {
    @Environment(ScrobbleController.self) private var scrobble

    var body: some View {
        @Bindable var scrobble = scrobble

        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            SettingsRow(
                "Scrobble to \(scrobble.serviceName)",
                caption: caption
            ) {
                Toggle("", isOn: $scrobble.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Tokens.Palette.accent)
                    .disabled(!scrobble.isConfigured)
            }

            if scrobble.isConfigured {
                accountRow
            }

            if scrobble.pendingCount > 0 {
                statusLine("\(scrobble.pendingCount) "
                    + (scrobble.pendingCount == 1 ? "scrobble" : "scrobbles")
                    + " waiting to send", icon: "clock")
            }
            if let error = scrobble.lastError {
                statusLine(error, icon: "exclamationmark.triangle")
            }
        }
    }

    private var caption: String {
        if !scrobble.isConfigured {
            return "No \(scrobble.serviceName) API key is configured in this build."
        }
        return "Send “now playing” updates and log tracks you finish."
    }

    @ViewBuilder
    private var accountRow: some View {
        if let account = scrobble.account {
            HStack(spacing: Tokens.Space.m) {
                Text("Signed in as \(account.username)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: Tokens.Space.l)
                CapsuleButton(title: "Sign Out") { scrobble.signOut() }
            }
        } else {
            HStack(spacing: Tokens.Space.m) {
                Text(connectPrompt)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                Spacer(minLength: Tokens.Space.l)
                CapsuleButton(title: "Connect…", kind: .filled) { scrobble.connect() }
                    .disabled(scrobble.authState == .waitingForApproval)
            }
        }
    }

    private var connectPrompt: String {
        switch scrobble.authState {
        case .idle:
            "Not connected."
        case .waitingForApproval:
            "Waiting for approval on \(scrobble.serviceName)…"
        case .failed(let message):
            message
        }
    }

    private func statusLine(_ text: String, icon: String) -> some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Tokens.Palette.textMuted)
            Text(text)
                .font(Tokens.Typography.captionSmall)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows. The heading is the same mono, wide-tracked label the
/// rest of the app uses for sections.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                content
            }
        }
    }
}

/// One setting: a name, an optional line of explanation, and its control on the
/// trailing edge.
struct SettingsRow<Control: View>: View {
    var name: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ name: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.name = name
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.l) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(name)
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.l)
            control
        }
    }
}

/// A row of pills, one selected. Small enough for a Preferences row and styled
/// like the rest of the app rather than an `NSSegmentedControl`.
struct SegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Tokens.Typography.sans(12, .semibold))
                        .foregroundStyle(isSelected
                                         ? Tokens.Palette.textPrimary
                                         : Tokens.Palette.textSecondary)
                        .padding(.horizontal, Tokens.Space.m)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                             style: .continuous)
                                .fill(isSelected ? Tokens.Palette.navActive : .clear)
                        }
                }
                .plainControl()
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.fieldBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.fieldBorder, lineWidth: 1)
        }
    }
}
