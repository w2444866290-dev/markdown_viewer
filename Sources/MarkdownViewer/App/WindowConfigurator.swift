import SwiftUI
import AppKit

/// Owns the process-lifetime handshake used by bounded foreground E2E phases.
///
/// A passive visual-test window is ordered out, so it intentionally has no AX
/// window that an external process could raise. The driver instead posts one
/// token-bound distributed notification. Only the Debug process launched with
/// that exact random token and PID accepts it. When focus returns to the prior
/// app, this controller immediately orders the test window out again.
@MainActor
final class VisualTestWindowActivationController {
    static let shared = VisualTestWindowActivationController()

    private weak var window: NSWindow?
    private var distributedObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var activationGeneration = 0
    private var activationInFlight = false
    private var safetyHideWork: DispatchWorkItem?
    private var requestCount = 0
    private var presentationAttemptCount = 0
    private var becomeActiveCount = 0
    private var resignCount = 0
    private var ignoredRequestCount = 0
    private var safetyTimeoutCount = 0

    private init() {}

    func attach(window: NSWindow) {
        precondition(Thread.isMainThread)
        guard AppEnv.visualTest,
              let notificationName = AppEnv.visualTestActivationNotificationName else {
            return
        }

        self.window = window
        DebugPointerTrace.shared.attach(window: window)
        if distributedObserver == nil {
            let expectedObject = String(ProcessInfo.processInfo.processIdentifier)
            distributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: notificationName,
                object: expectedObject,
                queue: .main
            ) { [weak self] notification in
                guard notification.object as? String == expectedObject else { return }
                Task { @MainActor [weak self] in
                    self?.requestCount += 1
                    self?.publishDiagnostic(event: "request-received")
                    self?.activateBoundWindow()
                }
            }
        }
        if becomeActiveObserver == nil {
            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.becomeActiveCount += 1
                    self?.publishDiagnostic(event: "did-become-active")
                }
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resignCount += 1
                    self?.hideBoundWindow()
                    self?.publishDiagnostic(event: "did-resign-active")
                }
            }
        }
        moveOffscreenAndOrderOut(window: window)
        publishDiagnostic(event: "observer-ready")
    }

    private func activateBoundWindow() {
        precondition(Thread.isMainThread)
        guard let window else {
            publishDiagnostic(event: "request-missing-window")
            return
        }
        guard !activationInFlight else {
            ignoredRequestCount += 1
            publishDiagnostic(event: "request-ignored-in-flight")
            return
        }

        activationInFlight = true
        activationGeneration += 1
        let generation = activationGeneration
        presentationAttemptCount += 1
        VisualTestWindowLevelPolicy.prepareForBoundedForeground(window)
        window.ignoresMouseEvents = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        publishDiagnostic(event: "presentation-attempted")

        safetyHideWork?.cancel()
        let safetyWork = DispatchWorkItem { [weak self, weak window] in
            guard let self,
                  let window,
                  self.activationGeneration == generation,
                  self.activationInFlight else {
                return
            }
            self.activationInFlight = false
            self.activationGeneration += 1
            self.safetyHideWork = nil
            self.safetyTimeoutCount += 1
            DebugPointerTrace.shared.flush()
            window.orderOut(nil)
            VisualTestWindowLevelPolicy.restoreNormal(window)
            self.publishDiagnostic(event: "safety-timeout")
        }
        safetyHideWork = safetyWork
        DispatchQueue.main.asyncAfter(
            deadline: .now() + VisualTestWindowLevelPolicy.safetyTimeoutSeconds,
            execute: safetyWork
        )

        // Fail closed if macOS rejects activation. This prevents a delivered
        // request from leaving a visible inactive window behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self, weak window] in
            guard let self,
                  let window,
                  self.activationGeneration == generation,
                  !NSApp.isActive else {
                return
            }
            self.activationInFlight = false
            self.safetyHideWork?.cancel()
            self.safetyHideWork = nil
            window.orderOut(nil)
            VisualTestWindowLevelPolicy.restoreNormal(window)
            self.publishDiagnostic(event: "activation-rejected")
        }
    }

    private func hideBoundWindow() {
        precondition(Thread.isMainThread)
        guard let window else { return }
        activationInFlight = false
        activationGeneration += 1
        safetyHideWork?.cancel()
        safetyHideWork = nil
        DebugPointerTrace.shared.flush()
        window.orderOut(nil)
        VisualTestWindowLevelPolicy.restoreNormal(window)
    }

    private func moveOffscreenAndOrderOut(window: NSWindow) {
        let offscreenX = NSScreen.screens.map(\.frame.maxX).max() ?? 10_000
        let offscreenY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(NSPoint(x: offscreenX + 200, y: offscreenY))
        window.orderOut(nil)
        VisualTestWindowLevelPolicy.restoreNormal(window)
    }

    private func publishDiagnostic(event: String) {
        guard let stateFile = AppEnv.diagnosticStateFileURL else { return }
        let file = stateFile
            .deletingLastPathComponent()
            .appendingPathComponent("window-activation.json")
        let snapshot = VisualTestWindowActivationDiagnostic(
            schemaVersion: 1,
            pid: ProcessInfo.processInfo.processIdentifier,
            observerReady: distributedObserver != nil,
            requestCount: requestCount,
            presentationAttemptCount: presentationAttemptCount,
            becomeActiveCount: becomeActiveCount,
            resignCount: resignCount,
            ignoredRequestCount: ignoredRequestCount,
            safetyTimeoutCount: safetyTimeoutCount,
            activationInFlight: activationInFlight,
            applicationIsActive: NSApp.isActive,
            windowNumber: window?.windowNumber,
            windowIsVisible: window?.isVisible ?? false,
            windowIsKey: window?.isKeyWindow ?? false,
            windowIsMovable: window?.isMovable ?? false,
            windowIsMovableByWindowBackground:
                window?.isMovableByWindowBackground ?? false,
            windowLevel: window?.level.rawValue ?? NSWindow.Level.normal.rawValue,
            event: event,
            updatedAt: Date()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: file, options: .atomic)
        } catch {
            MVLog.warn(
                "window activation diagnostic write failed: \(error)",
                category: "visual-test"
            )
        }
    }
}

