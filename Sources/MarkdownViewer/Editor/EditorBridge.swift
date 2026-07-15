import SwiftUI

/// Single AppKit → SwiftUI observable bridge and command channel.
final class EditorBridge: ObservableObject {
    @Published var headings: [OutlineController.Heading] = []

    /// Set by EditorView.Coordinator — when called, scrolls to heading.
    var onJumpToHeading: ((Int) -> Void)?

    /// True while the mouse is over the outline rail. Plain (non-@Published) so
    /// setting it never re-renders ContentView; PaperTextView reads it in
    /// `cursorUpdate` to show a pointing-hand over the rail instead of the I-beam.
    var cursorOverRail = false
}

/// Isolated, single-value observable for the status-bar scroll percentage.
///
/// Scroll progress changes on every frame while scrolling. If it lived on
/// `EditorBridge`, every `@Published` change would re-evaluate the whole
/// `ContentView` body (editor, outline rail, overlays) because SwiftUI
/// invalidation is object-level. Keeping it on its own tiny object — held by
/// `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated `EditorStatusBar` — means scrolling
/// re-renders just that one small view.
final class ScrollProgressModel: ObservableObject {
    @Published private(set) var value: Double = 0
    @Published private(set) var activityRevision = 0
    private(set) var documentToken: UUID?

    func reset(for documentToken: UUID?) {
        guard self.documentToken != documentToken else { return }
        self.documentToken = documentToken
        if value != 0 { value = 0 }
    }

    func publish(
        _ value: Double,
        for documentToken: UUID?,
        isScrollActivity: Bool
    ) {
        guard self.documentToken == documentToken else { return }
        let clampedValue = min(1, max(0, value))
        if self.value != clampedValue { self.value = clampedValue }
        if isScrollActivity { activityRevision &+= 1 }
    }
}

/// Isolated, single-value observable for the active outline heading.
///
/// The active heading changes on every scroll frame (as new headings cross the
/// top of the viewport). For the exact reason `ScrollProgressModel` is isolated:
/// if it lived on `EditorBridge`, each `@Published` change would re-evaluate the
/// whole `ContentView` body (editor, sidebar, rail, overlays) because SwiftUI
/// invalidation is object-level. Keeping it on its own tiny object — held by
/// `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated `OutlineRailView` — means scrolling
/// re-renders just the rail.
final class ActiveHeadingModel: ObservableObject {
    @Published private(set) var index: Int = 0
    private(set) var documentToken: UUID?

    func reset(for documentToken: UUID?) {
        guard self.documentToken != documentToken else { return }
        self.documentToken = documentToken
        if index != 0 { index = 0 }
    }

    func publish(_ index: Int, for documentToken: UUID?) {
        guard self.documentToken == documentToken else { return }
        let boundedIndex = max(0, index)
        if self.index != boundedIndex { self.index = boundedIndex }
    }
}

/// Isolated, single-value observable for the link URL under the mouse cursor.
///
/// The hovered URL changes on every mouse move over a link. For the exact reason
/// `ActiveHeadingModel` is isolated: if it lived on `EditorBridge`, each
/// `@Published` change would re-evaluate the whole `ContentView` body because
/// SwiftUI invalidation is object-level. Keeping it on its own tiny object — held
/// by `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated bottom-left hover-preview leaf — means a
/// mouse move over a link re-renders just that preview.
/// Empty string = nothing hovered.
struct HoverURLState: Equatable {
    var url = ""
    var sourceBlockIndex: Int?
}

final class HoverURLModel: ObservableObject {
    @Published private(set) var state = HoverURLState()

    var url: String { state.url }
    var sourceBlockIndex: Int? { state.sourceBlockIndex }

    func publish(_ url: String, sourceBlockIndex: Int?) {
        let next = HoverURLState(
            url: url,
            sourceBlockIndex: url.isEmpty ? nil : sourceBlockIndex
        )
        if state != next { state = next }
    }

    func clear() {
        publish("", sourceBlockIndex: nil)
    }
}

/// Isolated observable for the document's character / line counts.
///
/// The counts change on every edit (recomputed only on text change, not per
/// scroll frame, so the status bar never does O(n) work while scrolling). They
/// are shown ONLY by the bottom-right `EditorStatusBar`. If they lived on
/// `EditorBridge` (which `ContentView` observes via `@StateObject`), each
/// `@Published` change would re-evaluate the whole `ContentView` body because
/// SwiftUI invalidation is object-level. Keeping them on their own tiny object —
/// held by `ContentView` via `@State` (which does NOT subscribe to
/// `objectWillChange`) and observed only by the isolated `EditorStatusBar` —
/// means an edit re-renders just that one small view (性能-3).
final class DocMetricsModel: ObservableObject {
    @Published private(set) var charCount: Int = 0
    @Published private(set) var lineCount: Int = 0
    private(set) var documentToken: UUID?

