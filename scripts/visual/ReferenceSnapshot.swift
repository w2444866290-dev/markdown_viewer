import AppKit
import Foundation
import WebKit

private let authoritativeHTMLSHA256 = "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
private let acceptanceContractSHA256 = "1b28f6d306b97f18afbffda694bb659955a69298a9557b5a24e3d2d0a8d010dc"

private struct Viewport: Hashable {
    let width: Int
    let height: Int

    var name: String { "\(width)x\(height)" }
}

private struct Options {
    var htmlURL: URL
    var reactURL: URL
    var reactDOMURL: URL
    var contractURL: URL
    var outputURL: URL
    var viewports: [Viewport]
    var states: [String]
    var outputScale: Int
    var settleMilliseconds: Int

    static let supportedStates = [
        "default",
        "palette",
        "find",
        "replace",
        "preview",
        "sidebar-hidden",
        "source-editor",
        "table-editor",
    ]

    static func parse(_ arguments: [String]) throws -> Options {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var options = Options(
            htmlURL: workingDirectory.appendingPathComponent("ui/Markdown Viewer.dc.html"),
            reactURL: workingDirectory.appendingPathComponent("build/visual-tools/cache/react.production.min.js"),
            reactDOMURL: workingDirectory.appendingPathComponent("build/visual-tools/cache/react-dom.production.min.js"),
            contractURL: workingDirectory.appendingPathComponent("scripts/visual/acceptance-contract.json"),
            outputURL: workingDirectory.appendingPathComponent("build/visual-reference"),
            viewports: [Viewport(width: 1180, height: 760), Viewport(width: 860, height: 560), Viewport(width: 1440, height: 900)],
            states: ["default", "palette", "find", "preview", "sidebar-hidden", "source-editor", "table-editor"],
            outputScale: 2,
            settleMilliseconds: 420
        )

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                printUsage()
                exit(0)
            }
            guard index + 1 < arguments.count else {
                throw ToolError.badArguments("\(argument) requires a value")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--html":
                options.htmlURL = absoluteURL(value, relativeTo: workingDirectory)
            case "--react":
                options.reactURL = absoluteURL(value, relativeTo: workingDirectory)
            case "--react-dom":
                options.reactDOMURL = absoluteURL(value, relativeTo: workingDirectory)
            case "--contract":
                options.contractURL = absoluteURL(value, relativeTo: workingDirectory)
            case "--output":
                options.outputURL = absoluteURL(value, relativeTo: workingDirectory)
            case "--sizes":
                options.viewports = try parseViewports(value)
            case "--states":
                options.states = try parseStates(value)
            case "--scale":
                guard let scale = Int(value), (1...4).contains(scale) else {
                    throw ToolError.badArguments("--scale must be an integer from 1 through 4")
                }
                options.outputScale = scale
            case "--settle-ms":
                guard let milliseconds = Int(value), (0...5_000).contains(milliseconds) else {
                    throw ToolError.badArguments("--settle-ms must be an integer from 0 through 5000")
                }
                options.settleMilliseconds = milliseconds
            default:
                throw ToolError.badArguments("unknown option: \(argument)")
            }
            index += 2
        }
        return options
    }

    private static func absoluteURL(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base.appendingPathComponent(path)
    }

    private static func parseViewports(_ rawValue: String) throws -> [Viewport] {
        let rawViewports = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard !rawViewports.isEmpty else {
            throw ToolError.badArguments("--sizes cannot be empty")
        }
        let values = try rawViewports.map { raw -> Viewport in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = normalized.lowercased().split(separator: "x")
            guard parts.count == 2,
                  let width = Int(parts[0]),
                  let height = Int(parts[1]),
                  width >= 320,
                  height >= 240 else {
                throw ToolError.badArguments("invalid viewport: \(normalized)")
            }
            return Viewport(width: width, height: height)
        }
        guard Set(values).count == values.count else {
            throw ToolError.badArguments("--sizes cannot contain duplicate viewports")
        }
        return values
    }

    private static func parseStates(_ rawValue: String) throws -> [String] {
        let states = rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !states.isEmpty else { throw ToolError.badArguments("--states cannot be empty") }
        guard states.allSatisfy({ !$0.isEmpty }) else {
            throw ToolError.badArguments("--states cannot contain empty entries")
        }
        for state in states where !supportedStates.contains(state) {
            throw ToolError.badArguments("unsupported state '\(state)'; expected one of \(supportedStates.joined(separator: ", "))")
        }
        guard Set(states).count == states.count else {
            throw ToolError.badArguments("--states cannot contain duplicates")
        }
        return states
    }

    private static func printUsage() {
        print(
            """
            Usage: ReferenceSnapshot [options]

              --html PATH         Authoritative .dc.html input.
              --react PATH        Pinned React UMD input.
              --react-dom PATH    Pinned ReactDOM UMD input.
              --contract PATH     Schema-v2 visual acceptance contract.
              --output PATH       Snapshot directory.
              --sizes LIST        Comma-separated logical viewports, such as 1180x760,860x560.
              --states LIST       Comma-separated named states.
              --scale N           Normalized PNG pixels per viewport point. Default: 2.
              --settle-ms N       Render settle delay after each state action. Default: 420.

            Named states: \(supportedStates.joined(separator: ", "))
            """
        )
    }
}

