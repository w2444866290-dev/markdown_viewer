import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// Render-layer checks for AppKit drawing that plain NSTextStorage attribute
    /// probes cannot see.
    @Suite(.serialized)
    @MainActor
    struct RenderLayerTests {
        init() { pinBodyPointSize() }

        @Test func codeCardPaintsFullWidthFill() throws {
            let bitmap = try RenderProbe.backgroundBitmap(for: "```swift\nlet answer = 42\n```")

            let fillRun = bitmap.maxHorizontalRun(near: NSColor(hex: 0xFAFAFA), tolerance: 2)
            #expect(fillRun >= 280)
        }

        @Test func tableRulesPaintHeaderAndBodyHairlines() throws {
            let bitmap = try RenderProbe.backgroundBitmap(for: "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")

            let headerRun = bitmap.maxHorizontalRun(near: NSColor(hex: 0xECECEE), tolerance: 2)
            let bodyRun = bitmap.maxHorizontalRun(near: NSColor(hex: 0xF4F4F5), tolerance: 2)
            #expect(headerRun >= 280)
            #expect(bodyRun >= 280)
        }
    }
}

@MainActor
private enum RenderProbe {
    static func backgroundBitmap(for markdown: String, width: CGFloat = 320) throws -> RenderBitmap {
        let storage = NSTextStorage(string: markdown)
        let layoutManager = CardLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)

        LiveMarkdownStyler.apply(to: storage)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let imageWidth = Int(ceil(width + 48))
        let imageHeight = max(80, Int(ceil(usedRect.height + 64)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: imageWidth,
            pixelsHigh: imageHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.bitmapAllocationFailed
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw RenderError.graphicsContextAllocationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight).fill()
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: NSPoint(x: 24, y: 24))
        NSGraphicsContext.restoreGraphicsState()

        return RenderBitmap(rep: rep)
    }
}

private enum RenderError: Error {
    case bitmapAllocationFailed
    case graphicsContextAllocationFailed
}

private struct RenderBitmap {
    let rep: NSBitmapImageRep

    func maxHorizontalRun(near color: NSColor, tolerance: CGFloat) -> Int {
        var best = 0
        for y in 0..<rep.pixelsHigh {
            var current = 0
            for x in 0..<rep.pixelsWide {
                if isPixel(x: x, y: y, near: color, tolerance: tolerance) {
                    current += 1
                    best = max(best, current)
                } else {
                    current = 0
                }
            }
        }
        return best
    }

    private func isPixel(x: Int, y: Int, near expected: NSColor, tolerance: CGFloat) -> Bool {
        guard let actual = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              let expected = expected.usingColorSpace(.deviceRGB) else {
            return false
        }

        return abs(actual.redComponent * 255 - expected.redComponent * 255) <= tolerance
            && abs(actual.greenComponent * 255 - expected.greenComponent * 255) <= tolerance
            && abs(actual.blueComponent * 255 - expected.blueComponent * 255) <= tolerance
            && actual.alphaComponent > 0.95
    }
}
