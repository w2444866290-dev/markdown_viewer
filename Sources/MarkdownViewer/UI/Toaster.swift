import SwiftUI

/// Decoupled toast hub. Both the SwiftUI layer and AppKit controllers
/// (FindController, CodeOverlayController, …) can call `Toaster.shared.flash`.
///
/// Mirrors the reference UI `flash()` (ui/Markdown Viewer.dc.html L770-774):
/// show the message, then auto-dismiss after 1.6s. Repeated calls reset the
/// timer so the latest message stays visible for a full interval.
@MainActor
final class Toaster: ObservableObject {
    static let shared = Toaster()

    @Published var message: String = ""
    @Published var visible: Bool = false

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func flash(_ s: String) {
        message = s
        withAnimation(.easeOut(duration: 0.18)) { visible = true }

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.visible = false }
        }
    }
}

/// Centered pill toast — aligns to ui/Markdown Viewer.dc.html L261:
/// `✓ {{ toast }}` over rgba(28,28,30,0.9), white text, radius 99,
/// padding 7×16, font-size 12, shadow 0 8px 28px rgba(0,0,0,0.2).
struct ToastView: View {
    let message: String

    var body: some View {
        Text("✓ \(message)")
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(red: 28/255, green: 28/255, blue: 30/255).opacity(0.9))
            )
            .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
            .transition(.opacity)
    }
}
