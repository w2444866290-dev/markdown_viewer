import SwiftUI
import AppKit

/// Configures the NSWindow to match the old AppKit setup:
/// hidden title, transparent titlebar, full-size content, movable by background.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
