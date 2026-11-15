import Foundation

/// Slows down guessing, by address.
///
/// Nothing here makes a 256-bit key guessable; it is unguessable without any
/// limit at all. The limit is for the things around it. It stops a device on
/// the network from hammering the server with attempts, it makes the six
/// tries a pairing token allows harder to spend from one place, and it keeps
/// a misbehaving client from filling the log.
///
/// An address that fails `limit` times within `window` seconds is refused
/// outright for `block` seconds: every request, before any key is looked at.
/// Checking a key during a block would make the block pointless, since the
/// answer to "is this key right?" is what a guesser wants.
///
/// The address is the one the connection came from. On a local network that
/// is hard to forge for a TCP connection, which must complete a handshake.
/// Devices behind one router elsewhere would share an address, but the server
/// is for the local network, where each device has its own.
final class FailureThrottle: @unchecked Sendable {

    private struct Record {
        var failures: [Date] = []
        var blockedUntil: Date?
        var lastTouched: Date
    }

    private let limit: Int
    private let window: TimeInterval
    private let block: TimeInterval
    /// Addresses remembered at once. Past this the least recently seen is
    /// forgotten, so a flood of addresses cannot grow the table without end.
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    init(limit: Int, window: TimeInterval, block: TimeInterval, capacity: Int = 1024,
         now: @escaping @Sendable () -> Date) {
        self.limit = limit
        self.window = window
        self.block = block
        self.capacity = capacity
        self.now = now
    }

    /// Seconds until `address` may try again, or nil if it is not blocked.
    func secondsBlocked(_ address: String) -> TimeInterval? {
        lock.withLock {
            guard let until = records[address]?.blockedUntil else { return nil }
            let remaining = until.timeIntervalSince(now())
            if remaining <= 0 {
                // The block is served. The address starts again with a clean
                // record, not one failure away from the next block.
                records[address] = nil
                return nil
            }
            return remaining
        }
    }

    func recordFailure(_ address: String) {
        lock.withLock {
            let moment = now()
            var record = records[address] ?? Record(lastTouched: moment)
            record.failures = record.failures.filter { moment.timeIntervalSince($0) < window }
            record.failures.append(moment)
            record.lastTouched = moment
            if record.failures.count >= limit {
                record.blockedUntil = moment.addingTimeInterval(block)
                record.failures = []
            }
            records[address] = record

            if records.count > capacity,
               let oldest = records.min(by: { $0.value.lastTouched < $1.value.lastTouched }) {
                records[oldest.key] = nil
            }
        }
    }

    var trackedAddressCount: Int { lock.withLock { records.count } }
}

/// Caps how many files one device can be sent at once.
///
/// A stream holds a file open and a connection busy for as long as the client
/// cares to read. Without a cap, one paired device, or one stolen key, could
/// take every connection the server has and leave the others with none.
final class StreamLimiter: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var active: [PairedDevice.ID: Int] = [:]

    init(limit: Int) { self.limit = limit }

    /// Takes a place for `device` if it has one free.
    func acquire(_ device: PairedDevice.ID) -> Bool {
        lock.withLock {
            let count = active[device, default: 0]
            guard count < limit else { return false }
            active[device] = count + 1
            return true
        }
    }

    func release(_ device: PairedDevice.ID) {
        lock.withLock {
            let count = active[device, default: 0]
            active[device] = count > 1 ? count - 1 : nil
        }
    }

    func activeCount(_ device: PairedDevice.ID) -> Int {
        lock.withLock { active[device, default: 0] }
    }
}
