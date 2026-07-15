import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

private struct AccessReport: Codable {
    let accessibilityTrusted: Bool
    let listenEventAccess: Bool
    let postEventAccess: Bool
    let screenCaptureAccess: Bool
    let sessionLocked: Bool
}

private struct WindowBounds: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct WindowReport: Codable {
    let pid: Int32
    let owner: String
    let title: String
    let windowNumber: UInt32
    let bounds: WindowBounds
    let layer: Int
    let onScreen: Bool
}

private struct WindowCaptureReport: Codable {
    let pid: Int32
    let windowNumber: UInt32
    let output: String
    let method: String
    let width: Int
    let height: Int
    let durationMs: Int
}

private struct ActionReport: Codable {
    let pid: Int32
    let actions: [String]
    let postEventAccess: Bool
}

private enum ForegroundActionKind: String {
    case moveSafePoint = "move-safe-point"
    case moveOutline = "move-outline"
    case windowMove = "window-move"
    case windowClick = "window-click"
    case windowDrag = "window-drag"
    case elementMove = "element-move"
    case elementClick = "element-click"
    case elementCheck = "element-check"
    case elementDescriptionCheck = "element-description-check"
    case elementDrag = "element-drag"
    case focusedElementCheck = "focused-element-check"
    case scroll
    case shiftTap = "shift-tap"
    case key
    case text
    case pasteboardStringCheck = "pasteboard-string-check"
    case findControlClick = "find-control-click"
    case windowScreenshot = "window-screenshot"
    case wait
}

private struct ForegroundElementSelector {
    let identifier: String?
    let description: String?
    let role: String?
    let expectedValue: String?
    let expectedSelected: Bool?
    let expectedFrameWidth: Double?
    let expectedFrameHeight: Double?
}

private struct ForegroundAction {
    let kind: ForegroundActionKind
    let waitMs: Int
    let durationMs: Int?
    let key: String?
    let text: String?
    let control: String?
    let path: String?
    let xFraction: Double?
    let yFraction: Double?
    let elementSelector: ForegroundElementSelector?
    let deltaX: Int?
    let deltaY: Int?
}

private struct ForegroundPlan {
    let actions: [ForegroundAction]
}

private struct ForegroundPlanActionReport: Codable {
    let index: Int
    let kind: String
    let waitMs: Int?
    let durationMs: Int?
    let detail: String?
}

private struct ForegroundPlanReport: Codable {
    let valid: Bool
    let budgetMs: Int
    let estimatedForegroundMs: Int
    let cleanupReserveMs: Int
    let actions: [ForegroundPlanActionReport]
}

private struct ForegroundBatchActionReport: Codable {
    let index: Int
    let kind: String
    let status: String
    let durationMs: Int
    let detail: String?
    let element: ForegroundElementReport?
    let injectedPointerEvents: ForegroundInjectedPointerEventsReport
    let targetInjectedPointerEvents: ForegroundInjectedPointerEventsReport
    let pointerClickReadiness: ForegroundPointerClickReadinessReport?
    let pointerDragEndpointReadiness: ForegroundPointerClickReadinessReport?
}

private struct ForegroundElementReport: Codable {
    let identifier: String
    let role: String
    let frame: WindowBounds
    let activationPoint: DesktopPointerReport?
    let value: String?
    let selected: Bool?
    let title: String?
    let description: String?
}

private struct TerminateAppReport: Codable {
    let schemaVersion: Int
    let pid: Int32
    let bundleIdentifier: String
    let requested: Bool
    let exited: Bool
    let forced: Bool
    let durationMs: Int
}

private struct ForegroundInterferenceReport: Codable {
    let detected: Bool
    let eventType: String?
    let atMs: Int?
    let pointerInputDetected: Bool
    let pointerPositionInterferenceDetected: Bool
    let eventTapReliable: Bool
}

private struct ForegroundInjectedPointerEventsReport: Codable {
    let moveCount: Int
    let leftMouseDownCount: Int
    let leftMouseDraggedCount: Int
    let leftMouseUpCount: Int
    let lastMoveLocation: DesktopPointerReport?
    let lastLeftMouseDownLocation: DesktopPointerReport?
    let lastLeftMouseDraggedLocation: DesktopPointerReport?
    let lastLeftMouseUpLocation: DesktopPointerReport?
    let completeClickSequenceObserved: Bool
    let completeDragSequenceObserved: Bool
}

private struct ForegroundAXFocusedWindowReadinessReport: Codable {
    let attributeStatus: Int32
    let role: String?
    let title: String?
    let frame: WindowBounds?
    let hasUsableGeometry: Bool
    let containsClickPoint: Bool
    let matchesTargetWindowGeometry: Bool
    let ready: Bool
}

private struct ForegroundAccessibilityHitReport: Codable {
    let status: Int32
    let pid: Int32?
    let role: String?
    let identifier: String?
    let targetPIDMatches: Bool
}

private struct ForegroundPointerClickReadinessReport: Codable {
    let point: DesktopPointerReport
    let targetPID: Int32
    let targetWindowNumber: UInt32
    let topmostWindow: WindowReport?
    let targetOwnerPIDMatches: Bool
    let targetWindowNumberMatches: Bool
    let accessibilityHit: ForegroundAccessibilityHitReport
    let axFocusedWindow: ForegroundAXFocusedWindowReadinessReport
    let ready: Bool
}

private struct ForegroundFocusRestoreReport: Codable {
    let attempted: Bool
    let restored: Bool
    let priorPID: Int32?
    let reason: String
}

private struct ForegroundPointerRestoreReport: Codable {
    let attempted: Bool
    let restored: Bool
    let reason: String
}

private struct ForegroundPasteboardRestoreReport: Codable {
    let attempted: Bool
    let restored: Bool
    let itemCount: Int
    let reason: String
}

private struct ForegroundBatchReport: Codable {
    let pid: Int32
    let durationMs: Int
    let budgetMs: Int
    let targetActivationRequestCount: Int
    let completed: Bool
    let actions: [ForegroundBatchActionReport]
    let interference: ForegroundInterferenceReport
    let injectedPointerEvents: ForegroundInjectedPointerEventsReport
    let targetInjectedPointerEvents: ForegroundInjectedPointerEventsReport
    let deadlineExceeded: Bool
    let focusRestore: ForegroundFocusRestoreReport
    let pointerRestore: ForegroundPointerRestoreReport
    let pasteboardRestore: ForegroundPasteboardRestoreReport
    let error: String?
}

private struct DesktopPointerReport: Codable {
    let x: Double
    let y: Double
}

private struct DesktopStateReport: Codable {
    let frontmostPID: Int32?
    let pointer: DesktopPointerReport
}

private struct PasteboardSelfTestReport: Codable {
    let schemaVersion: Int
    let restored: Bool
    let itemCount: Int
    let typeCount: Int
    let emptyPasteboardRestored: Bool
}

private struct FrontmostObservationReport: Codable {
    let source: String
    let elapsedMs: Int
    let frontmostPID: Int32?
}

private struct FrontmostObserverReadyReport: Codable {
    let schemaVersion: Int
    let observerPID: Int32
    let notificationObserverRegistered: Bool
    let sampleIntervalMs: Int
}

private struct FrontmostObserverReport: Codable {
    let schemaVersion: Int
    let observerPID: Int32
    let durationMs: Int
    let sampleIntervalMs: Int
    let notificationObserverRegistered: Bool
    let readyFileCreated: Bool
    let stopFileObserved: Bool
    let timedOut: Bool
    let targetPID: Int32?
    let targetPIDLoadedAtMs: Int?
    let targetBecameFrontmost: Bool
    let firstTargetFrontmostObservation: FrontmostObservationReport?
    let initialFrontmostPID: Int32?
    let finalFrontmostPID: Int32?
    let notificationCount: Int
    let sampleCount: Int
    let transitions: [FrontmostObservationReport]
}

private struct ImageComparisonReport: Codable {
    let before: String
    let after: String
    let width: Int
    let height: Int
    let changedPixelRatio: Double
    let meanAbsoluteChannelDifference: Double
    let threshold: UInt8
}

private struct SidebarRowReport: Codable {
    let role: String
    let description: String
    let relativeY: Double
}

private struct RecognizedTextObservation {
    let string: String
    let relativeX: Double
    let relativeY: Double
}

private struct ColorReport: Codable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private struct SidebarReport: Codable {
    let pid: Int32
    let rows: [SidebarRowReport]
    let requiredRows: [String]
    let activeSampleBackground: ColorReport
    let inactiveSampleBackground: ColorReport
    let activeSampleBackgroundDelta: Int
    let activeTabBackground: ColorReport
    let inactiveTabBarBackground: ColorReport
    let activeTabBackgroundDelta: Int
    let rowEvidenceMethod: String
    let recognizedText: [String]
}

private struct SidebarFilterResetReport: Codable {
    let pid: Int32
    let accessibilityTrusted: Bool
    let previousValue: String
    let currentValue: String
    let reset: Bool
}

private struct ScreenshotTextReport: Codable {
    let screenshot: String
    let requiredText: [String]
    let forbiddenText: [String]
    let recognizedText: [String]
}

private struct TextClickReport: Codable {
    let pid: Int32
    let actions: [String]
    let postEventAccess: Bool
    let screenshot: String
    let requestedText: String
    let recognizedText: String
    let relativeX: Double
    let relativeY: Double
    let clickCount: Int
}

private struct ElementReport: Codable {
    let pid: Int32
    let relativeX: Double
    let relativeY: Double
    let role: String
    let identifier: String
    let description: String
    let value: String
}

private struct FindControlPointReport: Codable {
    let control: String
    let windowWidth: Double
    let windowHeight: Double
    let relativeX: Double
    let relativeY: Double
}

private enum DriverError: Error, CustomStringConvertible {
    case badArguments(String)
    case permissionDenied(String)
    case processMissing(Int32)
    case windowMissing(Int32)
    case windowNumberMissing(Int32, UInt32)
    case windowSize(Int32, Double, Double)
    case eventCreation(String)
    case imageRead(String)
    case captureFailed(String)
    case imageSizeMismatch(String, String)

