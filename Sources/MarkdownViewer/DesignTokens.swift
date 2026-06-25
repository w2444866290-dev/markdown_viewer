import SwiftUI
import AppKit

/// Single hex palette — all colors defined once, both NSColor
/// and SwiftUI.Color derived from the same source.
private enum Palette {
    static let paper          = 0xFFFFFF
    static let sidebar        = 0xF7F7F8
    static let appBackground  = 0xF2F2F4
    static let codeBackground = 0xFAFAFA

    static let titleText      = 0x1D1D1F
    static let headingText    = 0x111111
    static let bodyText       = 0x333336
    static let secondaryText  = 0x6E6E73
    static let tertiaryText   = 0x86868B
    static let fileRowText    = 0x3F3F46
    static let statusText     = 0x767676
    static let placeholderText = 0xAEAEB2
    static let disabledText   = 0xC7C7CC
    static let folderIcon     = 0xC7C7CC
    static let tickRest       = 0xCACACE
    static let divider        = 0xF0F0F1
    static let line           = 0xF4F4F5
    static let paletteKbd     = 0x9A9A9E

    static let accent         = 0xE8A33D
    static let danger         = 0xC7482E
    static let link           = 0x2A6FDB
    static let systemBlue     = 0x007AFF
}

/// Shared design tokens.
enum DesignTokens {
    // MARK: - Surfaces
    static let paper = color(Palette.paper)
    static let sidebar = color(Palette.sidebar)
    static let appBackground = color(Palette.appBackground)
    static let codeBackground = color(Palette.codeBackground)

    // MARK: - Text
    static let titleText = color(Palette.titleText)
    static let headingText = color(Palette.headingText)
    static let bodyText = color(Palette.bodyText)
    static let secondaryText = color(Palette.secondaryText)
    static let tertiaryText = color(Palette.tertiaryText)
    static let fileRowText = color(Palette.fileRowText)
    static let statusText = color(Palette.statusText)
    static let placeholderText = color(Palette.placeholderText)
    static let disabledText = color(Palette.disabledText)
    static let folderIcon = color(Palette.folderIcon)
    static let tickRest = color(Palette.tickRest)
    static let divider = color(Palette.divider)
    static let line = color(Palette.line)

    // MARK: - Accent
    static let accent = color(Palette.accent)
    static let accentStrong = color(Palette.accent, alpha: 0.55)
    static let accentSoft = color(Palette.accent, alpha: 0.22)
    static let danger = color(Palette.danger)
    static let link = color(Palette.link)
    static let systemBlue = color(Palette.systemBlue)

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
    static let editorTopInset: CGFloat = 44
    static let editorBottomPadding: CGFloat = 220  // ~33vh on 760px window
    static let bodyLineHeight: CGFloat = 1.7
    static let paletteKbdColor = 0x9A9A9E

    // MARK: - Color factory

    private static func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(hex: hex, alpha: alpha)
    }

    // MARK: - SwiftUI Color (derived from same Palette)

    enum swiftUI {
        static let paper = color(Palette.paper)
        static let sidebar = color(Palette.sidebar)
        static let sidebarFill = color(Palette.sidebar)
        static let appBackground = color(Palette.appBackground)
        static let titleText = color(Palette.titleText)
        static let headingText = color(Palette.headingText)
        static let bodyText = color(Palette.bodyText)
        static let secondaryText = color(Palette.secondaryText)
        static let tertiaryText = color(Palette.tertiaryText)
        static let fileRowText = color(Palette.fileRowText)
        static let statusText = color(Palette.statusText)
        static let placeholderText = color(Palette.placeholderText)
        static let disabledText = color(Palette.disabledText)
        static let folderIcon = color(Palette.folderIcon)
        static let tickRest = color(Palette.tickRest)
        static let divider = color(Palette.divider)
        static let line = color(Palette.line)
        static let accent = color(Palette.accent)
        static let danger = color(Palette.danger)
        static let link = color(Palette.link)
        static let hover = color(blackAlpha: 0.05)
        static let sidebarHover = color(blackAlpha: 0.045)
        static let pressed = color(blackAlpha: 0.08)
        static let selected = color(blackAlpha: 0.06)
        static let ring = color(blackAlpha: 0.05)
        static let fieldFill = color(blackAlpha: 0.04)
        static let paletteKbd = color(Palette.paletteKbd)

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
