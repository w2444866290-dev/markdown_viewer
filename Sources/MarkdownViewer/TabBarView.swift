import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { docManager.sidebarOpen.toggle() }) {
                Image(nsImage: CustomIcons.sidebarToggle)
            }
            .buttonStyle(.borderless)
            .frame(width: 26, height: 26)
            .foregroundColor(DesignTokens.swiftUI.placeholderText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(docManager.tabs) { tab in
                        TabPill(tab: tab)
                    }
                    Button(action: { docManager.newDocument() }) {
                        Text("＋")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 26, height: 26)
                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
                }
            }

            Spacer()

            Button(action: { docManager.findOpen.toggle() }) {
                Image(nsImage: CustomIcons.find)
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 26)
            .foregroundColor(DesignTokens.swiftUI.placeholderText)

            Button(action: { /* open file */ }) {
                Image(nsImage: CustomIcons.openFolder)
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 26)
            .foregroundColor(DesignTokens.swiftUI.placeholderText)
        }
        .padding(.horizontal, 12)
        .frame(height: DesignTokens.tabBarHeight)
        .background(DesignTokens.swiftUI.paper)
    }
}

struct TabPill: View {
    @EnvironmentObject var docManager: DocumentManager
    let tab: DocumentTab
    @State private var hovering = false

    var isActive: Bool { docManager.activeTabID == tab.id }

    var body: some View {
        Button(action: { docManager.activeTabID = tab.id }) {
            HStack(spacing: 6) {
                Text(tab.name)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? DesignTokens.swiftUI.titleText : DesignTokens.swiftUI.tertiaryText)
                    .lineLimit(1)
                if tab.isDirty, !hovering {
                    Circle()
                        .fill(DesignTokens.swiftUI.accent)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(isActive ? DesignTokens.swiftUI.selected : (hovering ? DesignTokens.swiftUI.hover : .clear))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