    var description: String {
        switch self {
        case .badArguments(let message):
            return message
        case .permissionDenied(let message):
            return message
        case .processMissing(let pid):
            return "no running application for pid \(pid)"
        case .windowMissing(let pid):
            return "no on-screen app window for pid \(pid)"
        case .windowNumberMissing(let pid, let windowNumber):
            return "no on-screen window \(windowNumber) for pid \(pid)"
        case .windowSize(let pid, let width, let height):
            return "window for pid \(pid) did not reach \(width)x\(height) before timeout"
        case .eventCreation(let action):
            return "could not create CGEvent for \(action)"
        case .imageRead(let path):
            return "could not decode image: \(path)"
        case .captureFailed(let message):
            return "window capture failed: \(message)"
        case .imageSizeMismatch(let before, let after):
            return "image sizes differ: \(before) and \(after)"
        }
    }
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

private func values(after option: String, in arguments: [String]) -> [String] {
    arguments.indices.compactMap { index in
        guard arguments[index] == option, index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

private func int32Option(_ option: String, arguments: [String]) throws -> Int32 {
    guard let rawValue = value(after: option, in: arguments), let value = Int32(rawValue), value > 0 else {
        throw DriverError.badArguments("\(option) requires a positive process id")
    }
    return value
}

private func uint32Option(_ option: String, arguments: [String]) throws -> UInt32 {
    guard let rawValue = value(after: option, in: arguments),
          let value = UInt32(rawValue),
          value > 0 else {
        throw DriverError.badArguments("\(option) requires a positive window number")
    }
    return value
}

private func doubleOption(_ option: String, arguments: [String], default defaultValue: Double) throws -> Double {
    guard let rawValue = value(after: option, in: arguments) else { return defaultValue }
    guard let value = Double(rawValue), value >= 0 else {
        throw DriverError.badArguments("\(option) requires a nonnegative number")
    }
    return value
}

private func stringOption(_ option: String, arguments: [String]) throws -> String {
    guard let string = value(after: option, in: arguments), !string.isEmpty else {
        throw DriverError.badArguments("\(option) requires a value")
    }
    return string
}

private let foregroundDefaultWaitMs = 60
private let foregroundCleanupReserveMs = 400
private let foregroundActivationWaitMs = 250
private let foregroundClickGapMs = 40
private let foregroundDragGapCount = 4
private let foregroundElementLookupEstimateMs = 50
private let foregroundScreenshotEstimateMs = 200

private func foregroundBudget(arguments: [String]) throws -> Int {
    guard let rawValue = value(after: "--budget", in: arguments),
          let seconds = Double(rawValue),
          seconds.isFinite,
          (2...10).contains(seconds) else {
        throw DriverError.badArguments("--budget requires a number from 2 through 10 seconds")
    }
    return Int((seconds * 1_000).rounded())
}

private func jsonInteger(_ value: Any?, field: String) throws -> Int {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue.rounded(.towardZero) == number.doubleValue else {
        throw DriverError.badArguments("\(field) requires an integer")
    }
    return number.intValue
}

private func jsonDouble(_ value: Any?, field: String) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else {
        throw DriverError.badArguments("\(field) requires a finite number")
    }
    return number.doubleValue
}

private func validateJSONKeys(
    _ object: [String: Any],
    required: Set<String>,
    allowed: Set<String>,
    context: String
) throws {
    let keys = Set(object.keys)
    let missing = required.subtracting(keys).sorted()
    guard missing.isEmpty else {
        throw DriverError.badArguments("\(context) is missing fields: \(missing)")
    }
    let unknown = keys.subtracting(allowed).sorted()
    guard unknown.isEmpty else {
        throw DriverError.badArguments("\(context) has unknown fields: \(unknown)")
    }
}

private func validateScreenshotPath(_ rawPath: String, context: String) throws -> String {
    guard (rawPath as NSString).isAbsolutePath else {
        throw DriverError.badArguments("\(context) path must be absolute")
    }
    let path = URL(fileURLWithPath: rawPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    guard URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
        throw DriverError.badArguments("\(context) path must end in .png")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
          isDirectory.boolValue,
          FileManager.default.isWritableFile(atPath: parent) else {
        throw DriverError.badArguments("\(context) parent directory must exist and be writable")
    }
    return path
}

private func loadForegroundPlan(path: String, budgetMs: Int) throws -> ForegroundPlan {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
        throw DriverError.badArguments("could not read foreground plan: \(path)")
    }
    guard data.count <= 1_048_576 else {
        throw DriverError.badArguments("foreground plan exceeds 1 MiB")
    }

    let rawJSON: Any
    do {
        rawJSON = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw DriverError.badArguments("foreground plan is not valid JSON: \(error)")
    }
    guard let root = rawJSON as? [String: Any] else {
        throw DriverError.badArguments("foreground plan root must be an object")
    }
    try validateJSONKeys(
        root,
        required: ["schemaVersion", "actions"],
        allowed: ["schemaVersion", "actions"],
        context: "foreground plan"
    )
    guard try jsonInteger(root["schemaVersion"], field: "schemaVersion") == 1 else {
        throw DriverError.badArguments("foreground plan schemaVersion must be 1")
    }
    guard let rawActions = root["actions"] as? [Any],
          (1...64).contains(rawActions.count) else {
        throw DriverError.badArguments("foreground plan actions must contain 1 through 64 entries")
    }

    var actions: [ForegroundAction] = []
    var screenshotPaths = Set<String>()
    for (index, rawAction) in rawActions.enumerated() {
        let context = "foreground action \(index)"
        guard let object = rawAction as? [String: Any],
              let rawKind = object["kind"] as? String,
              let kind = ForegroundActionKind(rawValue: rawKind) else {
            throw DriverError.badArguments("\(context) has an unsupported kind")
        }

        let commonKeys: Set<String> = ["kind", "waitMs"]
        let specificKeys: Set<String>
        let requiredKeys: Set<String>
        switch kind {
        case .moveSafePoint, .moveOutline, .shiftTap:
            specificKeys = []
            requiredKeys = ["kind"]
        case .windowMove, .windowClick:
            specificKeys = ["xFraction", "yFraction"]
            requiredKeys = ["kind", "xFraction", "yFraction"]
        case .windowDrag:
            specificKeys = ["xFraction", "yFraction", "deltaX", "deltaY"]
            requiredKeys = ["kind", "xFraction", "yFraction"]
        case .elementClick:
            specificKeys = [
                "identifier", "role", "expectedValue", "expectedSelected",
                "expectedFrameWidth", "expectedFrameHeight",
                "xFraction", "yFraction",
            ]
            requiredKeys = ["kind", "identifier"]
        case .elementMove, .elementCheck, .focusedElementCheck:
            specificKeys = [
                "identifier", "role", "expectedValue", "expectedSelected",
                "expectedFrameWidth", "expectedFrameHeight",
            ]
            requiredKeys = ["kind", "identifier"]
        case .elementDescriptionCheck:
            specificKeys = [
                "description", "role", "expectedValue", "expectedSelected",
                "expectedFrameWidth", "expectedFrameHeight",
            ]
            requiredKeys = ["kind", "description"]
        case .elementDrag:
            specificKeys = [
                "identifier", "role", "expectedValue", "expectedSelected",
                "expectedFrameWidth", "expectedFrameHeight",
                "deltaX", "deltaY",
            ]
            requiredKeys = ["kind", "identifier"]
        case .scroll:
            specificKeys = ["deltaY"]
            requiredKeys = ["kind", "deltaY"]
        case .key:
            specificKeys = ["key"]
            requiredKeys = ["kind", "key"]
        case .text, .pasteboardStringCheck:
            specificKeys = ["text"]
            requiredKeys = ["kind", "text"]
        case .findControlClick:
            specificKeys = ["control"]
            requiredKeys = ["kind", "control"]
        case .windowScreenshot:
            specificKeys = ["path"]
            requiredKeys = ["kind", "path"]
        case .wait:
            specificKeys = ["durationMs"]
            requiredKeys = ["kind", "durationMs"]
        }
        let allowedKeys = kind == .wait ? Set(["kind", "durationMs"]) : commonKeys.union(specificKeys)
        try validateJSONKeys(
            object,
            required: requiredKeys,
            allowed: allowedKeys,
            context: context
        )

        let waitMs: Int
        let durationMs: Int?
        if kind == .wait {
            waitMs = 0
            let duration = try jsonInteger(object["durationMs"], field: "\(context).durationMs")
            guard (40...400).contains(duration) else {
                throw DriverError.badArguments("\(context).durationMs must be from 40 through 400")
            }
            durationMs = duration
        } else {
            waitMs = try object["waitMs"].map {
                try jsonInteger($0, field: "\(context).waitMs")
            } ?? foregroundDefaultWaitMs
            guard (40...80).contains(waitMs) else {
                throw DriverError.badArguments("\(context).waitMs must be from 40 through 80")
            }
            durationMs = nil
        }

        var key: String?
        var text: String?
        var control: String?
        var screenshotPath: String?
        var xFraction: Double?
        var yFraction: Double?
        var elementSelector: ForegroundElementSelector?
        var deltaX: Int?
        var deltaY: Int?
        switch kind {
        case .key:
            guard let value = object["key"] as? String, !value.isEmpty else {
                throw DriverError.badArguments("\(context).key requires a nonempty string")
            }
            _ = try keySpec(value)
            key = value
        case .text:
            guard let value = object["text"] as? String,
                  !value.isEmpty,
                  value.utf16.count <= 256 else {
                throw DriverError.badArguments(
                    "\(context).text requires 1 through 256 UTF-16 code units"
                )
            }
            text = value
        case .pasteboardStringCheck:
            guard let value = object["text"] as? String,
                  !value.isEmpty,
                  value.utf16.count <= 4_096 else {
                throw DriverError.badArguments(
                    "\(context).text requires 1 through 4096 UTF-16 code units"
                )
            }
            text = value
        case .findControlClick:
            guard let value = object["control"] as? String else {
                throw DriverError.badArguments("\(context).control requires a string")
            }
            _ = try findControlPoint(value, windowWidth: 1_180, windowHeight: 760)
            control = value
        case .windowScreenshot:
            guard let value = object["path"] as? String else {
                throw DriverError.badArguments("\(context).path requires a string")
            }
            let validatedPath = try validateScreenshotPath(value, context: context)
            guard screenshotPaths.insert(validatedPath).inserted else {
                throw DriverError.badArguments("foreground screenshot paths must be unique")
            }
            screenshotPath = validatedPath
        case .windowMove, .windowClick, .windowDrag:
            let x = try jsonDouble(
                object["xFraction"],
                field: "\(context).xFraction"
            )
            let y = try jsonDouble(
                object["yFraction"],
                field: "\(context).yFraction"
            )
            guard (0...1).contains(x) else {
                throw DriverError.badArguments(
                    "\(context).xFraction must be from 0 through 1"
                )
            }
            guard (0...1).contains(y) else {
                throw DriverError.badArguments(
                    "\(context).yFraction must be from 0 through 1"
                )
            }
            xFraction = x
            yFraction = y
            if kind == .windowDrag {
                let xDelta = try object["deltaX"].map {
                    try jsonInteger($0, field: "\(context).deltaX")
                } ?? 0
                let yDelta = try object["deltaY"].map {
                    try jsonInteger($0, field: "\(context).deltaY")
                } ?? 0
                guard (-2_000...2_000).contains(xDelta),
                      (-2_000...2_000).contains(yDelta),
                      xDelta != 0 || yDelta != 0 else {
                    throw DriverError.badArguments(
                        "\(context) window-drag requires a nonzero deltaX or deltaY, each from -2000 through 2000"
                    )
                }
                deltaX = xDelta
                deltaY = yDelta
            }
        case .elementMove, .elementClick, .elementCheck, .elementDescriptionCheck,
             .elementDrag, .focusedElementCheck:
            let identifier: String?
            let description: String?
            if kind == .elementDescriptionCheck {
                guard let value = object["description"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= 256 else {
                    throw DriverError.badArguments(
                        "\(context).description requires 1 through 256 UTF-16 code units"
                    )
                }
                identifier = nil
                description = value
            } else {
                guard let value = object["identifier"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= 256 else {
                    throw DriverError.badArguments(
                        "\(context).identifier requires 1 through 256 UTF-16 code units"
                    )
                }
                identifier = value
                description = nil
            }
            let role: String?
            if let rawRole = object["role"] {
                guard let value = rawRole as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= 128 else {
                    throw DriverError.badArguments(
                        "\(context).role requires 1 through 128 UTF-16 code units"
                    )
                }
                role = value
            } else {
                role = nil
            }
            let expectedValue: String?
            if let rawExpectedValue = object["expectedValue"] {
                guard let value = rawExpectedValue as? String,
                      value.utf16.count <= 4_096 else {
                    throw DriverError.badArguments(
                        "\(context).expectedValue requires at most 4096 UTF-16 code units"
                    )
                }
                expectedValue = value
            } else {
                expectedValue = nil
            }
            let expectedSelected: Bool?
            if let rawExpectedSelected = object["expectedSelected"] {
                guard let number = rawExpectedSelected as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw DriverError.badArguments(
                        "\(context).expectedSelected requires a boolean"
                    )
                }
                expectedSelected = number.boolValue
            } else {
                expectedSelected = nil
            }
            let expectedFrameWidth = try object["expectedFrameWidth"].map {
                try jsonDouble($0, field: "\(context).expectedFrameWidth")
            }
            let expectedFrameHeight = try object["expectedFrameHeight"].map {
                try jsonDouble($0, field: "\(context).expectedFrameHeight")
            }
            guard expectedFrameWidth.map({ $0.isFinite && $0 > 0 }) ?? true,
                  expectedFrameHeight.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw DriverError.badArguments(
                    "\(context) expected frame dimensions must be finite and positive"
                )
            }
            elementSelector = ForegroundElementSelector(
                identifier: identifier,
                description: description,
                role: role,
                expectedValue: expectedValue,
                expectedSelected: expectedSelected,
                expectedFrameWidth: expectedFrameWidth,
                expectedFrameHeight: expectedFrameHeight
            )
            if kind == .elementClick {
                let rawX = object["xFraction"]
                let rawY = object["yFraction"]
                guard (rawX == nil) == (rawY == nil) else {
                    throw DriverError.badArguments(
                        "\(context) element-click requires xFraction and yFraction together"
                    )
                }
                if let rawX, let rawY {
                    let x = try jsonDouble(rawX, field: "\(context).xFraction")
                    let y = try jsonDouble(rawY, field: "\(context).yFraction")
                    guard (0...1).contains(x), (0...1).contains(y) else {
                        throw DriverError.badArguments(
                            "\(context) element-click fractions must be from 0 through 1"
                        )
                    }
                    xFraction = x
                    yFraction = y
                }
            }
            if kind == .elementDrag {
                let x = try object["deltaX"].map {
                    try jsonInteger($0, field: "\(context).deltaX")
                } ?? 0
                let y = try object["deltaY"].map {
                    try jsonInteger($0, field: "\(context).deltaY")
                } ?? 0
                guard (-2_000...2_000).contains(x),
                      (-2_000...2_000).contains(y),
                      x != 0 || y != 0 else {
                    throw DriverError.badArguments(
                        "\(context) element-drag requires a nonzero deltaX or deltaY, each from -2000 through 2000"
                    )
                }
                deltaX = x
                deltaY = y
            }
        case .scroll:
            let value = try jsonInteger(object["deltaY"], field: "\(context).deltaY")
            guard value != 0, (-2_000...2_000).contains(value) else {
                throw DriverError.badArguments(
                    "\(context).deltaY must be a nonzero integer from -2000 through 2000"
                )
            }
            deltaY = value
        case .moveSafePoint, .moveOutline, .shiftTap, .wait:
            break
        }
        actions.append(ForegroundAction(
            kind: kind,
            waitMs: waitMs,
            durationMs: durationMs,
            key: key,
            text: text,
            control: control,
            path: screenshotPath,
            xFraction: xFraction,
            yFraction: yFraction,
            elementSelector: elementSelector,
            deltaX: deltaX,
            deltaY: deltaY
        ))
    }

    let estimatedForegroundMs = foregroundEstimatedDuration(actions: actions)
    guard estimatedForegroundMs + foregroundCleanupReserveMs <= budgetMs else {
        throw DriverError.badArguments(
            "foreground plan needs about \(estimatedForegroundMs + foregroundCleanupReserveMs) ms, exceeding the \(budgetMs) ms budget"
        )
    }
    return ForegroundPlan(actions: actions)
}

private func foregroundEstimatedDuration(actions: [ForegroundAction]) -> Int {
    foregroundActivationWaitMs + actions.reduce(0) { total, action in
        switch action.kind {
        case .findControlClick, .windowClick:
            return total + foregroundClickGapMs * 2 + action.waitMs
        case .windowDrag:
            return total + foregroundClickGapMs * foregroundDragGapCount
                + action.waitMs
        case .elementClick:
            return total + foregroundElementLookupEstimateMs
                + foregroundClickGapMs * 2 + action.waitMs
        case .elementDrag:
            return total + foregroundElementLookupEstimateMs
                + foregroundClickGapMs * foregroundDragGapCount
                + action.waitMs
        case .elementMove, .elementCheck, .elementDescriptionCheck,
             .focusedElementCheck:
            return total + foregroundElementLookupEstimateMs + action.waitMs
        case .windowScreenshot:
            return total + foregroundScreenshotEstimateMs + action.waitMs
        case .wait:
            return total + (action.durationMs ?? 0)
        default:
            return total + action.waitMs
        }
    }
}

private func foregroundSelectorDetail(_ selector: ForegroundElementSelector) -> String {
    var parts: [String] = []
    if let identifier = selector.identifier {
        parts.append("identifier=\(identifier)")
    }
    if let description = selector.description {
        parts.append("description=\(description)")
    }
    if let role = selector.role {
        parts.append("role=\(role)")
    }
    return parts.joined(separator: ",")
}

private func foregroundActionDetail(_ action: ForegroundAction) -> String? {
    switch action.kind {
    case .key: return action.key
    case .text: return "\(action.text?.utf16.count ?? 0) UTF-16 code units"
    case .pasteboardStringCheck:
        return "exact string with \(action.text?.utf16.count ?? 0) UTF-16 code units"
    case .findControlClick: return action.control
    case .windowScreenshot: return action.path
    case .wait: return "\(action.durationMs ?? 0) ms"
    case .windowMove, .windowClick:
        return String(
            format: "%.4f,%.4f",
            action.xFraction ?? 0,
            action.yFraction ?? 0
        )
    case .windowDrag:
        return String(
            format: "%.4f,%.4f,deltaX=%d,deltaY=%d",
            action.xFraction ?? 0,
            action.yFraction ?? 0,
            action.deltaX ?? 0,
            action.deltaY ?? 0
        )
    case .elementDrag:
        guard let selector = action.elementSelector else { return nil }
        let selectorDetail = foregroundSelectorDetail(selector)
        return "\(selectorDetail),deltaX=\(action.deltaX ?? 0),deltaY=\(action.deltaY ?? 0)"
    case .elementMove, .elementClick, .elementCheck, .elementDescriptionCheck,
        .focusedElementCheck:
        guard let selector = action.elementSelector else { return nil }
        var detail = foregroundSelectorDetail(selector)
        if let expectedValue = selector.expectedValue {
            detail += ",expectedValueUTF16=\(expectedValue.utf16.count)"
        }
    if let expectedSelected = selector.expectedSelected {
        detail += ",expectedSelected=\(expectedSelected)"
    }
    if let expectedFrameWidth = selector.expectedFrameWidth {
        detail += ",expectedFrameWidth=\(expectedFrameWidth)"
    }
    if let expectedFrameHeight = selector.expectedFrameHeight {
        detail += ",expectedFrameHeight=\(expectedFrameHeight)"
    }
        if let xFraction = action.xFraction, let yFraction = action.yFraction {
            detail += String(
                format: ",xFraction=%.4f,yFraction=%.4f",
                xFraction,
                yFraction
            )
        }
        return detail
    case .scroll:
        return "\(action.deltaY ?? 0) pixels"
    case .moveSafePoint, .moveOutline, .shiftTap: return nil
    }
}

private func foregroundPlanReport(plan: ForegroundPlan, budgetMs: Int) -> ForegroundPlanReport {
    ForegroundPlanReport(
        valid: true,
        budgetMs: budgetMs,
        estimatedForegroundMs: foregroundEstimatedDuration(actions: plan.actions),
        cleanupReserveMs: foregroundCleanupReserveMs,
        actions: plan.actions.enumerated().map { index, action in
            ForegroundPlanActionReport(
                index: index,
                kind: action.kind.rawValue,
                waitMs: action.kind == .wait ? nil : action.waitMs,
                durationMs: action.durationMs,
                detail: foregroundActionDetail(action)
            )
        }
    )
}

private func windowReport(from item: [String: Any]) -> WindowReport? {
    guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
          pid > 0 else {
        return nil
    }
    let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
    guard layer >= 0,
          let number = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          number > 0,
          let rawBounds = item[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
          bounds.origin.x.isFinite,
          bounds.origin.y.isFinite,
          bounds.width.isFinite,
          bounds.height.isFinite,
          bounds.width > 0,
          bounds.height > 0 else {
        return nil
    }
    return WindowReport(
        pid: pid,
        owner: item[kCGWindowOwnerName as String] as? String ?? "",
        title: item[kCGWindowName as String] as? String ?? "",
        windowNumber: number,
        bounds: WindowBounds(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
        ),
        layer: layer,
        onScreen: (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    )
}

private func windowReports(for pid: Int32, includeOffscreen: Bool = false) -> [WindowReport] {
    let options: CGWindowListOption = includeOffscreen
        ? [.excludeDesktopElements]
        : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return windows.compactMap { item in
        guard let report = windowReport(from: item), report.pid == pid else {
            return nil
        }
        return report
    }
}

private func topmostOnScreenWindow(at point: CGPoint) -> WindowReport? {
    guard point.x.isFinite,
          point.y.isFinite,
          let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
          ) as? [[String: Any]] else {
        return nil
    }
    // The Window Server returns this list front-to-back. Preserve that visual
    // evidence, including nonzero-layer overlays. Some system overlays are input
    // transparent, so Accessibility hit testing is the authoritative click gate.
    for item in windows {
        guard let report = windowReport(from: item), report.onScreen else {
            continue
        }
        // WindowServer publishes the cursor as an on-screen window above every
        // application window. It follows the pointer but never receives the
        // mouse event, so it is not part of pointer hit routing.
        guard !(report.owner == "Window Server" && report.title == "Cursor") else {
            continue
        }
        let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { continue }
        let bounds = report.bounds
        if point.x >= bounds.x,
           point.x < bounds.x + bounds.width,
           point.y >= bounds.y,
           point.y < bounds.y + bounds.height {
            return report
        }
    }
    return nil
}

private func windowInfo(
    for pid: Int32,
    includeOffscreen: Bool = false,
    mainWindowOnly: Bool = false
) -> WindowReport? {
    windowReports(for: pid, includeOffscreen: includeOffscreen)
        .filter { !mainWindowOnly || $0.layer == 0 }
        .max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
}

private func windowInfo(
    for pid: Int32,
    windowNumber: UInt32,
    includeOffscreen: Bool = false
) -> WindowReport? {
    windowReports(for: pid, includeOffscreen: includeOffscreen).first {
        $0.windowNumber == windowNumber
    }
}

private func waitForWindow(
    pid: Int32,
    timeout: Double,
    expectedWidth: Double? = nil,
    expectedHeight: Double? = nil,
    includeOffscreen: Bool = false,
    requireOffscreen: Bool = false,
    allowUniformPresentationScale: Bool = false,
    mainWindowOnly: Bool = false
) throws -> WindowReport {
    let deadline = Date().addingTimeInterval(timeout)
    var sawWindow = false
    var sawMatchingWindow = false
    repeat {
        if let window = windowInfo(
            for: pid,
            includeOffscreen: includeOffscreen,
            mainWindowOnly: mainWindowOnly
        ) {
            sawWindow = true
            let widthMatches = expectedWidth.map { abs(window.bounds.width - $0) <= 0.5 } ?? true
            let heightMatches = expectedHeight.map { abs(window.bounds.height - $0) <= 0.5 } ?? true
            if widthMatches && heightMatches {
                sawMatchingWindow = true
                if !requireOffscreen || !window.onScreen { return window }
            }
            if allowUniformPresentationScale,
               let expectedWidth,
               let expectedHeight {
                let scaleX = window.bounds.width / expectedWidth
                let scaleY = window.bounds.height / expectedHeight
                if (0.75...1).contains(scaleX),
                   (0.75...1).contains(scaleY),
                   abs(scaleX - scaleY) <= 0.005 {
                    sawMatchingWindow = true
                    if !requireOffscreen || !window.onScreen { return window }
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    if requireOffscreen, sawMatchingWindow {
        throw DriverError.badArguments(
            "window for pid \(pid) did not become offscreen before timeout"
        )
    }
    if sawWindow, let width = expectedWidth, let height = expectedHeight {
        throw DriverError.windowSize(pid, width, height)
    }
    throw DriverError.windowMissing(pid)
}

private func waitForWindow(
    pid: Int32,
    windowNumber: UInt32,
    timeout: Double,
    includeOffscreen: Bool,
    requireOffscreen: Bool = false
) throws -> WindowReport {
    let deadline = Date().addingTimeInterval(timeout)
    var sawWindow = false
    repeat {
        if let window = windowInfo(
            for: pid,
            windowNumber: windowNumber,
            includeOffscreen: includeOffscreen
        ) {
            sawWindow = true
            if !requireOffscreen || !window.onScreen { return window }
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    if requireOffscreen, sawWindow {
        throw DriverError.badArguments(
            "window \(windowNumber) for pid \(pid) did not become offscreen before timeout"
        )
    }
    throw DriverError.windowNumberMissing(pid, windowNumber)
}

private func eventSource() -> CGEventSource? {
    CGEventSource(stateID: .hidSystemState)
}

private func postKey(
    _ keyCode: CGKeyCode,
    modifiers: CGEventFlags,
    pid: Int32
) throws {
    let source = eventSource()
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw DriverError.eventCreation("key \(keyCode)")
    }
    down.flags = modifiers
    up.flags = modifiers
    down.postToPid(pid)
    up.postToPid(pid)
}

private func postShiftTap(pid: Int32) throws {
    let source = eventSource()
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else {
        throw DriverError.eventCreation("shift modifier")
    }
    down.flags = .maskShift
    up.flags = []
    down.postToPid(pid)
    up.postToPid(pid)
}

private func postText(_ text: String, pid: Int32) throws {
    let source = eventSource()
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        throw DriverError.eventCreation("text")
    }
    let utf16 = Array(text.utf16)
    utf16.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
        )
        up.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
        )
    }
    down.postToPid(pid)
    up.postToPid(pid)
}

private func postMouseClick(at point: CGPoint, pid: Int32) throws {
    let source = eventSource()
    guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
          ) else {
        throw DriverError.eventCreation("mouse click")
    }
    try focusTargetForGlobalPointerEvent(pid: pid)
    Thread.sleep(forTimeInterval: 0.12)
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    moved.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    up.post(tap: .cghidEventTap)
}

private func postMouseMove(at point: CGPoint) throws {
    let source = eventSource()
    guard let moved = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        throw DriverError.eventCreation("mouse move")
    }
    moved.post(tap: .cghidEventTap)
}

private func postScroll(delta: Int32, at point: CGPoint, pid: Int32) throws {
    let source = eventSource()
    guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let scroll = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
          ) else {
        throw DriverError.eventCreation("scroll")
    }
    try focusTargetForGlobalPointerEvent(pid: pid)
    Thread.sleep(forTimeInterval: 0.12)
    moved.post(tap: .cghidEventTap)
    scroll.post(tap: .cghidEventTap)
}

private func focusTargetForGlobalPointerEvent(pid: Int32) throws {
    guard AXIsProcessTrusted() else {
        throw DriverError.permissionDenied(
            "macOS Accessibility permission is required to focus the target before a global pointer event"
        )
    }
    try setApplicationFrontmost(pid: pid)
}

private func setApplicationFrontmost(pid: Int32) throws {
    let application = AXUIElementCreateApplication(pid)
    let result = AXUIElementSetAttributeValue(
        application,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
    )
    guard result == .success else {
        throw DriverError.badArguments(
            "could not set process \(pid) frontmost through Accessibility: \(result.rawValue)"
        )
    }
}

private func postVisualTestActivationRequest(pid: Int32, launchToken: UUID) {
    let name = Notification.Name(
        "local.codex.markdownviewer.visual-test.activate." + launchToken.uuidString
    )
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: String(pid),
        userInfo: nil,
        deliverImmediately: true
    )
}

