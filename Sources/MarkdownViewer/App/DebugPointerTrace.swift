import AppKit
import Foundation

struct DebugPointerTraceEntry: Codable, Equatable {
    let sequence: Int
    let phase: String
    let blockIndex: Int?
    let blockID: String?
    let sidebarWidth: Double?
    let locationX: Double?
    let locationY: Double?
    let hitViewClass: String?
    let hitViewPath: [String]
    let hitViewMouseDownCanMoveWindow: Bool?
    let windowIsMovableByWindowBackground: Bool?
}

private struct DebugPointerTracePayload: Codable, Equatable {
    let schemaVersion: Int
    let entries: [DebugPointerTraceEntry]
}

/// Debug-only trace for proving where bounded real pointer input is delivered.
///
/// It observes local mouse events without replacing them and records semantic
/// block callbacks separately. Ordinary Debug and every Release launch remain
/// inert because only a token-bound visual-test process can enable the trace.
@MainActor
final class DebugPointerTrace {
    static let shared = DebugPointerTrace()

    private weak var window: NSWindow?
    private var localMonitor: Any?
    private var entries: [DebugPointerTraceEntry] = []
    private var nextSequence = 0
    private var writeWork: DispatchWorkItem?

    private var fileURL: URL? {
        AppEnv.diagnosticStateFileURL?
            .deletingLastPathComponent()
            .appendingPathComponent("pointer-trace.json")
    }

    private init() {}

    func attach(window: NSWindow) {
        guard AppEnv.visualTest, fileURL != nil else { return }
        self.window = window
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            self?.record(event)
            return event
        }
        append(phase: "trace-attached")
    }

    func recordSemantic(
        _ phase: String,
        blockIndex: Int,
        blockID: UUID
    ) {
        guard AppEnv.visualTest else { return }
        append(
            phase: phase,
            blockIndex: blockIndex,
            blockID: blockID.uuidString
        )
    }

    func recordSidebarResize(_ phase: String, width: CGFloat) {
        guard AppEnv.visualTest, width.isFinite else { return }
        append(phase: phase, sidebarWidth: Double(width))
    }

    func flush() {
        writeWork?.cancel()
        writeWork = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(DebugPointerTracePayload(
                schemaVersion: 1,
                entries: entries
            )).write(to: fileURL, options: .atomic)
        } catch {
            MVLog.warn("pointer trace write failed: \(error)", category: "visual-test")
        }
    }

    private func record(_ event: NSEvent) {
        guard let window else { return }
        let hitView = window.contentView?.hitTest(event.locationInWindow)
        append(
            phase: event.window === window
                ? Self.phase(for: event.type)
                : "foreign-\(Self.phase(for: event.type))",
            locationX: Double(event.locationInWindow.x),
            locationY: Double(event.locationInWindow.y),
            hitViewClass: hitView.map { String(describing: type(of: $0)) },
            hitViewPath: Self.viewPath(from: hitView),
            hitViewMouseDownCanMoveWindow: hitView?.mouseDownCanMoveWindow,
            windowIsMovableByWindowBackground: window.isMovableByWindowBackground
        )
    }

    private func append(
        phase: String,
        blockIndex: Int? = nil,
        blockID: String? = nil,
        sidebarWidth: Double? = nil,
        locationX: Double? = nil,
        locationY: Double? = nil,
        hitViewClass: String? = nil,
        hitViewPath: [String] = [],
        hitViewMouseDownCanMoveWindow: Bool? = nil,
        windowIsMovableByWindowBackground: Bool? = nil
    ) {
        entries.append(DebugPointerTraceEntry(
            sequence: nextSequence,
            phase: phase,
            blockIndex: blockIndex,
            blockID: blockID,
            sidebarWidth: sidebarWidth,
            locationX: locationX,
            locationY: locationY,
            hitViewClass: hitViewClass,
            hitViewPath: hitViewPath,
            hitViewMouseDownCanMoveWindow: hitViewMouseDownCanMoveWindow,
            windowIsMovableByWindowBackground: windowIsMovableByWindowBackground
        ))
        nextSequence += 1
        if entries.count > 128 {
            entries.removeFirst(entries.count - 128)
        }
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard fileURL != nil else { return }
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private static func phase(for type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: return "left-mouse-down"
        case .leftMouseUp: return "left-mouse-up"
        case .leftMouseDragged: return "left-mouse-dragged"
        default: return "mouse-\(type.rawValue)"
        }
    }

    private static func viewPath(from leaf: NSView?) -> [String] {
        var path: [String] = []
        var current = leaf
        while let view = current, path.count < 16 {
            path.append(String(describing: type(of: view)))
            current = view.superview
        }
        return path
    }
}
