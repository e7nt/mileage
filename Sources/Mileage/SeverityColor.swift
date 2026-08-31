import AppKit
import MileageCore
import SwiftUI

extension Formatting.Severity {
    /// Resolved by the appearance in force at draw time rather than at construction, so a
    /// switch between light and dark repaints correctly without any redraw of our own.
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(SeverityPalette.color(for: self, in: isDark ? .dark : .light))
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension NSColor {
    convenience init(_ rgb: SeverityPalette.RGB) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
