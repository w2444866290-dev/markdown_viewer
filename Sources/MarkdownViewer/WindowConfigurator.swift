import SwiftUI
import AppKit

/// Sets isMovableByWindowBackground once the view is in a window.
struct MovableByBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window, !w.isMovableByWindowBackground {
            w.isMovableByWindowBackground = true
        }
    }
}
