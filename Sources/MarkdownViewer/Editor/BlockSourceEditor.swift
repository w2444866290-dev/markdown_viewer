import AppKit
import SwiftUI

enum BlockSourceEditorLayout {
    static let leadingOverflow: CGFloat = 14
    static let cssLineHeightMultiple: CGFloat = 1.72

    static func headingLineHeight(
        level: Int,
        bodyFontSize: CGFloat
    ) -> CGFloat {
        let headingSizes: [CGFloat] = [24, 19, 16.5, 15.5, 14, 13]
        let index = min(6, max(1, level)) - 1
        return floor(max(bodyFontSize, headingSizes[index]) * cssLineHeightMultiple)
    }
}

// MARK: - Pure source highlighting

extension NSAttributedString.Key {
    /// True on visible Markdown syntax markers in the active block source editor.
    static let blockSourceSyntaxMarker = NSAttributedString.Key("blockSourceSyntaxMarker")
    /// A stable semantic role used by tests and accessibility diagnostics.
    static let blockSourceSyntaxRole = NSAttributedString.Key("blockSourceSyntaxRole")
}

/// Attribute-only Markdown source highlighting.
///
/// This highlighter never replaces characters. Every result keeps the input string
/// and UTF-16 length exactly intact, which makes selections and IME ranges stable.
enum BlockSourceHighlighter {
    static let pointSize: CGFloat = 12.5
    static let defaultBodyFontSize: CGFloat = 16.5

