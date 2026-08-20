import Foundation
import CoreAudio
import AudioToolbox

/// Bit-perfect output means matching the device's sample rate to the file's,
/// which means writing `kAudioDevicePropertyNominalSampleRate`.
///
/// PLAN.md §3 flags this as the question that can reshape the release plan: if
/// the sandbox denies the write, the choice is direct distribution with
/// Sparkle, or the App Store without bit-perfect output. Answering it needs a
/// genuinely sandboxed build, which is why it sat unanswered until there was
/// one.
public enum OutputDevice {

    public struct Report: Sendable {
        public var deviceName: String
        public var currentRate: Double
        public var availableRates: [Double]
        /// nil when the write succeeded.
        public var writeStatus: OSStatus?
        public var isSandboxed: Bool
        /// False when a rate switch could not be undone — worth shouting
        /// about, since it means the user's device was left reconfigured.
        public var restored: Bool = true

        /// True only when the device was observed at the requested rate, not
        /// merely when the setter returned success.
        public var verified: Bool = false

        public var canSetSampleRate: Bool { writeStatus == nil }
    }

    public enum DeviceError: Error {
        case noDefaultOutput(OSStatus)
    }

    /// The sandbox writes into a container; its presence in the path is the
    /// simplest honest signal that the sandbox is active.
    public static var isSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw DeviceError.noDefaultOutput(status) }
        return deviceID
    }

    public static func name(of deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : "Unknown device"
    }

    public static func sampleRate(of deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    public static func availableSampleRates(of deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &ranges) == noErr else { return [] }

        // Devices report ranges; for the discrete rates we care about, minimum
        // and maximum are the same value.
        return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
    }

    /// Attempts the write and returns the status. `noErr` means bit-perfect
    /// output is available under whatever sandboxing is in force.
    @discardableResult
    public static func setSampleRate(_ rate: Double, on deviceID: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    /// Polls until the device reports `rate`, or the timeout expires. Returns
    /// whether it settled.
    @discardableResult
    public static func waitForSampleRate(
        _ rate: Double, on deviceID: AudioDeviceID, timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sampleRate(of: deviceID) == rate { return true }
            usleep(50_000)
        }
        return sampleRate(of: deviceID) == rate
    }

    /// Probes whether the rate is writable.
    ///
    /// By default it writes the rate the device is *already* using: that
    /// traverses the same permission path in coreaudiod without audibly
    /// reconfiguring the user's DAC. Pass `switchRates: true` for the fuller
    /// test, which really does change the rate and then puts it back.
    public static func probe(switchRates: Bool = false) throws -> Report {
        let deviceID = try defaultOutputDeviceID()
        let current = sampleRate(of: deviceID)
        let available = availableSampleRates(of: deviceID)

        var restored = true
        let target: Double
        if switchRates, let other = available.first(where: { $0 != current }) {
            target = other
        } else {
            target = current
        }

        let status = setSampleRate(target, on: deviceID)
        var tookEffect = status == noErr

        if switchRates, target != current, status == noErr {
            // coreaudiod applies the change asynchronously, so a `noErr` from
            // the setter proves only that the request was accepted. Waiting for
            // the device to actually report the new rate is the real test of
            // whether bit-perfect output works.
            tookEffect = waitForSampleRate(target, on: deviceID)

            // Only then put it back — and confirm that too. Restoring before
            // the switch has landed lets the in-flight change apply afterwards,
            // leaving the device on the wrong rate.
            setSampleRate(current, on: deviceID)
            restored = waitForSampleRate(current, on: deviceID)
        }

        return Report(
            deviceName: name(of: deviceID),
            currentRate: current,
            availableRates: available,
            writeStatus: tookEffect ? nil : (status == noErr ? kAudioHardwareUnspecifiedError : status),
            isSandboxed: isSandboxed,
            restored: restored,
            verified: tookEffect)
    }
}
