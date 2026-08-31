import Foundation
import Testing

@testable import MileageCore

@Suite("Severity colours stay legible")
struct SeverityPaletteTests {
    /// What WCAG 2.1 AA asks of body text. The gauge numbers are 11pt, well under the 18pt that
    /// would let the looser 3:1 apply.
    private static let minimumForBodyText = 4.5

    @Test(
        "Every severity clears WCAG AA against the surface it is drawn on",
        arguments: Formatting.Severity.allCases, SeverityPalette.Appearance.allCases
    )
    func clearsAA(_ severity: Formatting.Severity, _ appearance: SeverityPalette.Appearance) {
        let ratio = SeverityPalette.contrastRatio(
            SeverityPalette.color(for: severity, in: appearance),
            appearance.background
        )
        #expect(ratio >= Self.minimumForBodyText)
    }

    @Test("The system colours this palette replaces would not have passed")
    func systemColoursFailed() {
        // Kept as a record of why the palette exists: systemGreen, systemOrange and systemRed on
        // a light popover. Delete this only alongside evidence that AppKit's values changed.
        let onLight = SeverityPalette.Appearance.light.background
        #expect(SeverityPalette.contrastRatio(SeverityPalette.RGB(40, 205, 65), onLight) < 2.5)
        #expect(SeverityPalette.contrastRatio(SeverityPalette.RGB(255, 149, 0), onLight) < 2.5)
        #expect(SeverityPalette.contrastRatio(SeverityPalette.RGB(255, 59, 48), onLight) < 4.5)
    }

    @Test("Contrast is symmetric and anchored at the known extremes")
    func contrastMaths() {
        let white = SeverityPalette.RGB(255, 255, 255)
        let black = SeverityPalette.RGB(0, 0, 0)

        #expect(abs(SeverityPalette.contrastRatio(white, black) - 21) < 0.01)
        #expect(SeverityPalette.contrastRatio(black, white)
            == SeverityPalette.contrastRatio(white, black))
        #expect(abs(SeverityPalette.contrastRatio(white, white) - 1) < 0.001)
    }
}
