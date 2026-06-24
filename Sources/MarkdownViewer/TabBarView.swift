import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(docManager.tabs) { tab in
                        TabPill(tab: tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.trailing, 28)
            }
            .frame(height: 44)

            Spacer()

            HStack(spacing: 8) {
                Button(action: { docManager.openFile() }) {
                    CIcon { CustomIcons.openFolder }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开文件")

                Button(action: { findState.toggleOpen() }) {
                    CIcon { CustomIcons.find }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查找 / 替换")
            }
            .padding(.trailing, 16)
        }
    }
}

private struct TabPill: View {
    @EnvironmentObject var docManager: DocumentManager
    let tab: DocumentTab

    var body: some View {
        Button(action: { docManager.activeTabID = tab.id }) {
            HStack(spacing: 6) {
                Text(tab.isDirty ? "● " : "")
                    .foregroundColor(DesignTokens.swiftUI.accent)
                    .font(.system(size: 10))
                Text(tab.name)
                    .font(.system(size: 11.5))
                    .fontWeight(tab.id == docManager.activeTabID ? .semibold : .regular)
                    .foregroundColor(tab.id == docManager.activeTabID
                        ? DesignTokens.swiftUI.titleText
                        : DesignTokens.swiftUI.tertiaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.id == docManager.activeTabID
                        ? Color.black.opacity(0.06)
                        : .clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("关闭") { docManager.closeTab(tab) }
            Button("关闭其他") {
                for t in docManager.tabs where t.id != tab.id {
                    docManager.closeTab(t)
                }
            }
        }
    }
}
