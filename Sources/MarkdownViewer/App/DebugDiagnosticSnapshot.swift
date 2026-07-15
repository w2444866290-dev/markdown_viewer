import Foundation
import SwiftUI

struct DebugDiagnosticRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

struct DebugDiagnosticVisualState: Codable, Equatable {
    var documentVisible: Bool
    var sidebarVisible: Bool
    var paletteVisible: Bool
    var palettePresentation: String
    var findPanelVisible: Bool
    var replaceRowVisible: Bool
    var previewActive: Bool
    var sourceEditorVisible: Bool
    var tableGridVisible: Bool
    var anchors: [String: DebugDiagnosticRect]

    static let empty = DebugDiagnosticVisualState(
        documentVisible: false,
        sidebarVisible: false,
        paletteVisible: false,
        palettePresentation: PalettePresentationMode.childPanel.rawValue,
        findPanelVisible: false,
        replaceRowVisible: false,
        previewActive: false,
        sourceEditorVisible: false,
        tableGridVisible: false,
        anchors: [:]
    )
}

private struct DebugVisualAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct DebugVisualAnchorModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .background {
                if AppEnv.debug {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: DebugVisualAnchorPreferenceKey.self,
                            value: [name: proxy.frame(in: .global)]
                        )
                    }
                }
            }
            .onPreferenceChange(DebugVisualAnchorPreferenceKey.self) { frames in
                guard AppEnv.debug, let rect = frames[name],
                      !rect.isNull, !rect.isInfinite,
                      rect.width > 0, rect.height > 0 else { return }
                DebugDiagnosticWriter.shared.updateVisualAnchor(name, frame: rect)
            }
            .onDisappear {
                guard AppEnv.debug else { return }
                DebugDiagnosticWriter.shared.updateVisualAnchor(name, frame: nil)
            }
    }
}

extension View {
    func debugVisualAnchor(_ name: String) -> some View {
        modifier(DebugVisualAnchorModifier(name: name))
    }

    @ViewBuilder
    func debugVisualTestBlockAnchor(_ name: @autoclosure () -> String) -> some View {
        if AppEnv.visualTest {
            debugVisualAnchor(name())
        } else {
            self
        }
    }
}

struct DebugDiagnosticSelection: Codable, Equatable {
    let location: Int
    let length: Int
}

struct DebugDiagnosticTableCell: Codable, Equatable {
    let row: Int
    let column: Int
}

struct DebugDiagnosticFindState: Codable, Equatable {
    let query: String
    let display: String
    let matchCount: Int
    let currentIndex: Int
    let invalidRegex: Bool
    let replaceExpanded: Bool
    let caseSensitive: Bool
    let wholeWord: Bool
    let regex: Bool

    @MainActor
    static func current(_ state: FindState?) -> DebugDiagnosticFindState {
        DebugDiagnosticFindState(
            query: state?.query ?? "",
            display: state?.displayText ?? "",
            matchCount: state?.matchCount ?? 0,
            currentIndex: state?.currentIndex ?? 0,
            invalidRegex: state?.isError ?? false,
            replaceExpanded: state?.showReplace ?? false,
            caseSensitive: state?.caseSensitive ?? false,
            wholeWord: state?.wholeWord ?? false,
            regex: state?.useRegex ?? false
        )
    }
}

struct DebugDiagnosticOutlineState: Codable, Equatable {
    let headingCount: Int
    let activeIndex: Int
}

struct DebugDiagnosticSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let document: String
    let blockID: String?
    let blockType: String?
    let mode: String
    let selection: DebugDiagnosticSelection?
    let activeTableCell: DebugDiagnosticTableCell?
    let dirty: Bool
    let find: DebugDiagnosticFindState
    let outline: DebugDiagnosticOutlineState
    let scrollY: Double
    let sessionPath: String
    let parseCount: Int
    let localMutationCount: Int
    var renderedBlockUpdateCount: Int
    var activeBlockRenderUpdateCount: Int
    var renderedBlockUpdates: [String: Int]
    var visual: DebugDiagnosticVisualState
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, document, blockID, blockType, mode, selection
        case activeTableCell, dirty, find, outline, scrollY, sessionPath
        case parseCount, localMutationCount, renderedBlockUpdateCount
        case activeBlockRenderUpdateCount, renderedBlockUpdates, visual, updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(document, forKey: .document)
        if let blockID {
            try container.encode(blockID, forKey: .blockID)
        } else {
            try container.encodeNil(forKey: .blockID)
        }
        if let blockType {
            try container.encode(blockType, forKey: .blockType)
        } else {
            try container.encodeNil(forKey: .blockType)
        }
        try container.encode(mode, forKey: .mode)
        if let selection {
            try container.encode(selection, forKey: .selection)
        } else {
            try container.encodeNil(forKey: .selection)
        }
        if let activeTableCell {
            try container.encode(activeTableCell, forKey: .activeTableCell)
        } else {
            try container.encodeNil(forKey: .activeTableCell)
        }
        try container.encode(dirty, forKey: .dirty)
        try container.encode(find, forKey: .find)
        try container.encode(outline, forKey: .outline)
        try container.encode(scrollY, forKey: .scrollY)
        try container.encode(sessionPath, forKey: .sessionPath)
        try container.encode(parseCount, forKey: .parseCount)
        try container.encode(localMutationCount, forKey: .localMutationCount)
        try container.encode(renderedBlockUpdateCount, forKey: .renderedBlockUpdateCount)
        try container.encode(
            activeBlockRenderUpdateCount,
            forKey: .activeBlockRenderUpdateCount
        )
        try container.encode(renderedBlockUpdates, forKey: .renderedBlockUpdates)
        try container.encode(visual, forKey: .visual)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func plainSource(
        document: String,
        selection: NSRange?,
        dirty: Bool,
        find: DebugDiagnosticFindState,
        scrollY: Double,
        sessionPath: String
    ) -> DebugDiagnosticSnapshot {
        nonMarkdownSurface(
            document: document,
            mode: "source",
            selection: selection,
            dirty: dirty,
            find: find,
            scrollY: scrollY,
            sessionPath: sessionPath
        )
    }

    static func emptyWorkspace(
        find: DebugDiagnosticFindState,
        sessionPath: String
    ) -> DebugDiagnosticSnapshot {
        nonMarkdownSurface(
            document: "",
            mode: "empty",
            selection: nil,
            dirty: false,
            find: find,
            scrollY: 0,
            sessionPath: sessionPath
        )
    }

    private static func nonMarkdownSurface(
        document: String,
        mode: String,
        selection: NSRange?,
        dirty: Bool,
        find: DebugDiagnosticFindState,
        scrollY: Double,
        sessionPath: String
    ) -> DebugDiagnosticSnapshot {
        DebugDiagnosticSnapshot(
            schemaVersion: 1,
            document: document,
            blockID: nil,
            blockType: nil,
            mode: mode,
            selection: selection.map {
                DebugDiagnosticSelection(location: $0.location, length: $0.length)
            },
            activeTableCell: nil,
            dirty: dirty,
            find: find,
            outline: DebugDiagnosticOutlineState(headingCount: 0, activeIndex: 0),
            scrollY: scrollY,
            sessionPath: sessionPath,
            parseCount: 0,
            localMutationCount: 0,
            renderedBlockUpdateCount: 0,
            activeBlockRenderUpdateCount: 0,
            renderedBlockUpdates: [:],
            visual: .empty,
            updatedAt: Date()
        )
    }
}