    private struct SourceStyle {
        let baseFont: NSFont
        let semiboldFont: NSFont
        let markerFont: NSFont
        let headingFont: NSFont?
        let baseTextColor: NSColor
        let paragraphStyle: NSParagraphStyle
        let inlineCodeFont: NSFont
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6})([ \\t]+)(.*)$",
        options: [.anchorsMatchLines]
    )
    private static let listRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*(?:[-+*]|(?:[0-9]+|[A-Za-z]+)[.)])[ \\t]+)(\\[[ xX]\\][ \\t]+)?",
        options: [.anchorsMatchLines]
    )
    private static let quoteRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*>+[ \\t]*)",
        options: [.anchorsMatchLines]
    )
    private static let fenceRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*(?:`{3,}|~{3,}))([^\\r\\n]*)$",
        options: [.anchorsMatchLines]
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: "(!?\\[)([^\\]\\r\\n]*)(\\])(\\()([^)\\r\\n]+)(\\))"
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "(?<!`)`([^`\\r\\n]+)`(?!`)"
    )
    private static let strongRegex = try! NSRegularExpression(
        pattern: "(?:\\*\\*|__)([^\\r\\n]+?)(?:\\*\\*|__)"
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*([^*\\r\\n]+)\\*(?!\\*)"
    )
    private static let strikeRegex = try! NSRegularExpression(
        pattern: "~~([^~\\r\\n]+)~~"
    )
    private static let emphasisMarkerRegex = try! NSRegularExpression(
        pattern: "(?<!\\\\)(?:\\*{1,3}|_{1,3}|~~|(?<!`)`(?!``))"
    )
    private static let tablePipeRegex = try! NSRegularExpression(pattern: "(?<!\\\\)\\|")
    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*\\|?[ \\t]*(?::?-{3,}:?[ \\t]*\\|[ \\t]*)+(?::?-{3,}:?)[ \\t]*\\|?[ \\t]*$",
        options: [.anchorsMatchLines]
    )

    static func highlightedSource(
        _ source: String,
        kind: MarkdownBlockKind,
        bodyFontSize: CGFloat = defaultBodyFontSize
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        apply(to: result, kind: kind, bodyFontSize: bodyFontSize)
        return result
    }

    static func apply(
        to storage: NSMutableAttributedString,
        kind: MarkdownBlockKind,
        bodyFontSize: CGFloat = defaultBodyFontSize
    ) {
        let original = storage.string
        let fullRange = NSRange(location: 0, length: (original as NSString).length)
        guard fullRange.length > 0 else { return }
        let style = sourceStyle(
            kind: kind,
            source: original,
            bodyFontSize: bodyFontSize
        )

        storage.beginEditing()
        storage.setAttributes(baseAttributes(style), range: fullRange)

        applyMatches(headingRegex, to: storage, source: original) { match in
            mark(
                match.range(at: 1),
                in: storage,
                style: style,
                role: "heading-marker"
            )
            mark(
                match.range(at: 2),
                in: storage,
                style: style,
                role: "heading-spacing"
            )
            let body = match.range(at: 3)
            if body.location != NSNotFound, body.length > 0 {
                storage.addAttributes([
                    .font: style.headingFont ?? style.semiboldFont,
                    .foregroundColor: DesignTokens.headingText,
                    .blockSourceSyntaxRole: "heading-text",
                ], range: body)
            }
        }

        applyMatches(listRegex, to: storage, source: original) { match in
            mark(
                match.range(at: 1),
                in: storage,
                style: style,
                role: "list-marker"
            )
            let task = match.range(at: 2)
            if task.location != NSNotFound, task.length > 0 {
                accentMark(task, in: storage, style: style, role: "task-marker")
            }
        }

        applyMatches(quoteRegex, to: storage, source: original) { match in
            mark(
                match.range(at: 1),
                in: storage,
                style: style,
                role: "quote-marker"
            )
        }

        applyMatches(linkRegex, to: storage, source: original) { match in
            for group in [1, 3, 4, 6] {
                mark(
                    match.range(at: group),
                    in: storage,
                    style: style,
                    role: "link-marker"
                )
            }
            let label = match.range(at: 2)
            if label.location != NSNotFound, label.length > 0 {
                storage.addAttributes([
                    .foregroundColor: DesignTokens.sourceLink,
                    .blockSourceSyntaxRole: "link-label",
                ], range: label)
            }
            let destination = match.range(at: 5)
            if destination.location != NSNotFound, destination.length > 0 {
                storage.addAttributes([
                    .foregroundColor: DesignTokens.sourceLink,
                    .blockSourceSyntaxRole: "link-destination",
                ], range: destination)
            }
        }

        applyMatches(strongRegex, to: storage, source: original) { match in
            addFontTrait(.boldFontMask, to: match.range(at: 1), in: storage)
        }
        applyMatches(italicRegex, to: storage, source: original) { match in
            addFontTrait(.italicFontMask, to: match.range(at: 1), in: storage)
        }
        applyMatches(strikeRegex, to: storage, source: original) { match in
            let content = match.range(at: 1)
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .blockSourceSyntaxRole: "strikethrough-text",
            ], range: content)
        }

        applyMatches(inlineCodeRegex, to: storage, source: original) { match in
            let content = match.range(at: 1)
            storage.addAttributes([
                .font: style.inlineCodeFont,
                .foregroundColor: DesignTokens.titleText,
                .backgroundColor: DesignTokens.codeBackground,
                .blockSourceSyntaxRole: "inline-code",
            ], range: content)
        }

        applyMatches(emphasisMarkerRegex, to: storage, source: original) { match in
            mark(match.range, in: storage, style: style, role: "inline-marker")
        }

        applyMatches(fenceRegex, to: storage, source: original) { match in
            mark(
                match.range(at: 1),
                in: storage,
                style: style,
                role: "code-fence"
            )
            let info = match.range(at: 2)
            if info.location != NSNotFound, info.length > 0 {
                storage.addAttributes([
                    .foregroundColor: DesignTokens.secondaryText,
                    .blockSourceSyntaxRole: "code-language",
                ], range: info)
            }
        }

        if kind == .table || original.contains("|") {
            applyMatches(tableSeparatorRegex, to: storage, source: original) { match in
                storage.addAttributes([
                    .foregroundColor: DesignTokens.secondaryText,
                    .blockSourceSyntaxRole: "table-separator",
                ], range: match.range)
            }
            applyMatches(tablePipeRegex, to: storage, source: original) { match in
                mark(match.range, in: storage, style: style, role: "table-pipe")
            }
        }

        storage.endEditing()
        assert(storage.string == original)
        assert(storage.length == fullRange.length)
    }

    static func baseTypingAttributes(
        kind: MarkdownBlockKind,
        source: String,
        bodyFontSize: CGFloat = defaultBodyFontSize
    ) -> [NSAttributedString.Key: Any] {
        baseAttributes(sourceStyle(
            kind: kind,
            source: source,
            bodyFontSize: bodyFontSize
        ))
    }

    private static func baseAttributes(
        _ style: SourceStyle
    ) -> [NSAttributedString.Key: Any] {
        return [
            .font: style.baseFont,
            .foregroundColor: style.baseTextColor,
            .paragraphStyle: style.paragraphStyle,
            .ligature: 0,
        ]
    }

    private static func mark(
        _ range: NSRange,
        in storage: NSMutableAttributedString,
        style: SourceStyle,
        role: String
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttributes([
            .foregroundColor: DesignTokens.sourceSyntax,
            .font: style.markerFont,
            .blockSourceSyntaxMarker: true,
            .blockSourceSyntaxRole: role,
        ], range: range)
    }

    private static func accentMark(
        _ range: NSRange,
        in storage: NSMutableAttributedString,
        style: SourceStyle,
        role: String
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttributes([
            .foregroundColor: DesignTokens.accent,
            .font: style.semiboldFont,
            .blockSourceSyntaxMarker: true,
            .blockSourceSyntaxRole: role,
        ], range: range)
    }

    private static func addFontTrait(
        _ trait: NSFontTraitMask,
        to range: NSRange,
        in storage: NSMutableAttributedString
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: defaultBodyFontSize)
            storage.addAttribute(
                .font,
                value: NSFontManager.shared.convert(font, toHaveTrait: trait),
                range: subrange
            )
        }
    }

    private static func applyMatches(
        _ regex: NSRegularExpression,
        to storage: NSMutableAttributedString,
        source: String,
        body: (NSTextCheckingResult) -> Void
    ) {
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in regex.matches(in: source, range: range) { body(match) }
    }

    private static func sourceStyle(
        kind: MarkdownBlockKind,
        source: String,
        bodyFontSize: CGFloat
    ) -> SourceStyle {
        let isMonospaced = kind == .code || kind == .table
        let baseFont = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            : NSFont.systemFont(ofSize: bodyFontSize, weight: .regular)
        let semiboldFont = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .semibold)
            : NSFont.systemFont(ofSize: bodyFontSize, weight: .semibold)
        let sourceHeadingLevel = headingLevel(in: source)
        let headingFont = sourceHeadingLevel.map { level in
            let sizes: [CGFloat] = [24, 19, 16.5, 15.5, 14, 13]
            return NSFont.systemFont(ofSize: sizes[level - 1], weight: .semibold)
        }
        let paragraph = NSMutableParagraphStyle()
        if kind == .heading, let sourceHeadingLevel {
            let lineHeight = BlockSourceEditorLayout.headingLineHeight(
                level: sourceHeadingLevel,
                bodyFontSize: bodyFontSize
            )
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        } else {
            paragraph.lineHeightMultiple = isMonospaced ? 1.7 : 1.72
        }
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 24
        return SourceStyle(
            baseFont: baseFont,
            semiboldFont: semiboldFont,
            markerFont: baseFont,
            headingFont: headingFont,
            // The prototype's code and table source cards use #444 rather than
            // the regular reading text. This is a source-state color only; it
            // deliberately does not tune the native glyph metrics.
            baseTextColor: isMonospaced
                ? NSColor(srgbRed: 68 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1)
                : DesignTokens.bodyText,
            paragraphStyle: paragraph,
            inlineCodeFont: NSFont.monospacedSystemFont(
                ofSize: max(11, bodyFontSize * 0.85),
                weight: .medium
            )
        )
    }

    private static func headingLevel(in source: String) -> Int? {
        guard let match = headingRegex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) else {
            return nil
        }
        return min(6, max(1, match.range(at: 1).length))
    }
}