private func waitForForegroundActivation(
    pid: Int32,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws -> Bool {
    let activationDeadline = min(
        deadline,
        monotonicNanoseconds() + UInt64(foregroundActivationWaitMs) * 1_000_000
    )
    while monotonicNanoseconds() < activationDeadline {
        try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return true
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.005)
        )
    }
    try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

private func keySpec(_ rawSpec: String) throws -> (CGKeyCode, CGEventFlags) {
    let components = rawSpec.lowercased().split(separator: "+").map(String.init)
    guard let keyName = components.last else {
        throw DriverError.badArguments("empty key specification")
    }

    var modifiers: CGEventFlags = []
    for modifier in components.dropLast() {
        switch modifier {
        case "command", "cmd": modifiers.insert(.maskCommand)
        case "shift": modifiers.insert(.maskShift)
        case "option", "alt": modifiers.insert(.maskAlternate)
        case "control", "ctrl": modifiers.insert(.maskControl)
        default: throw DriverError.badArguments("unknown key modifier: \(modifier)")
        }
    }

    let keyCodes: [String: CGKeyCode] = [
        "a": 0,
        "s": 1,
        "f": 3,
        "z": 6,
        "b": 11,
        "w": 13,
        "e": 14,
        "t": 17,
        "equals": 24,
        "=": 24,
        "minus": 27,
        "-": 27,
        "zero": 29,
        "0": 29,
        "o": 31,
        "i": 34,
        "k": 40,
        "n": 45,
        "p": 35,
        "return": 36,
        "enter": 36,
        "tab": 48,
        "space": 49,
        "delete": 51,
        "backspace": 51,
        "escape": 53,
        "esc": 53,
        "backslash": 42,
        "up": 126,
        "down": 125,
        "left": 123,
        "right": 124,
        "pageup": 116,
        "pagedown": 121,
        "home": 115,
        "end": 119,
    ]
    guard let keyCode = keyCodes[keyName] else {
        throw DriverError.badArguments("unsupported key: \(keyName)")
    }
    return (keyCode, modifiers)
}

private func actionArguments(_ arguments: [String]) throws -> [String] {
    guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
        throw DriverError.badArguments("send requires actions after --")
    }
    return Array(arguments[(separator + 1)...])
}

private func relativePoint(_ raw: String, prefix: String, window: WindowReport) throws -> CGPoint {
    let coordinates = raw.dropFirst(prefix.count).split(separator: ",").map(String.init)
    guard coordinates.count == 2,
          let relativeX = Double(coordinates[0]),
          let relativeY = Double(coordinates[1]) else {
        throw DriverError.badArguments("\(prefix) requires x,y coordinates")
    }
    guard relativeX >= 0,
          relativeY >= 0,
          relativeX < window.bounds.width,
          relativeY < window.bounds.height else {
        throw DriverError.badArguments("relative point is outside the target window: \(relativeX),\(relativeY)")
    }
    return CGPoint(x: window.bounds.x + relativeX, y: window.bounds.y + relativeY)
}

private func findControlPoint(
    _ control: String,
    windowWidth: Double,
    windowHeight: Double
) throws -> CGPoint {
    let relativePoint: CGPoint
    switch control {
    case "disclosure":
        relativePoint = CGPoint(x: windowWidth - 456, y: 74)
    case "whole-word":
        relativePoint = CGPoint(x: windowWidth - 159, y: 74)
    case "query-field":
        relativePoint = CGPoint(x: windowWidth - 320, y: 74)
    case "replace-field":
        relativePoint = CGPoint(x: windowWidth - 320, y: 108)
    case "replace-current":
        relativePoint = CGPoint(x: windowWidth - 122, y: 108)
    case "replace-all":
        relativePoint = CGPoint(x: windowWidth - 59, y: 108)
    default:
        throw DriverError.badArguments("unsupported find control: \(control)")
    }
    guard relativePoint.x >= 0,
          relativePoint.y >= 0,
          relativePoint.x < windowWidth,
          relativePoint.y < windowHeight else {
        throw DriverError.badArguments(
            "find control is outside the target window: \(control)"
        )
    }
    return relativePoint
}

private func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func elapsedMilliseconds(since start: UInt64, until end: UInt64? = nil) -> Int {
    let finish = end ?? monotonicNanoseconds()
    guard finish >= start else { return 0 }
    return Int((finish - start) / 1_000_000)
}

private let foregroundObservedEventTypes: [CGEventType] = [
    .leftMouseDown,
    .leftMouseUp,
    .rightMouseDown,
    .rightMouseUp,
    .mouseMoved,
    .leftMouseDragged,
    .rightMouseDragged,
    .keyDown,
    .keyUp,
    .flagsChanged,
    .scrollWheel,
    .otherMouseDown,
    .otherMouseUp,
    .otherMouseDragged,
]

private func foregroundEventMask() -> CGEventMask {
    foregroundObservedEventTypes.reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << CGEventMask(type.rawValue))
    }
}

private func foregroundEventName(_ type: CGEventType) -> String {
    switch type {
    case .leftMouseDown: return "left-mouse-down"
    case .leftMouseUp: return "left-mouse-up"
    case .rightMouseDown: return "right-mouse-down"
    case .rightMouseUp: return "right-mouse-up"
    case .mouseMoved: return "mouse-moved"
    case .leftMouseDragged: return "left-mouse-dragged"
    case .rightMouseDragged: return "right-mouse-dragged"
    case .keyDown: return "key-down"
    case .keyUp: return "key-up"
    case .flagsChanged: return "flags-changed"
    case .scrollWheel: return "scroll"
    case .otherMouseDown: return "other-mouse-down"
    case .otherMouseUp: return "other-mouse-up"
    case .otherMouseDragged: return "other-mouse-dragged"
    default: return "event-\(type.rawValue)"
    }
}

private func foregroundEventUsesPointer(_ type: CGEventType) -> Bool {
    switch type {
    case .leftMouseDown,
         .leftMouseUp,
         .rightMouseDown,
         .rightMouseUp,
         .mouseMoved,
         .leftMouseDragged,
         .rightMouseDragged,
         .scrollWheel,
         .otherMouseDown,
         .otherMouseUp,
         .otherMouseDragged:
        return true
    default:
        return false
    }
}

private func foregroundEventMayOwnPointerPosition(_ type: CGEventType) -> Bool {
    foregroundEventUsesPointer(type) && type != .scrollWheel
}

private struct ForegroundInjectedPointerAccumulator {
    var moveCount = 0
    var leftMouseDownCount = 0
    var leftMouseDraggedCount = 0
    var leftMouseUpCount = 0
    var lastMoveLocation: CGPoint?
    var lastLeftMouseDownLocation: CGPoint?
    var lastLeftMouseDraggedLocation: CGPoint?
    var lastLeftMouseUpLocation: CGPoint?

    mutating func observe(type: CGEventType, location: CGPoint) {
        guard location.x.isFinite, location.y.isFinite else { return }
        switch type {
        case .mouseMoved:
            moveCount += 1
            lastMoveLocation = location
        case .leftMouseDown:
            leftMouseDownCount += 1
            lastLeftMouseDownLocation = location
        case .leftMouseDragged:
            leftMouseDraggedCount += 1
            lastLeftMouseDraggedLocation = location
        case .leftMouseUp:
            leftMouseUpCount += 1
            lastLeftMouseUpLocation = location
        default:
            break
        }
    }

    func report(
        since baseline: ForegroundInjectedPointerEventsReport? = nil
    ) -> ForegroundInjectedPointerEventsReport {
        let reportedMoveCount = moveCount - (baseline?.moveCount ?? 0)
        let reportedDownCount = leftMouseDownCount
            - (baseline?.leftMouseDownCount ?? 0)
        let reportedDraggedCount = leftMouseDraggedCount
            - (baseline?.leftMouseDraggedCount ?? 0)
        let reportedUpCount = leftMouseUpCount
            - (baseline?.leftMouseUpCount ?? 0)
        return ForegroundInjectedPointerEventsReport(
            moveCount: reportedMoveCount,
            leftMouseDownCount: reportedDownCount,
            leftMouseDraggedCount: reportedDraggedCount,
            leftMouseUpCount: reportedUpCount,
            lastMoveLocation: reportedMoveCount > 0
                ? lastMoveLocation.map { DesktopPointerReport(x: $0.x, y: $0.y) }
                : nil,
            lastLeftMouseDownLocation: reportedDownCount > 0
                ? lastLeftMouseDownLocation.map {
                    DesktopPointerReport(x: $0.x, y: $0.y)
                }
                : nil,
            lastLeftMouseDraggedLocation: reportedDraggedCount > 0
                ? lastLeftMouseDraggedLocation.map {
                    DesktopPointerReport(x: $0.x, y: $0.y)
                }
                : nil,
            lastLeftMouseUpLocation: reportedUpCount > 0
                ? lastLeftMouseUpLocation.map {
                    DesktopPointerReport(x: $0.x, y: $0.y)
                }
                : nil,
            completeClickSequenceObserved: reportedMoveCount > 0
                && reportedDownCount > 0
                && reportedUpCount > 0,
            completeDragSequenceObserved: reportedMoveCount > 0
                && reportedDownCount > 0
                && reportedDraggedCount > 0
                && reportedUpCount > 0
        )
    }
}

private final class ForegroundInterferenceMonitor {
    let targetPID: Int32
    let nonce: Int64
    let startedAt: UInt64
    private(set) var eventType: String?
    private(set) var detectedAt: UInt64?
    private(set) var pointerInputDetected = false
    private(set) var pointerPositionInterferenceDetected = false
    private(set) var eventTapReliable = true
    private var sessionInjectedPointerEvents = ForegroundInjectedPointerAccumulator()
    private var targetInjectedPointerEvents = ForegroundInjectedPointerAccumulator()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetEventTap: CFMachPort?
    private var targetRunLoopSource: CFRunLoopSource?

    init(targetPID: Int32, nonce: Int64, startedAt: UInt64) {
        self.targetPID = targetPID
        self.nonce = nonce
        self.startedAt = startedAt
    }

    var detected: Bool { eventType != nil }
    var pointerRestorationUnsafe: Bool {
        pointerPositionInterferenceDetected || !eventTapReliable
    }

    func start() throws {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: foregroundEventMask(),
            callback: foregroundEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw DriverError.permissionDenied(
                "macOS Input Monitoring permission is required for foreground interference detection"
            )
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard let targetTap = CGEvent.tapCreateForPid(
            pid: targetPID,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: foregroundEventMask(),
            callback: foregroundTargetEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stop()
            throw DriverError.permissionDenied(
                "could not create the target-process foreground delivery event tap"
            )
        }
        let targetSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            targetTap,
            0
        )
        targetEventTap = targetTap
        targetRunLoopSource = targetSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), targetSource, .commonModes)
        CGEvent.tapEnable(tap: targetTap, enable: true)
    }

    func stop() {
        if let tap = targetEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = targetRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        targetRunLoopSource = nil
        targetEventTap = nil
    }

    func observe(type: CGEventType, event: CGEvent) {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if tag == nonce {
            sessionInjectedPointerEvents.observe(type: type, location: event.location)
            return
        }
        if foregroundEventUsesPointer(type) {
            pointerInputDetected = true
        }
        if foregroundEventMayOwnPointerPosition(type) {
            pointerPositionInterferenceDetected = true
        }
        record(eventType: foregroundEventName(type))
    }

    func observeTarget(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) == nonce else { return }
        targetInjectedPointerEvents.observe(type: type, location: event.location)
    }

    func injectedPointerEvents(
        since baseline: ForegroundInjectedPointerEventsReport? = nil
    ) -> ForegroundInjectedPointerEventsReport {
        sessionInjectedPointerEvents.report(since: baseline)
    }

    func targetInjectedPointerEventsReport(
        since baseline: ForegroundInjectedPointerEventsReport? = nil
    ) -> ForegroundInjectedPointerEventsReport {
        targetInjectedPointerEvents.report(since: baseline)
    }

    func recordEventTapFailure(eventType: String) {
        eventTapReliable = false
        record(eventType: eventType)
    }

    func record(eventType: String) {
        guard !detected else { return }
        self.eventType = eventType
        detectedAt = monotonicNanoseconds()
    }

    func report() -> ForegroundInterferenceReport {
        ForegroundInterferenceReport(
            detected: detected,
            eventType: eventType,
            atMs: detectedAt.map { elapsedMilliseconds(since: startedAt, until: $0) },
            pointerInputDetected: pointerInputDetected,
            pointerPositionInterferenceDetected: pointerPositionInterferenceDetected,
            eventTapReliable: eventTapReliable
        )
    }
}

private let foregroundEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    if let userInfo {
        let monitor = Unmanaged<ForegroundInterferenceMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        if type == .tapDisabledByTimeout {
            monitor.recordEventTapFailure(eventType: "event-tap-timeout")
        } else if type == .tapDisabledByUserInput {
            monitor.recordEventTapFailure(eventType: "event-tap-disabled-by-user-input")
        } else {
            monitor.observe(type: type, event: event)
        }
    }
    // This is a listen-only tap. Always return the original event unchanged.
    return Unmanaged.passUnretained(event)
}

private let foregroundTargetEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    if let userInfo {
        let monitor = Unmanaged<ForegroundInterferenceMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        if type == .tapDisabledByTimeout {
            monitor.recordEventTapFailure(eventType: "target-event-tap-timeout")
        } else if type == .tapDisabledByUserInput {
            monitor.recordEventTapFailure(
                eventType: "target-event-tap-disabled-by-user-input"
            )
        } else {
            monitor.observeTarget(type: type, event: event)
        }
    }
    return Unmanaged.passUnretained(event)
}

private enum ForegroundBatchStop: Error {
    case interference
    case deadline
}

private struct HeldForegroundKey: Hashable {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    static func == (lhs: HeldForegroundKey, rhs: HeldForegroundKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

private final class ForegroundInputState {
    let pid: Int32
    let nonce: Int64
    var heldKeys = Set<HeldForegroundKey>()
    var leftButtonDown = false
    var lastInjectedPointer: CGPoint?

    init(pid: Int32, nonce: Int64) {
        self.pid = pid
        self.nonce = nonce
    }

    func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: nonce)
    }

    func releaseInputs() {
        let source = eventSource()
        for held in heldKeys {
            if let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: held.keyCode,
                keyDown: false
            ) {
                up.flags = held.modifiers
                tag(up)
                up.postToPid(pid)
            }
        }
        heldKeys.removeAll()

        if leftButtonDown, let point = lastInjectedPointer,
           let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
           ) {
            tag(up)
            up.post(tap: .cghidEventTap)
        }
        leftButtonDown = false
    }
}

private func ensureForegroundCanContinue(
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws {
    if monitor.detected { throw ForegroundBatchStop.interference }
    if monotonicNanoseconds() >= deadline { throw ForegroundBatchStop.deadline }
}

private func foregroundWait(
    milliseconds: Int,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws {
    let now = monotonicNanoseconds()
    let requestedEnd = now + UInt64(milliseconds) * 1_000_000
    guard requestedEnd <= deadline else { throw ForegroundBatchStop.deadline }
    while true {
        try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
        let current = monotonicNanoseconds()
        guard current < requestedEnd else { break }
        let remaining = requestedEnd - current
        let slice = min(0.01, Double(remaining) / 1_000_000_000)
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: max(0.001, slice))
        )
    }
    try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
}

