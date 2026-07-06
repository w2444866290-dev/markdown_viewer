import SwiftUI
import AppKit

/// Borderless panel that can become key (so the palette's search field accepts
/// typing) without activating/deactivating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the ⌘K command palette in a SEPARATE borderless window so its backdrop
/// can use `NSVisualEffectView(.behindWindow)` — the only reliable way to blur
/// the main window's content. The editor is a layer-backed hosted `NSTextView`;
/// in-window blur (`.withinWindow` / SwiftUI `Material`) can't sample it, so it
/// rendered flat. A separate window's `.behindWindow` blur samples the composited
/// main window at the window-server level (exactly how Spotlight / menus do it).
///
/// A zero-size representable lives in `ContentView`'s background just to reach the
/// host window and drive the panel from `docManager.paletteOpen`.
struct PaletteBlurHost: NSViewRepresentable {
    @ObservedObject var docManager: DocumentManager

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(open: docManager.paletteOpen, anchor: nsView, docManager: docManager)
    }

    final class Coordinator {
        private var panel: KeyablePanel?

        func sync(open: Bool, anchor: NSView, docManager: DocumentManager) {
            if open {
                guard panel == nil, let parent = anchor.window else { return }
                let p = buildPanel(docManager: docManager)
                p.setFrame(parent.frame, display: true)
                parent.addChildWindow(p, ordered: .above)
                p.makeKeyAndOrderFront(nil)
                panel = p
            } else if let p = panel {
                p.parent?.removeChildWindow(p)
                p.orderOut(nil)
                panel = nil
            }
        }

        private func buildPanel(docManager: DocumentManager) -> KeyablePanel {
            let p = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = false

            let effect = NSVisualEffectView()
            effect.material = .fullScreenUI
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = NSAppearance(named: .aqua) // keep the frost light
            effect.autoresizingMask = [.width, .height]

            // Fresh hosting view each open → palette state (query/selection) resets.
            let host = NSHostingView(rootView: CommandPaletteView().environmentObject(docManager))
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)

            p.contentView = effect
            return p
        }
    }
}