private enum ToolError: Error, CustomStringConvertible {
    case badArguments(String)
    case missingFile(String)
    case hashMismatch(expected: String, actual: String)
    case navigation(String)
    case timeout(String)
    case script(String)
    case snapshot(String)
    case imageEncoding(String)

    var description: String {
        switch self {
        case .badArguments(let message),
             .missingFile(let message),
             .navigation(let message),
             .timeout(let message),
             .script(let message),
             .snapshot(let message),
             .imageEncoding(let message):
            return message
        case .hashMismatch(let expected, let actual):
            return "authoritative HTML SHA-256 mismatch: expected \(expected), found \(actual)"
        }
    }
}

private struct SnapshotRecord: Encodable {
    let state: String
    let viewportWidth: Int
    let viewportHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let outputScale: Int
    let webDevicePixelRatio: Double
    let pngSHA256: String
    let relativePath: String
    let visualEvidence: VisualEvidence
}

private struct EvidenceRectangle: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct StateAssertionEvidence: Codable {
    let name: String
    let evaluated: Bool
    let passed: Bool
}

private struct StateEvaluationEvidence: Codable {
    let evaluated: Bool
    let status: String
    let expectedState: String
    let observedState: String
    let source: String
    let assertions: [StateAssertionEvidence]
}

private struct GeometryAnchorEvidence: Codable {
    let name: String
    let evaluated: Bool
    let source: String
    let rect: EvidenceRectangle
}

private struct GeometryEvaluationEvidence: Codable {
    let evaluated: Bool
    let status: String
    let coordinateSpace: String
    let anchors: [GeometryAnchorEvidence]
}

private struct VisualProbe: Decodable {
    let stateEvaluation: StateEvaluationEvidence
    let geometryEvaluation: GeometryEvaluationEvidence
}

private struct VisualEvidence: Encodable {
    let schemaVersion: Int
    let kind: String
    let screenshotSHA256: String
    let stateEvaluation: StateEvaluationEvidence
    let geometryEvaluation: GeometryEvaluationEvidence
}

private struct AcceptanceContract: Decodable {
    let schemaVersion: Int
    let kind: String
    let states: [String: AcceptanceStateContract]
}

private struct AcceptanceStateContract: Decodable {
    let appLabel: String?
    let requiredStateAssertions: [String]
    let requiredGeometryAnchors: [String]
}

private struct Manifest: Encodable {
    let schemaVersion: Int
    let kind: String
    let authoritativeHTML: String
    let authoritativeHTMLSHA256: String
    let acceptanceContractSHA256: String
    let supportJSSHA256: String
    let reactSHA256: String
    let reactDOMSHA256: String
    let outputScale: Int
    let requestedMatrix: RequestedMatrix
    let coverage: CaptureCoverage
    let snapshots: [SnapshotRecord]
}

