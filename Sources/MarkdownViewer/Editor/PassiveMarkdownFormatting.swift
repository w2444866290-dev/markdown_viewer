import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Stable semantic roles for the passive block renderer and its tests.
    static let passiveMarkdownRole = NSAttributedString.Key("passiveMarkdownRole")
}

extension NSAttributedString {
    var containsLinks: Bool {
        var found = false
        enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

struct PassiveMarkdownInlineStyle {
    let font: NSFont
    let color: NSColor
    let kern: CGFloat

    init(font: NSFont, color: NSColor, kern: CGFloat = 0) {
        self.font = font
        self.color = color
        self.kern = kern
    }
}

struct PassiveFindHighlight: Equatable {
    let range: NSRange
    let isCurrent: Bool
}

struct PassiveFootnoteDefinition: Equatable {
    let id: String
    var text: String
}

enum PassiveFootnoteDefinitionParser {
    static func parse(_ source: String) -> [PassiveFootnoteDefinition] {
        var definitions: [PassiveFootnoteDefinition] = []
        var continuationIndex: Int?
        for line in source.components(separatedBy: .newlines) {
            let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedLeading.hasPrefix("[^") {
                let value = String(trimmedLeading)
                if let close = value.range(of: "]:") {
                    let idStart = value.index(value.startIndex, offsetBy: 2)
                    let id = String(value[idStart..<close.lowerBound])
                    if !id.isEmpty {
                        definitions.append(PassiveFootnoteDefinition(
                            id: id,
                            text: String(value[close.upperBound...])
                                .trimmingCharacters(in: .whitespaces)
                        ))
                        continuationIndex = definitions.indices.last
                        continue
                    }
                }
            }

            let isIndented = line.first == " " || line.first == "\t"
            let continuation = line.trimmingCharacters(in: .whitespaces)
            if isIndented, !continuation.isEmpty, let continuationIndex {
                if !definitions[continuationIndex].text.isEmpty {
                    definitions[continuationIndex].text += " "
                }
                definitions[continuationIndex].text += continuation
            } else {
                continuationIndex = nil
            }
        }
        return definitions
    }
}

/// Produces the display-only inline string used by inactive Markdown blocks.
///
/// The parser walks UTF-16 offsets because those are the offsets consumed by
/// NSAttributedString and TextKit.
/// It never indexes a Swift String with an NSRange.
enum PassiveMarkdownInlineRenderer {
    static let underlineColor = NSColor(hex: 0xC7C7CC)
    static let inlineCodeBackground = NSColor(hex: 0xF6F6F9)
    static let linkColor = NSColor(hex: 0x1D1D1F)
    static let linkUnderlineColor = NSColor(hex: 0xE8A33D, alpha: 0.75)
    static let markBackground = NSColor(hex: 0xE8A33D, alpha: 0.28)
    static let inlineImageColor = NSColor(hex: 0x9A9A9E)
    static let inlineImageBackground = NSColor(hex: 0xF4F4F5)

    private struct ParsedInline {
        let attributed: NSAttributedString
        let renderedRangesByProjectionUTF16Unit: [NSRange]

        func renderedRange(forProjectionRange range: NSRange) -> NSRange? {
            guard range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= renderedRangesByProjectionUTF16Unit.count else {
                return nil
            }
            let mapped = renderedRangesByProjectionUTF16Unit[
                range.location..<NSMaxRange(range)
            ]
            guard let first = mapped.first, let last = mapped.last else { return nil }
            return NSRange(
                location: first.location,
                length: NSMaxRange(last) - first.location
            )
        }
    }

    static func render(
        _ source: String,
        style: PassiveMarkdownInlineStyle,
        findHighlights: [PassiveFindHighlight] = []
    ) -> NSAttributedString {
        let parsed = Parser(source: source, style: style).render()
        let rendered = NSMutableAttributedString(
            attributedString: parsed.attributed
        )
        for highlight in findHighlights {
            guard let renderedRange = parsed.renderedRange(forProjectionRange: highlight.range) else {
                continue
            }
            rendered.addAttribute(
                .backgroundColor,
                value: highlight.isCurrent
                    ? DesignTokens.accentStrong
                    : DesignTokens.accentSoft,
                range: renderedRange
            )
        }
        return rendered
    }

    static func linkDestination(
        atUTF16Index index: Int,
        in attributed: NSAttributedString
    ) -> String? {
        guard index >= 0, index < attributed.length,
              let value = attributed.attribute(.link, at: index, effectiveRange: nil) else {
            return nil
        }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return value as? String
    }

    private final class Parser {
        private enum VerticalPosition {
            case normal
            case superscript
            case subscripted
        }

        private struct State {
            var bold = false
            var italic = false
            var strike = false
            var underline = false
            var inlineCode = false
            var marked = false
            var inlineImage = false
            var vertical = VerticalPosition.normal
            var color: NSColor?
            var link: String?
            var role: String?
        }

        private struct HTMLTag {
            let name: String
            let isClosing: Bool
            let isSelfClosing: Bool
            let range: NSRange
        }

        private let source: NSString
        private let style: PassiveMarkdownInlineStyle
        private let output = NSMutableAttributedString()
        private var renderedRangesByProjectionUTF16Unit: [NSRange] = []
        private let escapable = CharacterSet(charactersIn: #"\`*_~[]()#+-.!<>{}"#)

        init(source: String, style: PassiveMarkdownInlineStyle) {
            self.source = source as NSString
            self.style = style
        }

        func render() -> ParsedInline {
            parse(NSRange(location: 0, length: source.length), state: State())
            return ParsedInline(
                attributed: output.copy() as! NSAttributedString,
                renderedRangesByProjectionUTF16Unit: renderedRangesByProjectionUTF16Unit
            )
        }

        private func parse(_ bounds: NSRange, state: State) {
            var cursor = bounds.location
            let end = NSMaxRange(bounds)
            while cursor < end {
                if source.character(at: cursor) == 92,
                   cursor + 1 < end,
                   isEscapable(at: cursor + 1) {
                    var literal = state
                    literal.role = "escaped-literal"
                    append(source.substring(with: NSRange(location: cursor + 1, length: 1)), state: literal)
                    cursor += 2
                    continue
                }

                if hasPrefix("`", at: cursor, before: end),
                   let close = closingDelimiter("`", after: cursor + 1, before: end),
                   close > cursor + 1 {
                    var code = state
                    code.inlineCode = true
                    code.role = "inline-code"
                    append(
                        source.substring(with: NSRange(location: cursor + 1, length: close - cursor - 1)),
                        state: code
                    )
                    cursor = close + 1
                    continue
                }

                if let consumed = parseHTML(at: cursor, before: end, state: state) {
                    cursor = consumed
                    continue
                }

                if hasPrefix("![", at: cursor, before: end),
                   let labelEnd = range(of: "](", after: cursor + 2, before: end),
                   let destinationEnd = closingDelimiter(")", after: NSMaxRange(labelEnd), before: end),
                   parsedDestination(source.substring(with: NSRange(
                    location: NSMaxRange(labelEnd),
                    length: destinationEnd - NSMaxRange(labelEnd)
                   ))) != nil {
                    var image = state
                    image.inlineImage = true
                    image.role = "inline-image"
                    append("🖼 ", state: image, contributesToProjection: false)
                    let labelRange = NSRange(
                        location: cursor + 2,
                        length: labelEnd.location - cursor - 2
                    )
                    if labelRange.length > 0 {
                        parse(labelRange, state: image)
                    } else {
                        append("image", state: image, contributesToProjection: false)
                    }
                    cursor = destinationEnd + 1
                    continue
                }

                if hasPrefix("[^", at: cursor, before: end),
                   let close = closingDelimiter("]", after: cursor + 2, before: end),
                   close > cursor + 2 {
                    let identifier = source.substring(with: NSRange(
                        location: cursor + 2,
                        length: close - cursor - 2
                    ))
                    var reference = state
                    reference.bold = true
                    reference.vertical = .superscript
                    reference.color = DesignTokens.accent
                    reference.link = "mv-footnote:\(identifier)"
                    reference.role = "footnote-reference"
                    append(
                        identifier,
                        state: reference
                    )
                    cursor = close + 1
                    continue
                }

                if hasPrefix("[", at: cursor, before: end),
                   let labelEnd = range(of: "](", after: cursor + 1, before: end),
                   let destinationEnd = closingDelimiter(")", after: NSMaxRange(labelEnd), before: end) {
                    let destinationRange = NSRange(
                        location: NSMaxRange(labelEnd),
                        length: destinationEnd - NSMaxRange(labelEnd)
                    )
                    if let destination = parsedDestination(source.substring(with: destinationRange)) {
                        var link = state
                        link.link = destination
                        link.role = "link"
                        parse(
                            NSRange(location: cursor + 1, length: labelEnd.location - cursor - 1),
                            state: link
                        )
                        cursor = destinationEnd + 1
                        continue
                    }
                }

                let delimiterCases: [(String, Bool, Bool, Bool)] = [
                    ("***", true, true, false),
                    ("___", true, true, false),
                    ("**", true, false, false),
                    ("__", true, false, false),
                    ("~~", false, false, true),
                    ("*", false, true, false),
                    ("_", false, true, false),
                ]
                var matchedDelimiter = false
                for (delimiter, bold, italic, strike) in delimiterCases {
                    guard hasPrefix(delimiter, at: cursor, before: end),
                          isValidOpening(delimiter, at: cursor, before: end),
                          let close = closingDelimiter(
                            delimiter,
                            after: cursor + delimiter.utf16.count,
                            before: end,
                            requiresWordBoundary: delimiter == "*" || delimiter == "_"
                          ),
                          close > cursor + delimiter.utf16.count else {
                        continue
                    }
                    var emphasized = state
                    emphasized.bold = emphasized.bold || bold
                    emphasized.italic = emphasized.italic || italic
                    emphasized.strike = emphasized.strike || strike
                    emphasized.role = strike ? "strikethrough" : (bold && italic
                        ? "bold-italic"
                        : (bold ? "bold" : "italic"))
                    parse(
                        NSRange(
                            location: cursor + delimiter.utf16.count,
                            length: close - cursor - delimiter.utf16.count
                        ),
                        state: emphasized
                    )
                    cursor = close + delimiter.utf16.count
                    matchedDelimiter = true
                    break
                }
                if matchedDelimiter { continue }

                let composed = source.rangeOfComposedCharacterSequence(at: cursor)
                let clipped = NSIntersectionRange(composed, NSRange(location: cursor, length: end - cursor))
                append(source.substring(with: clipped), state: state)
                cursor = NSMaxRange(clipped)
            }
        }

        private func parseHTML(
            at cursor: Int,
            before end: Int,
            state: State
        ) -> Int? {
            guard let opening = htmlTag(at: cursor, before: end), !opening.isClosing else {
                return nil
            }
            if opening.name == "br" {
                var lineBreak = state
                lineBreak.role = "line-break"
                append("\n", state: lineBreak)
                return NSMaxRange(opening.range)
            }
            guard !opening.isSelfClosing,
                  let closing = closingHTMLTag(
                    named: opening.name,
                    after: NSMaxRange(opening.range),
                    before: end
                  ) else {
                return nil
            }

            var nested = state
            switch opening.name {
            case "u":
                nested.underline = true
                nested.role = "underline"
            case "sup":
                nested.vertical = .superscript
                nested.role = "superscript"
            case "sub":
                nested.vertical = .subscripted
                nested.role = "subscript"
            case "mark":
                nested.marked = true
                nested.role = "mark"
            default:
                return nil
            }
            parse(
                NSRange(
                    location: NSMaxRange(opening.range),
                    length: closing.range.location - NSMaxRange(opening.range)
                ),
                state: nested
            )
            return NSMaxRange(closing.range)
        }

        private func append(
            _ text: String,
            state: State,
            contributesToProjection: Bool = true
        ) {
            guard !text.isEmpty else { return }
            let outputStart = output.length
            output.append(NSAttributedString(string: text, attributes: attributes(for: state)))
            if contributesToProjection {
                renderedRangesByProjectionUTF16Unit.append(contentsOf: (0..<text.utf16.count).map {
                    NSRange(location: outputStart + $0, length: 1)
                })
            }
        }

        private func attributes(for state: State) -> [NSAttributedString.Key: Any] {
            var font = state.inlineImage
                ? NSFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.80, weight: .regular)
                : style.font
            var traits: NSFontTraitMask = []
            if state.bold { traits.insert(.boldFontMask) }
            if state.italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            switch state.vertical {
            case .normal:
                break
            case .superscript, .subscripted:
                font = NSFontManager.shared.convert(font, toSize: style.font.pointSize * 0.70)
            }
            if state.inlineCode {
                font = NSFont.monospacedSystemFont(
                    ofSize: style.font.pointSize * 0.85,
                    weight: .medium
                )
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: state.color ?? style.color,
            ]
            if style.kern != 0 { attributes[.kern] = style.kern }
            if state.italic { attributes[.obliqueness] = 0.15 }
            if state.strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = PassiveMarkdownInlineRenderer.underlineColor
            }
            if state.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = PassiveMarkdownInlineRenderer.underlineColor
            }
            if state.marked {
                attributes[.backgroundColor] = PassiveMarkdownInlineRenderer.markBackground
            }
            if state.inlineImage {
                attributes[.backgroundColor] = PassiveMarkdownInlineRenderer.inlineImageBackground
                attributes[.foregroundColor] = PassiveMarkdownInlineRenderer.inlineImageColor
            }
            if state.inlineCode {
                attributes[.backgroundColor] = PassiveMarkdownInlineRenderer.inlineCodeBackground
                attributes[.foregroundColor] = PassiveMarkdownInlineRenderer.linkColor
            }
            switch state.vertical {
            case .normal:
                break
            case .superscript:
                attributes[.baselineOffset] = style.font.pointSize * 0.34
            case .subscripted:
                attributes[.baselineOffset] = -style.font.pointSize * 0.16
            }
            if let destination = state.link {
                attributes[.link] = URL(string: destination) ?? destination
                if state.role != "footnote-reference" {
                    let underline = NSUnderlineStyle.single.union(.patternDash)
                    attributes[.foregroundColor] = PassiveMarkdownInlineRenderer.linkColor
                    attributes[.underlineStyle] = underline.rawValue
                    attributes[.underlineColor] = PassiveMarkdownInlineRenderer.linkUnderlineColor
                }
            }
            if let role = state.role { attributes[.passiveMarkdownRole] = role }
            return attributes
        }

        private func htmlTag(at cursor: Int, before end: Int) -> HTMLTag? {
            guard hasPrefix("<", at: cursor, before: end),
                  let closingBracket = range(of: ">", after: cursor + 1, before: end) else {
                return nil
            }
            let tagRange = NSRange(
                location: cursor,
                length: NSMaxRange(closingBracket) - cursor
            )
            var contents = source.substring(with: NSRange(
                location: cursor + 1,
                length: closingBracket.location - cursor - 1
            )).trimmingCharacters(in: .whitespacesAndNewlines)
            let isClosing = contents.hasPrefix("/")
            if isClosing { contents.removeFirst() }
            contents = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSelfClosing = contents.hasSuffix("/")
            if isSelfClosing { contents.removeLast() }
            let name = contents
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map { String($0).lowercased() }
                ?? ""
            guard ["u", "sup", "sub", "mark", "br"].contains(name) else { return nil }
            return HTMLTag(
                name: name,
                isClosing: isClosing,
                isSelfClosing: isSelfClosing,
                range: tagRange
            )
        }

        private func closingHTMLTag(
            named name: String,
            after start: Int,
            before end: Int
        ) -> HTMLTag? {
            var depth = 1
            var cursor = start
            while cursor < end {
                guard let openingBracket = range(of: "<", after: cursor, before: end) else {
                    return nil
                }
                guard let tag = htmlTag(at: openingBracket.location, before: end) else {
                    cursor = NSMaxRange(openingBracket)
                    continue
                }
                cursor = NSMaxRange(tag.range)
                guard tag.name == name, !tag.isSelfClosing else { continue }
                depth += tag.isClosing ? -1 : 1
                if depth == 0 { return tag }
            }
            return nil
        }

        private func parsedDestination(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.first == "<", trimmed.last == ">", trimmed.count > 2 {
                return String(trimmed.dropFirst().dropLast())
            }
            if let whitespace = trimmed.firstIndex(where: { $0.isWhitespace }) {
                let destination = String(trimmed[..<whitespace])
                let title = trimmed[whitespace...].trimmingCharacters(in: .whitespaces)
                if title.first == "\"", title.last == "\"" { return destination }
                return nil
            }
            return trimmed
        }

        private func isEscapable(at index: Int) -> Bool {
            guard index < source.length,
                  let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return escapable.contains(scalar)
        }

        private func hasPrefix(_ value: String, at index: Int, before end: Int) -> Bool {
            let length = value.utf16.count
            guard index >= 0, index + length <= end else { return false }
            return source.substring(with: NSRange(location: index, length: length)) == value
        }

        private func range(of value: String, after start: Int, before end: Int) -> NSRange? {
            guard start <= end else { return nil }
            var searchStart = start
            while searchStart < end {
                let found = source.range(
                    of: value,
                    options: [],
                    range: NSRange(location: searchStart, length: end - searchStart)
                )
                if found.location == NSNotFound { return nil }
                if !isEscaped(at: found.location) { return found }
                searchStart = NSMaxRange(found)
            }
            return nil
        }

        private func closingDelimiter(
            _ delimiter: String,
            after start: Int,
            before end: Int,
            requiresWordBoundary: Bool = false
        ) -> Int? {
            var searchStart = start
            while searchStart < end {
                guard let found = range(of: delimiter, after: searchStart, before: end) else {
                    return nil
                }
                if source.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: start, length: found.location - start)
                ).location != NSNotFound {
                    return nil
                }
                let previous = found.location - 1
                let next = NSMaxRange(found)
                let tight = previous >= start && !isWhitespace(at: previous)
                let boundaryOK = !requiresWordBoundary || next >= end || !isASCIIWord(at: next)
                if tight && boundaryOK { return found.location }
                searchStart = NSMaxRange(found)
            }
            return nil
        }

        private func isValidOpening(_ delimiter: String, at index: Int, before end: Int) -> Bool {
            let contentStart = index + delimiter.utf16.count
            guard contentStart < end, !isWhitespace(at: contentStart) else { return false }
            if delimiter == "*" || delimiter == "_" {
                return index == 0 || !isASCIIWord(at: index - 1)
            }
            return true
        }

        private func isEscaped(at index: Int) -> Bool {
            var slashCount = 0
            var cursor = index - 1
            while cursor >= 0, source.character(at: cursor) == 92 {
                slashCount += 1
                cursor -= 1
            }
            return slashCount % 2 == 1
        }

        private func isWhitespace(at index: Int) -> Bool {
            guard index >= 0, index < source.length,
                  let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        private func isASCIIWord(at index: Int) -> Bool {
            guard index >= 0, index < source.length else { return false }
            let value = source.character(at: index)
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 95
        }
    }
}

