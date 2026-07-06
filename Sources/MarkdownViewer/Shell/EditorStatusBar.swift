import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Status bar — isolated so scroll only re-renders THIS view
//
// spec: bottom 14px, right 20px, "{千分位字数} 字 · {行数} 行 · {pct}%",
// font 11.5 monospaced, statusText color, fade out 0.8s after scrolling stops.
//
// Observes ScrollProgressModel (the per-frame scroll sink) and DocMetricsModel
// (char/line counts, changed only on edit). Both are held by ContentView via
// @State and NOT observed there, so scrolling / editing re-evaluate only this view.
struct EditorStatusBar: View {
    @ObservedObject var scrollModel: ScrollProgressModel
    @ObservedObject var metrics: DocMetricsModel
    @State private var faded = false

    // Shared formatter avoids a fresh allocation on every render.
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var wordCount: String {
        Self.numberFormatter.string(from: NSNumber(value: metrics.charCount))
            ?? "\(metrics.charCount)"
    }

    var body: some View {
        // spec L208: 11.5px with tabular numerals (font-variant-numeric: tabular-nums),
        // NOT a monospaced family.
        Text("\(wordCount) 字 · \(metrics.lineCount) 行 · \(Int(scrollModel.value * 100))%")
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundColor(DesignTokens.swiftUI.statusText)
            .opacity(faded ? 0 : 1)
            .animation(.easeInOut(duration: 0.3), value: faded)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .onReceive(
                scrollModel.$value.debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            ) { _ in
                faded = false
            }
            .onReceive(scrollModel.$value) { _ in
                faded = true
            }
    }
}

// MARK: - Link URL preview — isolated so a mouse move over a link re-renders
// ONLY this leaf (性能-2). Spec L213: bottom 14, left 20, 11.5px, #767676,
// single line ellipsis, max-width 42%, no hit testing.
//
// Observes the isolated HoverURLModel. Because ContentView holds the model via
// @State and does NOT observe it, hovering links never re-evaluates ContentView.body.
struct HoverURLPreview: View {
    @ObservedObject var model: HoverURLModel

    var body: some View {
        GeometryReader { geo in
            if !model.url.isEmpty {
                Text(model.url)
                    .font(.system(size: 11.5))
                    .foregroundColor(DesignTokens.swiftUI.statusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: geo.size.width * 0.42, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

// DIAG (temporary) ----------------------------------------------------------
// On-screen restyle-path readout for the "whole-document styling flashes for one
// frame while typing/deleting" bug. Shows the LAST re-style path plus cumulative
// per-path tallies, updated on every keystroke by EditorView.Coordinator.diagRecord.
//
// Observes the isolated DiagModel. ContentView holds that model via @State and does
// NOT observe it, so the instrumentation re-renders ONLY this yellow leaf - it can
// never itself trigger the whole-ContentView re-render we are hunting. Deliberately
// loud debug styling. Rip out with the rest of the `// DIAG (temporary)` markers.
struct DiagReadout: View {
    @ObservedObject var model: DiagModel
    // Collapse to a tiny chip so it never blocks the editor / find bar. Session-only.
    @State private var collapsed = false

    var body: some View {
        Group {
            if collapsed {
                Text("▸ DIAG")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.yellow.opacity(0.9))
                    .cornerRadius(5)
                    .onTapGesture { collapsed = false }
                    .help("展开诊断")
            } else {
                expanded
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, 8)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("DIAG · 点击复制")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.black.opacity(0.5))
                Spacer(minLength: 10)
                Button(action: { collapsed = true }) {
                    Text("×")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("隐藏")
            }
            Text(model.text.isEmpty ? "DIAG  (waiting for keystroke...)" : model.text)
            if !model.findText.isEmpty {
                Text(model.findText)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.black)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.yellow)
        .cornerRadius(6)
        .frame(maxWidth: 560, alignment: .leading)
        // Click-to-copy: hand the full readout to the pasteboard so the developer
        // can paste it straight into a report instead of screenshotting the HUD.
        // (The × button consumes its own tap, so it hides rather than copies.)
        .contentShape(Rectangle())
        .onTapGesture {
            let visible = [model.text, model.findText].filter { !$0.isEmpty }.joined(separator: "\n")
            let payload = model.findDetail.isEmpty ? visible : "\(model.text)\n\(model.findDetail)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            Toaster.shared.flash("已复制诊断信息")
        }
        .help("点击复制诊断信息到剪贴板")
    }
}
