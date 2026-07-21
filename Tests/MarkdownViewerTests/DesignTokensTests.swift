import AppKit
import Testing
@testable import MarkdownViewer

@Suite("Design tokens")
struct DesignTokensTests {
    @Test("hex colors retain exact sRGB components")
    func hexColorsRetainSRGBComponents() throws {
        let color = try #require(
            NSColor(hex: 0x333336, alpha: 0.4).usingColorSpace(.sRGB)
        )

        #expect(abs(color.redComponent - 0x33 / 255.0) < 0.0001)
        #expect(abs(color.greenComponent - 0x33 / 255.0) < 0.0001)
        #expect(abs(color.blueComponent - 0x36 / 255.0) < 0.0001)
        #expect(abs(color.alphaComponent - 0.4) < 0.0001)
    }
}
