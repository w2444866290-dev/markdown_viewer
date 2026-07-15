import AppKit
import SwiftUI

/// Observes the native NSScrollView that backs a SwiftUI ScrollView.
struct BlockScrollObserver: NSViewRepresentable {
    let initialY: CGFloat
    let onResolve: (NSScrollView) -> Void
    let onScroll: (_ y: CGFloat, _ progress: Double, _ isScrollActivity: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.onAttached = { [weak coordinator = context.coordinator] in
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(from: view)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var parent: BlockScrollObserver
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var restored = false
        private var activityTracker = ScrollActivityTracker()
        private var suppressActivity = false

        init(parent: BlockScrollObserver) {
            self.parent = parent
        }

        func attach(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      let scrollView = view.enclosingScrollView else { return }
                if self.scrollView !== scrollView {
                    self.detach()
                    self.scrollView = scrollView
                    scrollView.contentView.postsBoundsChangedNotifications = true
                    self.observer = NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: scrollView.contentView,
                        queue: .main
                    ) { [weak self] _ in self?.publish() }
                    self.parent.onResolve(scrollView)
                }
                self.restoreIfNeeded()
                self.publish(isScrollActivity: false)
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scrollView = nil
            activityTracker.reset()
            suppressActivity = false
        }

        private func restoreIfNeeded() {
            guard !restored, let scrollView else { return }
            restored = true
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                scrollView.layoutSubtreeIfNeeded()
                let viewport = scrollView.contentView.bounds.height
                let documentHeight = scrollView.documentView?.bounds.height ?? viewport
                let maximum = max(0, documentHeight - viewport)
                let y = min(max(0, self.parent.initialY), maximum)
                self.suppressActivity = true
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.publish(isScrollActivity: false)
                DispatchQueue.main.async { [weak self] in
                    self?.suppressActivity = false
                }
            }
        }

        private func publish(isScrollActivity activityOverride: Bool? = nil) {
            guard let scrollView else { return }
            let y = max(0, scrollView.contentView.bounds.origin.y)
            let viewport = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.bounds.height ?? viewport
            let maximum = max(0, documentHeight - viewport)
            let progress = maximum > 0 ? min(1, max(0, Double(y / maximum))) : 0
            let isScrollActivity: Bool
            if let activityOverride {
                _ = activityTracker.observe(y, suppressed: true)
                isScrollActivity = activityOverride
            } else {
                isScrollActivity = activityTracker.observe(
                    y,
                    suppressed: suppressActivity
                )
            }
            parent.onScroll(y, progress, isScrollActivity)
        }
    }
}

final class ObserverView: NSView {
    var onAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAttached?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onAttached?()
    }
}

final class WeakScrollViewBox {
    weak var scrollView: NSScrollView?
}
