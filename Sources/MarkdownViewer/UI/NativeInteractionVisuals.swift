import AppKit
import SwiftUI

/// AppKit owns cursor resolution for native windows. Registering a cursor rect
/// keeps the pointer stable when SwiftUI rebuilds a button label or presents a
/// tooltip, without mutating the process-wide NSCursor push/pop stack.
private struct NativeCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NativeCursorRegionView {
        NativeCursorRegionView(cursor: cursor)
    }

    func updateNSView(_ view: NativeCursorRegionView, context: Context) {
        view.cursor = cursor
    }
}

private final class NativeCursorRegionView: NSView {
    private var trackingArea: NSTrackingArea?

    var cursor: NSCursor {
        didSet {
            guard cursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

}

private struct NativeCursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content.overlay {
            NativeCursorRegion(cursor: cursor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Mirrors the prototype's `:focus-visible` treatment. A ring is shown only
/// when focus arrives through Tab or Shift-Tab, not when a button is clicked.
private struct KeyboardFocusVisibleModifier: ViewModifier {
    let cornerRadius: CGFloat

    @FocusState private var focused: Bool
    @State private var pendingKeyboardTraversal = false
    @State private var ringVisible = false
    @State private var eventMonitor: Any?

    private let ringColor = Color(red: 0, green: 122 / 255, blue: 1).opacity(0.45)

    func body(content: Content) -> some View {
        content
            .focusable(true)
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 1)
                    .stroke(ringVisible ? ringColor : .clear, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .onChange(of: focused) { isFocused in
                ringVisible = isFocused && pendingKeyboardTraversal
                if isFocused { pendingKeyboardTraversal = false }
            }
            .onAppear { installEventMonitor() }
            .onDisappear { removeEventMonitor() }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { event in
            if event.type == .keyDown, event.keyCode == 48 {
                pendingKeyboardTraversal = true
                DispatchQueue.main.async {
                    pendingKeyboardTraversal = false
                }
            } else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                pendingKeyboardTraversal = false
                if focused { ringVisible = false }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        pendingKeyboardTraversal = false
        ringVisible = false
    }
}

extension View {
    func mvNativeCursor(_ cursor: NSCursor) -> some View {
        modifier(NativeCursorModifier(cursor: cursor))
    }

    func mvFocusVisible(cornerRadius: CGFloat = 6) -> some View {
        modifier(KeyboardFocusVisibleModifier(cornerRadius: cornerRadius))
    }
}