// MARK: - SwiftUI API

final class BlockSourceEditorBridge {
    struct Snapshot: Equatable {
        let source: String
        let selection: NSRange
        let hasMarkedText: Bool
    }

    private weak var coordinator: BlockSourceEditor.Coordinator?

    func snapshot() -> Snapshot? {
        coordinator?.liveSnapshot()
    }

    @discardableResult
    func applyFindReplacement(
        source: String,
        selection: NSRange
    ) -> Snapshot? {
        coordinator?.applyFindReplacement(
            source: source,
            selection: selection
        )
    }

    @discardableResult
    func flushForLifecycleBoundary() -> Snapshot? {
        coordinator?.flushForLifecycleBoundary()
    }

    fileprivate func attach(_ coordinator: BlockSourceEditor.Coordinator) {
        self.coordinator = coordinator
    }

    fileprivate func detach(_ coordinator: BlockSourceEditor.Coordinator) {
        if self.coordinator === coordinator {
            self.coordinator = nil
        }
    }
}

/// A reusable active-block Markdown source editor.
///
/// `initialSource` is loaded when the view mounts and whenever `focusToken` changes.
/// Live edits stay inside the NSTextView and flow outward through the callbacks.
struct BlockSourceEditor: NSViewRepresentable {
    struct FindHighlight: Equatable {
        let range: NSRange
        let isCurrent: Bool
    }

    typealias ChangeHandler = (_ source: String, _ selection: NSRange) -> Void
    typealias CommitHandler = (_ source: String, _ selection: NSRange) -> Void
    typealias KeyCommandInterceptor = (
        _ event: NSEvent,
        _ source: String,
        _ selection: NSRange
    ) -> MarkdownEditingResult?
    typealias BoundaryActionHandler = (MarkdownEditingBoundaryAction) -> Void

    let initialSource: String
    let blockKind: MarkdownBlockKind
    let bodyFontSize: CGFloat
    let focusToken: AnyHashable
    var initialSelection: NSRange?
    var accessibilityIdentifier: String
    var findHighlights: [FindHighlight]
    var onHeightChange: ((CGFloat) -> Void)?
    let lifecycleBridge: BlockSourceEditorBridge?
    let onChange: ChangeHandler
    let onCommit: CommitHandler
    let onKeyCommand: KeyCommandInterceptor
    let onBoundaryAction: BoundaryActionHandler