/// Transparent TextKit hit map layered over SwiftUI Text.
/// The SwiftUI leaf keeps the existing typography and wrapping, while this view
/// reports only the destination below the pointer.
struct PassiveInlineLinkHoverLayer: NSViewRepresentable {
    let attributed: NSAttributedString
    let accessibilityBlockIndex: Int?
    let accessibilityLeafScope: String?
    let lineSpacing: CGFloat
    let onHoverURL: (String) -> Void
    var onOpenURL: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> PassiveInlineLinkTrackingView {
        PassiveInlineLinkTrackingView(
            attributed: attributed,
            accessibilityBlockIndex: accessibilityBlockIndex,
            accessibilityLeafScope: accessibilityLeafScope,
            lineSpacing: lineSpacing,
            onHoverURL: onHoverURL,
            onOpenURL: onOpenURL
        )
    }

    func updateNSView(_ view: PassiveInlineLinkTrackingView, context: Context) {
        view.onHoverURL = onHoverURL
        view.onOpenURL = onOpenURL
        view.accessibilityBlockIndex = accessibilityBlockIndex
        view.accessibilityLeafScope = accessibilityLeafScope
        view.lineSpacing = lineSpacing
        view.attributed = attributed
    }

    static func dismantleNSView(
        _ view: PassiveInlineLinkTrackingView,
        coordinator: Void
    ) {
        view.prepareForDismantle()
    }
}

