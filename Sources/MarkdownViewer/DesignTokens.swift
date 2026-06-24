import SwiftUI
import AppKit

/// Shared design tokens. NSColor statics for the AppKit editor core.
/// SwiftUI Color access via `DesignTokens.swiftUI.<name>`.
enum DesignTokens {
    // MARK: - Surfaces
    static let paper = NSColor(hex: 0xFFFFFF)
    static let sidebar = NSColor(hex: 0xF7F7F8)
    static let appBackground = NSColor(hex: 0xF2F2F4)
    static let codeBackground = NSColor(hex: 0xFAFAFA)

    // MARK: - Text
    static let titleText = NSColor(hex: 0x1D1D1F)
    static let headingText = NSColor(hex: 0x111111)
    static let bodyText = NSColor(hex: 0x333336)
    static let secondaryText = NSColor(hex: 0x6E6E73)
    static let tertiaryText = NSColor(hex: 0x86868B)
    static let fileRowText = NSColor(hex: 0x3F3F46)
    static let statusText = NSColor(hex: 0x767676)
    static let placeholderText = NSColor(hex: 0xAEAEB2)
    static let disabledText = NSColor(hex: 0xC7C7CC)
    static let folderIcon = NSColor(hex: 0xC7C7CC)
    static let tickRest = NSColor(hex: 0xCACACE)
    static let divider = NSColor(hex: 0xF0F0F1)
    static let line = NSColor(hex: 0xF4F4F5)

    // MARK: - Accent
    static let accent = NSColor(hex: 0xE8A33D)
    static let accentStrong = NSColor(hex: 0xE8A33D, alpha: 0.55)
    static let accentSoft = NSColor(hex: 0xE8A33D, alpha: 0.22)
    static let danger = NSColor(hex: 0xC7482E)
    static let link = NSColor(hex: 0x2A6FDB)
    static let systemBlue = NSColor(hex: 0x007AFF)

    // MARK: - Interaction
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

    // MARK: - SwiftUI Color accessor
    enum swiftUI {
        static let paper = SwiftUI.Color(hex: 0xFFFFFF)
        static let sidebar = SwiftUI.Color(hex: 0xF7F7F8)
        static let sidebarFill = SwiftUI.Color(hex: 0xF7F7F8)
        static let titleText = SwiftUI.Color(hex: 0x1D1D1F)
        static let headingText = SwiftUI.Color(hex: 0x111111)
        static let bodyText = SwiftUI.Color(hex: 0x333336)
        static let secondaryText = SwiftUI.Color(hex: 0x6E6E73)
        static let tertiaryText = SwiftUI.Color(hex: 0x86868B)
        static let fileRowText = SwiftUI.Color(hex: 0x3F3F46)
        static let statusText = SwiftUI.Color(hex: 0x767676)
        static let placeholderText = SwiftUI.Color(hex: 0xAEAEB2)
        static let disabledText = SwiftUI.Color(hex: 0xC7C7CC)
        static let folderIcon = SwiftUI.Color(hex: 0xC7C7CC)
        static let tickRest = SwiftUI.Color(hex: 0xCACACE)
        static let divider = SwiftUI.Color(hex: 0xF0F0F1)
        static let line = SwiftUI.Color(hex: 0xF4F4F5)
        static let accent = SwiftUI.Color(hex: 0xE8A33D)
        static let danger = SwiftUI.Color(hex: 0xC7482E)
        static let link = SwiftUI.Color(hex: 0x2A6FDB)
        static let hover = SwiftUI.Color.black.opacity(0.05)
        static let sidebarHover = SwiftUI.Color.black.opacity(0.045)
        static let pressed = SwiftUI.Color.black.opacity(0.08)
        static let selected = SwiftUI.Color.black.opacity(0.06)
        static let ring = SwiftUI.Color.black.opacity(0.05)
        static let fieldFill = SwiftUI.Color.black.opacity(0.04)
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
