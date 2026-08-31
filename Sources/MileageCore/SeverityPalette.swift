import Foundation

/// The colours severity is drawn in, kept in Core so the menu bar and the popover cannot drift
/// apart, and kept as plain components so the contrast ratios can be tested without a screen.
///
/// The system colours are tuned for glyphs, not for 11pt text: `systemGreen` on a light popover
/// measures about 2.1:1, `systemOrange` 2.2:1, `systemRed` 3.6:1 — all under the 4.5:1 WCAG AA
/// asks of body text. The light values below are darkened until they clear it. The dark ones
/// were already close enough to keep, except red, which had to be lifted.
public enum SeverityPalette {
    /// Straight sRGB components, 0...1. Deliberately not an `NSColor`: MileageCore has no UI
    /// dependency, and what a colour *object* is belongs to the layer that draws it.
    public struct RGB: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
        }
    }

    public enum Appearance: Sendable, CaseIterable {
        case light
        case dark

        /// What these colours actually sit on. Measured against the translucent material rather
        /// than pure white or pure black, because the material is the harder case to clear —
        /// a grey background leaves less room than white does for dark text.
        public var background: RGB {
            switch self {
            case .light: RGB(236, 236, 236)
            case .dark: RGB(58, 58, 60)
            }
        }
    }

    public static func color(for severity: Formatting.Severity, in appearance: Appearance) -> RGB {
        switch (severity, appearance) {
        case (.healthy, .light): RGB(20, 108, 46)
        case (.healthy, .dark): RGB(48, 209, 88)
        case (.warning, .light): RGB(143, 74, 0)
        case (.warning, .dark): RGB(255, 159, 10)
        case (.critical, .light): RGB(192, 39, 30)
        case (.critical, .dark): RGB(255, 138, 128)
        }
    }

    /// The ratio WCAG 2.1 defines, 1...21. Order of the arguments does not matter.
    public static func contrastRatio(_ one: RGB, _ other: RGB) -> Double {
        let luminances = [relativeLuminance(one), relativeLuminance(other)]
        return (luminances.max()! + 0.05) / (luminances.min()! + 0.05)
    }

    /// WCAG 2.1 relative luminance: linearise each channel, then weight by how much the eye
    /// gets from it.
    public static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
}