final class PassiveInlineLinkTrackingView: NSView {
    var onHoverURL: (String) -> Void
    var onOpenURL: (String) -> Void
    var accessibilityBlockIndex: Int? {
        didSet {
            guard accessibilityBlockIndex != oldValue else { return }
            rebuildAccessibilityLinks()
        }
    }
    var accessibilityLeafScope: String? {
        didSet {
            guard accessibilityLeafScope != oldValue else { return }
            rebuildAccessibilityLinks()
        }
    }
    var lineSpacing: CGFloat {
        didSet {
            guard lineSpacing != oldValue else { return }
            updateTextStorage()
        }
    }
    var attributed: NSAttributedString {
        didSet {
            guard !attributed.isEqual(to: oldValue) else { return }
            updateTextStorage()
            rebuildAccessibilityLinks()
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private var tracking: NSTrackingArea?
    private var hoveredURL = ""
    private var accessibilityLinks: [PassiveInlineAccessibilityLink] = []
    private var accessibilityLinksByKey: [String: PassiveInlineAccessibilityLink] = [:]

    override var isFlipped: Bool { true }

    init(
        attributed: NSAttributedString,
        accessibilityBlockIndex: Int? = nil,
        accessibilityLeafScope: String? = nil,
        lineSpacing: CGFloat = 0,
        onHoverURL: @escaping (String) -> Void,
        onOpenURL: @escaping (String) -> Void
    ) {
        self.attributed = attributed
        self.accessibilityBlockIndex = accessibilityBlockIndex
        self.accessibilityLeafScope = accessibilityLeafScope
        self.lineSpacing = lineSpacing
        self.onHoverURL = onHoverURL
        self.onOpenURL = onOpenURL
        super.init(frame: .zero)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        updateTextStorage()
        setAccessibilityElement(false)
        rebuildAccessibilityLinks()
    }

    convenience init(
        attributed: NSAttributedString,
        onHoverURL: @escaping (String) -> Void
    ) {
        self.init(
            attributed: attributed,
            accessibilityBlockIndex: nil,
            accessibilityLeafScope: nil,
            lineSpacing: 0,
            onHoverURL: onHoverURL,
            onOpenURL: { _ in }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        detachAccessibilityLinks()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return linkDestination(at: point) == nil ? nil : self
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityLinks
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return super.accessibilityHitTest(point) }
        let windowPoint = window.convertPoint(fromScreen: point)
        let localPoint = convert(windowPoint, from: nil)
        if let link = accessibilityLink(at: localPoint) {
            return link
        }
        return super.accessibilityHitTest(point)
    }

    override func layout() {
        super.layout()
        updateTextContainerSize()
        layoutAccessibilityLinks()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let destination = linkDestination(at: point) else { return }
        onOpenURL(destination)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        updateTextContainerSize()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.link, in: fullRange) { value, characterRange, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    func clearHover() {
        setHoveredURL("")
    }

    func prepareForDismantle() {
        clearHover()
        detachAccessibilityLinks()
    }

    func reportHover(atUTF16Index index: Int?) {
        let destination = index.flatMap {
            PassiveMarkdownInlineRenderer.linkDestination(
                atUTF16Index: $0,
                in: textStorage
            )
        } ?? ""
        setHoveredURL(destination)
    }

    private func updateTextContainerSize() {
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let size = NSSize(width: width, height: height)
        guard textContainer.containerSize != size else { return }
        textContainer.containerSize = size
        layoutManager.ensureLayout(for: textContainer)
        window?.invalidateCursorRects(for: self)
    }

    private func updateHover(at point: NSPoint) {
        setHoveredURL(linkDestination(at: point) ?? "")
    }

    func linkDestination(at point: NSPoint) -> String? {
        updateTextContainerSize()
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            return nil
        }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyph < glyphCount else {
            return nil
        }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -1, dy: -2).contains(point) else {
            return nil
        }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return PassiveMarkdownInlineRenderer.linkDestination(
            atUTF16Index: character,
            in: textStorage
        )
    }

    private func setHoveredURL(_ value: String) {
        guard hoveredURL != value else { return }
        hoveredURL = value
        onHoverURL(value)
    }

    private func updateTextStorage() {
        let storage = NSMutableAttributedString(attributedString: attributed)
        if storage.length > 0, lineSpacing > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            storage.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: storage.length)
            )
        }
        textStorage.setAttributedString(storage)
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    fileprivate func activate(_ destination: String) {
        onOpenURL(destination)
    }

    private func rebuildAccessibilityLinks() {
        let previousLinksByKey = accessibilityLinksByKey
        var nextLinks: [PassiveInlineAccessibilityLink] = []
        var nextLinksByKey: [String: PassiveInlineAccessibilityLink] = [:]
        let fullRange = NSRange(location: 0, length: attributed.length)
        var linkIndex = 0
        var destinationOccurrences: [String: Int] = [:]
        attributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let destination = Self.destinationString(value), range.length > 0 else {
                return
            }
            let label = attributed.attributedSubstring(from: range).string
            let identifier: String?
            if let blockIndex = accessibilityBlockIndex {
                if destination.hasPrefix("mv-footnote:") {
                    let occurrence = destinationOccurrences[destination, default: 0]
                    destinationOccurrences[destination] = occurrence + 1
                    identifier = MarkdownAccessibilitySurface.footnoteReference(
                        blockIndex: blockIndex,
                        identifier: String(destination.dropFirst("mv-footnote:".count)),
                        scope: accessibilityLeafScope,
                        occurrence: occurrence
                    )
                } else {
                    identifier = MarkdownAccessibilitySurface.inlineLink(
                        blockIndex: blockIndex,
                        scope: accessibilityLeafScope,
                        index: linkIndex
                    )
                }
            } else {
                identifier = nil
            }
            let key = identifier ?? "anonymous-link-\(linkIndex)"
            let link = previousLinksByKey[key] ?? PassiveInlineAccessibilityLink(
                owner: self,
                key: key
            )
            link.update(
                destination: destination,
                characterRange: range,
                label: label,
                identifier: identifier
            )
            nextLinks.append(link)
            nextLinksByKey[key] = link
            linkIndex += 1
        }
        for (key, link) in previousLinksByKey where nextLinksByKey[key] == nil {
            link.invalidate()
        }
        accessibilityLinks = nextLinks
        accessibilityLinksByKey = nextLinksByKey
        needsLayout = true
    }

    private func layoutAccessibilityLinks() {
        var changed = false
        for link in accessibilityLinks {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: link.characterRange,
                actualCharacterRange: nil
            )
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                let hitRect = rect.insetBy(dx: -1, dy: -2).intersection(self.bounds)
                if !hitRect.isNull, !hitRect.isEmpty {
                    rects.append(hitRect)
                }
            }
            let frame = rects.reduce(NSRect.null) { $0.union($1) }
            changed = link.updateLayout(
                hitRects: rects,
                frameInParentSpace: frame.isNull ? .zero : frame,
                activationRect: rects.first ?? .zero
            ) || changed
        }
        if changed, !accessibilityLinks.isEmpty {
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    func screenPoint(for localPoint: NSPoint) -> NSPoint {
        return NSAccessibility.screenPoint(fromView: self, point: localPoint)
    }

    func accessibilityLink(at localPoint: NSPoint) -> PassiveInlineAccessibilityLink? {
        accessibilityLinks.first { $0.contains(localPoint) }
    }

    private static func destinationString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private func detachAccessibilityLinks() {
        accessibilityLinks.forEach { $0.invalidate() }
        accessibilityLinks.removeAll(keepingCapacity: false)
        accessibilityLinksByKey.removeAll(keepingCapacity: false)
    }
}

