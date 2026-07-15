import SwiftUI
import AppKit

/// Borderless panel that can become key (so the palette's search field accepts
/// typing) without activating/deactivating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PalettePresentationMode: String, Equatable {
    case childPanel = "child-panel"
    case inlinePassive = "inline-passive"
}

enum PalettePresentationPolicy {
    static func mode(
        isVisualTest: Bool,
        launchesForeground: Bool,
        hasActivated: Bool
    ) -> PalettePresentationMode {
        if isVisualTest, !launchesForeground, !hasActivated {
            return .inlinePassive
        }
        return .childPanel
    }
}

/// Hosts the command palette in a separate transparent borderless panel.
/// The panel can become key for search-field input while the SwiftUI palette root
/// supplies the translucent veil over the unchanged parent content.
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    final class Coordinator {
        private var panel: KeyablePanel?
        private weak var parentWindow: NSWindow?
        private var observationTokens: [NSObjectProtocol] = []

        func sync(open: Bool, anchor: NSView, docManager: DocumentManager) {
            guard open else {
                closePanel(restoreParentKey: true)
                return
            }
            guard let parent = anchor.window else { return }

            if let panel {
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                    installObservers(parent: parent, docManager: docManager)
                }
                parentWindow = parent
                matchPanelFrame(to: parent)
                if !panel.isVisible { panel.orderFront(nil) }
                return
            }

            let newPanel = buildPanel(docManager: docManager)
            panel = newPanel
            parentWindow = parent
            matchPanelFrame(to: parent)
            parent.addChildWindow(newPanel, ordered: .above)
            installObservers(parent: parent, docManager: docManager)
            if AppEnv.allowsAutomaticFocusRequests {
                newPanel.makeKeyAndOrderFront(nil)
            } else {
                newPanel.orderFront(nil)
            }
        }

        func tearDown() {
            closePanel(restoreParentKey: false)
        }

        private func matchPanelFrame(to parent: NSWindow) {
            guard let panel, !NSEqualRects(panel.frame, parent.frame) else { return }
            panel.setFrame(parent.frame, display: true)
        }

        private func installObservers(parent: NSWindow, docManager: DocumentManager) {
            removeObservers()
            let center = NotificationCenter.default
            let frameNotifications: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observationTokens.append(contentsOf: frameNotifications.map { name in
                center.addObserver(forName: name, object: parent, queue: .main) { [weak self, weak parent] _ in
                    guard let parent else { return }
                    self?.matchPanelFrame(to: parent)
                }
            })
            observationTokens.append(
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: parent,
                    queue: .main
                ) { [weak self, weak docManager] _ in
                    self?.closePanel(restoreParentKey: false)
                    Task { @MainActor [weak docManager] in
                        docManager?.closeCommandPalette()
                    }
                }
            )
            observationTokens.append(
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self, weak docManager] _ in
                    self?.closePanel(restoreParentKey: false)
                    Task { @MainActor [weak docManager] in
                        docManager?.closeCommandPalette()
                    }
                }
            )
        }

        private func closePanel(restoreParentKey: Bool) {
            removeObservers()
            guard let panel else {
                parentWindow = nil
                return
            }
            let parent = panel.parent ?? parentWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            parentWindow = nil

            guard restoreParentKey, NSApp.isActive, let parent, parent.isVisible else { return }
            DispatchQueue.main.async { [weak self, weak parent] in
                guard self?.panel == nil else { return }
                parent?.makeKey()
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observationTokens.forEach { center.removeObserver($0) }
            observationTokens.removeAll()
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
            p.collectionBehavior = [.fullScreenAuxiliary]

            // A fresh hosting view resets palette query and selection on each open.
            // The SwiftUI root supplies the translucent veil and interaction surface.
            let host = NSHostingView(rootView: CommandPaletteView().environmentObject(docManager))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.autoresizingMask = [.width, .height]

            p.contentView = host
            return p
        }
    }
}
