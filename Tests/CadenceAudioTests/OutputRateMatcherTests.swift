import Testing
import CoreAudio
@testable import CadenceAudio

/// A device that behaves the way the tests say it does, and records every write.
@MainActor
private final class FakeDevice: OutputRateControlling {
    var id: AudioDeviceID = 1
    var rate: Double = 44_100
    var supported: [ClosedRange<Double>] = [44_100...44_100, 48_000...48_000, 96_000...96_000]
    /// When true, writes are refused outright.
    var refuses = false
    private(set) var writes: [Double] = []

    func snapshot() -> OutputDeviceSnapshot? {
        OutputDeviceSnapshot(id: id, rate: rate, supported: supported)
    }

    func setRate(_ rate: Double, on id: AudioDeviceID) -> Bool {
        writes.append(rate)
        guard !refuses else { return false }
        self.rate = rate
        return true
    }

    func rate(of id: AudioDeviceID) -> Double { rate }
}

@MainActor
@Suite("OutputRateMatcher")
struct OutputRateMatcherTests {

    @Test("A supported rate the device is not on is switched to")
    func switches() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)

        #expect(matcher.needsSwitch(for: 96_000))
        #expect(matcher.match(fileRate: 96_000) == .matched)
        #expect(device.rate == 96_000)
        #expect(matcher.hasSavedRate)
    }

    @Test("A device already at the file's rate is left alone")
    func alreadyThere() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)

        #expect(!matcher.needsSwitch(for: 44_100))
        #expect(matcher.match(fileRate: 44_100) == .matched)
        #expect(device.writes.isEmpty)
        #expect(!matcher.hasSavedRate)
    }

    @Test("An unsupported rate falls back to the device rate without writing")
    func unsupported() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)

        #expect(!matcher.needsSwitch(for: 192_000))
        #expect(matcher.match(fileRate: 192_000) == .fallback(deviceRate: 44_100))
        #expect(device.writes.isEmpty)
    }

    @Test("A refused write falls back to whatever the device is on")
    func refused() {
        let device = FakeDevice()
        device.refuses = true
        let matcher = OutputRateMatcher(device: device)

        #expect(matcher.match(fileRate: 96_000) == .fallback(deviceRate: 44_100))
    }

    @Test("A device offering a continuous range accepts any rate in it")
    func continuousRange() {
        let device = FakeDevice()
        device.supported = [8_000...192_000]
        let matcher = OutputRateMatcher(device: device)

        #expect(matcher.match(fileRate: 88_200) == .matched)
    }

    @Test("Restoring writes the rate from before the first switch, once")
    func restoresOriginal() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)

        // Two switches in a row: the original is 44.1, not the intermediate 96.
        _ = matcher.match(fileRate: 96_000)
        _ = matcher.match(fileRate: 48_000)
        #expect(matcher.restore())
        #expect(device.rate == 44_100)
        #expect(!matcher.hasSavedRate)

        #expect(!matcher.restore())
    }

    @Test("Nothing to restore when nothing was changed")
    func restoreWithoutSwitch() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)
        _ = matcher.match(fileRate: 44_100)

        #expect(!matcher.restore())
        #expect(device.writes.isEmpty)
    }

    @Test("A rate saved from another device is not written onto this one")
    func deviceChanged() {
        let device = FakeDevice()
        let matcher = OutputRateMatcher(device: device)
        _ = matcher.match(fileRate: 96_000)

        // Default output moves to a different device, sitting at 48 kHz.
        device.id = 2
        device.rate = 48_000
        #expect(matcher.match(fileRate: 48_000) == .matched)
        #expect(!matcher.hasSavedRate)
    }
}