private func postForegroundKey(
    spec: String,
    input: ForegroundInputState
) throws {
    let (keyCode, modifiers) = try keySpec(spec)
    let source = eventSource()
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw DriverError.eventCreation("foreground key \(spec)")
    }
    down.flags = modifiers
    up.flags = modifiers
    input.tag(down)
    input.tag(up)
    let held = HeldForegroundKey(keyCode: keyCode, modifiers: modifiers)
    input.heldKeys.insert(held)
    down.postToPid(input.pid)
    up.postToPid(input.pid)
    input.heldKeys.remove(held)
}

private func postForegroundShiftTap(input: ForegroundInputState) throws {
    let source = eventSource()
    guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: 56,
            keyDown: true
          ),
          let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: 56,
            keyDown: false
          ) else {
        throw DriverError.eventCreation("foreground shift modifier")
    }
    down.flags = .maskShift
    up.flags = []
    input.tag(down)
    input.tag(up)
    let held = HeldForegroundKey(keyCode: 56, modifiers: .maskShift)
    input.heldKeys.insert(held)
    down.postToPid(input.pid)
    up.postToPid(input.pid)
    input.heldKeys.remove(held)
}

private func postForegroundText(_ text: String, input: ForegroundInputState) throws {
    let source = eventSource()
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        throw DriverError.eventCreation("foreground text")
    }
    let utf16 = Array(text.utf16)
    utf16.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
        )
        up.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
        )
    }
    input.tag(down)
    input.tag(up)
    let held = HeldForegroundKey(keyCode: 0, modifiers: [])
    input.heldKeys.insert(held)
    down.postToPid(input.pid)
    up.postToPid(input.pid)
    input.heldKeys.remove(held)
}

private func postForegroundMove(at point: CGPoint, input: ForegroundInputState) throws {
    guard let moved = CGEvent(
        mouseEventSource: eventSource(),
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        throw DriverError.eventCreation("foreground mouse move")
    }
    input.tag(moved)
    moved.post(tap: .cghidEventTap)
    input.lastInjectedPointer = point
}

private func postForegroundScroll(
    deltaY: Int,
    at point: CGPoint,
    input: ForegroundInputState
) throws {
    guard let wheelDelta = Int32(exactly: deltaY) else {
        throw DriverError.badArguments("foreground scroll delta is outside Int32 range")
    }
    let source = eventSource()
    guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let scroll = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: wheelDelta,
            wheel2: 0,
            wheel3: 0
          ) else {
        throw DriverError.eventCreation("foreground scroll")
    }
    scroll.location = point
    input.tag(moved)
    input.tag(scroll)
    moved.post(tap: .cghidEventTap)
    input.lastInjectedPointer = point
    scroll.post(tap: .cghidEventTap)
}

private func foregroundWindowPoint(
    action: ForegroundAction,
    window: WindowReport
) -> CGPoint {
    CGPoint(
        x: window.bounds.x + window.bounds.width * (action.xFraction ?? 0),
        y: window.bounds.y + window.bounds.height * (action.yFraction ?? 0)
    )
}

private func foregroundWindowDragPoints(
    action: ForegroundAction,
    window: WindowReport
) throws -> (start: CGPoint, end: CGPoint) {
    let start = foregroundWindowPoint(action: action, window: window)
    let end = CGPoint(
        x: start.x + Double(action.deltaX ?? 0),
        y: start.y + Double(action.deltaY ?? 0)
    )
    let bounds = window.bounds
    func contains(_ point: CGPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && point.x >= bounds.x
            && point.x <= bounds.x + bounds.width
            && point.y >= bounds.y
            && point.y <= bounds.y + bounds.height
    }
    guard contains(start), contains(end) else {
        throw DriverError.badArguments(
            "window-drag start and endpoint must stay inside the target window"
        )
    }
    return (start, end)
}

private func postForegroundClick(
    at point: CGPoint,
    input: ForegroundInputState,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws {
    let source = eventSource()
    guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
          ),
          let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
          ) else {
        throw DriverError.eventCreation("foreground mouse click")
    }
    for event in [moved, down, up] { input.tag(event) }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)

    moved.post(tap: .cghidEventTap)
    input.lastInjectedPointer = point
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )
    input.leftButtonDown = true
    down.post(tap: .cghidEventTap)
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )
    up.post(tap: .cghidEventTap)
    input.leftButtonDown = false
}

private func postForegroundDrag(
    from start: CGPoint,
    to end: CGPoint,
    input: ForegroundInputState,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws {
    let source = eventSource()
    let midpoint = CGPoint(
        x: start.x + (end.x - start.x) / 2,
        y: start.y + (end.y - start.y) / 2
    )
    guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: start,
            mouseButton: .left
          ),
          let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
          ),
          let draggedMidpoint = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: midpoint,
            mouseButton: .left
          ),
          let draggedEnd = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: end,
            mouseButton: .left
          ),
          let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
          ) else {
        throw DriverError.eventCreation("foreground mouse drag")
    }
    for event in [moved, down, draggedMidpoint, draggedEnd, up] {
        input.tag(event)
    }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)

    moved.post(tap: .cghidEventTap)
    input.lastInjectedPointer = start
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )

    input.leftButtonDown = true
    down.post(tap: .cghidEventTap)
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )

    draggedMidpoint.post(tap: .cghidEventTap)
    input.lastInjectedPointer = midpoint
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )

    draggedEnd.post(tap: .cghidEventTap)
    input.lastInjectedPointer = end
    try foregroundWait(
        milliseconds: foregroundClickGapMs,
        deadline: deadline,
        monitor: monitor
    )

    up.post(tap: .cghidEventTap)
    input.leftButtonDown = false
}

private struct ExactWindowCaptureResult {
    let method: String
    let width: Int
    let height: Int
}

private struct CaptureCallbackSnapshot<Value> {
    let completed: Bool
    let value: Value?
    let errorDescription: String?
}

private final class CaptureCallbackState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var value: Value?
    private var errorDescription: String?

    func complete(value: Value?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        self.value = value
        errorDescription = error?.localizedDescription
        completed = true
    }

    func snapshot() -> CaptureCallbackSnapshot<Value> {
        lock.lock()
        defer { lock.unlock() }
        return CaptureCallbackSnapshot(
            completed: completed,
            value: value,
            errorDescription: errorDescription
        )
    }
}

private func waitForCaptureCallback<Value>(
    _ state: CaptureCallbackState<Value>,
    operation: String,
    deadline: UInt64,
    continueCheck: () throws -> Void
) throws -> Value {
    while true {
        try continueCheck()
        let snapshot = state.snapshot()
        if snapshot.completed {
            if let value = snapshot.value { return value }
            throw DriverError.captureFailed(
                snapshot.errorDescription ?? "\(operation) returned no result"
            )
        }
        guard monotonicNanoseconds() < deadline else {
            throw DriverError.captureFailed("\(operation) timed out")
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }
}

private func writePNG(_ image: CGImage, to outputURL: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw DriverError.captureFailed("could not create PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw DriverError.captureFailed("could not write PNG: \(outputURL.path)")
    }
}

@available(macOS 14.0, *)
private func captureWindowUsingScreenCaptureKit(
    _ window: WindowReport,
    outputURL: URL,
    logicalSize: CGSize?,
    deadline: UInt64,
    continueCheck: () throws -> Void
) throws -> ExactWindowCaptureResult {
    let contentState = CaptureCallbackState<SCShareableContent>()
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
            contentState.complete(value: content, error: nil)
        } catch {
            contentState.complete(value: nil, error: error)
        }
    }
    let content = try waitForCaptureCallback(
        contentState,
        operation: "ScreenCaptureKit shareable-content lookup",
        deadline: deadline,
        continueCheck: continueCheck
    )
    guard let target = content.windows.first(where: {
        $0.windowID == window.windowNumber
            && $0.owningApplication?.processID == window.pid
    }) else {
        throw DriverError.windowNumberMissing(window.pid, window.windowNumber)
    }

    let configuration = SCStreamConfiguration()
    // The authoritative HTML reference is captured at a fixed 2x output scale.
    // Ask ScreenCaptureKit for the same deterministic pixel grid instead of
    // silently inheriting the current display's backing scale.
    let outputScale = 2.0
    let logicalWidth = logicalSize?.width ?? target.frame.width
    let logicalHeight = logicalSize?.height ?? target.frame.height
    configuration.width = max(1, Int((logicalWidth * outputScale).rounded()))
    configuration.height = max(1, Int((logicalHeight * outputScale).rounded()))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let imageState = CaptureCallbackState<CGImage>()
    SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
    ) { image, error in
        imageState.complete(value: image, error: error)
    }
    let image = try waitForCaptureCallback(
        imageState,
        operation: "ScreenCaptureKit image capture",
        deadline: deadline,
        continueCheck: continueCheck
    )
    try continueCheck()
    try writePNG(image, to: outputURL)
    try continueCheck()
    return ExactWindowCaptureResult(
        method: "screen-capture-kit",
        width: image.width,
        height: image.height
    )
}

private func captureWindowUsingScreencapture(
    _ window: WindowReport,
    outputURL: URL,
    deadline: UInt64,
    continueCheck: () throws -> Void
) throws -> ExactWindowCaptureResult {
    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = [
        "-x",
        "-o",
        "-l",
        String(window.windowNumber),
        outputURL.path,
    ]
    process.standardError = errorPipe
    try process.run()

    do {
        while process.isRunning {
            try continueCheck()
            guard monotonicNanoseconds() < deadline else {
                throw DriverError.captureFailed("screencapture timed out")
            }
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
        }
    } catch {
        if process.isRunning { process.terminate() }
        throw error
    }

    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw DriverError.captureFailed(
            errorText.isEmpty
                ? "screencapture exited with status \(process.terminationStatus)"
                : errorText
        )
    }
    let pixels = try imagePixels(path: outputURL.path)
    try continueCheck()
    return ExactWindowCaptureResult(
        method: "screencapture",
        width: pixels.width,
        height: pixels.height
    )
}

private func captureExactWindow(
    _ window: WindowReport,
    path: String,
    logicalSize: CGSize? = nil,
    deadline: UInt64,
    continueCheck: () throws -> Void
) throws -> ExactWindowCaptureResult {
    try continueCheck()
    let outputURL = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let result: ExactWindowCaptureResult
    if #available(macOS 14.0, *) {
        result = try captureWindowUsingScreenCaptureKit(
            window,
            outputURL: outputURL,
            logicalSize: logicalSize,
            deadline: deadline,
            continueCheck: continueCheck
        )
    } else {
        result = try captureWindowUsingScreencapture(
            window,
            outputURL: outputURL,
            deadline: deadline,
            continueCheck: continueCheck
        )
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
          let size = attributes[.size] as? NSNumber,
          size.intValue > 0 else {
        throw DriverError.imageRead(path)
    }
    try continueCheck()
    return result
}

private func captureForegroundWindow(
    _ window: WindowReport,
    path: String,
    logicalSize: CGSize?,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws {
    _ = try captureExactWindow(
        window,
        path: path,
        logicalSize: logicalSize,
        deadline: deadline
    ) {
        try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
    }
}

private func imagePixels(path: String) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw DriverError.imageRead(path)
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw DriverError.imageRead(path) }
    return (width, height, pixels)
}

private func compareImages(before: String, after: String) throws -> ImageComparisonReport {
    let lhs = try imagePixels(path: before)
    let rhs = try imagePixels(path: after)
    guard lhs.width == rhs.width, lhs.height == rhs.height else {
        throw DriverError.imageSizeMismatch(before, after)
    }
    let threshold: UInt8 = 8
    var changedPixels = 0
    var channelDifference: UInt64 = 0
    let pixelCount = lhs.width * lhs.height
    for pixel in 0..<pixelCount {
        let offset = pixel * 4
        var changed = false
        for channel in 0..<3 {
            let difference = abs(Int(lhs.pixels[offset + channel]) - Int(rhs.pixels[offset + channel]))
            channelDifference += UInt64(difference)
            if difference > threshold { changed = true }
        }
        if changed { changedPixels += 1 }
    }
    return ImageComparisonReport(
        before: before,
        after: after,
        width: lhs.width,
        height: lhs.height,
        changedPixelRatio: Double(changedPixels) / Double(pixelCount),
        meanAbsoluteChannelDifference: Double(channelDifference) / Double(pixelCount * 3),
        threshold: threshold
    )
}

private func accessibilityString(_ element: AXUIElement, attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return ""
    }
    return value as? String ?? ""
}

private func accessibilityOptionalString(
    _ element: AXUIElement,
    attribute: String
) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success else {
        return nil
    }
    return value as? String
}

private func accessibilityOptionalBoolean(
    _ element: AXUIElement,
    attribute: String
) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success,
          let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return nil
    }
    return number.boolValue
}

private func accessibilityChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &value
    ) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func accessibilityPoint(
    _ element: AXUIElement,
    attribute: String
) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue
    ) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }
    let value = rawValue as! AXValue
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

private func accessibilitySize(
    _ element: AXUIElement,
    attribute: String
) -> CGSize? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue
    ) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }
    let value = rawValue as! AXValue
    guard AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

private func accessibilityElementReport(
    _ element: AXUIElement,
    identifier: String,
    role: String
) throws -> ForegroundElementReport {
    guard let position = accessibilityPoint(element, attribute: kAXPositionAttribute),
          let size = accessibilitySize(element, attribute: kAXSizeAttribute),
          position.x.isFinite,
          position.y.isFinite,
          size.width.isFinite,
          size.height.isFinite,
          size.width > 0,
          size.height > 0 else {
        throw DriverError.badArguments(
            "accessibility element has no finite positive frame: \(identifier)"
        )
    }
    return ForegroundElementReport(
        identifier: identifier,
        role: role,
        frame: WindowBounds(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        ),
        activationPoint: accessibilityPoint(
            element,
            attribute: NSAccessibility.Attribute.activationPoint.rawValue
        ).flatMap { point in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return DesktopPointerReport(x: point.x, y: point.y)
        },
        value: accessibilityOptionalString(element, attribute: kAXValueAttribute),
        selected: accessibilityOptionalBoolean(element, attribute: kAXSelectedAttribute),
        title: accessibilityOptionalString(element, attribute: kAXTitleAttribute),
        description: accessibilityOptionalString(
            element,
            attribute: kAXDescriptionAttribute
        )
    )
}

private func validateForegroundElementExpectation(
    _ report: ForegroundElementReport,
    selector: ForegroundElementSelector
) throws {
    let selectorDetail = foregroundSelectorDetail(selector)
    if let expectedValue = selector.expectedValue,
       report.value != expectedValue {
        throw DriverError.badArguments(
            "accessibility element \(selectorDetail) value did not match the exact expectation"
        )
    }
    if let expectedSelected = selector.expectedSelected,
       report.selected != expectedSelected {
        throw DriverError.badArguments(
            "accessibility element \(selectorDetail) selected state did not match \(expectedSelected)"
        )
    }
    if let expectedFrameWidth = selector.expectedFrameWidth,
       abs(report.frame.width - expectedFrameWidth) > 0.75 {
        throw DriverError.badArguments(
            "accessibility element \(selectorDetail) frame width did not match the expectation"
        )
    }
    if let expectedFrameHeight = selector.expectedFrameHeight,
       abs(report.frame.height - expectedFrameHeight) > 0.75 {
        throw DriverError.badArguments(
            "accessibility element \(selectorDetail) frame height did not match the expectation"
        )
    }
}

private struct AccessibilityElementIdentity: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (
        lhs: AccessibilityElementIdentity,
        rhs: AccessibilityElementIdentity
    ) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

private func resolveForegroundElement(
    pid: Int32,
    selector: ForegroundElementSelector,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws -> ForegroundElementReport {
    let root = AXUIElementCreateApplication(pid)
    var queue = [root]
    var nextIndex = 0
    var visitedElements = Set<AccessibilityElementIdentity>()
    var matches: [(element: AXUIElement, identifier: String, role: String)] = []
    var primaryMatchRoles = Set<String>()
    let traversalLimit = 5_000

    while nextIndex < queue.count && visitedElements.count < traversalLimit {
        if nextIndex.isMultiple(of: 32) {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.001)
            )
        }
        try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
        let element = queue[nextIndex]
        nextIndex += 1
        guard visitedElements.insert(
            AccessibilityElementIdentity(element: element)
        ).inserted else {
            continue
        }

        let identifier = accessibilityString(element, attribute: kAXIdentifierAttribute)
        let role = accessibilityString(element, attribute: kAXRoleAttribute)
        let description = accessibilityOptionalString(
            element,
            attribute: kAXDescriptionAttribute
        )
        let primaryMatches = (selector.identifier == nil || identifier == selector.identifier)
            && (selector.description == nil || description == selector.description)
        if primaryMatches {
            primaryMatchRoles.insert(role)
        }
        if primaryMatches, selector.role == nil || role == selector.role {
            matches.append((element, identifier, role))
        }
        queue.append(contentsOf: accessibilityChildren(element))
    }
    try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)

    guard nextIndex >= queue.count else {
        throw DriverError.badArguments(
            "accessibility traversal exceeded \(traversalLimit) unique elements"
        )
    }
    let selectorDescription = foregroundSelectorDetail(selector)
    guard !matches.isEmpty else {
        let observedRoles = primaryMatchRoles.isEmpty
            ? ""
            : "; the primary selector appeared with roles \(primaryMatchRoles.sorted())"
        throw DriverError.badArguments(
            "accessibility selector found no element for \(selectorDescription)\(observedRoles)"
        )
    }
    guard matches.count == 1 else {
        throw DriverError.badArguments(
            "accessibility selector for \(selectorDescription) matched \(matches.count) elements"
        )
    }
    let match = matches[0]
    let report = try accessibilityElementReport(
        match.element,
        identifier: match.identifier,
        role: match.role
    )
    try validateForegroundElementExpectation(report, selector: selector)
    return report
}

