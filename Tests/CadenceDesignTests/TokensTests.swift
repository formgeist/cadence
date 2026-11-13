import Testing
import SwiftUI
import CadenceDesign

@Suite("Design tokens")
struct TokensTests {

    /// The fonts moved here from the app target. If the resource bundle is
    /// not where `FontLoader` looks, every screen silently falls back to the
    /// system face, which no other test would notice.
    @Test("Every face the design asks for is bundled and registers")
    func facesRegister() {
        let report = FontLoader.report()
        #expect(report.count == 7)
        for face in report {
            #expect(face.available, "\(face.name) did not register")
        }
        #expect(FontLoader.warmUp())
    }

    @Test("Weights map onto the faces that exist")
    func weightNames() {
        #expect(FontLoader.manropeName(for: .regular) == "Manrope-Regular")
        #expect(FontLoader.manropeName(for: .heavy) == "Manrope-ExtraBold")
        #expect(FontLoader.manropeName(for: .black) == "Manrope-ExtraBold")
        // Plex Mono ships in two weights; everything heavier is Medium.
        #expect(FontLoader.plexMonoName(for: .bold) == "IBMPlexMono-Medium")
        #expect(FontLoader.plexMonoName(for: .light) == "IBMPlexMono-Regular")
    }

    @Test("A hex colour is the sRGB colour it spells")
    func hex() {
        let resolved = Color(hex: 0xE8483F).resolve(in: EnvironmentValues())
        #expect(abs(Double(resolved.red) - Double(0xE8) / 255) < 0.02)
        #expect(abs(Double(resolved.green) - Double(0x48) / 255) < 0.02)
        #expect(abs(Double(resolved.blue) - Double(0x3F) / 255) < 0.02)
        #expect(resolved.opacity == 1)
    }
}
