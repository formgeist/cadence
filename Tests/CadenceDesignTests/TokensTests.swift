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

    /// WCAG contrast of two opaque colours.
    private func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let c = color.resolve(in: EnvironmentValues())
            func channel(_ v: Float) -> Double {
                let x = Double(v)
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The iOS text colours are there because the Mac's read too low on
    /// glass. They must at least pass for small text on the bare ground.
    @Test("Mobile text colours pass 4.5:1 on the surface")
    func mobileContrast() {
        let surface = Tokens.Palette.surface
        #expect(contrast(Tokens.Mobile.Palette.accentText, surface) >= 7)
        #expect(contrast(Tokens.Mobile.Palette.textSecondary, surface) >= 4.5)
        #expect(contrast(Tokens.Mobile.Palette.textTertiary, surface) >= 4.5)
        #expect(contrast(Tokens.Palette.textPrimary, surface) >= 4.5)
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
