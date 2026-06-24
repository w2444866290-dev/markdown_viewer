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

    func toggleOpen() { isOpen.toggle() }
}
