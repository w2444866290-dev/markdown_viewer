import SwiftUI

struct FindBarView: View {
    @State private var query: String = ""
    @State private var replaceText: String = ""
    @State private var showReplace: Bool = false
    @State private var caseSensitive: Bool = false
    @State private var wholeWord: Bool = false
    @State private var useRegex: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button(action: { showReplace.toggle() }) {
                    Text(showReplace ? "▾" : "▸")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .frame(width: 20, height: 28)

                HStack(spacing: 8) {
                    TextField("查找", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    Text("0/0")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DesignTokens.swiftUI.statusText)
                }
                .padding(.horizontal, 9)
                .frame(width: 240, height: 28)
                .background(DesignTokens.swiftUI.fieldFill)
                .cornerRadius(6)

                HStack(spacing: 2) {
                    ToggleChip("Aa", isOn: $caseSensitive)
                    ToggleChip("W", isOn: $wholeWord)
                    ToggleChip(".*", isOn: $useRegex)
                }

                Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1, height: 16)

                HStack(spacing: 2) {
                    Button("↑") {}.buttonStyle(.borderless).frame(width: 24, height: 24)
                    Button("↓") {}.buttonStyle(.borderless).frame(width: 24, height: 24)
                }
                .font(.system(size: 12))

                Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1, height: 16)

                Button("×") {}
                    .buttonStyle(.borderless)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
            }

            if showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20)
                    TextField("替换为", text: $replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(DesignTokens.swiftUI.fieldFill)
                        .cornerRadius(6)
                    Button("替换") {}
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                    Button("全部替换") {}
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
    }
}

struct ToggleChip: View {
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
                .foregroundColor(isOn ? DesignTokens.swiftUI.titleText : DesignTokens.swiftUI.placeholderText)
                .frame(width: 22, height: 22)
                .background(isOn ? Color.black.opacity(0.10) : .clear)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isOn ? Color.black.opacity(0.06) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