    init(
        initialSource: String,
        blockKind: MarkdownBlockKind,
        bodyFontSize: CGFloat = BlockSourceHighlighter.defaultBodyFontSize,
        focusToken: AnyHashable,
        initialSelection: NSRange? = nil,
        accessibilityIdentifier: String = "markdown-block-source-editor",
        findHighlights: [FindHighlight] = [],
        onHeightChange: ((CGFloat) -> Void)? = nil,
        lifecycleBridge: BlockSourceEditorBridge? = nil,
        onChange: @escaping ChangeHandler,
        onCommit: @escaping CommitHandler,
        onKeyCommand: @escaping KeyCommandInterceptor = { _, _, _ in nil },
        onBoundaryAction: @escaping BoundaryActionHandler = { _ in }
    ) {
        self.initialSource = initialSource
        self.blockKind = blockKind
        self.bodyFontSize = bodyFontSize
        self.focusToken = focusToken
        self.initialSelection = initialSelection
        self.accessibilityIdentifier = accessibilityIdentifier
        self.findHighlights = findHighlights
        self.onHeightChange = onHeightChange
        self.lifecycleBridge = lifecycleBridge
        self.onChange = onChange
        self.onCommit = onCommit
        self.onKeyCommand = onKeyCommand
        self.onBoundaryAction = onBoundaryAction
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> BlockSourceEditorHostView {
        let textView = BlockSourceTextView(frame: .zero)
        let host = BlockSourceEditorHostView(textView: textView)
        context.coordinator.attach(host: host)
        context.coordinator.connectLifecycleBridge(lifecycleBridge)
        context.coordinator.load(
            source: initialSource,
            kind: blockKind,
            token: focusToken,
            selection: initialSelection
        )
        return host
    }

    func updateNSView(_ host: BlockSourceEditorHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.connectLifecycleBridge(lifecycleBridge)
        context.coordinator.update(
            source: initialSource,
            kind: blockKind,
            token: focusToken,
            selection: initialSelection
        )
    }

    static func dismantleNSView(
        _ host: BlockSourceEditorHostView,
        coordinator: Coordinator
    ) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockSourceEditor
        private weak var host: BlockSourceEditorHostView?
        private weak var textView: BlockSourceTextView?
        private weak var lifecycleBridge: BlockSourceEditorBridge?
        private var lastFocusToken: AnyHashable?
        private var lastKind: MarkdownBlockKind?
        private var lastBodyFontSize: CGFloat?
        private var lastFindHighlights: [FindHighlight] = []
        private var pendingSelection: NSRange?
        private var pendingFocus = false
        private var focusAttemptCount = 0
        private var focusRequestGeneration = 0
        private var focusScheduledAttemptID = 0
        private var focusRetryWork: DispatchWorkItem?
        private var synchronizing = false
        private var applyingCommandResult = false
        private var compositionPending = false
        private var liveWork: DispatchWorkItem?
        private var measureWork: DispatchWorkItem?
        private var lastEmitted: Snapshot?
        private var lastCommitted: Snapshot?
        private var lastReportedHeight: CGFloat?
        private var isMeasuring = false

        private struct Snapshot: Equatable {
            let source: String
            let location: Int
            let length: Int

            init(_ textView: NSTextView) {
                source = textView.string
                location = textView.selectedRange().location
                length = textView.selectedRange().length
            }

            var selection: NSRange { NSRange(location: location, length: length) }
        }

        init(parent: BlockSourceEditor) {
            self.parent = parent
        }

        func attach(host: BlockSourceEditorHostView) {
            self.host = host
            textView = host.textView
            host.textView.delegate = self
            host.onLayout = { [weak self] in self?.scheduleMeasurement() }
            host.onWindowAttached = { [weak self] in self?.focusIfPossible() }
            host.textView.onKeyEvent = { [weak self] event in
                self?.handleKeyEvent(event) ?? false
            }
            host.textView.onEscape = { [weak self] in self?.commitAndResign() }
            host.textView.onCompositionEnded = { [weak self] in self?.compositionEnded() }
            configureTextView(host.textView)
        }

        func connectLifecycleBridge(_ bridge: BlockSourceEditorBridge?) {
            guard lifecycleBridge !== bridge else { return }
            lifecycleBridge?.detach(self)
            lifecycleBridge = bridge
            bridge?.attach(self)
        }

        func load(
            source: String,
            kind: MarkdownBlockKind,
            token: AnyHashable,
            selection: NSRange?
        ) {
            guard let host, let textView else { return }
            synchronizing = true
            defer { synchronizing = false }

            lastFocusToken = token
            lastKind = kind
            lastBodyFontSize = parent.bodyFontSize
            lastFindHighlights = parent.findHighlights
            pendingSelection = selection
            pendingFocus = true
            focusAttemptCount = 0
            focusRequestGeneration &+= 1
            focusScheduledAttemptID &+= 1
            let focusGeneration = focusRequestGeneration
            focusRetryWork?.cancel()
            focusRetryWork = nil
            lastEmitted = nil
            lastCommitted = nil
            lastReportedHeight = nil
            compositionPending = false
            liveWork?.cancel()
            measureWork?.cancel()

            let undo = textView.undoManager
            let reenableUndo = undo?.isUndoRegistrationEnabled == true
            if reenableUndo { undo?.disableUndoRegistration() }
            textView.string = source
            if reenableUndo { undo?.enableUndoRegistration() }
            undo?.removeAllActions()

            host.configureChrome(for: kind)
            host.setHorizontalScrolling(Self.scrollsHorizontally(kind))
            applyHighlight()
            applyAccessibility()
            applyPendingSelection()
            scheduleMeasurement()
            scheduleLiveChange()
            DispatchQueue.main.async { [weak self] in
                self?.focusIfPossible(expectedGeneration: focusGeneration)
            }
        }

        func update(
            source: String,
            kind: MarkdownBlockKind,
            token: AnyHashable,
            selection: NSRange?
        ) {
            guard let host else { return }
            applyAccessibility()
            if lastFocusToken != token {
                load(source: source, kind: kind, token: token, selection: selection)
                return
            }
            let kindChanged = lastKind != kind
            let fontSizeChanged = lastBodyFontSize != parent.bodyFontSize
            let highlightsChanged = lastFindHighlights != parent.findHighlights
            guard kindChanged || fontSizeChanged || highlightsChanged else { return }
            lastKind = kind
            lastBodyFontSize = parent.bodyFontSize
            lastFindHighlights = parent.findHighlights
            if kindChanged || fontSizeChanged {
                host.configureChrome(for: kind)
                host.setHorizontalScrolling(Self.scrollsHorizontally(kind))
                applyHighlight()
                scheduleMeasurement()
            } else {
                applyFindHighlights()
            }
        }

        func teardown() {
            liveWork?.cancel()
            measureWork?.cancel()
            pendingFocus = false
            focusAttemptCount = 0
            focusRequestGeneration &+= 1
            focusScheduledAttemptID &+= 1
            focusRetryWork?.cancel()
            focusRetryWork = nil
            lifecycleBridge?.detach(self)
            lifecycleBridge = nil
            textView?.delegate = nil
            textView?.onKeyEvent = nil
            textView?.onEscape = nil
            textView?.onCompositionEnded = nil
            host?.onLayout = nil
            host?.onWindowAttached = nil
        }

        private func configureTextView(_ textView: BlockSourceTextView) {
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.isEditable = true
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.backgroundColor = .clear
            textView.textColor = DesignTokens.bodyText
            textView.font = NSFont.systemFont(ofSize: parent.bodyFontSize)
            textView.insertionPointColor = DesignTokens.accent
            textView.textContainerInset = NSSize(width: 3, height: 1)
            textView.textContainer?.lineFragmentPadding = 0
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.typingAttributes = BlockSourceHighlighter.baseTypingAttributes(
                kind: parent.blockKind,
                source: parent.initialSource,
                bodyFontSize: parent.bodyFontSize
            )
            textView.placeholderText = "输入 Markdown… 试试 # 标题、- 列表、``` 代码"
        }

        private static func scrollsHorizontally(_ kind: MarkdownBlockKind) -> Bool {
            kind == .code || kind == .table
        }

        private func applyPendingSelection() {
            guard let textView else { return }
            let length = (textView.string as NSString).length
            let requested = pendingSelection
                ?? NSRange(location: length, length: 0)
            let location = min(max(0, requested.location), length)
            let range = NSRange(
                location: location,
                length: min(max(0, requested.length), length - location)
            )
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            pendingSelection = nil
        }

        private func focusIfPossible(expectedGeneration: Int? = nil) {
            if let expectedGeneration,
               expectedGeneration != focusRequestGeneration {
                return
            }
            if focusRetryWork != nil {
                return
            }
            guard pendingFocus, let textView, let window = textView.window else { return }
            guard AppEnv.allowsAutomaticFocusRequests else {
                pendingFocus = false
                applyPendingSelection()
                scheduleLiveChange()
                return
            }
            let accepted = window.makeFirstResponder(textView)
            guard accepted, window.firstResponder === textView else {
                focusAttemptCount += 1
                guard focusAttemptCount < 4 else {
                    pendingFocus = false
                    applyPendingSelection()
                    scheduleLiveChange()
                    return
                }
                focusRetryWork?.cancel()
                focusScheduledAttemptID &+= 1
                let scheduledAttemptID = focusScheduledAttemptID
                let generation = focusRequestGeneration
                let work = DispatchWorkItem { [weak self] in
                    self?.runScheduledFocusAttempt(
                        generation: generation,
                        attemptID: scheduledAttemptID
                    )
                }
                focusRetryWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.01,
                    execute: work
                )
                return
            }
            pendingFocus = false
            focusAttemptCount = 0
            focusRetryWork?.cancel()
            focusRetryWork = nil
            applyPendingSelection()
            scheduleLiveChange()
        }

