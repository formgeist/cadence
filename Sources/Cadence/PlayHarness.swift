import Foundation
import CadenceCore
import CadenceLibrary
import CadenceAudio

/// `Cadence --play <file-or-folder>` — drives real playback and reports what
/// happened, without a window.
///
/// This answers two of PLAN.md §3's four questions as far as a machine can.
/// Position advancing proves frames are actually being rendered to a device;
/// reaching the second track without the controller restarting it proves the
/// gapless handshake fires on real files. Whether the seam is *audible* still
/// needs ears — put on headphones and run this against a live album.
@MainActor
enum PlayHarness {

    struct Options {
        var target: URL
        /// How close to the end of the first track to start, so the handoff
        /// happens within seconds rather than minutes.
        var lead: TimeInterval
    }

    static func parse(_ arguments: [String]) -> Options? {
        guard let flag = arguments.firstIndex(of: "--play") else { return nil }
        let next = arguments.index(after: flag)
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("--") else {
            FileHandle.standardError.write(Data("--play needs a file or folder\n".utf8))
            return nil
        }
        var lead: TimeInterval = 6
        if let leadFlag = arguments.firstIndex(of: "--lead") {
            let value = arguments.index(after: leadFlag)
            if arguments.indices.contains(value), let parsed = Double(arguments[value]) {
                lead = parsed
            }
        }
        return Options(
            target: URL(fileURLWithPath:
                (arguments[next] as NSString).expandingTildeInPath),
            lead: lead)
    }

    static func run(_ options: Options) async throws -> Int32 {
        let router = AppContainer.metadataRouter

        var files: [URL]
        if options.target.hasDirectoryPath {
            files = LibraryScanner.audioFiles(
                in: options.target, extensions: router.supportedExtensions)
        } else {
            files = [options.target]
        }
        guard !files.isEmpty else {
            print("No audio files at \(options.target.path)")
            return 1
        }
        files = Array(files.prefix(2))

        let tracks = files.compactMap { url -> Track? in
            guard let reader = router.reader(for: url) else { return nil }
            return try? reader.readTrack(at: url)
        }
        guard let first = tracks.first else {
            print("Could not read metadata for \(files[0].lastPathComponent)")
            return 1
        }

        for track in tracks {
            print("  \(track.title) — \(track.artist)  "
                + "\(DurationFormat.clock(track.duration))  \(track.format.badgeDescription)")
        }
        print("")

        let controller = PlaybackController(engine: SFBPlayerEngine())
        controller.play(first, in: tracks)

        // Start near the end so the transition to track two happens inside the
        // observation window.
        if tracks.count > 1, first.duration > options.lead + 2 {
            // Give the engine a moment to open the device before seeking.
            try await Task.sleep(for: .milliseconds(400))
            controller.seek(to: first.duration - options.lead)
        }

        var lastState = ""
        var lastTrack = ""
        var positions: [TimeInterval] = []
        var sawSecondTrack = false
        var restarted = false

        let deadline = ContinuousClock().now + .seconds(Int(options.lead) + 6)
        while ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(250))

            let state = describe(controller.state)
            let title = controller.currentTrack?.title ?? "—"

            if title != lastTrack, !lastTrack.isEmpty {
                sawSecondTrack = true
                // A gapless handoff resumes near zero on the new track. A
                // restart of the *same* track would show as no title change,
                // so what is being checked here is that the controller followed
                // the engine rather than issuing a fresh play.
                print("  → moved to \"\(title)\" at \(String(format: "%.2f", controller.progress.elapsed))s")
            }
            if state != lastState {
                print("  state: \(state)")
                if state == "playing", sawSecondTrack, controller.progress.elapsed > 2 {
                    restarted = true
                }
            }
            lastState = state
            lastTrack = title
            positions.append(controller.progress.elapsed)

            if case .failed(let error) = controller.state {
                print("\n  ✗ \(error.message)")
                return 1
            }
        }
        controller.stop()

        let advanced = zip(positions, positions.dropFirst()).contains { $0 < $1 }
        print("""

            position advanced:   \(advanced ? "yes — frames are rendering" : "NO")
            reached next track:  \(sawSecondTrack ? "yes" : (tracks.count > 1 ? "no" : "n/a — one file"))
            gapless handoff:     \(sawSecondTrack && !restarted ? "engine-driven" : (sawSecondTrack ? "controller restarted it" : "not observed"))
            """)
        return advanced ? 0 : 1
    }

    private static func describe(_ state: PlaybackState) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .failed: "failed"
        }
    }
}