private struct RequestedMatrix: Encodable {
    let viewports: [String]
    let states: [String]
    let expectedSnapshotCount: Int
}

private struct CaptureCoverage: Encodable {
    let generatedSnapshotCount: Int
    let complete: Bool
}

@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForNavigation(of webView: WKWebView, htmlURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: ToolError.navigation(error.localizedDescription))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: ToolError.navigation(error.localizedDescription))
        continuation = nil
    }
}

@MainActor
private final class SnapshotPage {
    private let viewport: Viewport
    private let outputScale: Int
    private let window: NSWindow
    private let webView: WKWebView
    private let loader = PageLoader()

    init(viewport: Viewport, outputScale: Int, react: String, reactDOM: String) {
        self.viewport = viewport
        self.outputScale = outputScale

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let userContent = configuration.userContentController
        userContent.addUserScript(
            WKUserScript(
                source: react + "\n" + reactDOM,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContent.addUserScript(
            WKUserScript(
                source: """
                try { localStorage.clear(); sessionStorage.clear(); } catch (_) {}
                document.addEventListener('DOMContentLoaded', () => {
                  const style = document.createElement('style');
                  style.setAttribute('data-visual-snapshot-stability', '1');
                  style.textContent = '*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important;}';
                  document.head.appendChild(style);
                });
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let frame = NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.hasShadow = false
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = webView
    }

    func load(_ htmlURL: URL) async throws {
        try await loader.waitForNavigation(of: webView, htmlURL: htmlURL)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let ready = try await evaluate(
                "Boolean(document.querySelector('[data-screen-label=\"Markdown Editor\"]') && window.React && window.ReactDOM && window.__dcRegistry)"
            ) as? Bool, ready {
                try await waitForFonts()
                try await verifyViewport()
                return
            }
            try await sleep(milliseconds: 40)
        }
        throw ToolError.timeout("prototype did not reach its rendered ready state within 15 seconds")
    }

    func apply(state: String) async throws {
        switch state {
        case "default":
            break
        case "palette":
            try await dispatchKey("k", meta: true, shift: false)
        case "find":
            try await runLogicAction("openFind")
        case "replace":
            try await runLogicAction("openFind")
            try await sleep(milliseconds: 100)
            try await runLogicAction("toggleReplace")
        case "preview":
            try await dispatchKey("p", meta: true, shift: true)
        case "sidebar-hidden":
            try await dispatchKey("\\", meta: true, shift: false)
        case "source-editor":
            try await runAction(
                """
                const target = document.querySelector('[data-viewblock="1"]');
                if (!target) return 'missing rendered block';
                target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window, button: 0 }));
                return 'ok';
                """
            )
        case "table-editor":
            try await runAction(
                """
                const table = document.querySelector('[data-tbox="1"]');
                const target = table && table.closest('[data-viewblock="1"]');
                if (!target) return 'missing rendered table';
                target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window, button: 0 }));
                setTimeout(() => {
                  const input = document.querySelector('[data-tbl-input="1"]');
                  if (input) input.scrollIntoView({ block: 'center', inline: 'nearest' });
                }, 0);
                return 'ok';
                """
            )
        default:
            throw ToolError.badArguments("unsupported state: \(state)")
        }
        try await sleep(milliseconds: 40)
        try await verifyState(state)
    }

    func settle(milliseconds: Int) async throws {
        try await sleep(milliseconds: milliseconds)
        _ = try await evaluate("requestAnimationFrame(() => requestAnimationFrame(() => {})); true")
        try await sleep(milliseconds: 40)
    }

    func captureVisualProbe(
        state: String,
        requiredAssertions: [String],
        requiredAnchors: [String]
    ) async throws -> VisualProbe {
        let encoder = JSONEncoder()
        guard let stateJSON = String(data: try encoder.encode(state), encoding: .utf8),
              let assertionsJSON = String(data: try encoder.encode(requiredAssertions), encoding: .utf8),
              let anchorsJSON = String(data: try encoder.encode(requiredAnchors), encoding: .utf8) else {
            throw ToolError.script("could not encode visual evidence contract")
        }
        let script = """
        (() => {
          const expectedState = \(stateJSON);
          const requiredAssertions = \(assertionsJSON);
          const requiredAnchors = \(anchorsJSON);
          const root = document.querySelector('[data-screen-label="Markdown Editor"]');
          const visible = (node) => {
            if (!node) return false;
            const rect = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
          };
          const rectangle = (node) => {
            if (!visible(node)) return null;
            const rect = node.getBoundingClientRect();
            const values = [rect.x, rect.y, rect.width, rect.height];
            if (!values.every(Number.isFinite) || rect.width <= 0 || rect.height <= 0) return null;
            return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
          };
          const ancestor = (node, predicate) => {
            let current = node;
            while (current && current !== root) {
              if (predicate(current)) return current;
              current = current.parentElement;
            }
            return null;
          };
          const sidebarInput = document.querySelector('input[placeholder="筛选文档"]');
          let sidebar = sidebarInput;
          while (sidebar && sidebar.parentElement !== root) sidebar = sidebar.parentElement;
          if (!sidebar || sidebar.parentElement !== root) sidebar = null;
          const sidebarToggle = document.querySelector('[data-tip^="显示 / 隐藏侧栏"]');
          const tabBar = sidebarToggle ? sidebarToggle.parentElement : null;
          const contentNode = document.querySelector('[data-viewblock="1"], [data-editblock="1"], [data-tbl-input="1"]');
          const documentPage = ancestor(contentNode, (node) => {
            const style = node.getAttribute('style') || '';
            return style.includes('width: 640px') && style.includes('max-width: calc(100% - 132px)');
          });
          const documentSurface = documentPage ? documentPage.parentElement : null;
          const outlineRail = Array.from(document.querySelectorAll('div')).find((node) => {
            const style = node.getAttribute('style') || '';
            return style.includes('min-height: 130px') && style.includes('translateY(-50%)');
          }) || null;
          const paletteInput = Array.from(document.querySelectorAll('input[placeholder="搜索文档或命令…"]')).find(visible) || null;
          const palettePanel = paletteInput ? paletteInput.parentElement : null;
          const findInput = Array.from(document.querySelectorAll('input[placeholder="查找"]')).find(visible) || null;
          const findPanel = findInput && findInput.parentElement && findInput.parentElement.parentElement
            ? findInput.parentElement.parentElement.parentElement
            : null;
          const replaceInput = Array.from(document.querySelectorAll('input[placeholder="替换为"]')).find(visible) || null;
          const previewControl = Array.from(document.querySelectorAll('span')).find((node) => {
            const text = (node.textContent || '').trim();
            return visible(node) && (text === '预览' || text === '✐ 编辑');
          }) || null;
          const sourceEditor = Array.from(document.querySelectorAll('[data-editblock="1"]')).find(visible) || null;
          const tableInput = Array.from(document.querySelectorAll('[data-tbl-input="1"]')).find(visible) || null;
          const tableGrid = ancestor(tableInput, (node) => getComputedStyle(node).overflowX === 'auto');

          const assertionValues = {
            'document-visible': visible(root),
            'sidebar-visible': visible(sidebarInput),
            'sidebar-hidden': !visible(sidebarInput),
            'palette-visible': visible(paletteInput),
            'palette-hidden': !visible(paletteInput),
            'find-panel-visible': visible(findInput),
            'find-panel-hidden': !visible(findInput),
            'replace-row-visible': visible(replaceInput),
            'preview-active': visible(previewControl) && (previewControl.textContent || '').trim() === '✐ 编辑',
            'source-editor-visible': visible(sourceEditor),
            'source-editor-hidden': !visible(sourceEditor),
            'table-grid-visible': visible(tableInput),
            'table-grid-hidden': !visible(tableInput)
          };
          const anchorNodes = {
            'sidebar-frame': sidebar,
            'tab-bar-frame': tabBar,
            'document-surface-frame': documentSurface,
            'document-page-frame': documentPage,
            'outline-rail-frame': outlineRail,
            'palette-panel-frame': palettePanel,
            'find-panel-frame': findPanel,
            'preview-control-frame': previewControl,
            'source-editor-frame': sourceEditor,
            'table-grid-frame': tableGrid
          };
          const assertions = requiredAssertions.map((name) => ({
            name,
            evaluated: Object.prototype.hasOwnProperty.call(assertionValues, name),
            passed: assertionValues[name] === true
          }));
          const anchors = requiredAnchors.map((name) => {
            const rect = rectangle(anchorNodes[name]);
            return rect ? { name, evaluated: true, source: 'authoritative-dom', rect } : null;
          });
          const diagnosticBlockAnchors = Array.from(document.querySelectorAll('[data-viewblock="1"]'))
            .map((node, index) => {
              const rect = rectangle(node);
              const text = (node.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 18);
              return rect ? {
                name: 'document-block-' + index + '-' + text,
                evaluated: true,
                source: 'authoritative-dom',
                rect
              } : null;
            })
            .filter(Boolean);
          const statePassed = assertions.every((item) => item.evaluated && item.passed);
          const geometryPassed = anchors.every(Boolean);
          return JSON.stringify({
            stateEvaluation: {
              evaluated: true,
              status: statePassed ? 'passed' : 'failed',
              expectedState,
              observedState: statePassed ? expectedState : 'unverified',
              source: 'authoritative-dom',
              assertions
            },
            geometryEvaluation: {
              evaluated: true,
              status: geometryPassed ? 'passed' : 'failed',
              coordinateSpace: 'viewportPixels',
              anchors: anchors.filter(Boolean).concat(diagnosticBlockAnchors)
            }
          });
        })()
        """
        guard let result = try await evaluate(script) as? String,
              let data = result.data(using: .utf8) else {
            throw ToolError.script("authoritative DOM returned no visual evidence")
        }
        let probe = try JSONDecoder().decode(VisualProbe.self, from: data)
        guard probe.stateEvaluation.evaluated,
              probe.stateEvaluation.status == "passed",
              probe.stateEvaluation.expectedState == state,
              probe.stateEvaluation.observedState == state else {
            throw ToolError.script("authoritative state evidence did not pass for '\(state)'")
        }
        let assertionNames = Set(probe.stateEvaluation.assertions.filter { $0.evaluated && $0.passed }.map(\.name))
        guard Set(requiredAssertions).isSubset(of: assertionNames) else {
            throw ToolError.script("authoritative state evidence is incomplete for '\(state)'")
        }
        let anchorNames = Set(probe.geometryEvaluation.anchors.filter(\.evaluated).map(\.name))
        guard probe.geometryEvaluation.evaluated,
              probe.geometryEvaluation.status == "passed",
              probe.geometryEvaluation.coordinateSpace == "viewportPixels",
              Set(requiredAnchors).isSubset(of: anchorNames) else {
            throw ToolError.script("authoritative geometry evidence is incomplete for '\(state)'")
        }
        return probe
    }

    func snapshot(to outputURL: URL) async throws -> Double {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: ToolError.snapshot(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ToolError.snapshot("WebKit returned no snapshot image"))
                }
            }
        }
        let data = try normalizedPNG(from: image)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        return try await devicePixelRatio()
    }

    private func verifyViewport() async throws {
        guard let report = try await evaluate(
            "({ width: window.innerWidth, height: window.innerHeight })"
        ) as? [String: Any],
              let width = report["width"] as? NSNumber,
              let height = report["height"] as? NSNumber,
              width.intValue == viewport.width,
              height.intValue == viewport.height else {
            throw ToolError.script("WebKit viewport did not match \(viewport.name)")
        }
    }

    private func waitForFonts() async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let loaded = try await evaluate("!document.fonts || document.fonts.status === 'loaded'") as? Bool,
               loaded {
                return
            }
            try await sleep(milliseconds: 40)
        }
        throw ToolError.timeout("document fonts did not finish loading within 5 seconds")
    }

    private func verifyState(_ state: String) async throws {
        let expression: String
        switch state {
        case "default":
            expression = "Boolean(document.querySelector('[data-screen-label=\"Markdown Editor\"]'))"
        case "palette":
            expression = "Boolean(Array.from(document.querySelectorAll('input[placeholder=\"搜索文档或命令…\"]')).find((node) => node.getClientRects().length > 0))"
        case "find":
            expression = "Boolean(Array.from(document.querySelectorAll('input[placeholder=\"查找\"]')).find((node) => { const rect = node.getBoundingClientRect(); const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2); return rect.width > 100 && rect.height > 10 && (hit === node || node.contains(hit)); }))"
        case "replace":
            expression = "Boolean(Array.from(document.querySelectorAll('input[placeholder=\"替换为\"]')).find((node) => { const rect = node.getBoundingClientRect(); const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2); return rect.width > 100 && rect.height > 10 && (hit === node || node.contains(hit)); }))"
        case "preview":
            expression = "Array.from(document.querySelectorAll('span')).some((node) => node.textContent.trim() === '✐ 编辑')"
        case "sidebar-hidden":
            expression = "!document.querySelector('input[placeholder=\"筛选文档\"]')"
        case "source-editor":
            expression = "Boolean(Array.from(document.querySelectorAll('[data-editblock=\"1\"]')).find((node) => node.getClientRects().length > 0))"
        case "table-editor":
            expression = "Boolean(Array.from(document.querySelectorAll('[data-tbl-input=\"1\"]')).find((node) => node.getClientRects().length > 0))"
        default:
            expression = "false"
        }
        guard let success = try await evaluate(expression) as? Bool, success else {
            let visibleSummary = try await evaluate(
                "JSON.stringify({ inputs: Array.from(document.querySelectorAll('input')).map((node) => ({ placeholder: node.placeholder, rect: node.getBoundingClientRect().toJSON(), visibility: getComputedStyle(node).visibility, display: getComputedStyle(node).display })), edit: Boolean(document.querySelector('[data-editblock]')), table: Boolean(document.querySelector('[data-tbl-input]')), outlineHeights: Array.from(document.querySelectorAll('div[title]')).filter((node) => node.getAttribute('style') && node.getAttribute('style').includes('min-width: 26px')).slice(0, 4).map((node) => node.offsetHeight) })"
            ) as? String
            throw ToolError.script("named state '\(state)' did not become visible; DOM summary: \(visibleSummary ?? "unavailable")")
        }
    }

    private func dispatchKey(_ key: String, meta: Bool, shift: Bool) async throws {
        let keyJSON = try JSONEncoder().encode(key)
        guard let encodedKey = String(data: keyJSON, encoding: .utf8) else {
            throw ToolError.script("could not encode key action")
        }
        try await runAction(
            """
            window.dispatchEvent(new KeyboardEvent('keydown', {
              key: \(encodedKey), metaKey: \(meta), shiftKey: \(shift), bubbles: true, cancelable: true
            }));
            return 'ok';
            """
        )
    }

    private func runLogicAction(_ action: String) async throws {
        let actionJSON = try JSONEncoder().encode(action)
        guard let encodedAction = String(data: actionJSON, encoding: .utf8) else {
            throw ToolError.script("could not encode logic action")
        }
        let script = """
            const host = document.querySelector('[data-screen-label="Markdown Editor"]');
            if (!host) return 'missing prototype host';
            const fiberKey = Object.keys(host).find((key) => key.startsWith('__reactFiber$'));
            let fiber = fiberKey ? host[fiberKey] : null;
            while (fiber) {
              const logic = fiber.stateNode && fiber.stateNode.logic;
              if (logic && typeof logic[__ACTION__] === 'function') {
                logic[__ACTION__]();
                return 'ok';
              }
              fiber = fiber.return;
            }
            return 'missing prototype logic action';
            """
            .replacingOccurrences(of: "__ACTION__", with: encodedAction)
        try await runAction(script)
    }

    private func runAction(_ body: String) async throws {
        let result = try await evaluate("(() => { \(body) })()") as? String
        guard result == "ok" else {
            throw ToolError.script(result ?? "prototype action returned no result")
        }
    }

    private func devicePixelRatio() async throws -> Double {
        guard let ratio = try await evaluate("window.devicePixelRatio") as? NSNumber else {
            throw ToolError.script("could not read window.devicePixelRatio")
        }
        return ratio.doubleValue
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: ToolError.script(error.localizedDescription))
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private func normalizedPNG(from image: NSImage) throws -> Data {
        let pixelWidth = viewport.width * outputScale
        let pixelHeight = viewport.height * outputScale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: NSColorSpaceName.deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ToolError.imageEncoding("could not allocate normalized bitmap")
        }
        bitmap.size = NSSize(width: viewport.width, height: viewport.height)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            throw ToolError.imageEncoding("could not create normalized bitmap context")
        }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw ToolError.imageEncoding("could not encode normalized PNG")
        }
        return data
    }
}

private func sha256(of url: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError.missingFile("could not hash file: \(url.path)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), let hash = text.split(separator: " ").first else {
        throw ToolError.script("invalid shasum output for \(url.path)")
    }
    return String(hash)
}

private func readText(_ url: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ToolError.missingFile("missing file: \(url.path)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func relativePath(of fileURL: URL, under directoryURL: URL) -> String {
    let base = directoryURL.standardizedFileURL.path
    let path = fileURL.standardizedFileURL.path
    guard path.hasPrefix(base + "/") else { return path }
    return String(path.dropFirst(base.count + 1))
}

private func prepareOutputDirectory(_ outputURL: URL) throws {
    let fileManager = FileManager.default
    let markerName = ".markdownviewer-visual-reference"
    let markerURL = outputURL.appendingPathComponent(markerName)
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw ToolError.badArguments("output exists and is not a directory: \(outputURL.path)")
        }
        let contents = try fileManager.contentsOfDirectory(atPath: outputURL.path)
        guard contents.isEmpty || contents.contains(markerName) else {
            throw ToolError.badArguments("refusing to replace an unmarked nonempty output directory: \(outputURL.path)")
        }
        if contents.contains(markerName) {
            try fileManager.removeItem(at: outputURL)
        }
    }
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    try Data().write(to: markerURL, options: .atomic)
}

@main
private struct ReferenceSnapshotTool {
    @MainActor
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            _ = NSApplication.shared

            let htmlHash = try sha256(of: options.htmlURL)
            guard htmlHash == authoritativeHTMLSHA256 else {
                throw ToolError.hashMismatch(expected: authoritativeHTMLSHA256, actual: htmlHash)
            }
            let supportURL = options.htmlURL.deletingLastPathComponent().appendingPathComponent("support.js")
            let react = try readText(options.reactURL)
            let reactDOM = try readText(options.reactDOMURL)
            _ = try readText(supportURL)
            let contractData = try Data(contentsOf: options.contractURL)
            let contractHash = try sha256(of: options.contractURL)
            guard contractHash == acceptanceContractSHA256 else {
                throw ToolError.badArguments(
                    "visual acceptance contract SHA-256 mismatch: expected \(acceptanceContractSHA256), found \(contractHash)"
                )
            }
            let contract = try JSONDecoder().decode(AcceptanceContract.self, from: contractData)
            guard contract.schemaVersion == 2,
                  contract.kind == "markdown-viewer-visual-acceptance-contract" else {
                throw ToolError.badArguments("visual acceptance contract must use the supported schema-v2 kind")
            }
            for state in options.states where contract.states[state] == nil {
                throw ToolError.badArguments("visual acceptance contract has no state '\(state)'")
            }

            try prepareOutputDirectory(options.outputURL)

            var records: [SnapshotRecord] = []
            for viewport in options.viewports {
                for state in options.states {
                    let page = SnapshotPage(
                        viewport: viewport,
                        outputScale: options.outputScale,
                        react: react,
                        reactDOM: reactDOM
                    )
                    try await page.load(options.htmlURL)
                    try await page.apply(state: state)
                    try await page.settle(milliseconds: options.settleMilliseconds)
                    guard let stateContract = contract.states[state] else {
                        throw ToolError.badArguments("visual acceptance contract has no state '\(state)'")
                    }
                    let probe = try await page.captureVisualProbe(
                        state: state,
                        requiredAssertions: stateContract.requiredStateAssertions,
                        requiredAnchors: stateContract.requiredGeometryAnchors
                    )
                    let outputURL = options.outputURL
                        .appendingPathComponent(viewport.name)
                        .appendingPathComponent("\(state).png")
                    let devicePixelRatio = try await page.snapshot(to: outputURL)
                    let pngHash = try sha256(of: outputURL)
                    records.append(
                        SnapshotRecord(
                            state: state,
                            viewportWidth: viewport.width,
                            viewportHeight: viewport.height,
                            pixelWidth: viewport.width * options.outputScale,
                            pixelHeight: viewport.height * options.outputScale,
                            outputScale: options.outputScale,
                            webDevicePixelRatio: devicePixelRatio,
                            pngSHA256: pngHash,
                            relativePath: relativePath(of: outputURL, under: options.outputURL),
                            visualEvidence: VisualEvidence(
                                schemaVersion: 2,
                                kind: "machine-captured-visual-evidence",
                                screenshotSHA256: pngHash,
                                stateEvaluation: probe.stateEvaluation,
                                geometryEvaluation: probe.geometryEvaluation
                            )
                        )
                    )
                    print("Captured \(viewport.name)/\(state).png")
                }
            }

            let expectedSnapshotCount = options.viewports.count * options.states.count
            let uniqueSnapshotPairs = Set(records.map {
                "\($0.viewportWidth)x\($0.viewportHeight)/\($0.state)"
            })
            guard records.count == expectedSnapshotCount,
                  uniqueSnapshotPairs.count == expectedSnapshotCount else {
                throw ToolError.snapshot(
                    "capture matrix incomplete: generated \(records.count) records "
                        + "for \(expectedSnapshotCount) requested pairs"
                )
            }

            for viewport in options.viewports {
                let viewportRecords = records.filter {
                    $0.viewportWidth == viewport.width && $0.viewportHeight == viewport.height
                }
                guard let defaultHash = viewportRecords.first(where: { $0.state == "default" })?.pngSHA256 else {
                    continue
                }
                for record in viewportRecords where record.state != "default" {
                    guard record.pngSHA256 != defaultHash else {
                        throw ToolError.snapshot(
                            "named state '\(record.state)' matched the default snapshot at \(viewport.name)"
                        )
                    }
                }
            }

            let manifest = Manifest(
                schemaVersion: 2,
                kind: "authoritative-dc-webkit-reference",
                authoritativeHTML: options.htmlURL.lastPathComponent,
                authoritativeHTMLSHA256: htmlHash,
                acceptanceContractSHA256: contractHash,
                supportJSSHA256: try sha256(of: supportURL),
                reactSHA256: try sha256(of: options.reactURL),
                reactDOMSHA256: try sha256(of: options.reactDOMURL),
                outputScale: options.outputScale,
                requestedMatrix: RequestedMatrix(
                    viewports: options.viewports.map(\.name),
                    states: options.states,
                    expectedSnapshotCount: expectedSnapshotCount
                ),
                coverage: CaptureCoverage(
                    generatedSnapshotCount: records.count,
                    complete: records.count == expectedSnapshotCount
                ),
                snapshots: records
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestData = try encoder.encode(manifest) + Data("\n".utf8)
            try manifestData.write(to: options.outputURL.appendingPathComponent("manifest.json"), options: .atomic)
            print("Reference manifest: \(options.outputURL.appendingPathComponent("manifest.json").path)")
        } catch {
            FileHandle.standardError.write(Data("ReferenceSnapshot: \(error)\n".utf8))
            exit(1)
        }
    }
}