        private func runScheduledFocusAttempt(
            generation: Int,
            attemptID: Int
        ) {
            guard generation == focusRequestGeneration,
                  attemptID == focusScheduledAttemptID else {
                return
            }
            focusRetryWork = nil
            focusIfPossible(expectedGeneration: generation)
        }

        private func handleKeyEvent(_ event: NSEvent) -> Bool {
            guard let textView, !textView.hasMarkedText() else { return false }
            guard let result = parent.onKeyCommand(
                event,
                textView.string,
                textView.selectedRange()
            ) else {
                return false
            }
            guard Self.isValid(
                selection: result.selection,
                in: result.replacementSource
            ) else {
                assertionFailure("Key command returned an invalid UTF-16 selection")
                return true
            }
            guard applyCommandResult(result, to: textView) else { return true }

            measureWork?.cancel()
            measureHeight()
            liveWork?.cancel()
            lastEmitted = nil
            emitLiveChangeNow()
            if let action = result.boundaryAction {
                parent.onBoundaryAction(action)
            }
            return true
        }

        private func applyCommandResult(
            _ result: MarkdownEditingResult,
            to textView: BlockSourceTextView
        ) -> Bool {
            applyingCommandResult = true
            defer { applyingCommandResult = false }

            if textView.string != result.replacementSource {
                guard let storage = textView.textStorage else { return false }
                let currentRange = NSRange(
                    location: 0,
                    length: (textView.string as NSString).length
                )
                guard textView.shouldChangeText(
                    in: currentRange,
                    replacementString: result.replacementSource
                ) else {
                    return false
                }
                storage.replaceCharacters(
                    in: currentRange,
                    with: result.replacementSource
                )
                textView.didChangeText()
            }

            textView.setSelectedRange(result.selection)
            textView.scrollRangeToVisible(result.selection)
            applyHighlight()
            return true
        }

