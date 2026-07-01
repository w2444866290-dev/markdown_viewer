import SwiftUI
import AppKit

/// Find/replace bar — spec: position absolute top 10px right 18px, blur backdrop.
struct FindBarView: View {
    @ObservedObject var state: FindState
    /// Drives focus on open — spec #9 (b)/(c): focus the field + select-all.
    @FocusState private var fieldFocused: Bool
    /// Tracks focus on the replace field so the key monitor can route Esc there.
    @FocusState private var replaceFocused: Bool
    /// Local NSEvent monitor for Shift+Enter / Esc — spec #11 (design L919/L925).
    @State private var keyMonitor: Any?
    /// The query/options signature that produced the currently-highlighted matches.
    /// Search now fires on RETURN (not per-keystroke), so we need to know whether the
    /// field's contents have changed since the last search: if they have, Return runs
    /// a fresh search + jumps to the first match; if they haven't, Return navigates to
    /// the next match (standard cycling). `nil` means "nothing searched yet".
    @State private var lastSearchedSignature: SearchSignature?
    @State private var hoverChevron = false
    @State private var hoverPrev = false
    @State private var hoverNext = false
    @State private var hoverClose = false
    @State private var hoverReplace = false
    @State private var hoverReplaceAll = false

    private var canNav: Bool { !state.isError && state.matchCount > 0 }

    /// Spec: style-hover="background: rgba(0,0,0,0.05)" on panel buttons.
    private static let hoverFill = Color.black.opacity(0.05)

