import AppKit
import SwiftUI

/// Owns the native window actions behind the product's custom traffic controls.
///
/// The hidden-title-bar scene still creates AppKit's standard buttons, but their
/// inactive appearance does not match the authoritative product chrome. Keeping
/// the actions in AppKit preserves the normal close, minimize, and zoom behavior
/// while SwiftUI provides the product-owned visual surface.
@MainActor
final class WindowChromeController {
    static let shared = WindowChromeController()

    private weak var mainWindow: NSWindow?

    private init() {}

    func configure(window: NSWindow) {
        mainWindow = window
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }
    }

    func perform(_ action: NativeTrafficControlAction) {
        guard let window = mainWindow ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            return
        }

        switch action {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }
}

enum NativeTrafficControlAction: CaseIterable, Identifiable {
    case close
    case minimize
    case zoom

    var id: Self { self }

    var color: Color {
        switch self {
        case .close:
            Color(.sRGB, red: 1, green: 95 / 255, blue: 87 / 255, opacity: 1)
        case .minimize:
            Color(.sRGB, red: 254 / 255, green: 188 / 255, blue: 46 / 255, opacity: 1)
        case .zoom:
            Color(.sRGB, red: 40 / 255, green: 200 / 255, blue: 64 / 255, opacity: 1)
        }
    }

    var hoverSymbol: String {
        switch self {
        case .close: "×"
        case .minimize: "−"
        case .zoom: "+"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close: "关闭窗口"
        case .minimize: "最小化窗口"
        case .zoom: "缩放窗口"
        }
    }
}

/// Product-owned window controls matching the prototype at top:16, left:14.
/// Symbols appear for the whole control group on hover, matching the prototype's
/// `[data-traffic]:hover` selector rather than AppKit's per-button glyph behavior.
struct NativeTrafficControls: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NativeTrafficControlAction.allCases) { action in
                Button {
                    WindowChromeController.shared.perform(action)
                } label: {
                    Circle()
                        .fill(action.color)
                        .overlay {
                            Circle()
                                // CSS uses an inset 0.5 px shadow. `stroke` is
                                // centered on the path and leaves half of that
                                // shadow outside the control; `strokeBorder`
                                // keeps the full physical-pixel edge inside.
                                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                        }
                        .overlay {
                            if isHovering {
                                Text(action.hoverSymbol)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.45))
                                    .frame(width: 12, height: 12)
                            }
                        }
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.accessibilityLabel)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口控制")
    }
}