private func resolveForegroundFocusedElement(
    pid: Int32,
    selector: ForegroundElementSelector,
    deadline: UInt64,
    monitor: ForegroundInterferenceMonitor
) throws -> ForegroundElementReport {
    try ensureForegroundCanContinue(deadline: deadline, monitor: monitor)
    let root = AXUIElementCreateApplication(pid)
    var rawValue: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        root,
        kAXFocusedUIElementAttribute as CFString,
        &rawValue
    )
    guard status == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
        throw DriverError.badArguments(
            "target application has no focused accessibility element"
        )
    }
    let element = rawValue as! AXUIElement
    let identifier = accessibilityString(element, attribute: kAXIdentifierAttribute)
    let role = accessibilityString(element, attribute: kAXRoleAttribute)
    let description = accessibilityOptionalString(
        element,
        attribute: kAXDescriptionAttribute
    )
    guard (selector.identifier == nil || identifier == selector.identifier),
          (selector.description == nil || description == selector.description),
          selector.role == nil || role == selector.role else {
        let expected = foregroundSelectorDetail(selector)
        throw DriverError.badArguments(
            "focused accessibility element was identifier \(identifier), description \(description ?? ""), and role \(role), expected \(expected)"
        )
    }
    let report = try accessibilityElementReport(
        element,
        identifier: identifier,
        role: role
    )
    try validateForegroundElementExpectation(report, selector: selector)
    return report
}

private func foregroundWindowBoundsMatch(
    _ lhs: WindowBounds,
    _ rhs: WindowBounds,
    tolerance: Double = 1
) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance
        && abs(lhs.y - rhs.y) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func foregroundPoint(_ point: CGPoint, isInside bounds: WindowBounds) -> Bool {
    point.x >= bounds.x
        && point.x < bounds.x + bounds.width
        && point.y >= bounds.y
        && point.y < bounds.y + bounds.height
}

private func foregroundAXFocusedWindowReadiness(
    pid: Int32,
    point: CGPoint,
    targetWindow: WindowReport
) -> ForegroundAXFocusedWindowReadinessReport {
    let application = AXUIElementCreateApplication(pid)
    var rawValue: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &rawValue
    )
    guard status == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
        return ForegroundAXFocusedWindowReadinessReport(
            attributeStatus: status.rawValue,
            role: nil,
            title: nil,
            frame: nil,
            hasUsableGeometry: false,
            containsClickPoint: false,
            matchesTargetWindowGeometry: false,
            ready: false
        )
    }
    let window = rawValue as! AXUIElement
    let role = accessibilityOptionalString(window, attribute: kAXRoleAttribute)
    let title = accessibilityOptionalString(window, attribute: kAXTitleAttribute)
    let position = accessibilityPoint(window, attribute: kAXPositionAttribute)
    let size = accessibilitySize(window, attribute: kAXSizeAttribute)
    let hasUsableGeometry = position.map { $0.x.isFinite && $0.y.isFinite } == true
        && size.map {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        } == true
    let frame = hasUsableGeometry ? WindowBounds(
        x: position!.x,
        y: position!.y,
        width: size!.width,
        height: size!.height
    ) : nil
    let containsClickPoint = frame.map { foregroundPoint(point, isInside: $0) } ?? false
    let matchesTargetWindowGeometry = frame.map {
        foregroundWindowBoundsMatch($0, targetWindow.bounds)
    } ?? false
    let ready = role == kAXWindowRole
        && hasUsableGeometry
        && containsClickPoint
        && matchesTargetWindowGeometry
    return ForegroundAXFocusedWindowReadinessReport(
        attributeStatus: status.rawValue,
        role: role,
        title: title,
        frame: frame,
        hasUsableGeometry: hasUsableGeometry,
        containsClickPoint: containsClickPoint,
        matchesTargetWindowGeometry: matchesTargetWindowGeometry,
        ready: ready
    )
}

private func foregroundAccessibilityHit(
    at point: CGPoint,
    targetPID: Int32
) -> ForegroundAccessibilityHitReport {
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(
        system,
        Float(point.x),
        Float(point.y),
        &element
    )
    guard status == .success, let element else {
        return ForegroundAccessibilityHitReport(
            status: status.rawValue,
            pid: nil,
            role: nil,
            identifier: nil,
            targetPIDMatches: false
        )
    }
    var pid: pid_t = 0
    let pidStatus = AXUIElementGetPid(element, &pid)
    guard pidStatus == .success, pid > 0 else {
        return ForegroundAccessibilityHitReport(
            status: pidStatus.rawValue,
            pid: nil,
            role: accessibilityOptionalString(element, attribute: kAXRoleAttribute),
            identifier: accessibilityOptionalString(
                element,
                attribute: kAXIdentifierAttribute
            ),
            targetPIDMatches: false
        )
    }
    return ForegroundAccessibilityHitReport(
        status: status.rawValue,
        pid: pid,
        role: accessibilityOptionalString(element, attribute: kAXRoleAttribute),
        identifier: accessibilityOptionalString(
            element,
            attribute: kAXIdentifierAttribute
        ),
        targetPIDMatches: pid == targetPID
    )
}

private func foregroundPointerClickReadiness(
    at point: CGPoint,
    pid: Int32,
    targetWindow: WindowReport
) -> ForegroundPointerClickReadinessReport {
    let topmostWindow = topmostOnScreenWindow(at: point)
    let targetOwnerPIDMatches = topmostWindow?.pid == pid
    let targetWindowNumberMatches = topmostWindow?.windowNumber
        == targetWindow.windowNumber
    let accessibilityHit = foregroundAccessibilityHit(
        at: point,
        targetPID: pid
    )
    let axFocusedWindow = foregroundAXFocusedWindowReadiness(
        pid: pid,
        point: point,
        targetWindow: targetWindow
    )
    return ForegroundPointerClickReadinessReport(
        point: DesktopPointerReport(x: point.x, y: point.y),
        targetPID: pid,
        targetWindowNumber: targetWindow.windowNumber,
        topmostWindow: topmostWindow,
        targetOwnerPIDMatches: targetOwnerPIDMatches,
        targetWindowNumberMatches: targetWindowNumberMatches,
        accessibilityHit: accessibilityHit,
        axFocusedWindow: axFocusedWindow,
        ready: targetOwnerPIDMatches
            && targetWindowNumberMatches
            && accessibilityHit.targetPIDMatches
            && axFocusedWindow.ready
    )
}

private func validateForegroundPointerClickReadiness(
    _ report: ForegroundPointerClickReadinessReport
) throws {
    guard report.ready else {
        let observedPID = report.topmostWindow.map { String($0.pid) } ?? "none"
        let observedWindow = report.topmostWindow.map {
            String($0.windowNumber)
        } ?? "none"
        let observedHitPID = report.accessibilityHit.pid.map { String($0) } ?? "none"
        throw DriverError.badArguments(
            "global pointer click target was not ready: topmost pid/window "
                + "\(observedPID)/\(observedWindow), expected "
                + "\(report.targetPID)/\(report.targetWindowNumber), "
                + "AX hit pid=\(observedHitPID), "
                + "AX focused window ready=\(report.axFocusedWindow.ready)"
        )
    }
}

private func foregroundInjectedPointerLocationMatches(
    _ observed: DesktopPointerReport?,
    expected: DesktopPointerReport,
    tolerance: Double = 0.5
) -> Bool {
    guard let observed else { return false }
    return abs(observed.x - expected.x) <= tolerance
        && abs(observed.y - expected.y) <= tolerance
}

private func validateForegroundInjectedPointerClick(
    _ events: ForegroundInjectedPointerEventsReport,
    expectedPoint: DesktopPointerReport,
    deliveryLayer: String
) throws {
    guard events.completeClickSequenceObserved,
          foregroundInjectedPointerLocationMatches(
            events.lastMoveLocation,
            expected: expectedPoint
          ),
          foregroundInjectedPointerLocationMatches(
            events.lastLeftMouseDownLocation,
            expected: expectedPoint
          ),
          foregroundInjectedPointerLocationMatches(
            events.lastLeftMouseUpLocation,
            expected: expectedPoint
          ) else {
        throw DriverError.badArguments(
            "\(deliveryLayer) did not observe the complete same-nonce pointer click "
                + "at the requested location"
        )
    }
}

private func validateForegroundInjectedPointerDrag(
    _ events: ForegroundInjectedPointerEventsReport,
    expectedStart: DesktopPointerReport,
    expectedEnd: DesktopPointerReport,
    deliveryLayer: String
) throws {
    guard events.completeDragSequenceObserved,
          events.leftMouseDraggedCount >= 2,
          foregroundInjectedPointerLocationMatches(
            events.lastMoveLocation,
            expected: expectedStart
          ),
          foregroundInjectedPointerLocationMatches(
            events.lastLeftMouseDownLocation,
            expected: expectedStart
          ),
          foregroundInjectedPointerLocationMatches(
            events.lastLeftMouseDraggedLocation,
            expected: expectedEnd
          ),
          foregroundInjectedPointerLocationMatches(
            events.lastLeftMouseUpLocation,
            expected: expectedEnd
          ) else {
        throw DriverError.badArguments(
            "\(deliveryLayer) did not observe the complete same-nonce pointer drag "
                + "from the requested start through the requested endpoint"
        )
    }
}

private func foregroundElementPoint(
    action: ForegroundAction,
    _ element: ForegroundElementReport,
    inside window: WindowReport
) throws -> CGPoint {
    let point: CGPoint
    if let xFraction = action.xFraction, let yFraction = action.yFraction {
        point = CGPoint(
            x: element.frame.x + element.frame.width * xFraction,
            y: element.frame.y + element.frame.height * yFraction
        )
    } else {
        point = element.activationPoint.map {
            CGPoint(x: $0.x, y: $0.y)
        } ?? CGPoint(
            x: element.frame.x + element.frame.width / 2,
            y: element.frame.y + element.frame.height / 2
        )
    }
    let bounds = window.bounds
    guard point.x >= bounds.x,
          point.x <= bounds.x + bounds.width,
          point.y >= bounds.y,
          point.y <= bounds.y + bounds.height else {
        throw DriverError.badArguments(
            "accessibility element center is outside the target window: \(element.identifier)"
        )
    }
    return point
}

private func foregroundElementDragPoints(
    action: ForegroundAction,
    element: ForegroundElementReport,
    inside window: WindowReport
) throws -> (start: CGPoint, end: CGPoint) {
    let start = element.activationPoint.map {
        CGPoint(x: $0.x, y: $0.y)
    } ?? CGPoint(
        x: element.frame.x + element.frame.width / 2,
        y: element.frame.y + element.frame.height / 2
    )
    let end = CGPoint(
        x: start.x + Double(action.deltaX ?? 0),
        y: start.y + Double(action.deltaY ?? 0)
    )
    let bounds = window.bounds
    func contains(_ point: CGPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && point.x >= bounds.x
            && point.x <= bounds.x + bounds.width
            && point.y >= bounds.y
            && point.y <= bounds.y + bounds.height
    }
    guard contains(start) else {
        throw DriverError.badArguments(
            "accessibility element drag point is outside the target window: \(element.identifier)"
        )
    }
    guard contains(end) else {
        throw DriverError.badArguments(
            "element-drag endpoint is outside the target window: \(element.identifier)"
        )
    }
    return (start, end)
}

private func sidebarFilterElement(pid: Int32) -> AXUIElement? {
    var queue = [AXUIElementCreateApplication(pid)]
    var textFields: [AXUIElement] = []
    var visited = 0

    while !queue.isEmpty && visited < 500 {
        let element = queue.removeFirst()
        visited += 1
        if accessibilityString(element, attribute: kAXRoleAttribute) == kAXTextFieldRole {
            let placeholder = accessibilityString(
                element,
                attribute: kAXPlaceholderValueAttribute
            )
            let description = accessibilityString(element, attribute: kAXDescriptionAttribute)
            if placeholder == "筛选文档" || description == "筛选文档" {
                return element
            }
            textFields.append(element)
        }
        queue.append(contentsOf: accessibilityChildren(element))
    }

    // The baseline view has exactly one text field when find and palette are closed.
    return textFields.count == 1 ? textFields[0] : nil
}

private func resetSidebarFilter(pid: Int32) throws -> SidebarFilterResetReport {
    guard AXIsProcessTrusted() else {
        throw DriverError.permissionDenied(
            "macOS Accessibility permission is required to normalize the sidebar filter"
        )
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw DriverError.processMissing(pid)
    }
    _ = try waitForWindow(pid: pid, timeout: 2)
    _ = app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.12)

    guard let field = sidebarFilterElement(pid: pid) else {
        throw DriverError.badArguments("could not locate the sidebar filter text field")
    }
    let previousValue = accessibilityString(field, attribute: kAXValueAttribute)
    guard AXUIElementSetAttributeValue(
        field,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    ) == .success else {
        throw DriverError.badArguments("could not focus the sidebar filter text field")
    }
    try postKey(0, modifiers: .maskCommand, pid: pid)
    try postKey(51, modifiers: [], pid: pid)
    Thread.sleep(forTimeInterval: 0.12)
    let currentValue = accessibilityString(field, attribute: kAXValueAttribute)
    guard currentValue.isEmpty else {
        throw DriverError.badArguments("sidebar filter did not reset: \(currentValue)")
    }
    _ = AXUIElementSetAttributeValue(
        field,
        kAXFocusedAttribute as CFString,
        kCFBooleanFalse
    )
    return SidebarFilterResetReport(
        pid: pid,
        accessibilityTrusted: true,
        previousValue: previousValue,
        currentValue: currentValue,
        reset: !previousValue.isEmpty
    )
}

private func sidebarRows(window: WindowReport) -> [SidebarRowReport] {
    let system = AXUIElementCreateSystemWide()
    var rows: [SidebarRowReport] = []
    var seen = Set<String>()
    for relativeY in stride(from: 70.0, through: 280.0, by: 5.0) {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            system,
            Float(window.bounds.x + 110),
            Float(window.bounds.y + relativeY),
            &element
        )
        guard error == .success, let element else { continue }
        let description = accessibilityString(element, attribute: kAXDescriptionAttribute)
        guard !description.isEmpty, !seen.contains(description) else { continue }
        seen.insert(description)
        rows.append(SidebarRowReport(
            role: accessibilityString(element, attribute: kAXRoleAttribute),
            description: description,
            relativeY: relativeY
        ))
    }
    return rows
}

private func recognizedText(
    path: String,
    windowWidth: Double,
    windowHeight: Double
) throws -> [RecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do {
        try handler.perform([request])
    } catch {
        throw DriverError.imageRead(path)
    }
    return (request.results ?? []).compactMap { observation in
        guard let string = observation.topCandidates(1).first?.string else { return nil }
        return RecognizedTextObservation(
            string: string,
            relativeX: observation.boundingBox.midX * windowWidth,
            relativeY: (1 - observation.boundingBox.midY) * windowHeight
        )
    }
}

private func normalizedRowText(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
}

private func assertScreenshotText(
    screenshot: String,
    requiredText: [String],
    forbiddenText: [String]
) throws -> ScreenshotTextReport {
    guard !requiredText.isEmpty || !forbiddenText.isEmpty else {
        throw DriverError.badArguments(
            "screenshot-text requires at least one --contains or --not-contains value"
        )
    }
    let recognized = try recognizedText(
        path: screenshot,
        windowWidth: 1,
        windowHeight: 1
    ).map(\.string)
    let normalized = normalizedRowText(recognized.joined(separator: "\n"))
    let missing = requiredText.filter {
        !normalized.contains(normalizedRowText($0))
    }
    let present = forbiddenText.filter {
        normalized.contains(normalizedRowText($0))
    }
    guard missing.isEmpty, present.isEmpty else {
        throw DriverError.badArguments(
            "screenshot text mismatch; missing: \(missing), forbidden present: \(present)"
        )
    }
    return ScreenshotTextReport(
        screenshot: screenshot,
        requiredText: requiredText,
        forbiddenText: forbiddenText,
        recognizedText: recognized
    )
}

private func clickRecognizedText(
    pid: Int32,
    screenshot: String,
    requestedText: String,
    clickCount: Int
) throws -> TextClickReport {
    guard CGPreflightPostEventAccess() else {
        throw DriverError.permissionDenied(
            "macOS Input Monitoring or Accessibility permission is required for CGEvent posting"
        )
    }
    guard clickCount == 1 || clickCount == 2 else {
        throw DriverError.badArguments("--count must be 1 or 2")
    }
    let window = try waitForWindow(pid: pid, timeout: 2)
    let observations = try recognizedText(
        path: screenshot,
        windowWidth: window.bounds.width,
        windowHeight: window.bounds.height
    )
    let needle = normalizedRowText(requestedText)
    guard !needle.isEmpty else {
        throw DriverError.badArguments("--text must contain letters or numbers")
    }
    let matches = observations.filter {
        normalizedRowText($0.string).contains(needle)
    }
    guard let match = matches.min(by: { lhs, rhs in
        let lhsDistance = abs(lhs.relativeX - window.bounds.width / 2)
            + abs(lhs.relativeY - window.bounds.height / 2)
        let rhsDistance = abs(rhs.relativeX - window.bounds.width / 2)
            + abs(rhs.relativeY - window.bounds.height / 2)
        return lhsDistance < rhsDistance
    }) else {
        throw DriverError.badArguments(
            "could not locate screenshot text: \(requestedText)"
        )
    }

    let point = CGPoint(
        x: window.bounds.x + match.relativeX,
        y: window.bounds.y + match.relativeY
    )
    for _ in 0..<clickCount {
        try postMouseClick(at: point, pid: pid)
        Thread.sleep(forTimeInterval: 0.12)
    }
    return TextClickReport(
        pid: pid,
        actions: ["click-text:\(requestedText)"],
        postEventAccess: true,
        screenshot: screenshot,
        requestedText: requestedText,
        recognizedText: match.string,
        relativeX: match.relativeX,
        relativeY: match.relativeY,
        clickCount: clickCount
    )
}

private func sidebarRowY(
    named name: String,
    rows: [SidebarRowReport],
    recognizedText: [RecognizedTextObservation],
    sidebarWidth: Double
) -> Double? {
    if let row = rows.first(where: { $0.description == name }) {
        return row.relativeY
    }
    let normalizedName = normalizedRowText(name)
    return recognizedText.first { observation in
        observation.relativeX < sidebarWidth
            && observation.relativeY >= 60
            && observation.relativeY <= 320
            && normalizedRowText(observation.string).contains(normalizedName)
    }?.relativeY
}

