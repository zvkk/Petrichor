import AppKit
import SwiftUI

/// The iPhone visual language applied to the existing Mac compositions.
/// Native appearance remains selectable; the authored light skin is the default.
enum CrateStyle {
    static let paper = color("CratePaper", light: 0xFFFFFF, dark: 0x1D1D1D)
    static let sidebar = color("CrateSidebar", light: 0xFAFAFA, dark: 0x242424)
    static let ink = color("CrateInk", light: 0x282828, dark: 0xEDEDED)
    static let secondary = color("CrateSecondary", light: 0x757575, dark: 0xB0B0B0)
    static let hairline = color("CrateHairline", light: 0xE8E8E8, dark: 0x383838)
    static let control = color("CrateControl", light: 0xF3F3F3, dark: 0x2C2C2C)
    static let selection = color("CrateSelection", light: 0xE7E7E7, dark: 0x3B3B3B)
    static let artworkRadius: CGFloat = 2
    static let itemTitle = Font.system(size: 14, weight: .medium)
    static let metadata = Font.system(size: 12)

    private static func color(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
