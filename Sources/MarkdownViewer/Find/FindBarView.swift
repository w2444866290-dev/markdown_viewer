import SwiftUI
import AppKit

enum FindKeyboardAction: Equatable {
    case close
    case navigatePrevious
    case passThrough
}

enum FindKeyboardPolicy {
    static func action(
        forKeyCode keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        queryFieldFocused: Bool
    ) -> FindKeyboardAction {
        if keyCode == 53 { return .close }
        if (keyCode == 36 || keyCode == 76),
           queryFieldFocused,
           modifiers.contains(.shift) {
            return .navigatePrevious
        }
        return .passThrough
    }
}

/// Find/replace bar — spec: position absolute top 10px right 18px, blur backdrop.
struct FindBarView: View {
    @ObservedObject var state: FindState
    /// Drives focus on open — spec #9 (b)/(c): focus the field + select-all.
    @FocusState private var fieldFocused: Bool
    /// Local NSEvent monitor for Shift+Enter / Esc — spec #11 (design L919/L925).
    @State private var keyMonitor: Any?
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
                .accessibilityIdentifier("find-toggle-replace")
                .onHover { hoverChevron = $0 }

                // Search field — spec: 240×28, bg rgba(0,0,0,0.045), radius 6
                HStack(spacing: 8) {
                    TextField("查找", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .focused($fieldFocused)
                        .accessibilityIdentifier("find-query")
                        .onChange(of: state.query) { newValue in
                            state.onSearch?(newValue)
                        }
                        .onSubmit {
                            state.onNavigate?(1)
                        }
                        .background(FindFocusBridge(focusRequest: state.focusRequest))
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
                    ToggleChip(
                        "Aa",
                        identifier: "find-case-sensitive",
                        isOn: $state.caseSensitive
                    )
                        .onChange(of: state.caseSensitive) { _ in searchNow() }
                    ToggleChip(
                        "W",
                        identifier: "find-whole-word",
                        isOn: $state.wholeWord
                    )
                        .onChange(of: state.wholeWord) { _ in searchNow() }
                    ToggleChip(
                        ".*",
                        identifier: "find-regex",
                        isOn: $state.useRegex
                    )
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
                        .accessibilityIdentifier("find-previous")
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
                        .accessibilityIdentifier("find-next")
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
                .accessibilityIdentifier("find-close")
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
                        .accessibilityIdentifier("find-replacement")
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
                            .accessibilityIdentifier("find-replace-current")
                            .onHover { hoverReplace = $0 }
                        Button("全部替换") { state.onReplaceAll?() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 58/255, green: 58/255, blue: 60/255))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.black.opacity(hoverReplaceAll ? 0.08 : 0.05))
                            .cornerRadius(6)
                            .accessibilityIdentifier("find-replace-all")
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
        .debugVisualAnchor("find-panel-frame")
        .padding(.top, 10)
        .padding(.trailing, 18)
        // Spec #9 (b)/(c): every openFind() bumps focusRequest → focus the field
        // and select-all so the prior query is ready to overtype. requestAnimationFrame
        // in the spec maps to a main-async hop here (let SwiftUI commit focus first).
        .onChange(of: state.focusRequest) { _ in
            focusAndSelectAll()
        }
        .onAppear {
            focusAndSelectAll()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func searchNow() {
        state.onSearch?(state.query)
    }

    private func focusAndSelectAll() {
        guard AppEnv.allowsAutomaticFocusRequests else { return }
        fieldFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    // Spec #11 (design L919/L925): Shift+Enter in the query moves backward.
    // Esc closes the open find panel regardless of which document control owns focus.
    // The macOS 13 target rules out `.onKeyPress`, so use a local key monitor while
    // this panel exists. Plain Enter remains handled by SwiftUI `.onSubmit`.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            switch FindKeyboardPolicy.action(
                forKeyCode: event.keyCode,
                modifiers: event.modifierFlags,
                queryFieldFocused: fieldFocused
            ) {
            case .close:
                state.closeFind()
                return nil
            case .navigatePrevious:
                state.onNavigate?(-1)
                return nil
            case .passThrough:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

struct FindFocusBridge: NSViewRepresentable {
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        guard AppEnv.allowsAutomaticFocusRequests else { return }
        requestFocus(from: nsView, remainingAttempts: 4)
    }

    static func findQueryField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "查找" {
            return field
        }
        for child in view.subviews {
            if let match = findQueryField(in: child) { return match }
        }
        return nil
    }

    private func requestFocus(from view: NSView, remainingAttempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            guard let window = view.window, let contentView = window.contentView,
                  let field = Self.findQueryField(in: contentView) else {
                guard remainingAttempts > 1 else { return }
                requestFocus(from: view, remainingAttempts: remainingAttempts - 1)
                return
            }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator {
        var lastFocusRequest = -1
    }
}

// MARK: - Toggle chip

private struct ToggleChip: View {
    let label: String
    let identifier: String
    @Binding var isOn: Bool
    /// Hover is an ADDITIONAL cue on top of the ON/OFF states - spec (design
    /// L143-145) hover = background rgba(0,0,0,0.05). Shown only for an OFF chip;
    /// an ON chip already reads via its stronger 0.10 fill + ring, left intact.
    @State private var hovered = false

    init(_ label: String, identifier: String, isOn: Binding<Bool>) {
        self.label = label
        self.identifier = identifier
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
                        .fill(isOn
                            ? Color.black.opacity(0.10)
                            : (hovered ? Color.black.opacity(0.05) : Color.clear))
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
        .accessibilityIdentifier(identifier)
        .onHover { hovered = $0 }
    }
}
