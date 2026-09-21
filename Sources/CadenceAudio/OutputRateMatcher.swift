import Foundation
import CoreAudio

/// A reading of the default output device.
struct OutputDeviceSnapshot: Equatable {
    var id: AudioDeviceID
    var rate: Double
    var supported: [ClosedRange<Double>]

    func supports(_ rate: Double) -> Bool {
        supported.contains { $0.contains(rate) }
    }
}

/// The slice of the output device the matcher needs. A protocol so the policy
/// — when to switch, what to remember, when to put it back — can be tested
/// without a DAC on the desk.
@MainActor
protocol OutputRateControlling {
    /// The default output device now, or nil when there is none.
    func snapshot() -> OutputDeviceSnapshot?
    /// Requests `rate` and waits until the device reports it. False when the
    /// write was refused or the device never settled.
    func setRate(_ rate: Double, on id: AudioDeviceID) -> Bool
    func rate(of id: AudioDeviceID) -> Double
}

/// The real device, through `OutputDevice`.
struct SystemOutputRate: OutputRateControlling {
    /// `waitForSampleRate`'s 2 s default is tight for a USB DAC that reports
    /// the new rate before it is ready, or that refuses until its stream drains.
    var timeout: TimeInterval = 4

    func snapshot() -> OutputDeviceSnapshot? {
        guard let id = try? OutputDevice.defaultOutputDeviceID() else { return nil }
        return OutputDeviceSnapshot(id: id, rate: OutputDevice.sampleRate(of: id),
                        supported: OutputDevice.availableSampleRateRanges(of: id))
    }

    func setRate(_ rate: Double, on id: AudioDeviceID) -> Bool {
        // `noErr` from the setter says coreaudiod accepted the request, not
        // that the device is running at the rate. Only the wait proves that.
        guard OutputDevice.setSampleRate(rate, on: id) == noErr else { return false }
        return OutputDevice.waitForSampleRate(rate, on: id, timeout: timeout)
    }

    func rate(of id: AudioDeviceID) -> Double { OutputDevice.sampleRate(of: id) }
}

/// Decides whether the output device follows the file — issue #34.
///
/// It only ever acts when asked, and it remembers what it changed. A DAC that
/// was on 44.1 kHz when playback began goes back to 44.1 kHz when playback
/// ends, so playing an album does not leave the user's other audio on the
/// album's rate.
@MainActor
final class OutputRateMatcher {

    enum Outcome: Equatable {
        /// The device is at the file's rate.
        case matched
        /// It is not, and the file plays resampled at `deviceRate` — because
        /// the device does not offer the rate, refused it, or never settled.
        case fallback(deviceRate: Double)
        /// No output device to ask.
        case unavailable
    }

    private let device: any OutputRateControlling

    /// What the device was on before the first switch, and which device that
    /// was. Nil whenever nothing of the user's has been changed.
    private var saved: (id: AudioDeviceID, rate: Double)?

    init(device: any OutputRateControlling = SystemOutputRate()) {
        self.device = device
    }

    /// True when following `fileRate` would mean writing to the device. A
    /// device that lacks the rate answers false: nothing will be written, so
    /// nothing has to be interrupted.
    func needsSwitch(for fileRate: Double) -> Bool {
        guard let now = device.snapshot() else { return false }
        return now.rate != fileRate && now.supports(fileRate)
    }

    /// True while a rate the user did not choose is still in force.
    var hasSavedRate: Bool { saved != nil }

    /// Puts the device on `fileRate` if it offers it. The caller must have
    /// stopped rendering first: a rate change under a running stream clicks.
    func match(fileRate: Double) -> Outcome {
        guard let now = device.snapshot() else { return .unavailable }

        // The default output moved since the last switch; the rate saved
        // belongs to a device that is no longer the one playing.
        if let saved, saved.id != now.id { restore() }

        if now.rate == fileRate { return .matched }
        guard now.supports(fileRate) else { return .fallback(deviceRate: now.rate) }

        if saved == nil { saved = (now.id, now.rate) }
        if device.setRate(fileRate, on: now.id) { return .matched }
        return .fallback(deviceRate: device.rate(of: now.id))
    }

    /// Puts the device back where the user had it. Returns whether it wrote.
    @discardableResult
    func restore() -> Bool {
        guard let saved else { return false }
        self.saved = nil
        guard device.rate(of: saved.id) != saved.rate else { return false }
        return device.setRate(saved.rate, on: saved.id)
    }
}