    /// Spec #12 (design L138): find/replace input bg = rgba(0,0,0,0.045). LOCAL to
    /// this view — the shared DesignTokens.fieldFill is used by other views, so we
    /// don't mutate it here.
    private static let inputFill = Color.black.opacity(0.045)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Chevron toggle — spec: 20×28, radius 6
                Button(action: { state.showReplace.toggle() }) {
                    Text(state.showReplace ? "▾" : "▸")
                        .font(.system(size: 9))
                        .foregroundColor(state.showReplace || hoverChevron
                            ? DesignTokens.swiftUI.secondaryText
                            : DesignTokens.swiftUI.placeholderText)
                        .frame(width: 20, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(state.showReplace || hoverChevron ? Self.hoverFill : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverChevron = $0 }

                // Search field — spec: 240×28, bg rgba(0,0,0,0.045), radius 6
                HStack(spacing: 8) {
                    TextField("查找", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .focused($fieldFocused)
                        .onChange(of: state.query) { newValue in
                            // Search fires on RETURN, not per-keystroke — this avoids the
                            // whole-document highlight recompute flash on every edit (worst
                            // when deleting broadens the query → more matches). The ONE
                            // exception: an empty query clears highlights immediately. That
                            // path (onSearch("")) clears incrementally and is cheap (no
                            // flash), and it stops stale highlights lingering while the
                            // field is empty.
                            if newValue.isEmpty { clearSearch() }
                        }
                        .onSubmit {
                            // Return in the find field: search if the query/options changed
                            // since the last search (compute matches + highlight + jump to
                            // first), otherwise go to the NEXT match (repeated Return cycles).
                            performSearch(navigateIfUnchanged: 1)
                        }
                    Text(state.displayText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(state.isError
                            ? DesignTokens.swiftUI.danger
                            : DesignTokens.swiftUI.statusText)
                }
                .padding(.horizontal, 9)
                .frame(width: 240, height: 28)
                .background(Self.inputFill)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            state.isError
                                ? Color(red: 199/255, green: 72/255, blue: 46/255).opacity(0.45)
                                : Color.clear,
                            lineWidth: 1
                        )
                )

                // Toggle chips — spec: 22×22, radius 6
                HStack(spacing: 2) {
                    ToggleChip("Aa", isOn: $state.caseSensitive)
                        .onChange(of: state.caseSensitive) { _ in searchNow() }
                    ToggleChip("W", isOn: $state.wholeWord)
                        .onChange(of: state.wholeWord) { _ in searchNow() }
                    ToggleChip(".*", isOn: $state.useRegex)
                        .onChange(of: state.useRegex) { _ in searchNow() }
                    // Toggling an option is a single deliberate action (not per-keystroke),
                    // so re-running the search immediately is fine — no flash concern.
                }

                // Separator
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 16)

                // Nav buttons — spec: 24×24, radius 6, color depends on canNav
                HStack(spacing: 2) {
                    Button("↑") { state.onNavigate?(-1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(canNav
                            ? DesignTokens.swiftUI.secondaryText
                            : Color(red: 209/255, green: 209/255, blue: 214/255))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(canNav && hoverPrev ? Self.hoverFill : .clear)
                        )
                        .allowsHitTesting(canNav)
                        .onHover { hoverPrev = $0 }
                    Button("↓") { state.onNavigate?(1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(canNav
                            ? DesignTokens.swiftUI.secondaryText
                            : Color(red: 209/255, green: 209/255, blue: 214/255))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(canNav && hoverNext ? Self.hoverFill : .clear)
                        )
                        .allowsHitTesting(canNav)
                        .onHover { hoverNext = $0 }
                }

                // Separator
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 16)

                // Close — spec: 24×24, color #aeaeb2, hover #1d1d1f.
                // Spec L907 closeFind: also resets query/counts/replace + clears highlights.
                Button(action: { state.closeFind() }) {
                    Text("×")
                        .font(.system(size: 14))
                        .foregroundColor(hoverClose
                            ? DesignTokens.swiftUI.titleText
                            : DesignTokens.swiftUI.placeholderText)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hoverClose ? Self.hoverFill : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverClose = $0 }
            }

            // Replace row
            if state.showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20)
                    TextField("替换为", text: $state.replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .focused($replaceFocused)
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(Self.inputFill)
                        .cornerRadius(6)
                        .onSubmit { state.onReplaceCurrent?() }
                    Spacer()
                    HStack(spacing: 4) {
                        Button("替换") { state.onReplaceCurrent?() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 58/255, green: 58/255, blue: 60/255))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.black.opacity(hoverReplace ? 0.08 : 0.05))
                            .cornerRadius(6)
                            .onHover { hoverReplace = $0 }
                        Button("全部替换") { state.onReplaceAll?() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 58/255, green: 58/255, blue: 60/255))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.black.opacity(hoverReplaceAll ? 0.08 : 0.05))
                            .cornerRadius(6)
                            .onHover { hoverReplaceAll = $0 }
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(6)
        .background(
            // spec L135: rgba(255,255,255,0.97) + backdrop blur(8px) → frosted panel.
            // SwiftUI has no real backdrop blur; we approximate with an .ultraThinMaterial
            // base (the blur) tinted by a near-opaque white at 0.97 (the spec's white veil).
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 8)
        )
        .padding(.top, 10)
        .padding(.trailing, 18)
        // Spec #9 (b)/(c): every openFind() bumps focusRequest → focus the field
        // and select-all so the prior query is ready to overtype. requestAnimationFrame
        // in the spec maps to a main-async hop here (let SwiftUI commit focus first).
        .onChange(of: state.focusRequest) { _ in
            focusAndSelectAll()
            // openFind() re-runs the search for a non-empty prior query, so record
            // that signature: a Return without editing then navigates (matches exist)
            // instead of firing a dead re-search. Empty → nothing searched.
            lastSearchedSignature = state.query.isEmpty ? nil : currentSignature
        }
        .onAppear {
            focusAndSelectAll()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    /// The query + option combination that a search ran against. When Return is
    /// pressed we compare the field's current values to the last-searched signature:
    /// equal → the matches are already computed, so navigate; different → search.
    private struct SearchSignature: Equatable {
        var query: String
        var caseSensitive: Bool
        var wholeWord: Bool
        var useRegex: Bool
    }

    private var currentSignature: SearchSignature {
        SearchSignature(
            query: state.query,
            caseSensitive: state.caseSensitive,
            wholeWord: state.wholeWord,
            useRegex: state.useRegex
        )
    }

    /// Return in the find field. If the query/options changed since the last search,
    /// run the search — `onSearch` computes matches, highlights, and jumps to the
    /// first (currentIndex = 0). If unchanged (already searched), navigate by
    /// `navigateIfUnchanged` so repeated Return cycles through matches (Shift+Return
    /// passes -1). An empty query is a no-op (the onChange clear already handled it).
    private func performSearch(navigateIfUnchanged delta: Int) {
        guard !state.query.isEmpty else { return }
        if currentSignature == lastSearchedSignature {
            state.onNavigate?(delta)
        } else {
            state.onSearch?(state.query)
            lastSearchedSignature = currentSignature
        }
    }

    /// Option toggles (case/word/regex): a single deliberate action, so search now
    /// against the current query. Empty query is left to the onChange clear.
    private func searchNow() {
        guard !state.query.isEmpty else { return }
        state.onSearch?(state.query)
        lastSearchedSignature = currentSignature
    }

    /// Empty query: clear highlights immediately. `onSearch("")` clears incrementally
    /// (cheap, no flash) so stale highlights don't linger while the field is empty.
    /// Reset the searched signature so the next non-empty Return searches afresh.
    private func clearSearch() {
        state.onSearch?("")
        lastSearchedSignature = nil
    }

    private func focusAndSelectAll() {
        fieldFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    // Spec #11 (design L919/L925): the find input needs Shift+Enter = previous and
    // Esc = close; the replace input needs Esc = close. The macOS 13 target rules out
    // `.onKeyPress`, so we mirror SidebarView's local NSEvent.keyDown monitor and gate
    // it on the relevant field being focused. (Enter→next / Enter→replace are already
    // handled by SwiftUI `.onSubmit`, so we leave plain Enter to fall through.)
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Only intercept while one of the find/replace fields is focused.
            guard fieldFocused || replaceFocused else { return event }
            switch event.keyCode {
            case 53: // Esc — close from either field
                state.closeFind()
                return nil
            case 36, 76: // Return / keypad Enter
                // Shift+Enter in the find field = previous match. Route through the
                // same perform-search path so a first Shift+Return after typing also
                // searches (then navigates -1 on subsequent presses). Plain Enter
                // (next / replace) is left to SwiftUI's .onSubmit, so let it through.
                if fieldFocused && event.modifierFlags.contains(.shift) {
                    performSearch(navigateIfUnchanged: -1)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Toggle chip

private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(label)
                .font(.system(size: label == ".*" ? 12 : 11, design: .monospaced).bold())
                .foregroundColor(isOn
                    ? DesignTokens.swiftUI.titleText
                    : DesignTokens.swiftUI.placeholderText)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.black.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isOn ? Color.black.opacity(0.06) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