    func reset(for documentToken: UUID?) {
        guard self.documentToken != documentToken else { return }
        self.documentToken = documentToken
        if charCount != 0 { charCount = 0 }
        if lineCount != 0 { lineCount = 0 }
    }

    func publish(charCount: Int, lineCount: Int, for documentToken: UUID?) {
        guard self.documentToken == documentToken else { return }
        let boundedCharacterCount = max(0, charCount)
        let boundedLineCount = max(0, lineCount)
        if self.charCount != boundedCharacterCount {
            self.charCount = boundedCharacterCount
        }
        if self.lineCount != boundedLineCount {
            self.lineCount = boundedLineCount
        }
    }

    static func nonWhitespaceCharacterCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
    }

    /// Counts logical source lines without adding any rendered-block units.
    /// CRLF and bare CR are line endings, and a final line ending preserves the
    /// trailing empty source line produced by splitting the text.
    static func sourceLineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").count
    }

    /// Mirrors the authoritative block surface's status calculation without
    /// changing the lossless document source. The reference joins rendered
    /// block sources with one blank line before counting display lines.
    static func renderedBlockLineCount(in document: MarkdownDocument) -> Int {
        let renderedSource = document.blocks
            .map(\.source)
            .joined(separator: "\n\n")
        let baseCount = renderedSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .count
        let referenceListSeparators = document.blocks.reduce(into: 0) { count, block in
            guard block.kind == .list else { return }
            count += max(0, referenceListSubblockCount(in: block.source) - 1)
        }
        return baseCount + referenceListSeparators
    }

    /// The prototype presents each list marker as a block and treats a nested
    /// fence as its own block. The native editor intentionally keeps the whole
    /// list in one lossless editing block, so status metrics account for those
    /// visual separators without changing the document model or serialized text.
    private static func referenceListSubblockCount(in source: String) -> Int {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var count = 0
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }
            if isReferenceListStart(line) {
                count += 1
                index += 1
                while index < lines.count {
                    let continuation = lines[index]
                    let trimmed = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty
                        || isReferenceListStart(continuation)
                        || referenceFenceMarker(continuation) != nil {
                        break
                    }
                    guard continuation.first?.isWhitespace == true else { break }
                    index += 1
                }
                continue
            }
            if let marker = referenceFenceMarker(line) {
                count += 1
                index += 1
                while index < lines.count {
                    let closesFence = lines[index]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix(marker)
                    index += 1
                    if closesFence { break }
                }
                continue
            }
            count += 1
            index += 1
        }
        return count
    }

    private static func referenceFenceMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isReferenceListStart(_ line: String) -> Bool {
        let leadingCount = line.prefix(while: \.isWhitespace).count
        let body = line.drop(while: \.isWhitespace)
        guard let first = body.first else { return false }
        var cursor = body.index(after: body.startIndex)
        if first == "-" || first == "*" || first == "+" {
            return cursor < body.endIndex && body[cursor].isWhitespace
        }
        if first.isNumber {
            while cursor < body.endIndex, body[cursor].isNumber {
                cursor = body.index(after: cursor)
            }
            guard cursor < body.endIndex,
                  body[cursor] == "." || body[cursor] == ")" else { return false }
            cursor = body.index(after: cursor)
            return cursor < body.endIndex && body[cursor].isWhitespace
        }
        guard leadingCount >= 2, first.isASCII, first.isLetter else { return false }
        while cursor < body.endIndex, body[cursor].isASCII, body[cursor].isLetter {
            cursor = body.index(after: cursor)
        }
        guard cursor < body.endIndex,
              body[cursor] == "." || body[cursor] == ")" else { return false }
        cursor = body.index(after: cursor)
        return cursor < body.endIndex && body[cursor].isWhitespace
    }
}

// MARK: - Debug diagnostics
/// Debug-only sink for source-editor restyle and find diagnostics.
/// It records which restyle path each edit takes and drives the optional HUD.
///
/// Isolated exactly like `ScrollProgressModel`/`ActiveHeadingModel`/`HoverURLModel`:
/// held by `ContentView` via `@State` and not observed there, so writing it on every
/// edit does not re-evaluate the whole `ContentView` body.
/// Only the isolated `DiagReadout` leaf observes it.
final class DiagModel: ObservableObject {
    @Published var text: String = ""
    /// Second HUD line: the last find-search summary (see FindController
    /// `lastDebugDiagnostic`). Written by the editor Coordinator after each search.
    @Published var findText: String = ""
    /// The full per-match dump copied when the HUD is clicked (not displayed - the
    /// HUD only shows the summary line). Plain var: no view observes it for layout.
    var findDetail: String = ""
}