@MainActor
final class DebugDiagnosticWriter {
    static let shared = DebugDiagnosticWriter(fileURL: AppEnv.diagnosticStateFileURL)

    private let fileURL: URL?
    private let writeDelay: TimeInterval
    private var latest: DebugDiagnosticSnapshot?
    private var renderUpdates: [String: Int] = [:]
    private var visual = DebugDiagnosticVisualState.empty
    private var writeWork: DispatchWorkItem?

    init(fileURL: URL?, writeDelay: TimeInterval = 0.05) {
        self.fileURL = fileURL
        self.writeDelay = writeDelay
    }

    var renderedBlockUpdateCount: Int {
        renderUpdates.values.reduce(0, +)
    }

    func renderedBlockUpdateCount(for blockID: UUID?) -> Int {
        guard let blockID else { return 0 }
        return renderUpdates[blockID.uuidString, default: 0]
    }

    func update(_ snapshot: DebugDiagnosticSnapshot) {
        latest = snapshotWithRenderCounts(snapshot)
        scheduleWrite()
    }

    func recordBlockRender(_ blockID: UUID) {
        renderUpdates[blockID.uuidString, default: 0] += 1
        if let latest {
            self.latest = snapshotWithRenderCounts(latest)
        }
        scheduleWrite()
    }

    func updateVisualState(
        documentVisible: Bool,
        sidebarVisible: Bool,
        paletteVisible: Bool,
        palettePresentation: String,
        findPanelVisible: Bool,
        replaceRowVisible: Bool,
        previewActive: Bool
    ) {
        visual.documentVisible = documentVisible
        visual.sidebarVisible = sidebarVisible
        visual.paletteVisible = paletteVisible
        visual.palettePresentation = palettePresentation
        visual.findPanelVisible = findPanelVisible
        visual.replaceRowVisible = replaceRowVisible
        visual.previewActive = previewActive
        refreshDerivedVisualState()
        if let latest {
            self.latest = snapshotWithRenderCounts(latest)
        }
        scheduleWrite()
    }

    func updateVisualAnchor(_ name: String, frame: CGRect?) {
        if let frame {
            visual.anchors[name] = DebugDiagnosticRect(frame)
        } else {
            visual.anchors.removeValue(forKey: name)
        }
        refreshDerivedVisualState()
        if let latest {
            self.latest = snapshotWithRenderCounts(latest)
        }
        scheduleWrite()
    }

    func flush() throws {
        writeWork?.cancel()
        writeWork = nil
        guard let fileURL, let latest else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshotWithRenderCounts(latest)).write(to: fileURL, options: .atomic)
    }

    private func snapshotWithRenderCounts(
        _ snapshot: DebugDiagnosticSnapshot
    ) -> DebugDiagnosticSnapshot {
        var updated = snapshot
        updated.renderedBlockUpdateCount = renderedBlockUpdateCount
        updated.activeBlockRenderUpdateCount = snapshot.blockID.map {
            renderUpdates[$0, default: 0]
        } ?? 0
        updated.renderedBlockUpdates = renderUpdates
        updated.visual = visual
        updated.updatedAt = Date()
        return updated
    }

    private func refreshDerivedVisualState() {
        visual.sourceEditorVisible = visual.anchors["source-editor-frame"] != nil
        visual.tableGridVisible = visual.anchors["table-grid-frame"] != nil
    }

    private func scheduleWrite() {
        guard fileURL != nil, latest != nil else { return }
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do {
                try self?.flush()
            } catch {
                MVLog.warn("diagnostic snapshot write failed: \(error)", category: "diag")
            }
        }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }
}
