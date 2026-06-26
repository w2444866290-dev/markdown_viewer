import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSVisualEffectView` — the AppKit equivalent of the
/// spec's `backdrop-filter: blur(...)` (ui/Markdown Viewer.dc.html L135 / L227).
/// Used behind the ⌘K backdrop and the ⌘F / ⌘K panels; a translucent color is
/// layered on top to keep the spec's tint (e.g. white@0.97, #F8F8FA@0.6).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