        private static func isValid(
            selection: NSRange,
            in source: String
        ) -> Bool {
            let sourceLength = (source as NSString).length
            guard selection.location >= 0,
                  selection.length >= 0,
                  selection.location <= sourceLength,
                  selection.length <= sourceLength - selection.location else {
                return false
            }
            return Range(selection, in: source) != nil
        }

        private func commitAndResign() {
            guard let textView else { return }
            let window = textView.window
            commit()
            window?.makeFirstResponder(nil)
        }

        fileprivate func liveSnapshot() -> BlockSourceEditorBridge.Snapshot? {
            guard let textView else { return nil }
            return BlockSourceEditorBridge.Snapshot(
                source: textView.string,
                selection: textView.selectedRange(),
                hasMarkedText: textView.hasMarkedText()
            )
        }

        fileprivate func flushForLifecycleBoundary() -> BlockSourceEditorBridge.Snapshot? {
            commit()
            return liveSnapshot()
        }

        fileprivate func applyFindReplacement(
            source: String,
            selection: NSRange
        ) -> BlockSourceEditorBridge.Snapshot? {
            guard let textView,
                  Self.isValid(selection: selection, in: source) else {
                return nil
            }
            if textView.hasMarkedText() { textView.unmarkText() }
            compositionPending = false
            guard applyCommandResult(
                MarkdownEditingResult(
                    replacementSource: source,
                    selection: selection,
                    boundaryAction: nil
                ),
                to: textView
            ) else {
                return nil
            }
            liveWork?.cancel()
            lastEmitted = nil
            emitLiveChangeNow()
            scheduleMeasurement()
            return liveSnapshot()
        }

        private func commit() {
            guard let textView else { return }
            if textView.hasMarkedText() { textView.unmarkText() }
            compositionPending = false
            applyHighlight()
            liveWork?.cancel()
            emitLiveChangeNow()
            let snapshot = Snapshot(textView)
            guard snapshot != lastCommitted else { return }
            lastCommitted = snapshot
            parent.onCommit(snapshot.source, snapshot.selection)
        }