private struct VisualTestWindowActivationDiagnostic: Codable {
    let schemaVersion: Int
    let pid: Int32
    let observerReady: Bool
    let requestCount: Int
    let presentationAttemptCount: Int
    let becomeActiveCount: Int
    let resignCount: Int
    let ignoredRequestCount: Int
    let safetyTimeoutCount: Int
    let activationInFlight: Bool
    let applicationIsActive: Bool
    let windowNumber: Int?
    let windowIsVisible: Bool
    let windowIsKey: Bool
    let windowIsMovable: Bool
    let windowIsMovableByWindowBackground: Bool
    let windowLevel: Int
    let event: String
    let updatedAt: Date
}

enum VisualTestWindowLevelPolicy {
    static let boundedForeground = NSWindow.Level.screenSaver
    static let safetyTimeoutSeconds: TimeInterval = 3.8

    static func prepareForBoundedForeground(_ window: NSWindow) {
        precondition(Thread.isMainThread)
        window.level = boundedForeground
    }

    static func restoreNormal(_ window: NSWindow) {
        precondition(Thread.isMainThread)
        window.level = .normal
    }
}

enum WindowMovementPolicy {
    static func apply(to window: NSWindow) {
        precondition(Thread.isMainThread)
        window.isMovable = true
        window.isMovableByWindowBackground = false
    }
}

final class WindowConfigurationProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Applies deterministic content geometry after SwiftUI has attached the host view
/// to its native window.
struct WindowGeometryConfigurator: NSViewRepresentable {
    let frameSize: CGSize

    final class Coordinator {
        var didApply = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowConfigurationProbeView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didApply else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window, !context.coordinator.didApply else { return }
            context.coordinator.didApply = true
            WindowMovementPolicy.apply(to: window)
            window.minSize = NSSize(width: 860, height: 560)
            window.setFrame(
                NSRect(origin: window.frame.origin, size: frameSize),
                display: true
            )
            if AppEnv.visualTestForegroundOnLaunch {
                window.center()
                window.level = .normal
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else if AppEnv.visualTest {
                // Keep passive and pre-batch launches ordered out. AppKit constrains
                // ordinary titled windows so part of the title bar remains on a
                // display even when an offscreen origin is requested. An ordered-out
                // native window remains available to ScreenCaptureKit's
                // desktop-independent window filter without appearing in the user's
                // current desktop or Stage Manager.
                VisualTestWindowActivationController.shared.attach(window: window)
            } else {
                window.center()
            }
        }
    }
}
