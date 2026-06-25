import SwiftUI

/// Find/replace bar — spec: position absolute top 10px right 18px, blur backdrop.
struct FindBarView: View {
    @ObservedObject var state: FindState
    @State private var hoveredBtn: String?

    private var canNav: Bool { !state.isError && state.matchCount > 0 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Chevron toggle — spec: 20×28, radius 6
                Button(action: { state.showReplace.toggle() }) {
                    Text(state.showReplace ? "▾" : "▸")
                        .font(.system(size: 9))
                        .foregroundColor(state.showReplace
                            ? DesignTokens.swiftUI.secondaryText
                            : DesignTokens.swiftUI.placeholderText)
                        .frame(width: 20, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(state.showReplace ? Color.black.opacity(0.05) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Search field — spec: 240×28, bg rgba(0,0,0,0.045), radius 6
                HStack(spacing: 8) {
                    TextField("查找", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .onChange(of: state.query) { _ in
                            state.onSearch?(state.query)
                        }
                        .onSubmit { state.onNavigate?(1) }
                    Text(state.displayText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(state.isError
                            ? DesignTokens.swiftUI.danger
                            : DesignTokens.swiftUI.statusText)
                }
                .padding(.horizontal, 9)
                .frame(width: 240, height: 28)
                .background(DesignTokens.swiftUI.fieldFill)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            state.isError
                                ? Color(red: 199/255, green: 72/255, blue: 46/255).opacity(0.45)
                                : Color.clear,
                            lineWidth: 1
                        )
                )

                // Toggle chips — spec: 22×22, radius 6
                HStack(spacing: 2) {
                    ToggleChip("Aa", isOn: $state.caseSensitive)
                        .onChange(of: state.caseSensitive) { _ in state.onSearch?(state.query) }
                    ToggleChip("W", isOn: $state.wholeWord)
                        .onChange(of: state.wholeWord) { _ in state.onSearch?(state.query) }
                    ToggleChip(".*", isOn: $state.useRegex)
                        .onChange(of: state.useRegex) { _ in state.onSearch?(state.query) }
                }

                // Separator
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 16)

                // Nav buttons — spec: 24×24, radius 6, color depends on canNav
                HStack(spacing: 2) {
                    Button("↑") { state.onNavigate?(-1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(canNav
                            ? DesignTokens.swiftUI.secondaryText
                            : Color(red: 209/255, green: 209/255, blue: 214/255))
                        .frame(width: 24, height: 24)
                        .allowsHitTesting(canNav)
                    Button("↓") { state.onNavigate?(1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(canNav
                            ? DesignTokens.swiftUI.secondaryText
                            : Color(red: 209/255, green: 209/255, blue: 214/255))
                        .frame(width: 24, height: 24)
                        .allowsHitTesting(canNav)
                }

                // Separator
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 16)

                // Close — spec: 24×24, color #aeaeb2, hover #1d1d1f
                Button(action: { state.isOpen = false }) {
                    Text("×")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
            }

            // Replace row
            if state.showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20)
                    TextField("替换为", text: $state.replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(DesignTokens.swiftUI.fieldFill)
                        .cornerRadius(6)
                        .onSubmit { state.onReplaceCurrent?() }
                    Spacer()
                    HStack(spacing: 4) {
                        Button("替换") { state.onReplaceCurrent?() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 58/255, green: 58/255, blue: 60/255))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(6)
                        Button("全部替换") { state.onReplaceAll?() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 58/255, green: 58/255, blue: 60/255))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 4)
        )
        .padding(.top, 10)
        .padding(.trailing, 18)
    }
}

// MARK: - Toggle chip

private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(label)
                .font(.system(size: label == ".*" ? 12 : 11, design: .monospaced).bold())
                .foregroundColor(isOn
                    ? DesignTokens.swiftUI.titleText
                    : DesignTokens.swiftUI.placeholderText)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.black.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isOn ? Color.black.opacity(0.06) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