private func colorReport(
    pixels: (width: Int, height: Int, pixels: [UInt8]),
    logicalX: Double,
    logicalY: Double,
    window: WindowReport
) throws -> ColorReport {
    let scaleX = Double(pixels.width) / window.bounds.width
    let scaleY = Double(pixels.height) / window.bounds.height
    let pixelX = min(pixels.width - 1, max(0, Int((logicalX * scaleX).rounded())))
    let pixelY = min(pixels.height - 1, max(0, Int((logicalY * scaleY).rounded())))
    let offset = (pixelY * pixels.width + pixelX) * 4
    guard offset + 3 < pixels.pixels.count else {
        throw DriverError.imageRead("pixel sample")
    }
    return ColorReport(
        red: pixels.pixels[offset],
        green: pixels.pixels[offset + 1],
        blue: pixels.pixels[offset + 2],
        alpha: pixels.pixels[offset + 3]
    )
}

private func brightness(_ color: ColorReport) -> Int {
    Int(color.red) + Int(color.green) + Int(color.blue)
}

private func inspectSidebar(
    pid: Int32,
    screenshot: String,
    passive: Bool = false
) throws -> SidebarReport {
    let accessibilityTrusted = !passive && AXIsProcessTrusted()
    let window = try waitForWindow(pid: pid, timeout: 2, includeOffscreen: passive)
    if accessibilityTrusted {
        try focusTargetForGlobalPointerEvent(pid: pid)
        Thread.sleep(forTimeInterval: 0.12)
    }
    let rows = accessibilityTrusted ? sidebarRows(window: window) : []
    let descriptions = Set(rows.map(\.description))
    let requiredRows = ["格式示例.md", "config.yaml", "README.md", "更新日志.md"]
    let recognized = try recognizedText(
        path: screenshot,
        windowWidth: window.bounds.width,
        windowHeight: window.bounds.height
    )
    let ocrText = recognized.map(\.string)
    let ocrJoined = ocrText.joined(separator: "\n")
    let normalizedOCR = normalizedRowText(ocrJoined)
    let hasAXRows = descriptions.contains { $0.contains("docs") }
        && requiredRows.allSatisfy { descriptions.contains($0) }
    let hasDocs = hasAXRows || normalizedOCR.contains("docs")
    let missing = requiredRows.filter { row in
        !descriptions.contains(row) && !normalizedOCR.contains(normalizedRowText(row))
    }
    guard hasDocs, missing.isEmpty else {
        throw DriverError.badArguments(
            "sidebar fixture rows missing: \((hasDocs ? [] : ["docs"]) + missing)"
        )
    }

    let image = try imagePixels(path: screenshot)
    guard let activeY = sidebarRowY(
        named: "格式示例.md",
        rows: rows,
        recognizedText: recognized,
        sidebarWidth: 210
    ) else {
        throw DriverError.badArguments("could not locate active sidebar row geometry: 格式示例.md")
    }
    guard let inactiveY = sidebarRowY(
        named: "config.yaml",
        rows: rows,
        recognizedText: recognized,
        sidebarWidth: 210
    ) else {
        throw DriverError.badArguments("could not locate inactive sidebar row geometry: config.yaml")
    }
    let activeBackground = try colorReport(
        pixels: image,
        logicalX: 20,
        logicalY: activeY,
        window: window
    )
    let inactiveBackground = try colorReport(
        pixels: image,
        logicalX: 20,
        logicalY: inactiveY,
        window: window
    )
    let activeDelta = brightness(inactiveBackground) - brightness(activeBackground)
    guard activeDelta >= 20 else {
        throw DriverError.badArguments(
            "active sample sidebar row is not visibly stronger than inactive rows: delta \(activeDelta)"
        )
    }

    let activeTabBackground = try colorReport(
        pixels: image,
        logicalX: 280,
        logicalY: 15,
        window: window
    )
    let inactiveTabBarBackground = try colorReport(
        pixels: image,
        logicalX: 390,
        logicalY: 15,
        window: window
    )
    let tabDelta = brightness(inactiveTabBarBackground) - brightness(activeTabBackground)
    guard tabDelta >= 10 else {
        throw DriverError.badArguments(
            "active sample tab is not visibly stronger than the tab bar: delta \(tabDelta)"
        )
    }

    return SidebarReport(
        pid: pid,
        rows: rows,
        requiredRows: ["docs"] + requiredRows,
        activeSampleBackground: activeBackground,
        inactiveSampleBackground: inactiveBackground,
        activeSampleBackgroundDelta: activeDelta,
        activeTabBackground: activeTabBackground,
        inactiveTabBarBackground: inactiveTabBarBackground,
        activeTabBackgroundDelta: tabDelta,
        rowEvidenceMethod: hasAXRows ? "accessibility" : "vision-ocr",
        recognizedText: ocrText
    )
}

private func sendActions(pid: Int32, arguments: [String], delay: Double) throws -> ActionReport {
    guard CGPreflightPostEventAccess() else {
        throw DriverError.permissionDenied(
            "macOS Input Monitoring or Accessibility permission is required for CGEvent posting"
        )
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw DriverError.processMissing(pid)
    }
    let actions = try actionArguments(arguments)
    _ = try waitForWindow(pid: pid, timeout: 2, includeOffscreen: true)
    _ = app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: min(max(delay, 0.05), 0.5))
    let window = try waitForWindow(pid: pid, timeout: 2)

    let center = CGPoint(
        x: window.bounds.x + window.bounds.width / 2,
        y: window.bounds.y + window.bounds.height / 2
    )
    let bottomRight = CGPoint(
        x: window.bounds.x + window.bounds.width - 28,
        y: window.bounds.y + window.bounds.height - 28
    )
    let outline = CGPoint(
        // The rail starts at the content area's leading edge after the default
        // 216 pt sidebar and owns a 64 pt collapsed hover region.
        x: window.bounds.x + min(window.bounds.width - 20, 240),
        y: window.bounds.y + 56 + max(0, window.bounds.height - 56) * 0.46
    )

    for action in actions {
        if action.hasPrefix("key:") {
            let spec = String(action.dropFirst("key:".count))
            let (keyCode, modifiers) = try keySpec(spec)
            try postKey(keyCode, modifiers: modifiers, pid: pid)
        } else if action == "modifier:shift" {
            try postShiftTap(pid: pid)
        } else if action.hasPrefix("text:") {
            try postText(String(action.dropFirst("text:".count)), pid: pid)
        } else if action == "mouse:bottom-right" {
            try postMouseClick(at: bottomRight, pid: pid)
        } else if action == "mouse:center" {
            try postMouseClick(at: center, pid: pid)
        } else if action == "move:outside" {
            try postMouseMove(at: CGPoint(x: 1, y: 1))
        } else if action == "move:outline" {
            try focusTargetForGlobalPointerEvent(pid: pid)
            try postMouseMove(at: outline)
        } else if action.hasPrefix("click:") {
            let point = try relativePoint(action, prefix: "click:", window: window)
            try postMouseClick(at: point, pid: pid)
        } else if action.hasPrefix("find-click:") {
            let control = String(action.dropFirst("find-click:".count))
            let relative = try findControlPoint(
                control,
                windowWidth: window.bounds.width,
                windowHeight: window.bounds.height
            )
            try postMouseClick(
                at: CGPoint(
                    x: window.bounds.x + relative.x,
                    y: window.bounds.y + relative.y
                ),
                pid: pid
            )
        } else if action.hasPrefix("scroll:") {
            let rawDelta = String(action.dropFirst("scroll:".count))
            guard let delta = Int32(rawDelta) else {
                throw DriverError.badArguments("invalid scroll delta: \(rawDelta)")
            }
            try postScroll(delta: delta, at: center, pid: pid)
        } else {
            throw DriverError.badArguments("unsupported action: \(action)")
        }
        Thread.sleep(forTimeInterval: delay)
    }
    Thread.sleep(forTimeInterval: delay)
    return ActionReport(pid: pid, actions: actions, postEventAccess: true)
}

private func quartzPointerLocation() throws -> CGPoint {
    guard let event = CGEvent(source: nil) else {
        throw DriverError.eventCreation("Quartz pointer snapshot")
    }
    return event.location
}

private func desktopStateReport() throws -> DesktopStateReport {
    let pointer = try quartzPointerLocation()
    return DesktopStateReport(
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        pointer: DesktopPointerReport(x: pointer.x, y: pointer.y)
    )
}

private struct FrontmostObserverOptions {
    let targetPIDFile: String
    let readyFile: String
    let stopFile: String
    let timeoutSeconds: Double
}

private final class FrontmostObserverState {
    let startedAt: UInt64
    let sampleIntervalMs: Int
    private(set) var targetPID: Int32?
    private(set) var targetPIDLoadedAtMs: Int?
    private(set) var initialFrontmostPID: Int32?
    private(set) var finalFrontmostPID: Int32?
    private(set) var notificationCount = 0
    private(set) var sampleCount = 0
    private(set) var transitions: [FrontmostObservationReport] = []
    private(set) var firstTargetFrontmostObservation: FrontmostObservationReport?

    init(startedAt: UInt64, sampleIntervalMs: Int) {
        self.startedAt = startedAt
        self.sampleIntervalMs = sampleIntervalMs
    }

    func record(frontmostPID: Int32?, source: String) {
        let observation = FrontmostObservationReport(
            source: source,
            elapsedMs: elapsedMilliseconds(since: startedAt),
            frontmostPID: frontmostPID
        )
        if source == "initial" {
            initialFrontmostPID = frontmostPID
        } else if source == "notification" {
            notificationCount += 1
        } else if source == "sample" {
            sampleCount += 1
        }
        finalFrontmostPID = frontmostPID

        let shouldAppend = source != "sample"
            || transitions.last?.frontmostPID != frontmostPID
        if shouldAppend {
            transitions.append(observation)
        }
        if let targetPID,
           targetPID == frontmostPID,
           firstTargetFrontmostObservation == nil {
            firstTargetFrontmostObservation = observation
        }
    }

    func loadTargetPID(_ pid: Int32) {
        guard targetPID == nil else { return }
        targetPID = pid
        targetPIDLoadedAtMs = elapsedMilliseconds(since: startedAt)
        firstTargetFrontmostObservation = transitions.first {
            $0.frontmostPID == pid
        }
        record(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            source: "target-pid-loaded"
        )
    }
}

private func validatedObserverControlPath(
    _ rawPath: String,
    option: String
) throws -> String {
    guard (rawPath as NSString).isAbsolutePath else {
        throw DriverError.badArguments("\(option) requires an absolute path")
    }
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    guard !FileManager.default.fileExists(atPath: path) else {
        throw DriverError.badArguments("\(option) must not already exist")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
          isDirectory.boolValue,
          FileManager.default.isWritableFile(atPath: parent) else {
        throw DriverError.badArguments(
            "\(option) parent directory must exist and be writable"
        )
    }
    return path
}

private func frontmostObserverOptions(arguments: [String]) throws -> FrontmostObserverOptions {
    let allowedOptions: Set<String> = [
        "--target-pid-file", "--ready-file", "--stop-file", "--timeout",
    ]
    let rawArguments = Array(arguments.dropFirst())
    guard rawArguments.count == allowedOptions.count * 2 else {
        throw DriverError.badArguments(
            "observe-frontmost requires --target-pid-file, --ready-file, --stop-file, and --timeout"
        )
    }

    var values: [String: String] = [:]
    var index = 0
    while index < rawArguments.count {
        let option = rawArguments[index]
        guard allowedOptions.contains(option) else {
            throw DriverError.badArguments(
                "observe-frontmost has an unknown option: \(option)"
            )
        }
        guard values[option] == nil else {
            throw DriverError.badArguments(
                "observe-frontmost option appears more than once: \(option)"
            )
        }
        let optionValue = rawArguments[index + 1]
        guard !optionValue.isEmpty, !optionValue.hasPrefix("--") else {
            throw DriverError.badArguments("\(option) requires a value")
        }
        values[option] = optionValue
        index += 2
    }

    guard let rawTimeout = values["--timeout"],
          let timeoutSeconds = Double(rawTimeout),
          timeoutSeconds.isFinite,
          (1...300).contains(timeoutSeconds) else {
        throw DriverError.badArguments("--timeout requires a number from 1 through 300 seconds")
    }
    let targetPIDFile = try validatedObserverControlPath(
        values["--target-pid-file"]!,
        option: "--target-pid-file"
    )
    let readyFile = try validatedObserverControlPath(
        values["--ready-file"]!,
        option: "--ready-file"
    )
    let stopFile = try validatedObserverControlPath(
        values["--stop-file"]!,
        option: "--stop-file"
    )
    guard Set([targetPIDFile, readyFile, stopFile]).count == 3 else {
        throw DriverError.badArguments(
            "observe-frontmost control file paths must be distinct"
        )
    }
    return FrontmostObserverOptions(
        targetPIDFile: targetPIDFile,
        readyFile: readyFile,
        stopFile: stopFile,
        timeoutSeconds: timeoutSeconds
    )
}

private func writeAtomicObserverFile<T: Encodable>(_ value: T, path: String) throws {
    let destination = URL(fileURLWithPath: path)
    let temporary = destination
        .deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    let data = try encoder.encode(value)
    do {
        try data.write(to: temporary, options: [.withoutOverwriting])
        try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw DriverError.badArguments(
            "could not atomically create observer ready file: \(error)"
        )
    }
}

private func readObserverTargetPID(path: String) throws -> Int32? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    } catch {
        throw DriverError.badArguments("could not read target PID file: \(path)")
    }
    guard data.count <= 64,
          let rawValue = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !rawValue.isEmpty,
          rawValue.allSatisfy(\.isNumber),
          let pid = Int32(rawValue),
          pid > 0 else {
        throw DriverError.badArguments(
            "target PID file must contain one positive process id"
        )
    }
    return pid
}

private func observeFrontmostApplications(
    options: FrontmostObserverOptions
) throws -> FrontmostObserverReport {
    let sampleIntervalMs = 25
    let sampleIntervalNanoseconds = UInt64(sampleIntervalMs) * 1_000_000
    let startedAt = monotonicNanoseconds()
    let deadline = startedAt + UInt64(options.timeoutSeconds * 1_000_000_000)
    let state = FrontmostObserverState(
        startedAt: startedAt,
        sampleIntervalMs: sampleIntervalMs
    )
    let notificationCenter = NSWorkspace.shared.notificationCenter
    let token = notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { notification in
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        state.record(
            frontmostPID: app?.processIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
            source: "notification"
        )
    }
    defer { notificationCenter.removeObserver(token) }

    state.record(
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        source: "initial"
    )
    try writeAtomicObserverFile(FrontmostObserverReadyReport(
        schemaVersion: 1,
        observerPID: ProcessInfo.processInfo.processIdentifier,
        notificationObserverRegistered: true,
        sampleIntervalMs: sampleIntervalMs
    ), path: options.readyFile)

    var nextSample = startedAt + sampleIntervalNanoseconds
    var stopFileObserved = false
    var timedOut = false
    while true {
        if state.targetPID == nil,
           let targetPID = try readObserverTargetPID(path: options.targetPIDFile) {
            state.loadTargetPID(targetPID)
        }

        let now = monotonicNanoseconds()
        if now >= nextSample {
            state.record(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                source: "sample"
            )
            nextSample = now + sampleIntervalNanoseconds
        }
        if FileManager.default.fileExists(atPath: options.stopFile) {
            stopFileObserved = true
            break
        }
        if now >= deadline {
            timedOut = true
            break
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.005)
        )
    }

    state.record(
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        source: "stop"
    )
    return FrontmostObserverReport(
        schemaVersion: 1,
        observerPID: ProcessInfo.processInfo.processIdentifier,
        durationMs: elapsedMilliseconds(since: startedAt),
        sampleIntervalMs: sampleIntervalMs,
        notificationObserverRegistered: true,
        readyFileCreated: true,
        stopFileObserved: stopFileObserved,
        timedOut: timedOut,
        targetPID: state.targetPID,
        targetPIDLoadedAtMs: state.targetPIDLoadedAtMs,
        targetBecameFrontmost: state.firstTargetFrontmostObservation != nil,
        firstTargetFrontmostObservation: state.firstTargetFrontmostObservation,
        initialFrontmostPID: state.initialFrontmostPID,
        finalFrontmostPID: state.finalFrontmostPID,
        notificationCount: state.notificationCount,
        sampleCount: state.sampleCount,
        transitions: state.transitions
    )
}

private func foregroundPointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
    abs(lhs.x - rhs.x) <= 1.5 && abs(lhs.y - rhs.y) <= 1.5
}

private func restoreForegroundPointer(
    original: CGPoint,
    input: ForegroundInputState,
    monitor: ForegroundInterferenceMonitor
) -> ForegroundPointerRestoreReport {
    guard let lastInjected = input.lastInjectedPointer else {
        return ForegroundPointerRestoreReport(
            attempted: false,
            restored: true,
            reason: "no-pointer-action"
        )
    }
    guard !monitor.pointerRestorationUnsafe else {
        return ForegroundPointerRestoreReport(
            attempted: false,
            restored: false,
            reason: monitor.eventTapReliable
                ? "pointer-user-interference"
                : "event-tap-unreliable"
        )
    }
    guard let current = try? quartzPointerLocation(),
          foregroundPointsMatch(current, lastInjected) else {
        return ForegroundPointerRestoreReport(
            attempted: false,
            restored: false,
            reason: "pointer-moved-after-injection"
        )
    }
    do {
        try postForegroundMove(at: original, input: input)
        Thread.sleep(forTimeInterval: 0.01)
        let restored = (try? quartzPointerLocation()).map {
            foregroundPointsMatch($0, original)
        } ?? false
        return ForegroundPointerRestoreReport(
            attempted: true,
            restored: restored,
            reason: restored ? "restored" : "restore-not-observed"
        )
    } catch {
        return ForegroundPointerRestoreReport(
            attempted: true,
            restored: false,
            reason: "restore-failed: \(error)"
        )
    }
}

private struct ForegroundPasteboardSnapshot: Equatable {
    let items: [[String: Data]]