final class PassiveInlineAccessibilityLink: NSAccessibilityElement {
    weak var owner: PassiveInlineLinkTrackingView?
    let key: String
    private(set) var destination = ""
    private(set) var characterRange = NSRange(location: 0, length: 0)
    private(set) var hitRects: [NSRect] = []
    private(set) var frameInOwner = NSRect.zero
    private var activationRect = NSRect.zero
    private var invalidated = false

    var activationPointInParentSpace: NSPoint {
        NSPoint(x: activationRect.midX, y: activationRect.midY)
    }

    override var accessibilityNotifiesWhenDestroyed: Bool {
        true
    }

    init(
        owner: PassiveInlineLinkTrackingView,
        key: String
    ) {
        self.owner = owner
        self.key = key
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityParent(owner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        destination: String,
        characterRange: NSRange,
        label: String,
        identifier: String?
    ) {
        invalidated = false
        self.destination = destination
        self.characterRange = characterRange
        if let owner { setAccessibilityParent(owner) }
        setAccessibilityElement(true)
        setAccessibilityLabel(
            destination.hasPrefix("mv-footnote:") ? "脚注 \(label)" : label
        )
        setAccessibilityValue(destination)
        setAccessibilityIdentifier(identifier)
    }

    @discardableResult
    func updateLayout(
        hitRects: [NSRect],
        frameInParentSpace: NSRect,
        activationRect: NSRect
    ) -> Bool {
        let changed = self.hitRects != hitRects
            || frameInOwner != frameInParentSpace
            || self.activationRect != activationRect
        self.hitRects = hitRects
        self.frameInOwner = frameInParentSpace
        self.activationRect = activationRect
        return changed
    }

    func contains(_ point: NSPoint) -> Bool {
        hitRects.contains { $0.contains(point) }
    }

    override func accessibilityActivationPoint() -> NSPoint {
        owner?.screenPoint(for: activationPointInParentSpace) ?? .zero
    }

    override func accessibilityFrame() -> NSRect {
        guard let owner else { return .zero }
        return NSAccessibility.screenRect(fromView: owner, rect: frameInOwner)
    }

    override func accessibilityPerformPress() -> Bool {
        guard !invalidated, let owner else { return false }
        owner.activate(destination)
        return true
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        NSAccessibility.post(element: self, notification: .uiElementDestroyed)
        owner = nil
        setAccessibilityParent(nil)
        setAccessibilityElement(false)
        hitRects.removeAll(keepingCapacity: false)
        frameInOwner = .zero
        activationRect = .zero
    }
}

/// Small GitHub Light style highlighter for passive JavaScript and shell blocks.
/// It masks claimed UTF-16 ranges with spaces before later passes, so a token can
/// never be recolored by a lower-priority regular expression.
enum PassiveCodeHighlighter {
    static let defaultColor = NSColor(hex: 0x24292F)
    static let commentColor = NSColor(hex: 0x6E7781)
    static let keywordColor = NSColor(hex: 0xCF222E)
    static let stringColor = NSColor(hex: 0x0A3069)
    static let numberColor = NSColor(hex: 0x0550AE)
    static let functionColor = NSColor(hex: 0x8250DF)

