import AppKit
import Testing
@testable import MarkdownViewer

@Suite("Passive Markdown formatting", .serialized)
@MainActor
struct PassiveMarkdownFormattingTests {
    @Test("find highlights use exact UTF-16 display ranges and distinct strengths")
    func findHighlightsUseProjectedRanges() throws {
        let source = "A😀 **bold** B"
        let base = PassiveMarkdownInlineRenderer.render(source, style: style)
        let emoji = try range(of: "😀", in: base)
        let bold = try range(of: "bold", in: base)
        let rendered = PassiveMarkdownInlineRenderer.render(
            source,
            style: style,
            findHighlights: [
                PassiveFindHighlight(range: emoji, isCurrent: false),
                PassiveFindHighlight(range: bold, isCurrent: true),
            ]
        )

        #expect(rendered.string == "A😀 bold B")
        #expect(color(.backgroundColor, at: emoji.location, in: rendered) == DesignTokens.accentSoft)
        #expect(color(.backgroundColor, at: bold.location, in: rendered) == DesignTokens.accentStrong)
    }

    private let style = PassiveMarkdownInlineStyle(
        font: NSFont.systemFont(ofSize: 15),
        color: DesignTokens.bodyText
    )

    @Test("emphasis, strike, boundaries, and escapes render without markers")
    func emphasisAndEscapes() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            #"**bold** *italic* ***both*** ~~gone~~ 2 * 3 \*literal\*"#,
            style: style
        )

        #expect(rendered.string == "bold italic both gone 2 * 3 *literal*")
        let bold = try range(of: "bold", in: rendered)
        let italic = try range(of: "italic", in: rendered)
        let both = try range(of: "both", in: rendered)
        let gone = try range(of: "gone", in: rendered)
        let literal = try range(of: "*literal*", in: rendered)

        #expect(font(at: bold.location, in: rendered)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(at: italic.location, in: rendered)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(font(at: both.location, in: rendered)?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
        #expect(integer(.strikethroughStyle, at: gone.location, in: rendered) == NSUnderlineStyle.single.rawValue)
        #expect(rendered.attribute(.passiveMarkdownRole, at: literal.location, effectiveRange: nil) as? String == "escaped-literal")

        let multiplication = try range(of: "* 3", in: rendered)
        #expect(rendered.attribute(.passiveMarkdownRole, at: multiplication.location, effectiveRange: nil) == nil)
    }

    @Test("HTML underline, superscript, and subscript preserve their visual tokens")
    func htmlInlineTags() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "<u>under</u> x<sup>2</sup> H<sub>2</sub>O",
            style: style
        )

        #expect(rendered.string == "under x2 H2O")
        let under = try range(of: "under", in: rendered)
        let superscript = try range(of: "x2", in: rendered).location + 1
        let subscriptIndex = try range(of: "H2O", in: rendered).location + 1

        #expect(integer(.underlineStyle, at: under.location, in: rendered) == NSUnderlineStyle.single.rawValue)
        #expect(color(.underlineColor, at: under.location, in: rendered) == PassiveMarkdownInlineRenderer.underlineColor)
        #expect(number(.baselineOffset, at: superscript, in: rendered) > 0)
        #expect(number(.baselineOffset, at: subscriptIndex, in: rendered) < 0)
        #expect(font(at: superscript, in: rendered)?.pointSize == 10.5)
        #expect(font(at: subscriptIndex, in: rendered)?.pointSize == 10.5)
    }

    @Test("HTML mark and break tags render as native highlight and line break")
    func htmlMarkAndBreakTags() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "Before <mark>gold **bold**</mark><br />After",
            style: style
        )

        #expect(rendered.string == "Before gold bold\nAfter")
        let gold = try range(of: "gold", in: rendered)
        let bold = try range(of: "bold", in: rendered)
        let lineBreak = try range(of: "\n", in: rendered)

        #expect(color(.backgroundColor, at: gold.location, in: rendered) == NSColor(hex: 0xE8A33D, alpha: 0.28))
        #expect(color(.backgroundColor, at: bold.location, in: rendered) == NSColor(hex: 0xE8A33D, alpha: 0.28))
        #expect(rendered.attribute(.passiveMarkdownRole, at: gold.location, effectiveRange: nil) as? String == "mark")
        #expect(rendered.attribute(.passiveMarkdownRole, at: lineBreak.location, effectiveRange: nil) as? String == "line-break")
    }

    @Test("inline images render as non-link native pills with alt fallback")
    func inlineImages() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            #"Before ![diagram](assets/diagram.png "Diagram") after ![](empty.png)."#,
            style: style
        )

        #expect(rendered.string == "Before 🖼 diagram after 🖼 image.")
        let diagram = try range(of: "🖼 diagram", in: rendered)
        let fallback = try range(of: "🖼 image", in: rendered)
        for imageRange in [diagram, fallback] {
            #expect(font(at: imageRange.location, in: rendered)?.isFixedPitch == true)
            #expect(font(at: imageRange.location, in: rendered)?.pointSize == 12)
            #expect(color(.foregroundColor, at: imageRange.location, in: rendered) == NSColor(hex: 0x9A9A9E))
            #expect(color(.backgroundColor, at: imageRange.location, in: rendered) == NSColor(hex: 0xF4F4F5))
            #expect(rendered.attribute(.passiveMarkdownRole, at: imageRange.location, effectiveRange: nil) as? String == "inline-image")
            #expect(rendered.attribute(.link, at: imageRange.location, effectiveRange: nil) == nil)
        }
    }

    @Test("find highlight ranges remain aligned after inline image decorations")
    func findHighlightsAfterInlineImageDecoration() throws {
        let document = MarkdownDocument(source: "A ![pic](x) B **bold**")
        let block = try #require(document.blocks.first)
        let projection = BlockFindEngine.projection(for: block)
        #expect(projection.text == "A pic B bold")
        let projectedPic = (projection.text as NSString).range(of: "pic")
        let projectedBold = (projection.text as NSString).range(of: "bold")
        let rendered = PassiveMarkdownInlineRenderer.render(
            block.source,
            style: style,
            findHighlights: [
                PassiveFindHighlight(range: projectedPic, isCurrent: false),
                PassiveFindHighlight(range: projectedBold, isCurrent: true),
            ]
        )

        #expect(rendered.string == "A 🖼 pic B bold")
        let icon = try range(of: "🖼", in: rendered)
        let pic = try range(of: "pic", in: rendered)
        let bold = try range(of: "bold", in: rendered)
        #expect(color(.backgroundColor, at: icon.location, in: rendered) == NSColor(hex: 0xF4F4F5))
        #expect(color(.backgroundColor, at: pic.location, in: rendered) == DesignTokens.accentSoft)
        #expect(color(.backgroundColor, at: bold.location, in: rendered) == DesignTokens.accentStrong)
    }

    @Test("inline code is literal, monospaced, and uses the existing code fill")
    func inlineCode() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            #"`const **answer** = 42` and \`literal\`"#,
            style: style
        )

        #expect(rendered.string == "const **answer** = 42 and `literal`")
        let code = try range(of: "const", in: rendered)
        let literal = try range(of: "`literal`", in: rendered)
        #expect(font(at: code.location, in: rendered)?.isFixedPitch == true)
        #expect(color(.backgroundColor, at: code.location, in: rendered) == PassiveMarkdownInlineRenderer.inlineCodeBackground)
        #expect(rendered.attribute(.passiveMarkdownRole, at: code.location, effectiveRange: nil) as? String == "inline-code")
        #expect(color(.backgroundColor, at: literal.location, in: rendered) == nil)
    }

    @Test("inline code preserves the following link's semantic destination")
    func inlineCodePreservesFollowingLinkDestination() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "`code` then [guide](https://example.com)",
            style: style
        )
        let guide = try range(of: "guide", in: rendered)

        #expect(PassiveMarkdownInlineRenderer.linkDestination(
            atUTF16Index: guide.location,
            in: rendered
        ) == "https://example.com")
    }

    @Test("link labels stay visible and hover reports each exact destination")
    @MainActor
    func visibleLinksAndHoverCallback() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "See [SemVer](https://semver.org) and [guide](docs/guide.md \"Local\").",
            style: style
        )

        #expect(rendered.string == "See SemVer and guide.")
        let semver = try range(of: "SemVer", in: rendered)
        let guide = try range(of: "guide", in: rendered)
        #expect(PassiveMarkdownInlineRenderer.linkDestination(atUTF16Index: semver.location, in: rendered) == "https://semver.org")
        #expect(PassiveMarkdownInlineRenderer.linkDestination(atUTF16Index: guide.location, in: rendered) == "docs/guide.md")
        #expect(color(.foregroundColor, at: semver.location, in: rendered) == PassiveMarkdownInlineRenderer.linkColor)
        #expect(color(.underlineColor, at: semver.location, in: rendered) == PassiveMarkdownInlineRenderer.linkUnderlineColor)
        let underline = integer(.underlineStyle, at: semver.location, in: rendered)
        #expect((underline & NSUnderlineStyle.patternDash.rawValue) != 0)

        var callbacks: [String] = []
        var opened: [String] = []
        let tracker = PassiveInlineLinkTrackingView(
            attributed: rendered,
            accessibilityBlockIndex: 25,
            onHoverURL: { callbacks.append($0) },
            onOpenURL: { opened.append($0) }
        )
        tracker.reportHover(atUTF16Index: semver.location)
        tracker.reportHover(atUTF16Index: guide.location)
        tracker.reportHover(atUTF16Index: nil)
        #expect(callbacks == ["https://semver.org", "docs/guide.md", ""])
        let links = tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        } ?? []
        #expect(links.map { $0.accessibilityIdentifier() } == [
            "document-block-25-link-0",
            "document-block-25-link-1",
        ])
        #expect(links.allSatisfy { $0.accessibilityRole() == .link })
        #expect(links.first?.accessibilityPerformPress() == true)
        #expect(opened == ["https://semver.org"])
    }

    @Test("accessibility link objects persist across reflow and invalidate on removal")
    func accessibilityLinkLifecycle() throws {
        let initial = PassiveMarkdownInlineRenderer.render(
            "Read [guide](docs/guide.md).",
            style: style
        )
        let tracker = PassiveInlineLinkTrackingView(
            attributed: initial,
            accessibilityBlockIndex: 7,
            onHoverURL: { _ in },
            onOpenURL: { _ in }
        )
        #expect(tracker.subviews.isEmpty)
        let original = try #require(tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        }.first)
        #expect(original.accessibilityNotifiesWhenDestroyed)
        #expect((original.accessibilityParent()
            as? PassiveInlineLinkTrackingView) === tracker)

        tracker.attributed = PassiveMarkdownInlineRenderer.render(
            "Open the [local guide](docs/guide.md).",
            style: style
        )
        let updated = try #require(tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        }.first)
        #expect(updated === original)
        #expect(updated.accessibilityLabel() == "local guide")

        tracker.attributed = PassiveMarkdownInlineRenderer.render(
            "No links remain.",
            style: style
        )
        #expect(tracker.accessibilityChildren()?.isEmpty == true)
        #expect(original.accessibilityParent() == nil)
        #expect(original.isAccessibilityElement() == false)
        #expect(original.accessibilityPerformPress() == false)
    }

    @Test("multi-line link activation points stay on an exact glyph fragment")
    @MainActor
    func multiLineLinkActivationPoint() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "prefix prefix [abc def](https://example.com) suffix",
            style: style
        )
        let tracker = PassiveInlineLinkTrackingView(
            attributed: rendered,
            accessibilityBlockIndex: 4,
            lineSpacing: 7,
            onHoverURL: { _ in },
            onOpenURL: { _ in }
        )
        tracker.frame = NSRect(x: 0, y: 0, width: 118, height: 90)
        tracker.layoutSubtreeIfNeeded()

        let link = try #require(tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        }.first)
        #expect(link.frameInOwner.height > 30)
        let localPoint = link.activationPointInParentSpace
        #expect(link.accessibilityFrame() == NSAccessibility.screenRect(
            fromView: tracker,
            rect: link.frameInOwner
        ))
        #expect(link.accessibilityActivationPoint() == NSAccessibility.screenPoint(
            fromView: tracker,
            point: localPoint
        ))
        #expect(link.contains(localPoint))
        #expect(tracker.linkDestination(at: localPoint) == "https://example.com")
        #expect(tracker.accessibilityLink(at: localPoint) === link)

        let unionFrame = link.frameInOwner
        let gapPoint = NSPoint(x: unionFrame.midX, y: unionFrame.midY)
        if !link.contains(gapPoint) {
            #expect(tracker.accessibilityLink(at: gapPoint) !== link)
        }

        let narrowHeight = link.frameInOwner.height
        tracker.frame.size.width = 300
        tracker.needsLayout = true
        tracker.layoutSubtreeIfNeeded()
        let reflowed = try #require(tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        }.first)
        #expect(reflowed === link)
        #expect(reflowed.frameInOwner.height < narrowHeight)
    }

    @Test("footnote references render as compact accent superscripts")
    @MainActor
    func footnoteReference() throws {
        let rendered = PassiveMarkdownInlineRenderer.render(
            "Markdown[^scope] text",
            style: style
        )

        #expect(rendered.string == "Markdownscope text")
        let reference = try range(of: "scope", in: rendered)
        #expect(rendered.attribute(.passiveMarkdownRole, at: reference.location, effectiveRange: nil) as? String == "footnote-reference")
        #expect(color(.foregroundColor, at: reference.location, in: rendered) == DesignTokens.accent)
        #expect(number(.baselineOffset, at: reference.location, in: rendered) > 0)
        #expect(font(at: reference.location, in: rendered)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(PassiveMarkdownInlineRenderer.linkDestination(
            atUTF16Index: reference.location,
            in: rendered
        ) == "mv-footnote:scope")
        var opened: [String] = []
        let tracker = PassiveInlineLinkTrackingView(
            attributed: rendered,
            accessibilityBlockIndex: 35,
            onHoverURL: { _ in },
            onOpenURL: { opened.append($0) }
        )
        let link = try #require(tracker.accessibilityChildren()?.compactMap {
            $0 as? PassiveInlineAccessibilityLink
        }.first)
        #expect(link.accessibilityIdentifier()
            == "document-block-35-footnote-reference-scope")
        #expect(link.accessibilityRole() == .link)
        #expect(link.accessibilityLabel() == "脚注 scope")
        #expect(link.accessibilityPerformPress() == true)
        #expect(opened == ["mv-footnote:scope"])

        let repeated = PassiveMarkdownInlineRenderer.render(
            "A[^scope] B[^scope]",
            style: style
        )
        let repeatedTracker = PassiveInlineLinkTrackingView(
            attributed: repeated,
            accessibilityBlockIndex: 35,
            onHoverURL: { _ in },
            onOpenURL: { _ in }
        )
        #expect(repeatedTracker.accessibilityChildren()?.compactMap {
            ($0 as? PassiveInlineAccessibilityLink)?.accessibilityIdentifier()
        } == [
            "document-block-35-footnote-reference-scope",
            "document-block-35-footnote-reference-scope-occurrence-1",
        ])
    }

    @Test("footnote definitions keep IDs and join indented continuation text")
    func footnoteDefinitions() {
        let definitions = PassiveFootnoteDefinitionParser.parse(
            "[^1]: First definition.\n  Continued text.\n  [^scope]: Nested definition."
        )

        #expect(definitions == [
            PassiveFootnoteDefinition(id: "1", text: "First definition. Continued text."),
            PassiveFootnoteDefinition(id: "scope", text: "Nested definition."),
        ])
    }

    @Test("JavaScript highlighting is UTF-16 safe and protects strings from comments")
    func javaScriptHighlighting() throws {
        let code = "😀 function greet(name) {\n  const url = \"https://x/42\"; // note\n  return greet(name);\n}"
        let highlighted = PassiveCodeHighlighter.highlight(code, language: "js")

        #expect(highlighted.string == code)
        #expect(highlighted.length == (code as NSString).length)
        try expectRole("keyword", on: "function", in: highlighted)
        try expectRole("function", on: "greet", occurrence: 1, in: highlighted)
        try expectRole("string", on: "https://x/42", in: highlighted)
        try expectRole("comment", on: "// note", in: highlighted)
        let url = try range(of: "https://x/42", in: highlighted)
        #expect(color(.foregroundColor, at: url.location, in: highlighted) == PassiveCodeHighlighter.stringColor)
    }

    @Test("Bash highlighting covers comments, commands, flags, and numbers")
    func bashHighlighting() throws {
        let code = "# install\nnpx -y @dev/cli --version 42"
        let highlighted = PassiveCodeHighlighter.highlight(code, language: "bash")

        #expect(highlighted.string == code)
        try expectRole("comment", on: "# install", in: highlighted)
        try expectRole("command", on: "npx", in: highlighted)
        try expectRole("flag", on: "-y", in: highlighted)
        try expectRole("flag", on: "--version", in: highlighted)
        try expectRole("number", on: "42", in: highlighted)
    }

    @Test("unknown code languages keep the exact default code token")
    func unknownCodeLanguage() throws {
        let highlighted = PassiveCodeHighlighter.highlight("let 😀 = 42", language: "text")
        #expect(highlighted.string == "let 😀 = 42")
        let token = try range(of: "let", in: highlighted)
        #expect(color(.foregroundColor, at: token.location, in: highlighted) == PassiveCodeHighlighter.defaultColor)
        #expect(highlighted.attribute(.passiveMarkdownRole, at: token.location, effectiveRange: nil) == nil)
    }

    @Test("ordered list markers follow numeric, alphabetic, and Roman depth cycles")
    func orderedListMarkerDepthCycle() {
        #expect(MarkdownListMarkerFormatter.display(marker: "3)", level: 0) == "3)")
        #expect(MarkdownListMarkerFormatter.display(marker: "1.", level: 1) == "a.")
        #expect(MarkdownListMarkerFormatter.display(marker: "27.", level: 1) == "aa.")
        #expect(MarkdownListMarkerFormatter.display(marker: "2.", level: 2) == "ii.")
        #expect(MarkdownListMarkerFormatter.display(marker: "iv)", level: 2) == "iv)")
        #expect(MarkdownListMarkerFormatter.display(marker: "c.", level: 0) == "3.")
    }

    private func expectRole(
        _ role: String,
        on substring: String,
        occurrence: Int = 0,
        in attributed: NSAttributedString
    ) throws {
        let token = try range(of: substring, occurrence: occurrence, in: attributed)
        #expect(attributed.attribute(.passiveMarkdownRole, at: token.location, effectiveRange: nil) as? String == role)
    }

    private func range(
        of substring: String,
        occurrence: Int = 0,
        in attributed: NSAttributedString
    ) throws -> NSRange {
        var search = NSRange(location: 0, length: attributed.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (attributed.string as NSString).range(of: substring, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: attributed.length - next)
        }
        return try #require(found.location != NSNotFound ? found : nil)
    }

    private func font(at index: Int, in attributed: NSAttributedString) -> NSFont? {
        attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private func color(
        _ key: NSAttributedString.Key,
        at index: Int,
        in attributed: NSAttributedString
    ) -> NSColor? {
        attributed.attribute(key, at: index, effectiveRange: nil) as? NSColor
    }

    private func integer(
        _ key: NSAttributedString.Key,
        at index: Int,
        in attributed: NSAttributedString
    ) -> Int {
        (attributed.attribute(key, at: index, effectiveRange: nil) as? NSNumber)?.intValue
            ?? (attributed.attribute(key, at: index, effectiveRange: nil) as? Int)
            ?? 0
    }

    private func number(
        _ key: NSAttributedString.Key,
        at index: Int,
        in attributed: NSAttributedString
    ) -> CGFloat {
        (attributed.attribute(key, at: index, effectiveRange: nil) as? NSNumber).map {
            CGFloat(truncating: $0)
        }
            ?? (attributed.attribute(key, at: index, effectiveRange: nil) as? CGFloat)
            ?? 0
    }
}
