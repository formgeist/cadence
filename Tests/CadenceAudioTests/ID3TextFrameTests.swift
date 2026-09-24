import Testing
import Foundation
@testable import CadenceAudio

/// The null separators TagLib throws away, kept.
@Suite("ID3 text frames")
struct ID3TextFrameTests {

    /// One v2.4 frame. `padding` stands in for the zeros real tags end with.
    private let padding = [UInt8](repeating: 0, count: 16)

    private func tag(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        let size = payload.count
        let synchsafe: [UInt8] = [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F),
                                  UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        return Array(id.utf8) + synchsafe + [0, 0] + payload
    }

    @Test("A null-separated UTF-8 TCOM comes back as separate names")
    func utf8MultiValue() {
        let payload: [UInt8] = [3] + Array("Kurt Ballou\u{0}Jacob Bannon\u{0}Ben Koller".utf8)
        let values = ID3TextFrame.frame("TCOM", in: tag("TIT2", [3, 0x41]) + tag("TCOM", payload) + padding,
                                        version: 4, hasExtendedHeader: false)
        #expect(values == ["Kurt Ballou", "Jacob Bannon", "Ben Koller"])
    }

    @Test("UTF-16 values each carry their own BOM")
    func utf16MultiValue() {
        func utf16(_ s: String) -> [UInt8] {
            [0xFF, 0xFE] + s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        let payload: [UInt8] = [1] + utf16("Åsa") + [0, 0] + utf16("Nate Newton") + [0, 0]
        let values = ID3TextFrame.frame("TCOM", in: tag("TCOM", payload),
                                        version: 4, hasExtendedHeader: false)
        #expect(values == ["Åsa", "Nate Newton"])
    }

    @Test("A slash is part of the name, not a separator")
    func slashKept() {
        let values = ID3TextFrame.frame("TCOM", in: tag("TCOM", [0] + Array("AC/DC".utf8)),
                                        version: 4, hasExtendedHeader: false)
        #expect(values == ["AC/DC"])
    }

    @Test("A missing frame is nil, so the caller falls back")
    func missing() {
        #expect(ID3TextFrame.frame("TCOM", in: tag("TIT2", [3, 0x41]),
                                   version: 4, hasExtendedHeader: false) == nil)
    }
}
