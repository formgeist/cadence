import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CadenceDesign

/// The Sharing rows in Preferences: the switch, where the server is, the
/// pairing code, and the devices that may connect.
///
/// Built from the same rows and cards as the rest of the page. The paired
/// devices stay listed with sharing off, so access can be taken away without
/// first switching the server on.
struct SharingSettings: View {
    @Environment(SharingController.self) private var sharing: SharingController?

    @State private var pendingRemoval: SharedDevice?
    @State private var linkCopied = false

    /// Puts the pairing link on the pasteboard, for a Mac that has no camera
    /// to scan the code with. Marked concealed, so clipboard managers that
    /// honour the convention do not keep the token in their history.
    static func copy(_ link: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(link, forType: .string)
        board.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    }

    var body: some View {
        if let sharing {
            content(sharing)
        }
    }

    private func content(_ sharing: SharingController) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            SettingsRow(
                "Share library on this network",
                caption: "Let your paired iPhone and iPad browse and play this library over "
                    + "the local network. They can read it and cannot change it. "
                    + "When this is off, nothing is listening."
            ) {
                Toggle("", isOn: Binding(get: { sharing.isEnabled },
                                         set: { sharing.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Tokens.Palette.accent)
                    .accessibilityLabel("Share library on this network")
            }

            switch sharing.status {
            case .off:
                EmptyView()
            case .starting:
                statusLine("Starting…", icon: "arrow.clockwise")
            case .on(let endpoint):
                statusLine(address(sharing, endpoint), icon: "checkmark")
                pairingRows(sharing)
            }

            if let notice = sharing.notice {
                statusLine(notice, icon: "info.circle")
            }
            if let error = sharing.lastError {
                statusLine(error, icon: "exclamationmark.triangle")
            }

            deviceList(sharing)

            if case .on(let endpoint) = sharing.status {
                fingerprint(endpoint.fingerprint)
            }
        }
        // "Last seen" moves while the page is open, and a device can pair
        // from another room.
        .task {
            while !Task.isCancelled {
                await sharing.refreshDevices()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove “\($0.name)”?" } ?? "Remove device?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { device in
            Button("Remove Device", role: .destructive) {
                pendingRemoval = nil
                Task { await sharing.revoke(device) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("It loses access to this library at once. "
                 + "To connect again it must be paired again.")
        }
    }

    private func address(_ sharing: SharingController, _ endpoint: SharingEndpoint) -> String {
        let place = sharing.host.map { "\($0), port \(endpoint.port)" }
            ?? "port \(endpoint.port). This Mac is not on a network"
        return "Sharing as “\(sharing.computerName)” at \(place)."
    }

    // MARK: - Pairing

    @ViewBuilder
    private func pairingRows(_ sharing: SharingController) -> some View {
        if let pairing = sharing.pairing {
            HStack(alignment: .top, spacing: Tokens.Space.xl) {
                PairingCode(link: pairing.link)

                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    Text("Scan with Cadence on your iPhone or iPad")
                        .font(Tokens.Typography.sans(13, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text("To pair another Mac, copy the link and open it there. "
                         + "The code pairs one device, once. It stops working at "
                         + pairing.expiresAt.formatted(date: .omitted, time: .shortened)
                         + ", or when you close it. Anyone who has it can pair, "
                         + "so send it only to your own device.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Tokens.Space.s) {
                        CapsuleButton(title: linkCopied ? "Copied" : "Copy Link") {
                            Self.copy(pairing.link)
                            linkCopied = true
                        }
                        CapsuleButton(title: "Close Code") {
                            Task { await sharing.cancelPairing() }
                        }
                    }
                    .padding(.top, Tokens.Space.xs)
                }
                // A new code starts with the button reading "Copy Link" again.
                .onChange(of: pairing.link) { linkCopied = false }
            }
        } else {
            SettingsRow(
                "Pair a device",
                caption: "Shows a code to scan with Cadence on your iPhone or iPad."
            ) {
                CapsuleButton(title: "Show Code…", kind: .filled) {
                    Task { await sharing.beginPairing() }
                }
            }
        }
    }

    // MARK: - Devices

    @ViewBuilder
    private func deviceList(_ sharing: SharingController) -> some View {
        if sharing.devices.isEmpty {
            if sharing.isOn {
                Text("No devices are paired.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text("Paired devices")
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                ForEach(sharing.devices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: SharedDevice) -> some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(device.name)
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(Self.history(of: device, now: Date()))
                    .font(Tokens.Typography.captionSmall)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.m)
            Button {
                pendingRemoval = device
            } label: {
                CadenceIcon("minus.circle", size: 14)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .plainControl()
            .help("Remove this device")
            .accessibilityLabel("Remove \(device.name)")
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

    /// "Paired 12 Nov 2026 · Last connected 5 minutes ago"
    static func history(of device: SharedDevice, now: Date) -> String {
        let paired = "Paired " + device.pairedAt.formatted(date: .abbreviated, time: .omitted)
        guard let seen = device.lastSeenAt else { return paired + " · Has not connected yet" }
        // The server notes a connection to the nearest minute or so; anything
        // closer than that is "just now", not a count of seconds.
        if now.timeIntervalSince(seen) < 90 { return paired + " · Connected just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return paired + " · Last connected " + formatter.localizedString(for: seen, relativeTo: now)
    }

    // MARK: - Fingerprint

    /// What the phone pinned when it scanned the code, in a form two people
    /// can read to each other. The app shows the same digits for a paired
    /// server.
    private func fingerprint(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text("Certificate fingerprint")
                .font(Tokens.Typography.captionSmall)
                .foregroundStyle(Tokens.Palette.textTertiary)
            Text(Self.grouped(fingerprint))
                .font(Tokens.Typography.mono(10.5))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Certificate fingerprint")
                .accessibilityValue(fingerprint)
        }
    }

    /// Sixteen groups of four, eight to a line.
    static func grouped(_ fingerprint: String) -> String {
        var groups: [String] = []
        var rest = Substring(fingerprint.uppercased())
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return stride(from: 0, to: groups.count, by: 8)
            .map { groups[$0..<min($0 + 8, groups.count)].joined(separator: " ") }
            .joined(separator: "\n")
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

/// The pairing link as a QR code: black on white with a quiet border, which
/// is what a camera expects whatever the app around it looks like.
private struct PairingCode: View {
    var link: String

    static let side: CGFloat = 168

    var body: some View {
        Group {
            if let image = Self.image(for: link) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Self.side, height: Self.side)
            } else {
                Color.white.frame(width: Self.side, height: Self.side)
            }
        }
        .padding(Tokens.Space.m)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(Color.white)
        }
        // Named, and nothing more: the link holds the pairing token, which
        // has no business in an accessibility tree other programs can read.
        .accessibilityElement()
        .accessibilityLabel("Pairing code")
        .accessibilityAddTraits(.isImage)
    }

    static func image(for link: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// The title bar's sign that the Mac is listening. Shown whenever the server
/// runs and never otherwise, so sharing cannot be on without the window
/// saying so. Clicking it opens Preferences, where the switch is.
struct SharingIndicator: View {
    @Environment(SharingController.self) private var sharing: SharingController?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sharing, sharing.isOn {
            Button {
                if model.screen != .settings { model.show(.settings) }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    Circle()
                        .fill(Tokens.Palette.accent)
                        .frame(width: 6, height: 6)
                    Text("Sharing")
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize()
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .plainControl()
            .help("Library sharing is on. Click to open Preferences.")
            .accessibilityLabel("Library sharing is on")
            .accessibilityHint("Opens Preferences")
        }
    }
}
