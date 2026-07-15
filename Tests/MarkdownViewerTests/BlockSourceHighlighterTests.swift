import AppKit
import Testing
@testable import MarkdownViewer

@Suite("Active block source highlighter", .serialized)
@MainActor
struct BlockSourceHighlighterTests {
    @Test("representative Markdown syntax keeps every UTF-16 unit")
    func representativeSyntaxPreservesText() throws {
        let source = [
            "# Heading",
            "- [ ] item with **bold** and *italic*",
            "[link](https://example.com) and `inline code`",
            "| A | B |",
            "| --- | :---: |",
        ].joined(separator: "\r\n")
        let highlighted = BlockSourceHighlighter.highlightedSource(source, kind: .table)

        #expect(highlighted.string == source)
        #expect(highlighted.length == (source as NSString).length)
        try expectMarker("#", in: highlighted)
        try expectMarker("- [ ]", in: highlighted)
        try expectMarker("**", in: highlighted)
        try expectMarker("*italic*", offset: 0, in: highlighted)
        try expectMarker("[link]", offset: 0, in: highlighted)
        try expectMarker("`inline code`", offset: 0, in: highlighted)
        try expectMarker("| A", offset: 0, in: highlighted)

        let urlIndex = try index(of: "https://example.com", in: highlighted.string)
        #expect(highlighted.attribute(.blockSourceSyntaxRole, at: urlIndex, effectiveRange: nil) as? String == "link-destination")
    }

    @Test("heading, list, code fence, and table markers remain visible")
    func structuralMarkersRemainVisible() throws {
        let cases: [(String, MarkdownBlockKind, String)] = [
            ("### Heading", .heading, "###"),
            ("1. ordered", .list, "1."),
            ("> quote", .quote, ">"),
            ("```swift\nlet x = 1\n```", .code, "```"),
            ("| A |\n| --- |", .table, "|"),
        ]

        for (source, kind, marker) in cases {
            let highlighted = BlockSourceHighlighter.highlightedSource(source, kind: kind)
            #expect(highlighted.string == source)
            #expect(highlighted.length == (source as NSString).length)
            let markerIndex = try index(of: marker, in: source)
            #expect(highlighted.attribute(.blockSourceSyntaxMarker, at: markerIndex, effectiveRange: nil) as? Bool == true)
            let color = highlighted.attribute(.foregroundColor, at: markerIndex, effectiveRange: nil) as? NSColor
            #expect((color?.alphaComponent ?? 0) > 0.99)
        }
    }

    @Test("active heading keeps authoritative proportional typography")
    func activeHeadingTypography() throws {
        let source = "# Markdown 全格式示例"
        let highlighted = BlockSourceHighlighter.highlightedSource(
            source,
            kind: .heading,
            bodyFontSize: 16.5
        )
        let markerIndex = try index(of: "#", in: source)
        let headingIndex = try index(of: "Markdown", in: source)
        let markerFont = highlighted.attribute(
            .font,
            at: markerIndex,
            effectiveRange: nil
        ) as? NSFont
        let headingFont = highlighted.attribute(
            .font,
            at: headingIndex,
            effectiveRange: nil
        ) as? NSFont
        let markerColor = highlighted.attribute(
            .foregroundColor,
            at: markerIndex,
            effectiveRange: nil
        ) as? NSColor

        #expect(markerFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        #expect(markerFont?.pointSize == 16.5)
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(headingFont?.pointSize == 24)
        #expect(markerColor == DesignTokens.sourceSyntax)
    }

    @Test("Unicode and mixed line endings retain exact offsets")
    func unicodeOffsets() throws {
        let source = "# 标题 😀\r\n\r- [x] 完成\n`代码`"
        let storage = NSMutableAttributedString(string: source)
        BlockSourceHighlighter.apply(to: storage, kind: .paragraph)

        #expect(storage.string == source)
        #expect(storage.length == (source as NSString).length)
        let emoji = (source as NSString).range(of: "😀")
        #expect(emoji.length == 2)
        #expect(storage.attributedSubstring(from: emoji).string == "😀")
        let trailingCode = (source as NSString).range(of: "代码")
        #expect(storage.attribute(.blockSourceSyntaxRole, at: trailingCode.location, effectiveRange: nil) as? String == "inline-code")
    }

    @Test("reapplying highlights is character-idempotent")
    func repeatedApply() {
        let source = "~~old~~ and **new** with [link](target)"
        let storage = NSMutableAttributedString(string: source)

        BlockSourceHighlighter.apply(to: storage, kind: .paragraph)
        let firstMarkerCount = markerCount(in: storage)
        BlockSourceHighlighter.apply(to: storage, kind: .paragraph)

        #expect(storage.string == source)
        #expect(storage.length == (source as NSString).length)
        #expect(markerCount(in: storage) == firstMarkerCount)
    }

    @Test("active paragraph uses the adjustable proportional body font")
    func paragraphBaseStyle() {
        let source = "plain text without Markdown markers"
        let highlighted = BlockSourceHighlighter.highlightedSource(
            source,
            kind: .paragraph,
            bodyFontSize: 16.5
        )
        let font = highlighted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        #expect(font?.pointSize == 16.5)
        #expect((color?.alphaComponent ?? 0) > 0.99)
        #expect(markerCount(in: highlighted) == 0)
    }

    @Test("code and table source remain compact monospaced text")
    func codeAndTableBaseStyle() {
        for (source, kind) in [
            ("```swift\nlet value = 1\n```", MarkdownBlockKind.code),
            ("| A |\n| --- |", MarkdownBlockKind.table),
        ] {
            let highlighted = BlockSourceHighlighter.highlightedSource(
                source,
                kind: kind,
                bodyFontSize: 18
            )
            let bodyIndex = source.hasPrefix("```")
                ? (source as NSString).range(of: "let").location
                : (source as NSString).range(of: "A").location
            let font = highlighted.attribute(
                .font,
                at: bodyIndex,
                effectiveRange: nil
            ) as? NSFont

            #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
            #expect(font?.pointSize == BlockSourceHighlighter.pointSize)
        }
    }

    private func expectMarker(
        _ substring: String,
        offset: Int = 0,
        in attributed: NSAttributedString
    ) throws {
        let start = try index(of: substring, in: attributed.string) + offset
        #expect(attributed.attribute(.blockSourceSyntaxMarker, at: start, effectiveRange: nil) as? Bool == true)
    }

    private func index(of substring: String, in source: String) throws -> Int {
        let range = (source as NSString).range(of: substring)
        return try #require(range.location != NSNotFound ? range.location : nil)
    }

    private func markerCount(in attributed: NSAttributedString) -> Int {
        var count = 0
        attributed.enumerateAttribute(
            .blockSourceSyntaxMarker,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if (value as? Bool) == true { count += range.length }
        }
        return count
    }
}
