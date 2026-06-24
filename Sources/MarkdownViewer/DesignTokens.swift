import SwiftUI
import AppKit

/// Shared design tokens. A single hex source defines each color; both
/// NSColor and SwiftUI.Color are derived from it — no manual duplication.
enum DesignTokens {
    // MARK: - Surfaces
    static let paper = color(0xFFFFFF)
    static let sidebar = color(0xF7F7F8)
    static let appBackground = color(0xF2F2F4)
    static let codeBackground = color(0xFAFAFA)

    // MARK: - Text
    static let titleText = color(0x1D1D1F)
    static let headingText = color(0x111111)
    static let bodyText = color(0x333336)
    static let secondaryText = color(0x6E6E73)
    static let tertiaryText = color(0x86868B)
    static let fileRowText = color(0x3F3F46)
    static let statusText = color(0x767676)
    static let placeholderText = color(0xAEAEB2)
    static let disabledText = color(0xC7C7CC)
    static let folderIcon = color(0xC7C7CC)
    static let tickRest = color(0xCACACE)
    static let divider = color(0xF0F0F1)
    static let line = color(0xF4F4F5)

    // MARK: - Accent
    static let accent = color(0xE8A33D)
    static let accentStrong = color(0xE8A33D, alpha: 0.55)
    static let accentSoft = color(0xE8A33D, alpha: 0.22)
    static let danger = color(0xC7482E)
    static let link = color(0x2A6FDB)
    static let systemBlue = color(0x007AFF)

    // MARK: - Interaction (alpha-only over black)
    static let hover = NSColor.black.withAlphaComponent(0.05)
    static let sidebarHover = NSColor.black.withAlphaComponent(0.045)
    static let pressed = NSColor.black.withAlphaComponent(0.08)
    static let selected = NSColor.black.withAlphaComponent(0.06)
    static let ring = NSColor.black.withAlphaComponent(0.05)
    static let fieldFill = NSColor.black.withAlphaComponent(0.04)

    // MARK: - Dimensions
    static let sidebarWidth: CGFloat = 216
    static let sidebarMinWidth: CGFloat = 176
    static let sidebarMaxWidth: CGFloat = 440
    static let paperWidth: CGFloat = 540
    static let tabBarHeight: CGFloat = 44
    static let bodyFontSizes: [CGFloat] = [14, 15.5, 17]

    // MARK: - Color factory (single hex source)

    private static func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(hex: hex, alpha: alpha)
    }

    // MARK: - SwiftUI Color accessor (derived, not duplicated)

    enum swiftUI {
        static let paper = color(0xFFFFFF)
        static let sidebar = color(0xF7F7F8)
        static let sidebarFill = color(0xF7F7F8)
        static let titleText = color(0x1D1D1F)
        static let headingText = color(0x111111)
        static let bodyText = color(0x333336)
        static let secondaryText = color(0x6E6E73)
        static let tertiaryText = color(0x86868B)
        static let fileRowText = color(0x3F3F46)
        static let statusText = color(0x767676)
        static let placeholderText = color(0xAEAEB2)
        static let disabledText = color(0xC7C7CC)
        static let folderIcon = color(0xC7C7CC)
        static let tickRest = color(0xCACACE)
        static let divider = color(0xF0F0F1)
        static let line = color(0xF4F4F5)
        static let accent = color(0xE8A33D)
        static let danger = color(0xC7482E)
        static let link = color(0x2A6FDB)
        static let hover = color(blackAlpha: 0.05)
        static let sidebarHover = color(blackAlpha: 0.045)
        static let pressed = color(blackAlpha: 0.08)
        static let selected = color(blackAlpha: 0.06)
        static let ring = color(blackAlpha: 0.05)
        static let fieldFill = color(blackAlpha: 0.04)

        private static func color(_ hex: Int, opacity: Double = 1) -> SwiftUI.Color {
            SwiftUI.Color(hex: hex, opacity: opacity)
        }
        private static func color(blackAlpha: Double) -> SwiftUI.Color {
            SwiftUI.Color.black.opacity(blackAlpha)
        }
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension SwiftUI.Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
