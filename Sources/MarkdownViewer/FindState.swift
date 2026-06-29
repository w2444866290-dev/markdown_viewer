import SwiftUI

/// Shared state for the find/replace panel, bridging between
/// SwiftUI FindBarView and the AppKit NSTextView in EditorView.
/// All access is main-thread (SwiftUI views + AppKit delegate callbacks).
final class FindState: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
    @Published var replaceText = ""
    @Published var showReplace = false
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var useRegex = false

    @Published var matchCount = 0
    @Published var currentIndex = 0
    @Published var isError = false

    /// Bumped each time `openFind()` is called so FindBarView can drive its
    /// @FocusState (focus + select-all) on open — even when find is already
    /// visible. A plain `isOpen` toggle wouldn't re-fire when already true.
    @Published var focusRequest = 0

    /// Called by EditorView.Coordinator to perform the actual search.
    var onSearch: ((String) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onReplaceCurrent: (() -> Void)?
    var onReplaceAll: (() -> Void)?

    var displayText: String {
        if isError { return "无效正则" }
        if matchCount == 0 { return query.isEmpty ? "" : "无结果" }
        return "\(currentIndex + 1)/\(matchCount)"
    }

    /// Spec L901 `openFind`: opening must ALWAYS (a) set isOpen, (b) focus the
    /// find field, (c) select-all its text, (d) recompute matches if a prior
    /// query is non-empty. Never toggles closed — re-invoking while open simply
    /// re-focuses and re-selects (via the bumped focusRequest).
    func openFind() {
        isOpen = true
        focusRequest &+= 1            // FindBarView observes this to focus + select-all
        if !query.isEmpty { onSearch?(query) }
    }

    /// Spec L907 `closeFind`: closing resets the whole find/replace state and
    /// clears highlights (the latter via onSearch("") through FindController).
    func closeFind() {
        onSearch?("")                 // clears temporary highlights + match state
        isOpen = false
        query = ""
        matchCount = 0
        currentIndex = 0
        isError = false
        showReplace = false
    }

    /// Retained for the App.swift ⌘F menu binding and the findStateToggle
    /// closure. Per spec #9 ⌘F must ALWAYS open (never toggle closed), so this
    /// now routes to `openFind()` rather than flipping `isOpen`.
    func toggleOpen() { openFind() }
}