        private func compositionEnded() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView,
                      !textView.hasMarkedText() else { return }
                self.compositionPending = false
                self.applyHighlight()
                self.scheduleMeasurement()
                self.scheduleLiveChange()
            }
        }

        private func applyHighlight() {
            guard let textView,
                  let storage = textView.textStorage,
                  !textView.hasMarkedText() else { return }
            let selection = textView.selectedRange()
            let undo = textView.undoManager
            let reenableUndo = undo?.isUndoRegistrationEnabled == true
            if reenableUndo { undo?.disableUndoRegistration() }
            let kind = lastKind ?? parent.blockKind
            BlockSourceHighlighter.apply(
                to: storage,
                kind: kind,
                bodyFontSize: parent.bodyFontSize
            )
            if reenableUndo { undo?.enableUndoRegistration() }
            textView.typingAttributes = BlockSourceHighlighter.baseTypingAttributes(
                kind: kind,
                source: textView.string,
                bodyFontSize: parent.bodyFontSize
            )
            let length = (textView.string as NSString).length
            if selection.location <= length {
                textView.setSelectedRange(NSRange(
                    location: selection.location,
                    length: min(selection.length, length - selection.location)
                ))
            }
            applyAccessibility()
            applyFindHighlights()
        }

        private func applyFindHighlights() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let fullRange = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            for highlight in parent.findHighlights {
                guard highlight.range.location >= 0,
                      highlight.range.length > 0,
                      NSMaxRange(highlight.range) <= length else { continue }
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: highlight.isCurrent
                        ? DesignTokens.accentStrong
                        : DesignTokens.accentSoft,
                    forCharacterRange: highlight.range
                )
            }
            layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        }

        private func applyAccessibility() {
            guard let textView else { return }
            textView.identifier = NSUserInterfaceItemIdentifier(parent.accessibilityIdentifier)
            textView.setAccessibilityIdentifier(parent.accessibilityIdentifier)
            textView.setAccessibilityLabel("Markdown 源代码编辑器")
            textView.setAccessibilityHelp("编辑当前 Markdown 区块。按 Escape 完成编辑。")
        }

        private func scheduleLiveChange() {
            guard !synchronizing else { return }
            liveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.emitLiveChangeNow() }
            liveWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func emitLiveChangeNow() {
            guard let textView else { return }
            if textView.hasMarkedText() {
                compositionPending = true
                return
            }
            let snapshot = Snapshot(textView)
            guard snapshot != lastEmitted else { return }
            lastEmitted = snapshot
            applyAccessibility()
            parent.onChange(snapshot.source, snapshot.selection)
        }

        private func scheduleMeasurement() {
            measureWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.measureHeight() }
            measureWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func measureHeight() {
            guard !isMeasuring, let host, let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            isMeasuring = true
            defer { isMeasuring = false }

            let availableWidth = max(40, host.editorViewportWidth)
            let inset = textView.textContainerInset
            if host.scrollsHorizontally {
                textView.isHorizontallyResizable = true
                textContainer.widthTracksTextView = false
                textContainer.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            } else {
                textView.isHorizontallyResizable = false
                textContainer.widthTracksTextView = true
                textContainer.containerSize = NSSize(
                    width: max(1, availableWidth - inset.width * 2),
                    height: .greatestFiniteMagnitude
                )
            }

            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let height = max(34, ceil(used.height + inset.height * 2))
            let width = host.scrollsHorizontally
                ? max(availableWidth, ceil(used.width + inset.width * 2))
                : availableWidth
            textView.setFrameSize(NSSize(width: width, height: height))
            host.updateMeasuredHeight(height)
            if lastReportedHeight == nil
                || abs((lastReportedHeight ?? height) - height) >= 0.5 {
                lastReportedHeight = height
                parent.onHeightChange?(height)
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !synchronizing, !applyingCommandResult,
                  let textView else { return }
            textView.needsDisplay = true
            scheduleMeasurement()
            if textView.hasMarkedText() {
                compositionPending = true
                return
            }
            compositionPending = false
            applyHighlight()
            scheduleLiveChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !synchronizing, !applyingCommandResult,
                  let textView else { return }
            if textView.hasMarkedText() {
                compositionPending = true
                return
            }
            scheduleLiveChange()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !synchronizing else { return }
            commit()
        }
    }
}

// MARK: - AppKit host

final class BlockSourceTextView: NSTextView {
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    var onCompositionEnded: (() -> Void)?
    var placeholderText = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerInset.width,
            y: textContainerInset.height
        )
        placeholderText.draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(
                    ofSize: BlockSourceHighlighter.defaultBodyFontSize
                ),
                .foregroundColor: DesignTokens.disabledText,
            ]
        )
    }

    override func keyDown(with event: NSEvent) {
        // While an input method owns marked text, it must receive every key first.
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if onKeyEvent?(event) == true { return }
        super.keyDown(with: event)
    }

    override func unmarkText() {
        let hadMarkedText = hasMarkedText()
        super.unmarkText()
        if hadMarkedText { onCompositionEnded?() }
    }
}