    static func capture(
        from pasteboard: NSPasteboard,
        maximumBytes: Int = 64 * 1_024 * 1_024
    ) throws -> ForegroundPasteboardSnapshot {
        var byteCount = 0
        let items = try (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw DriverError.badArguments(
                        "could not snapshot pasteboard type \(type.rawValue)"
                    )
                }
                byteCount += data.count
                guard byteCount <= maximumBytes else {
                    throw DriverError.badArguments(
                        "pasteboard snapshot exceeds the 64 MiB safety limit"
                    )
                }
                values[type.rawValue] = data
            }
            return values
        }
        return ForegroundPasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) throws -> String {
        let current = try Self.capture(from: pasteboard)
        guard current != self else { return "unchanged" }

        pasteboard.clearContents()
        if !items.isEmpty {
            let restoredItems = try items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (rawType, data) in values {
                    guard item.setData(
                        data,
                        forType: NSPasteboard.PasteboardType(rawType)
                    ) else {
                        throw DriverError.badArguments(
                            "could not restore pasteboard type \(rawType)"
                        )
                    }
                }
                return item
            }
            guard pasteboard.writeObjects(restoredItems) else {
                throw DriverError.badArguments("could not restore pasteboard items")
            }
        }
        guard try Self.capture(from: pasteboard) == self else {
            throw DriverError.badArguments("pasteboard restoration did not round trip")
        }
        return "restored"
    }
}

private func restoreForegroundPasteboard(
    snapshot: ForegroundPasteboardSnapshot?
) -> ForegroundPasteboardRestoreReport {
    guard let snapshot else {
        return ForegroundPasteboardRestoreReport(
            attempted: false,
            restored: true,
            itemCount: 0,
            reason: "no-pasteboard-action"
        )
    }
    do {
        let reason = try snapshot.restore(to: .general)
        return ForegroundPasteboardRestoreReport(
            attempted: true,
            restored: true,
            itemCount: snapshot.items.count,
            reason: reason
        )
    } catch {
        return ForegroundPasteboardRestoreReport(
            attempted: true,
            restored: false,
            itemCount: snapshot.items.count,
            reason: String(describing: error)
        )
    }
}

private func pasteboardSelfTestReport() throws -> PasteboardSelfTestReport {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("MarkdownViewer.RealAppDriver.\(UUID().uuidString)")
    )
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()

    let first = NSPasteboardItem()
    guard first.setString("alpha", forType: .string),
          first.setData(
            Data([0x00, 0x7F, 0xFF]),
            forType: NSPasteboard.PasteboardType("dev.markdownviewer.self-test")
          ) else {
        throw DriverError.badArguments("could not seed the named pasteboard self-test")
    }
    let second = NSPasteboardItem()
    guard second.setString("beta", forType: .string),
          pasteboard.writeObjects([first, second]) else {
        throw DriverError.badArguments("could not write the named pasteboard self-test")
    }
    let expected = try ForegroundPasteboardSnapshot.capture(from: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString("changed", forType: .string) else {
        throw DriverError.badArguments("could not mutate the named pasteboard self-test")
    }
    _ = try expected.restore(to: pasteboard)
    let restored = try ForegroundPasteboardSnapshot.capture(from: pasteboard) == expected

    pasteboard.clearContents()
    let empty = try ForegroundPasteboardSnapshot.capture(from: pasteboard)
    guard pasteboard.setString("temporary", forType: .string) else {
        throw DriverError.badArguments("could not seed the empty pasteboard self-test")
    }
    _ = try empty.restore(to: pasteboard)
    let emptyRestored = try ForegroundPasteboardSnapshot.capture(from: pasteboard) == empty
    return PasteboardSelfTestReport(
        schemaVersion: 1,
        restored: restored,
        itemCount: expected.items.count,
        typeCount: expected.items.reduce(0) { $0 + $1.count },
        emptyPasteboardRestored: emptyRestored
    )
}

private func restoreForegroundFocus(
    targetPID: Int32,
    priorPID: Int32?
) -> ForegroundFocusRestoreReport {
    guard let priorPID else {
        return ForegroundFocusRestoreReport(
            attempted: false,
            restored: false,
            priorPID: nil,
            reason: "no-prior-frontmost-app"
        )
    }
    if priorPID == targetPID {
        return ForegroundFocusRestoreReport(
            attempted: false,
            restored: false,
            priorPID: priorPID,
            reason: "invalid-prior-target-match"
        )
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
        return ForegroundFocusRestoreReport(
            attempted: false,
            restored: false,
            priorPID: priorPID,
            reason: "target-no-longer-frontmost"
        )
    }
    guard NSRunningApplication(processIdentifier: priorPID)?.isTerminated == false else {
        return ForegroundFocusRestoreReport(
            attempted: false,
            restored: false,
            priorPID: priorPID,
            reason: "prior-app-no-longer-running"
        )
    }
    do {
        try setApplicationFrontmost(pid: priorPID)
    } catch {
        return ForegroundFocusRestoreReport(
            attempted: true,
            restored: false,
            priorPID: priorPID,
            reason: "activation-failed: \(error)"
        )
    }
    let observationDeadline = monotonicNanoseconds() + 200_000_000
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID,
          monotonicNanoseconds() < observationDeadline {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }
    let restored = NSWorkspace.shared.frontmostApplication?.processIdentifier == priorPID
    return ForegroundFocusRestoreReport(
        attempted: true,
        restored: restored,
        priorPID: priorPID,
        reason: restored ? "restored" : "restore-not-observed"
    )
}