    private static let stringRegex = try! NSRegularExpression(
        pattern: #"`(?:[^`\\]|\\[\s\S])*`|"(?:[^"\\\r\n]|\\.)*"|'(?:[^'\\\r\n]|\\.)*'"#
    )
    private static let slashCommentRegex = try! NSRegularExpression(
        pattern: #"//[^\r\n]*|/\*[\s\S]*?\*/"#
    )
    private static let hashCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\r\n]*"#
    )
    private static let javaScriptKeywordRegex = try! NSRegularExpression(
        pattern: #"\b(function|return|const|let|var|if|else|for|while|do|switch|case|break|continue|new|typeof|instanceof|await|async|class|extends|super|import|export|from|default|try|catch|finally|throw|delete|in|of|void|yield|this)\b"#
    )
    private static let primitiveRegex = try! NSRegularExpression(
        pattern: #"\b(true|false|null|nil|None|True|False|yes|no|on|off)\b"#
    )
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b\d+(?:\.\d+)?\b"#
    )
    private static let functionRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_$][\w$]*(?=\s*\()"#
    )
    private static let shellCommandRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(npm|npx|node|git|cd|ls|echo|cat|mkdir|rm|cp|mv|curl|wget|sudo|brew|python|pip|yarn|pnpm|docker|make|export|source)\b"#,
        options: [.anchorsMatchLines]
    )
    private static let shellFlagRegex = try! NSRegularExpression(
        pattern: #"(^|\s)(--?[A-Za-z][\w-]*)"#,
        options: [.anchorsMatchLines]
    )

    static func highlight(_ code: String, language: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: defaultColor,
            ]
        )
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        guard fullRange.length > 0 else { return result }

        let mask = NSMutableString(string: code)
        apply(
            stringRegex,
            to: result,
            source: code,
            mask: mask,
            color: stringColor,
            role: "string"
        )

        let normalized = language.lowercased()
        if ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"].contains(normalized) {
            apply(
                slashCommentRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: commentColor,
                role: "comment"
            )
            apply(
                javaScriptKeywordRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: keywordColor,
                role: "keyword"
            )
            apply(
                primitiveRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: numberColor,
                role: "literal"
            )
            apply(
                numberRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: numberColor,
                role: "number"
            )
            apply(
                functionRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: functionColor,
                role: "function"
            )
        } else if ["bash", "sh", "shell", "zsh", "console"].contains(normalized) {
            apply(
                hashCommentRegex,
                to: result,
                source: mask as String,
                mask: mask,
                color: commentColor,
                role: "comment"
            )
            apply(
                shellCommandRegex,
                capture: 2,
                to: result,
                source: mask as String,
                mask: mask,
                color: functionColor,
                role: "command"
            )
            apply(
                shellFlagRegex,
                capture: 2,
                to: result,
                source: mask as String,
                mask: mask,
                color: functionColor,
                role: "flag"
            )
            apply(numberRegex, to: result, source: mask as String, color: numberColor, role: "number")
        }

        assert(result.string == code)
        assert(result.length == fullRange.length)
        return result
    }

    private static func apply(
        _ regex: NSRegularExpression,
        capture: Int = 0,
        to result: NSMutableAttributedString,
        source: String,
        mask: NSMutableString? = nil,
        color: NSColor,
        role: String
    ) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let matches = regex.matches(in: source, range: fullRange)
        for match in matches {
            let range = match.range(at: capture)
            guard range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= result.length else { continue }
            result.addAttributes([
                .foregroundColor: color,
                .passiveMarkdownRole: role,
            ], range: range)
        }
        guard let mask else { return }
        for match in matches.reversed() {
            let range = match.range
            guard range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= mask.length else { continue }
            mask.replaceCharacters(
                in: range,
                with: String(repeating: " ", count: range.length)
            )
        }
    }
}