final class BlockSourceEditorHostView: NSView {
    static let backgroundTransitionDuration: TimeInterval = 0.13

    private static let codeCardBorder = NSColor(
        srgbRed: 233 / 255,
        green: 233 / 255,
        blue: 239 / 255,
        alpha: 1
    )

    let textView: BlockSourceTextView
    let scrollView = NSScrollView(frame: .zero)
    private let sourceCard = NSView(frame: .zero)
    private let amberRail = NSView(frame: .zero)
    private let cardAccentRail = NSView(frame: .zero)
    private var blockKind: MarkdownBlockKind = .paragraph
    private var hasAnimatedEntryBackground = false
    private(set) var scrollsHorizontally = false
    private var measuredHeight: CGFloat = 34
    var onLayout: (() -> Void)?
    var onWindowAttached: (() -> Void)?

    init(textView: BlockSourceTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        sourceCard.wantsLayer = true
        sourceCard.layer?.backgroundColor = DesignTokens.codeBackground.cgColor
        sourceCard.layer?.borderColor = Self.codeCardBorder.cgColor
        sourceCard.layer?.borderWidth = 1
        sourceCard.layer?.cornerRadius = 6
        sourceCard.layer?.masksToBounds = true
        sourceCard.isHidden = true
        addSubview(sourceCard)

        amberRail.wantsLayer = true
        amberRail.layer?.backgroundColor = DesignTokens.accent.cgColor
        amberRail.layer?.cornerRadius = 1.5
        addSubview(amberRail)

        cardAccentRail.wantsLayer = true
        cardAccentRail.layer?.backgroundColor = DesignTokens.accent.cgColor
        cardAccentRail.isHidden = true
        addSubview(cardAccentRail)

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    var editorViewportWidth: CGFloat {
        max(0, scrollView.contentSize.width)
    }

    /// Mirrors the three source-editing surfaces from the prototype without
    /// replacing the native NSTextView: plain blocks use the external amber
    /// rail, code uses that rail plus an inset code card, and table source puts
    /// the amber rail inside its code card.
    func configureChrome(for kind: MarkdownBlockKind) {
        blockKind = kind
        let usesCard = kind == .code || kind == .table
        sourceCard.isHidden = !usesCard
        amberRail.isHidden = kind == .table
        cardAccentRail.isHidden = kind != .table
        textView.textContainerInset = usesCard
            ? NSSize(width: 14, height: 12)
            : NSSize(width: 3, height: 1)
        textView.needsDisplay = true
        needsLayout = true
        onLayout?()
    }

    func setHorizontalScrolling(_ enabled: Bool) {
        guard scrollsHorizontally != enabled else { return }
        scrollsHorizontally = enabled
        scrollView.hasHorizontalScroller = enabled
        scrollView.horizontalScrollElasticity = enabled ? .automatic : .none
        textView.isHorizontallyResizable = enabled
        textView.textContainer?.widthTracksTextView = !enabled
        if !enabled {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        needsLayout = true
        onLayout?()
    }

    func updateMeasuredHeight(_ height: CGFloat) {
        guard abs(measuredHeight - height) >= 0.5 else { return }
        measuredHeight = height
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            animateEntryBackgroundIfNeeded()
            onWindowAttached?()
        }
    }

    /// Continue the rendered block's hover wash into the newly mounted native
    /// editor and let it settle to the editor background over the prototype's
    /// 130 ms interval. The NSTextView stays live throughout the animation.
    private func animateEntryBackgroundIfNeeded() {
        guard !hasAnimatedEntryBackground else { return }
        hasAnimatedEntryBackground = true
        guard !MotionPolicy.systemReduceMotion, blockKind != .code, blockKind != .table,
              let layer else { return }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = NSColor.black.withAlphaComponent(0.035).cgColor
        animation.toValue = NSColor.clear.cgColor
        animation.duration = Self.backgroundTransitionDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "mv-source-background-entry")
    }

    override func layout() {
        super.layout()
        amberRail.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
        let usesCard = blockKind == .code || blockKind == .table
        let editorLeading = usesCard ? 14.0 : 11.0
        let editorFrame = NSRect(
            x: editorLeading,
            y: 0,
            width: max(0, bounds.width - editorLeading),
            height: bounds.height
        )
        sourceCard.frame = usesCard ? editorFrame : .zero
        cardAccentRail.frame = NSRect(
            x: editorFrame.minX,
            y: 0,
            width: 3,
            height: bounds.height
        )
        scrollView.frame = editorFrame
        onLayout?()
    }
}