private func runForegroundBatch(
    pid: Int32,
    plan: ForegroundPlan,
    budgetMs: Int,
    logicalSize: CGSize?,
    launchToken: UUID
) throws -> ForegroundBatchReport {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        throw DriverError.permissionDenied(
            "macOS Accessibility and Input Monitoring permissions are required for foreground input"
        )
    }
    guard CGPreflightListenEventAccess() else {
        throw DriverError.permissionDenied(
            "macOS Input Monitoring permission is required for foreground interference detection"
        )
    }
    if plan.actions.contains(where: { $0.kind == .windowScreenshot }) {
        guard CGPreflightScreenCaptureAccess() else {
            throw DriverError.permissionDenied(
                "macOS Screen Recording permission is required for foreground screenshots"
            )
        }
    }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let sessionLocked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    guard !sessionLocked else {
        throw DriverError.permissionDenied("the macOS session is locked")
    }
    guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
        throw DriverError.processMissing(pid)
    }

    // Validate window existence and all geometry before the sole target activation.
    let backgroundWindow = try waitForWindow(
        pid: pid,
        timeout: 2,
        includeOffscreen: true,
        requireOffscreen: true
    )
    let validationWidth = logicalSize.map { Double($0.width) }
        ?? backgroundWindow.bounds.width
    let validationHeight = logicalSize.map { Double($0.height) }
        ?? backgroundWindow.bounds.height
    for action in plan.actions where action.kind == .findControlClick {
        _ = try findControlPoint(
            action.control!,
            windowWidth: validationWidth,
            windowHeight: validationHeight
        )
    }
    let pasteboardSnapshot = plan.actions.contains {
        $0.kind == .pasteboardStringCheck
    } ? try ForegroundPasteboardSnapshot.capture(from: .general) : nil

    let startedAt = monotonicNanoseconds()
    let hardDeadline = startedAt + UInt64(budgetMs) * 1_000_000
    let actionDeadline = hardDeadline - UInt64(foregroundCleanupReserveMs) * 1_000_000
    let nonce = Int64.random(in: 1...Int64.max)
    let monitor = ForegroundInterferenceMonitor(
        targetPID: pid,
        nonce: nonce,
        startedAt: startedAt
    )
    try monitor.start()
    let input = ForegroundInputState(pid: pid, nonce: nonce)

    var cleanupFinished = false
    defer {
        if !cleanupFinished {
            input.releaseInputs()
            monitor.stop()
        }
    }

    _ = RunLoop.current.run(
        mode: .default,
        before: Date(timeIntervalSinceNow: 0.005)
    )
    guard !monitor.detected,
          let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          priorPID != pid,
          NSRunningApplication(processIdentifier: priorPID)?.isTerminated == false else {
        throw DriverError.badArguments(
            "foreground batch requires an undisturbed live prior app and a background target"
        )
    }
    let priorPointer = try quartzPointerLocation()
    guard !monitor.detected,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == priorPID else {
        throw DriverError.badArguments(
            "frontmost application changed before foreground activation"
        )
    }

    var reports: [ForegroundBatchActionReport] = []
    var targetActivationRequestCount = 0
    var runtimeError: String?
    var deadlineExceeded = false

    do {
        targetActivationRequestCount += 1
        postVisualTestActivationRequest(pid: pid, launchToken: launchToken)
        guard try waitForForegroundActivation(
            pid: pid,
            deadline: actionDeadline,
            monitor: monitor
        ) else {
            throw DriverError.badArguments(
                "target did not become frontmost after its token-bound Debug activation request"
            )
        }

        var activeWindow: WindowReport?
        for _ in 0..<10 {
            if let candidate = windowInfo(for: pid) {
                if let logicalSize {
                    let widthMatches = abs(
                        candidate.bounds.width - Double(logicalSize.width)
                    ) <= 0.5
                    let heightMatches = abs(
                        candidate.bounds.height - Double(logicalSize.height)
                    ) <= 0.5
                    if widthMatches && heightMatches {
                        activeWindow = candidate
                        break
                    }
                } else {
                    activeWindow = candidate
                    break
                }
            }
            try foregroundWait(
                milliseconds: 20,
                deadline: actionDeadline,
                monitor: monitor
            )
        }
        guard let activeWindow else {
            throw DriverError.badArguments(
                "target window did not restore its logical geometry after activation"
            )
        }
        // NSWorkspace can report the process as frontmost before WindowServer has
        // synchronized global pointer routing. The legacy real-pointer path proved
        // that this synchronous AX frontmost write closes that gap. The existing
        // bounded move and action waits provide settling time without an added sleep.
        try setApplicationFrontmost(pid: pid)

        for (index, action) in plan.actions.enumerated() {
            try ensureForegroundCanContinue(deadline: actionDeadline, monitor: monitor)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw DriverError.badArguments(
                    "target stopped being frontmost without a monitored input event"
                )
            }
            let actionStartedAt = monotonicNanoseconds()
            let injectedPointerBaseline = monitor.injectedPointerEvents()
            let targetInjectedPointerBaseline = monitor
                .targetInjectedPointerEventsReport()
            var resolvedElement: ForegroundElementReport?
            var pointerClickReadiness: ForegroundPointerClickReadinessReport?
            var pointerDragEnd: DesktopPointerReport?
            var pointerDragEndpointReadiness: ForegroundPointerClickReadinessReport?
            do {
                switch action.kind {
                case .moveSafePoint:
                    let point = CGPoint(
                        x: activeWindow.bounds.x + max(20, activeWindow.bounds.width - 80),
                        y: activeWindow.bounds.y + activeWindow.bounds.height * 0.55
                    )
                    try postForegroundMove(at: point, input: input)
                case .moveOutline:
                    let point = CGPoint(
                        x: activeWindow.bounds.x + min(activeWindow.bounds.width - 20, 240),
                        y: activeWindow.bounds.y + 56
                            + max(0, activeWindow.bounds.height - 56) * 0.46
                    )
                    try postForegroundMove(at: point, input: input)
                case .windowMove:
                    try postForegroundMove(
                        at: foregroundWindowPoint(action: action, window: activeWindow),
                        input: input
                    )
                case .windowClick:
                    let point = foregroundWindowPoint(
                        action: action,
                        window: activeWindow
                    )
                    pointerClickReadiness = foregroundPointerClickReadiness(
                        at: point,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerClickReadiness!
                    )
                    try postForegroundClick(
                        at: point,
                        input: input,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .windowDrag:
                    let points = try foregroundWindowDragPoints(
                        action: action,
                        window: activeWindow
                    )
                    pointerClickReadiness = foregroundPointerClickReadiness(
                        at: points.start,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerClickReadiness!
                    )
                    pointerDragEnd = DesktopPointerReport(
                        x: points.end.x,
                        y: points.end.y
                    )
                    try postForegroundDrag(
                        from: points.start,
                        to: points.end,
                        input: input,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                    pointerDragEndpointReadiness = foregroundPointerClickReadiness(
                        at: points.end,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerDragEndpointReadiness!
                    )
                case .elementMove:
                    let element = try resolveForegroundElement(
                        pid: pid,
                        selector: action.elementSelector!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                    resolvedElement = element
                    try postForegroundMove(
                        at: try foregroundElementPoint(
                            action: action,
                            element,
                            inside: activeWindow
                        ),
                        input: input
                    )
                case .elementCheck, .elementDescriptionCheck:
                    resolvedElement = try resolveForegroundElement(
                        pid: pid,
                        selector: action.elementSelector!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .elementClick:
                    let element = try resolveForegroundElement(
                        pid: pid,
                        selector: action.elementSelector!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                    resolvedElement = element
                    let point = try foregroundElementPoint(
                        action: action,
                        element,
                        inside: activeWindow
                    )
                    pointerClickReadiness = foregroundPointerClickReadiness(
                        at: point,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerClickReadiness!
                    )
                    try postForegroundClick(
                        at: point,
                        input: input,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .elementDrag:
                    let element = try resolveForegroundElement(
                        pid: pid,
                        selector: action.elementSelector!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                    resolvedElement = element
                    let points = try foregroundElementDragPoints(
                        action: action,
                        element: element,
                        inside: activeWindow
                    )
                    pointerClickReadiness = foregroundPointerClickReadiness(
                        at: points.start,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerClickReadiness!
                    )
                    pointerDragEnd = DesktopPointerReport(
                        x: points.end.x,
                        y: points.end.y
                    )
                    try postForegroundDrag(
                        from: points.start,
                        to: points.end,
                        input: input,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                    pointerDragEndpointReadiness = foregroundPointerClickReadiness(
                        at: points.end,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerDragEndpointReadiness!
                    )
                case .focusedElementCheck:
                    resolvedElement = try resolveForegroundFocusedElement(
                        pid: pid,
                        selector: action.elementSelector!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .scroll:
                    try postForegroundScroll(
                        deltaY: action.deltaY!,
                        at: CGPoint(
                            x: activeWindow.bounds.x + activeWindow.bounds.width / 2,
                            y: activeWindow.bounds.y + activeWindow.bounds.height / 2
                        ),
                        input: input
                    )
                case .shiftTap:
                    try postForegroundShiftTap(input: input)
                case .key:
                    try postForegroundKey(spec: action.key!, input: input)
                case .text:
                    try postForegroundText(action.text!, input: input)
                case .pasteboardStringCheck:
                    guard NSPasteboard.general.string(forType: .string) == action.text else {
                        throw DriverError.badArguments(
                            "general pasteboard string did not match the exact expected value"
                        )
                    }
                case .findControlClick:
                    let relative = try findControlPoint(
                        action.control!,
                        windowWidth: activeWindow.bounds.width,
                        windowHeight: activeWindow.bounds.height
                    )
                    let point = CGPoint(
                        x: activeWindow.bounds.x + relative.x,
                        y: activeWindow.bounds.y + relative.y
                    )
                    pointerClickReadiness = foregroundPointerClickReadiness(
                        at: point,
                        pid: pid,
                        targetWindow: activeWindow
                    )
                    try validateForegroundPointerClickReadiness(
                        pointerClickReadiness!
                    )
                    try postForegroundClick(
                        at: point,
                        input: input,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .windowScreenshot:
                    try captureForegroundWindow(
                        activeWindow,
                        path: action.path!,
                        logicalSize: logicalSize,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                case .wait:
                    try foregroundWait(
                        milliseconds: action.durationMs!,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                }
                if action.kind != .wait {
                    try foregroundWait(
                        milliseconds: action.waitMs,
                        deadline: actionDeadline,
                        monitor: monitor
                    )
                }
                let injectedPointerEvents = monitor.injectedPointerEvents(
                    since: injectedPointerBaseline
                )
                let targetInjectedPointerEvents = monitor
                    .targetInjectedPointerEventsReport(
                        since: targetInjectedPointerBaseline
                    )
                if let pointerClickReadiness, let pointerDragEnd {
                    try validateForegroundInjectedPointerDrag(
                        injectedPointerEvents,
                        expectedStart: pointerClickReadiness.point,
                        expectedEnd: pointerDragEnd,
                        deliveryLayer: "session event tap"
                    )
                    try validateForegroundInjectedPointerDrag(
                        targetInjectedPointerEvents,
                        expectedStart: pointerClickReadiness.point,
                        expectedEnd: pointerDragEnd,
                        deliveryLayer: "target-process event tap"
                    )
                } else if let pointerClickReadiness {
                    try validateForegroundInjectedPointerClick(
                        injectedPointerEvents,
                        expectedPoint: pointerClickReadiness.point,
                        deliveryLayer: "session event tap"
                    )
                    try validateForegroundInjectedPointerClick(
                        targetInjectedPointerEvents,
                        expectedPoint: pointerClickReadiness.point,
                        deliveryLayer: "target-process event tap"
                    )
                }
                reports.append(ForegroundBatchActionReport(
                    index: index,
                    kind: action.kind.rawValue,
                    status: "completed",
                    durationMs: elapsedMilliseconds(since: actionStartedAt),
                    detail: foregroundActionDetail(action),
                    element: resolvedElement,
                    injectedPointerEvents: injectedPointerEvents,
                    targetInjectedPointerEvents: targetInjectedPointerEvents,
                    pointerClickReadiness: pointerClickReadiness,
                    pointerDragEndpointReadiness: pointerDragEndpointReadiness
                ))
            } catch {
                let status: String
                if case ForegroundBatchStop.interference = error {
                    status = "interrupted"
                } else if case ForegroundBatchStop.deadline = error {
                    status = "deadline-exceeded"
                } else {
                    status = "failed"
                }
                reports.append(ForegroundBatchActionReport(
                    index: index,
                    kind: action.kind.rawValue,
                    status: status,
                    durationMs: elapsedMilliseconds(since: actionStartedAt),
                    detail: foregroundActionDetail(action),
                    element: resolvedElement,
                    injectedPointerEvents: monitor.injectedPointerEvents(
                        since: injectedPointerBaseline
                    ),
                    targetInjectedPointerEvents: monitor
                        .targetInjectedPointerEventsReport(
                            since: targetInjectedPointerBaseline
                        ),
                    pointerClickReadiness: pointerClickReadiness,
                    pointerDragEndpointReadiness: pointerDragEndpointReadiness
                ))
                throw error
            }
        }
    } catch ForegroundBatchStop.interference {
        runtimeError = "foreground batch stopped for user interference"
    } catch ForegroundBatchStop.deadline {
        deadlineExceeded = true
        runtimeError = "foreground batch stopped at its cleanup-reserved deadline"
    } catch {
        runtimeError = String(describing: error)
    }

    // Drain already queued input before deciding whether it is safe to restore.
    _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    input.releaseInputs()
    let pasteboardRestore = restoreForegroundPasteboard(snapshot: pasteboardSnapshot)
    let pointerRestore = restoreForegroundPointer(
        original: priorPointer,
        input: input,
        monitor: monitor
    )
    let focusRestore = restoreForegroundFocus(targetPID: pid, priorPID: priorPID)
    monitor.stop()
    cleanupFinished = true

    let finishedAt = monotonicNanoseconds()
    if finishedAt > hardDeadline { deadlineExceeded = true }
    if runtimeError == nil, !pointerRestore.restored {
        runtimeError = "foreground batch could not safely restore the pointer"
    }
    if runtimeError == nil, !pasteboardRestore.restored {
        runtimeError = "foreground batch could not restore the pasteboard"
    }
    if runtimeError == nil, !focusRestore.restored {
        runtimeError = "foreground batch could not confirm focus restoration"
    }
    let completed = runtimeError == nil
        && !monitor.detected
        && !deadlineExceeded
        && reports.count == plan.actions.count
        && reports.allSatisfy { $0.status == "completed" }
    return ForegroundBatchReport(
        pid: pid,
        durationMs: elapsedMilliseconds(since: startedAt, until: finishedAt),
        budgetMs: budgetMs,
        targetActivationRequestCount: targetActivationRequestCount,
        completed: completed,
        actions: reports,
        interference: monitor.report(),
        injectedPointerEvents: monitor.injectedPointerEvents(),
        targetInjectedPointerEvents: monitor.targetInjectedPointerEventsReport(),
        deadlineExceeded: deadlineExceeded,
        focusRestore: focusRestore,
        pointerRestore: pointerRestore,
        pasteboardRestore: pasteboardRestore,
        error: runtimeError
    )
}

private func inspectElement(
    pid: Int32,
    relativeX: Double,
    relativeY: Double,
    expectedRole: String?,
    identifierPrefix: String?
) throws -> ElementReport {
    guard AXIsProcessTrusted() else {
        throw DriverError.permissionDenied(
            "macOS Accessibility permission is required for element assertions"
        )
    }
    let window = try waitForWindow(pid: pid, timeout: 2)
    try focusTargetForGlobalPointerEvent(pid: pid)
    Thread.sleep(forTimeInterval: 0.12)
    let point = CGPoint(
        x: window.bounds.x + relativeX,
        y: window.bounds.y + relativeY
    )
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(
        system,
        Float(point.x),
        Float(point.y),
        &element
    )
    guard error == .success, let element else {
        throw DriverError.badArguments("no accessibility element at \(relativeX),\(relativeY)")
    }
    let role = accessibilityString(element, attribute: kAXRoleAttribute)
    let identifier = accessibilityString(element, attribute: kAXIdentifierAttribute)
    if let expectedRole, role != expectedRole {
        throw DriverError.badArguments("expected role \(expectedRole), found \(role)")
    }
    if let identifierPrefix, !identifier.hasPrefix(identifierPrefix) {
        throw DriverError.badArguments(
            "expected identifier prefix \(identifierPrefix), found \(identifier)"
        )
    }
    return ElementReport(
        pid: pid,
        relativeX: relativeX,
        relativeY: relativeY,
        role: role,
        identifier: identifier,
        description: accessibilityString(element, attribute: kAXDescriptionAttribute),
        value: accessibilityString(element, attribute: kAXValueAttribute)
    )
}

private func requestNormalAppTermination(
    pid: Int32,
    timeout: Double,
    expectedBundleIdentifier: String,
    expectedExecutablePath: String? = nil,
    commandName: String
) throws -> TerminateAppReport {
    guard pid != ProcessInfo.processInfo.processIdentifier else {
        throw DriverError.badArguments("\(commandName) cannot target the driver process")
    }
    guard timeout.isFinite, (0.2...10).contains(timeout) else {
        throw DriverError.badArguments(
            "--timeout requires a number from 0.2 through 10 seconds"
        )
    }
    guard let application = NSRunningApplication(processIdentifier: pid),
          !application.isTerminated else {
        throw DriverError.badArguments("\(commandName) target is not running: \(pid)")
    }
    let actualBundleIdentifier = application.bundleIdentifier ?? "<missing>"
    guard actualBundleIdentifier == expectedBundleIdentifier else {
        if commandName == "terminate-app" {
            throw DriverError.badArguments(
                "terminate-app refuses non-Debug Markdown Viewer process \(pid)"
            )
        }
        throw DriverError.badArguments(
            "\(commandName) refuses process \(pid) with bundle identifier "
                + actualBundleIdentifier
        )
    }
    if let expectedExecutablePath {
        let normalizedExpectedPath = URL(fileURLWithPath: expectedExecutablePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let actualExecutablePath = application.executableURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard actualExecutablePath == normalizedExpectedPath else {
            throw DriverError.badArguments(
                "\(commandName) refuses process \(pid) with executable "
                    + (actualExecutablePath ?? "<missing>")
            )
        }
    }

    let startedAt = monotonicNanoseconds()
    let requested = application.terminate()
    let deadline = Date().addingTimeInterval(timeout)
    if requested {
        while !application.isTerminated, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
        }
    }
    return TerminateAppReport(
        schemaVersion: 1,
        pid: pid,
        bundleIdentifier: expectedBundleIdentifier,
        requested: requested,
        exited: application.isTerminated,
        forced: false,
        durationMs: elapsedMilliseconds(since: startedAt)
    )
}

private func requestNormalDebugAppTermination(
    pid: Int32,
    timeout: Double
) throws -> TerminateAppReport {
    let expectedBundleIdentifier = "local.codex.markdownviewer.debug"
    return try requestNormalAppTermination(
        pid: pid,
        timeout: timeout,
        expectedBundleIdentifier: expectedBundleIdentifier,
        commandName: "terminate-app"
    )
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw DriverError.badArguments(
            "expected preflight, desktop-state, pasteboard-self-test, observe-frontmost, terminate-app, terminate-release-smoke-app, window, windows, capture-window, send, foreground-batch, foreground-batch-plan, click-text, compare, sidebar, screenshot-text, reset-sidebar-filter, element, or find-control-point"
        )
    }

    switch command {
    case "preflight":
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sessionLocked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        try printJSON(AccessReport(
            accessibilityTrusted: AXIsProcessTrusted(),
            listenEventAccess: CGPreflightListenEventAccess(),
            postEventAccess: CGPreflightPostEventAccess(),
            screenCaptureAccess: CGPreflightScreenCaptureAccess(),
            sessionLocked: sessionLocked
        ))
    case "desktop-state":
        try printJSON(try desktopStateReport())
    case "pasteboard-self-test":
        guard arguments.count == 1 else {
            throw DriverError.badArguments("pasteboard-self-test takes no options")
        }
        try printJSON(try pasteboardSelfTestReport())
    case "observe-frontmost":
        let options = try frontmostObserverOptions(arguments: arguments)
        let report = try observeFrontmostApplications(options: options)
        try printJSON(report)
        if report.timedOut || !report.stopFileObserved {
            throw DriverError.badArguments(
                "frontmost observer timed out before the stop file appeared"
            )
        }
        if report.targetPID == nil {
            throw DriverError.badArguments(
                "frontmost observer stopped before the target PID file appeared"
            )
        }
    case "terminate-app":
        let pid = try int32Option("--pid", arguments: arguments)
        let timeout = try doubleOption("--timeout", arguments: arguments, default: 2)
        let report = try requestNormalDebugAppTermination(
            pid: pid,
            timeout: timeout
        )
        try printJSON(report)
        if !report.requested {
            throw DriverError.badArguments(
                "Debug Markdown Viewer rejected the normal termination request"
            )
        }
        if !report.exited {
            throw DriverError.badArguments(
                "Debug Markdown Viewer did not terminate before timeout"
            )
        }
    case "terminate-release-smoke-app":
        let pid = try int32Option("--pid", arguments: arguments)
        let timeout = try doubleOption("--timeout", arguments: arguments, default: 2)
        let executablePath = try stringOption("--executable", arguments: arguments)
        guard (executablePath as NSString).isAbsolutePath else {
            throw DriverError.badArguments("--executable requires an absolute path")
        }
        let report = try requestNormalAppTermination(
            pid: pid,
            timeout: timeout,
            expectedBundleIdentifier: "local.codex.markdownviewer.release-smoke",
            expectedExecutablePath: executablePath,
            commandName: "terminate-release-smoke-app"
        )
        try printJSON(report)
        if !report.requested {
            throw DriverError.badArguments(
                "Release smoke Markdown Viewer rejected the normal termination request"
            )
        }
        if !report.exited {
            throw DriverError.badArguments(
                "Release smoke Markdown Viewer did not terminate before timeout"
            )
        }
    case "window":
        let pid = try int32Option("--pid", arguments: arguments)
        let timeout = try doubleOption("--timeout", arguments: arguments, default: 5)
        let requestedWindowNumber = value(after: "--window-number", in: arguments)
        let windowNumber = try requestedWindowNumber.map { rawValue -> UInt32 in
            guard let value = UInt32(rawValue), value > 0 else {
                throw DriverError.badArguments("--window-number requires a positive window number")
            }
            return value
        }
        let rawWidth = value(after: "--width", in: arguments)
        let rawHeight = value(after: "--height", in: arguments)
        if (rawWidth == nil) != (rawHeight == nil) {
            throw DriverError.badArguments("--width and --height must be supplied together")
        }
        let expectedWidth = rawWidth.flatMap(Double.init)
        let expectedHeight = rawHeight.flatMap(Double.init)
        if rawWidth != nil && (expectedWidth == nil || expectedHeight == nil) {
            throw DriverError.badArguments("--width and --height require numbers")
        }
        if let windowNumber {
            if rawWidth != nil
                || arguments.contains("--allow-uniform-presentation-scale")
                || arguments.contains("--main-window-only") {
                throw DriverError.badArguments(
                    "--window-number cannot be combined with size or main-window selection options"
                )
            }
            try printJSON(try waitForWindow(
                pid: pid,
                windowNumber: windowNumber,
                timeout: timeout,
                includeOffscreen: arguments.contains("--include-offscreen"),
                requireOffscreen: arguments.contains("--require-offscreen")
            ))
        } else {
            try printJSON(try waitForWindow(
                pid: pid,
                timeout: timeout,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                includeOffscreen: arguments.contains("--include-offscreen"),
                requireOffscreen: arguments.contains("--require-offscreen"),
                allowUniformPresentationScale: arguments.contains("--allow-uniform-presentation-scale"),
                mainWindowOnly: arguments.contains("--main-window-only")
            ))
        }
    case "windows":
        let pid = try int32Option("--pid", arguments: arguments)
        let reports = windowReports(
            for: pid,
            includeOffscreen: arguments.contains("--include-offscreen")
        ).sorted { lhs, rhs in
            lhs.windowNumber < rhs.windowNumber
        }
        try printJSON(reports)
    case "capture-window":
        let pid = try int32Option("--pid", arguments: arguments)
        let windowNumber = try uint32Option("--window-number", arguments: arguments)
        let output = try validateScreenshotPath(
            try stringOption("--output", arguments: arguments),
            context: "--output"
        )
        let timeout = try doubleOption("--timeout", arguments: arguments, default: 3)
        guard timeout.isFinite, (0.2...10).contains(timeout) else {
            throw DriverError.badArguments("--timeout requires a number from 0.2 through 10 seconds")
        }
        let rawLogicalWidth = value(after: "--logical-width", in: arguments)
        let rawLogicalHeight = value(after: "--logical-height", in: arguments)
        if (rawLogicalWidth == nil) != (rawLogicalHeight == nil) {
            throw DriverError.badArguments(
                "--logical-width and --logical-height must be supplied together"
            )
        }
        let logicalSize: CGSize?
        if let rawLogicalWidth,
           let rawLogicalHeight,
           let width = Double(rawLogicalWidth),
           let height = Double(rawLogicalHeight),
           width.isFinite,
           height.isFinite,
           width > 0,
           height > 0 {
            logicalSize = CGSize(width: width, height: height)
        } else if rawLogicalWidth != nil {
            throw DriverError.badArguments(
                "--logical-width and --logical-height require positive finite numbers"
            )
        } else {
            logicalSize = nil
        }
        guard let window = windowInfo(
            for: pid,
            windowNumber: windowNumber,
            includeOffscreen: true
        ) else {
            throw DriverError.windowNumberMissing(pid, windowNumber)
        }
        let startedAt = monotonicNanoseconds()
        let deadline = startedAt + UInt64((timeout * 1_000_000_000).rounded())
        let result = try captureExactWindow(
            window,
            path: output,
            logicalSize: logicalSize,
            deadline: deadline
        ) {
            guard monotonicNanoseconds() < deadline else {
                throw DriverError.captureFailed("capture-window timed out")
            }
        }
        try printJSON(WindowCaptureReport(
            pid: pid,
            windowNumber: windowNumber,
            output: output,
            method: result.method,
            width: result.width,
            height: result.height,
            durationMs: elapsedMilliseconds(since: startedAt)
        ))
    case "send":
        let pid = try int32Option("--pid", arguments: arguments)
        let delay = try doubleOption("--delay", arguments: arguments, default: 0.18)
        try printJSON(try sendActions(pid: pid, arguments: arguments, delay: delay))
    case "foreground-batch-plan":
        let budgetMs = try foregroundBudget(arguments: arguments)
        let planPath = try stringOption("--plan", arguments: arguments)
        let plan = try loadForegroundPlan(path: planPath, budgetMs: budgetMs)
        try printJSON(foregroundPlanReport(plan: plan, budgetMs: budgetMs))
    case "foreground-batch":
        let budgetMs = try foregroundBudget(arguments: arguments)
        let planPath = try stringOption("--plan", arguments: arguments)
        let plan = try loadForegroundPlan(path: planPath, budgetMs: budgetMs)
        let pid = try int32Option("--pid", arguments: arguments)
        let rawLaunchToken = try stringOption("--launch-token", arguments: arguments)
        guard let launchToken = UUID(uuidString: rawLaunchToken) else {
            throw DriverError.badArguments("--launch-token requires a UUID")
        }
        let rawWidth = value(after: "--width", in: arguments)
        let rawHeight = value(after: "--height", in: arguments)
        if (rawWidth == nil) != (rawHeight == nil) {
            throw DriverError.badArguments("--width and --height must be supplied together")
        }
        let logicalSize: CGSize?
        if let rawWidth,
           let rawHeight,
           let width = Double(rawWidth),
           let height = Double(rawHeight),
           width.isFinite,
           height.isFinite,
           width > 0,
           height > 0 {
            logicalSize = CGSize(width: width, height: height)
        } else if rawWidth != nil {
            throw DriverError.badArguments("--width and --height require positive finite numbers")
        } else {
            logicalSize = nil
        }
        try printJSON(try runForegroundBatch(
            pid: pid,
            plan: plan,
            budgetMs: budgetMs,
            logicalSize: logicalSize,
            launchToken: launchToken
        ))
    case "click-text":
        let pid = try int32Option("--pid", arguments: arguments)
        let screenshot = try stringOption("--screenshot", arguments: arguments)
        let requestedText = try stringOption("--text", arguments: arguments)
        let rawCount = value(after: "--count", in: arguments) ?? "1"
        guard let clickCount = Int(rawCount) else {
            throw DriverError.badArguments("--count requires an integer")
        }
        try printJSON(try clickRecognizedText(
            pid: pid,
            screenshot: screenshot,
            requestedText: requestedText,
            clickCount: clickCount
        ))
    case "compare":
        let before = try stringOption("--before", arguments: arguments)
        let after = try stringOption("--after", arguments: arguments)
        try printJSON(try compareImages(before: before, after: after))
    case "sidebar":
        let pid = try int32Option("--pid", arguments: arguments)
        let screenshot = try stringOption("--screenshot", arguments: arguments)
        try printJSON(try inspectSidebar(
            pid: pid,
            screenshot: screenshot,
            passive: arguments.contains("--passive")
        ))
    case "screenshot-text":
        let screenshot = try stringOption("--screenshot", arguments: arguments)
        try printJSON(try assertScreenshotText(
            screenshot: screenshot,
            requiredText: values(after: "--contains", in: arguments),
            forbiddenText: values(after: "--not-contains", in: arguments)
        ))
    case "reset-sidebar-filter":
        let pid = try int32Option("--pid", arguments: arguments)
        try printJSON(try resetSidebarFilter(pid: pid))
    case "element":
        let pid = try int32Option("--pid", arguments: arguments)
        guard let relativeX = Double(try stringOption("--x", arguments: arguments)),
              let relativeY = Double(try stringOption("--y", arguments: arguments)) else {
            throw DriverError.badArguments("--x and --y require numbers")
        }
        let expectedRole = value(after: "--role", in: arguments)
        let identifierPrefix = value(after: "--identifier-prefix", in: arguments)
        try printJSON(try inspectElement(
            pid: pid,
            relativeX: relativeX,
            relativeY: relativeY,
            expectedRole: expectedRole,
            identifierPrefix: identifierPrefix
        ))
    case "find-control-point":
        let control = try stringOption("--control", arguments: arguments)
        let width = try doubleOption("--width", arguments: arguments, default: 1_180)
        let height = try doubleOption("--height", arguments: arguments, default: 760)
        let point = try findControlPoint(
            control,
            windowWidth: width,
            windowHeight: height
        )
        try printJSON(FindControlPointReport(
            control: control,
            windowWidth: width,
            windowHeight: height,
            relativeX: point.x,
            relativeY: point.y
        ))
    default:
        throw DriverError.badArguments("unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("RealAppDriver: \(error)\n".utf8))
    exit(2)
}
