#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/MarkdownViewerHarnessTests.XXXXXX")"
OBSERVER_PID=""
LOCK_HOLDER_PID=""

cleanup() {
    if [[ -n "$OBSERVER_PID" ]] && kill -0 "$OBSERVER_PID" 2>/dev/null; then
        kill "$OBSERVER_PID" 2>/dev/null || true
        wait "$OBSERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$LOCK_HOLDER_PID" ]] && kill -0 "$LOCK_HOLDER_PID" 2>/dev/null; then
        kill "$LOCK_HOLDER_PID" 2>/dev/null || true
        wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

bash -n "$ROOT/scripts/e2e/run-real-app-e2e.sh"
bash -n "$ROOT/scripts/run-debug.sh"
PYTHONPYCACHEPREFIX="$TEMP_ROOT/pycache" python3 -m py_compile \
    "$ROOT/scripts/e2e/aggregate-foreground-palette-find.py" \
    "$ROOT/scripts/e2e/aggregate-foreground-sidebar-layout.py" \
    "$ROOT/scripts/e2e/build-foreground-block-activation-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-editor-boundaries-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-editor-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-find-options-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-find-regex-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-outline-navigation-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-preview-content-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-preview-footnotes-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-sidebar-filter-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-sidebar-layout-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-smoke-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-tab-session-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-table-navigation-plan.py" \
    "$ROOT/scripts/e2e/build-foreground-table-plan.py" \
    "$ROOT/scripts/e2e/build-visual-evidence.py" \
    "$ROOT/scripts/e2e/verify-passive-lifecycle.py" \
    "$ROOT/scripts/e2e/verify-find-diagnostic.py" \
    "$ROOT/scripts/e2e/verify-foreground-find-session.py" \
    "$ROOT/scripts/e2e/verify-foreground-outline-navigation.py" \
    "$ROOT/scripts/e2e/verify-foreground-palette-find.py" \
    "$ROOT/scripts/e2e/verify-foreground-preview-content.py" \
    "$ROOT/scripts/e2e/verify-foreground-preview-footnotes.py" \
    "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
    "$ROOT/scripts/e2e/verify-palette-find-phase.py" \
    "$ROOT/scripts/e2e/verify-sidebar-resize-phase.py" \
    "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
    "$ROOT/scripts/e2e/verify-visual-launch-state.py"

if [[ "$(rg -c -- '--require-offscreen' "$ROOT/scripts/e2e/run-real-app-e2e.sh")" -ne 5 ]]; then
    echo "RealAppHarnessTests: passive and restored window lookups do not require offscreen state" >&2
    exit 1
fi
rg -Fq 'requireOffscreen: arguments.contains("--require-offscreen")' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'NSAccessibility.Attribute.activationPoint.rawValue' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'point = element.activationPoint.map' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'element.frame.width * xFraction' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'try setApplicationFrontmost(pid: pid)' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'try setApplicationFrontmost(pid: priorPID)' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'postVisualTestActivationRequest(pid: pid, launchToken: launchToken)' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq 'DistributedNotificationCenter.default().postNotificationName(' \
    "$ROOT/scripts/e2e/RealAppDriver.swift"
rg -Fq -- '--launch-token "$CURRENT_LAUNCH_TOKEN"' \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh"
if rg -Fq 'raiseApplicationWindowForForeground' \
        "$ROOT/scripts/e2e/RealAppDriver.swift" \
        || rg -Fq 'kAXRaiseAction' "$ROOT/scripts/e2e/RealAppDriver.swift"; then
    echo "RealAppHarnessTests: ordered-out window activation still depends on AX raise" >&2
    exit 1
fi

python3 - \
    "$ROOT/Sources/MarkdownViewer/App/WindowConfigurator.swift" \
    "$ROOT/Sources/MarkdownViewer/Shell/ContentView.swift" <<'PY'
import pathlib
import sys

window_source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
content_source = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
if window_source.count("window.orderOut(nil)") != 4:
    raise SystemExit(
        "passive launch, failed activation, safety timeout, and focus restore must order out"
    )
if window_source.count("window.makeKeyAndOrderFront(nil)") != 2:
    raise SystemExit(
        "explicit foreground launch and later activation must both restore key-window semantics"
    )
if "window.orderFront(nil)" in window_source:
    raise SystemExit("activation must not consume the first content click with orderFront only")
for required in (
    "final class VisualTestWindowActivationController",
    "DistributedNotificationCenter.default().addObserver(",
    "NSApplication.didResignActiveNotification",
    "VisualTestWindowActivationController.shared.attach(window: window)",
    "window.ignoresMouseEvents = false",
    "guard !activationInFlight else {",
    "object: expectedObject",
    "notification.object as? String == expectedObject",
    'appendingPathComponent("window-activation.json")',
    'publishDiagnostic(event: "request-received")',
    'publishDiagnostic(event: "presentation-attempted")',
    'publishDiagnostic(event: "did-resign-active")',
    'publishDiagnostic(event: "safety-timeout")',
    "VisualTestWindowLevelPolicy.prepareForBoundedForeground(window)",
    "VisualTestWindowLevelPolicy.restoreNormal(window)",
    "windowLevel: window?.level.rawValue",
    "VisualTestWindowLevelPolicy.safetyTimeoutSeconds",
):
    if required not in window_source:
        raise SystemExit(f"token-bound visual-test activation is incomplete: {required}")

shift_start = content_source.index("private func installShiftMonitor()")
shift_end = content_source.index("private func removeShiftMonitor()", shift_start)
shift_monitor = content_source[shift_start:shift_end]
if "event.isARepeat" in shift_monitor:
    raise SystemExit("flags-changed Shift events must not query key-down-only isARepeat")
PY

python3 - \
    "$ROOT/Sources/MarkdownViewer/Editor/MarkdownBlockRenderer.swift" \
    "$ROOT/Sources/MarkdownViewer/Editor/BlockSourceEditor.swift" <<'PY'
import pathlib
import sys

renderer = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
source_editor = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for required in (
    "final class BlockRenderProbeView: NSView",
    "override func hitTest(_ point: NSPoint) -> NSView?",
    "view.setAccessibilityElement(false)",
):
    if required not in renderer:
        raise SystemExit(f"render diagnostics can intercept block input: {required}")
for required in (
    "let accepted = window.makeFirstResponder(textView)",
    "accepted, window.firstResponder === textView",
    "focusAttemptCount < 4",
    "focusRetryWork?.cancel()",
):
    if required not in source_editor:
        raise SystemExit(f"block source focus retry contract is incomplete: {required}")
PY

python3 - \
    "$ROOT/Sources/MarkdownViewer/App/AppEnv.swift" \
    "$ROOT/Sources/MarkdownViewer/Shell/ContentView.swift" \
    "$ROOT/Sources/MarkdownViewer/Documents/DocumentManager.swift" \
    "$ROOT/scripts/run-debug.sh" \
    "$ROOT/scripts/e2e/RealAppDriver.swift" <<'PY'
import pathlib
import sys

app_env = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
content = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
documents = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
launcher = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
driver = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")

activation_prefix = '"local.codex.markdownviewer.visual-test.activate."'
if app_env.count(activation_prefix) != 1 or driver.count(activation_prefix) != 1:
    raise SystemExit("App and Driver activation notification prefixes drifted")
if "object: String(pid)" not in driver:
    raise SystemExit("Driver activation request is not bound to the target PID")

for required in (
    "let visualTestRestoresSession: Bool",
    "let visualTestRestoresSession = visualTestEnabled",
    'arguments.contains("--visual-test-restore-session")',
    "visualTestRestoresSession: visualTestRestoresSession",
):
    if required not in app_env:
        raise SystemExit(f"Debug-only session restore gating is missing: {required}")
restore_gate = app_env.split(
    "let visualTestRestoresSession = visualTestEnabled",
    1,
)[1].split("let visualTestForegroundOnLaunch", 1)[0]
if 'arguments.contains("--visual-test-restore-session")' not in restore_gate:
    raise SystemExit("session restore must remain gated by Debug visual-test mode")

restore_branch = content.split("if AppEnv.visualTestRestoresSession {", 1)[1].split(
    "                } else {\n                    do {",
    1,
)[0]
for required in (
    "SessionStore.load()",
    "!session.tabs.isEmpty",
    "docManager.restoreVisualTestSession(",
    "docManager.newDocument()",
):
    if required not in restore_branch:
        raise SystemExit(f"visual-test restore branch is incomplete: {required}")
for forbidden in (
    "DebugFixtureLoader.load(",
    "DebugFixtureLoader.prepareWorkspace(",
    "loadVisualTestDocument(",
):
    if forbidden in restore_branch:
        raise SystemExit(f"restore branch must not inject a fresh fixture: {forbidden}")

restore_method = documents.split(
    "func restoreVisualTestSession(from session: Session, fixtureName: String)",
    1,
)[1].split("// MARK: - Font", 1)[0]
for required in (
    "guard visualTestEnabled else { return }",
    "restore(from: session)",
    "$0.url == nil && $0.isMarkdown && $0.name == fixtureName",
    "tabMatches.count == 1",
    "workspaceMatches.count == 1",
    "visualTestFixtureTabID = tabMatches[0].id",
):
    if required not in restore_method:
        raise SystemExit(f"restored fixture rebinding is incomplete: {required}")

for required in (
    "--visual-test-restore-session   Restore the selected profile",
    "RESTORE_SESSION=0",
    "--reset cannot be combined with --visual-test-restore-session",
    "APP_ARGUMENTS+=(--visual-test-restore-session)",
    'BOOTSTRAP_URL="markdownviewer-debug-bootstrap://launch/$LAUNCH_TOKEN"',
    'open "${OPEN_ARGUMENTS[@]}" -a "$APP" "$BOOTSTRAP_URL" --args',
    'DIAGNOSTIC_STATE_FILE="$PROFILE_ROOT/Diagnostics/state.json"',
    "Debug app did not publish fresh visual-test diagnostics",
):
    if required not in launcher:
        raise SystemExit(f"Debug launcher restore contract is missing: {required}")
if "OPEN_ARGUMENTS+=(-j)" in launcher:
    raise SystemExit("background Debug launch must not hide the app with open -j")

for required in (
    "let visualTestLaunchToken: UUID?",
    'value(for: "--visual-test-launch-token", in: arguments).flatMap(UUID.init(uuidString:))',
    "var visualTestActivationNotificationName: Notification.Name?",
    '"local.codex.markdownviewer.visual-test.activate."',
    "func consumesVisualTestBootstrapURL(_ url: URL) -> Bool",
    'url.scheme?.lowercased() == "markdownviewer-debug-bootstrap"',
    'url.host?.lowercased() == "launch"',
):
    if required not in app_env:
        raise SystemExit(f"Debug bootstrap URL gate is missing: {required}")
if "guard !AppEnv.consumesVisualTestBootstrapURL(url) else { return }" not in content:
    raise SystemExit("ContentView does not consume the exact Debug bootstrap URL")

for required in (
    "private struct TerminateAppReport: Codable",
    'let expectedBundleIdentifier = "local.codex.markdownviewer.debug"',
    "let requested = application.terminate()",
    "forced: false",
    'case "terminate-app":',
    "if !report.requested",
    "if !report.exited",
):
    if required not in driver:
        raise SystemExit(f"normal Debug termination contract is missing: {required}")
termination = driver.split(
    "private func requestNormalDebugAppTermination(",
    1,
)[1].split("private func run()", 1)[0]
for forbidden in ("forceTerminate()", "kill(", "CGEvent("):
    if forbidden in termination:
        raise SystemExit(f"normal termination must not force or inject input: {forbidden}")

for required in (
    '"identifier", "role", "expectedValue", "expectedSelected"',
    'case elementDescriptionCheck = "element-description-check"',
    '"description", "role", "expectedValue", "expectedSelected"',
    '"\\(context).description requires 1 through 256 UTF-16 code units"',
    '"\\(context).expectedValue requires at most 4096 UTF-16 code units"',
    '"\\(context).expectedSelected requires a boolean"',
    "primaryMatchRoles",
    "report.value != expectedValue",
    "report.selected != expectedSelected",
):
    if required not in driver:
        raise SystemExit(f"exact AX assertion contract is missing: {required}")
PY

python3 - "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import pathlib
import sys

runner = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

for required in (
    "five-phase tab-session-lifecycle suite",
    "tab-session-lifecycle|table-controls",
    "tab-session-lifecycle) run_foreground_tab_session_lifecycle",
    '"foregroundPhases": (',
    '"sessionRelaunch": session_relaunch',
    '"phaseCount": (',
    '"perPhaseBudgetMs": (',
):
    if required not in runner:
        raise SystemExit(f"tab-session runner contract is missing: {required}")

launch_restore = runner.split("launch_restored_visual_session() {", 1)[1].split(
    "prove_normal_termination_session_flush() {",
    1,
)[0]
for required in (
    'if [[ ! -s "$session" ]]',
    "--background",
    "--skip-build",
    '--visual-test-root "$PROFILE_ROOT"',
    '--visual-test-size "$SIZE"',
    "--visual-test-restore-session",
    "--visual-test-hide-hud",
    "debug_process_matches_identity",
):
    if required not in launch_restore:
        raise SystemExit(f"restored launch is not fail-closed: {required}")
if "--reset" in launch_restore:
    raise SystemExit("restored session launch must never reset its profile")

flush = runner.split("prove_normal_termination_session_flush() {", 1)[1].split(
    "stop_passive_observer_for_cleanup() {",
    1,
)[0]
flush_steps = [
    'if observed != expected:',
    'mv "$live_session" "$removed_session"',
    'normal_terminate_current_app "$termination_report"',
    'if [[ ! -s "$live_session" ]]',
    'cp "$live_session" "$rebuilt_session"',
    'if removed != expected or rebuilt != expected:',
    '"liveSessionRemovedBeforeTermination": True',
    '"willTerminateRecreatedSession": True',
    '"rebuiltSessionExactlyMatchesExpected": True',
    '"normalCocoaTerminationUsed": (',
]
positions = []
for required in flush_steps:
    if required not in flush:
        raise SystemExit(f"normal session rebuild proof is missing: {required}")
    positions.append(flush.index(required))
if positions != sorted(positions):
    raise SystemExit("normal session rebuild proof runs in an unsafe order")

verify_stage = runner.split("verify_tab_session_stage() {", 1)[1].split(
    "record_visual_text_assertion() {",
    1,
)[0]
for required in (
    '--session "$session_snapshot"',
    '--expected-session-path "$live_session"',
    '--diagnostic "$diagnostic_snapshot"',
    '--previous-session "$previous_session"',
    '--previous-diagnostic "$previous_diagnostic"',
):
    if required not in verify_stage:
        raise SystemExit(f"tab-session verifier wiring is incomplete: {required}")

phase_runner = runner.split("run_tab_session_phase() {", 1)[1].split(
    "write_tab_session_aggregate_evidence() {",
    1,
)[0]
if 'local session="${2:-$PROFILE_ROOT/Application Support/MarkdownViewer/session.json}"' \
        not in phase_runner:
    raise SystemExit("tab-session phase runner does not accept a session snapshot")

aggregate = runner.split("write_tab_session_aggregate_evidence() {", 1)[1].split(
    "run_foreground_tab_session_lifecycle() {",
    1,
)[0]
phase_order = [
    "switch-commit",
    "close-right-reopen",
    "close-left-seed",
    "seed-layout",
    "relaunch-scroll-check",
]
phase_positions = []
for phase in phase_order:
    if phase not in aggregate:
        raise SystemExit(f"aggregate evidence omits phase: {phase}")
    phase_positions.append(aggregate.index(phase))
if phase_positions != sorted(phase_positions):
    raise SystemExit("aggregate evidence phase order drifted")
for required in (
    '"phaseCount": len(phases)',
    '"perPhaseBudgetMs": budget_ms',
    '"totalBudgetMs": budget_ms * len(phases)',
    '"planValidation": validation',
    '"report": report',
    '"focusRestore"]["restored"] is True',
    '"pointerRestore"]["restored"] is True',
    '"pasteboardRestore"]["restored"] is True',
    '"deadlineExceeded"',
    '"interference"',
):
    if required not in aggregate:
        raise SystemExit(f"aggregate foreground evidence is incomplete: {required}")

lifecycle = runner.split("run_foreground_tab_session_lifecycle() {", 1)[1].split(
    "run_foreground_smoke() {",
    1,
)[0]
for stage in (
    'verify_tab_session_stage "switch-commit"',
    '"close-right-reopen" "$stage1_session" "$stage1_diagnostic"',
    '"close-left-seed" "$stage2_session" "$stage2_diagnostic"',
    '"relaunch" "$stage3_session" "$stage3_diagnostic"',
    '"relaunch-scroll-check" "$stage3_session" "$stage3_diagnostic"',
):
    if stage not in lifecycle:
        raise SystemExit(f"five-stage session verification is incomplete: {stage}")
for required in (
    'run_tab_session_phase "seed-layout" "$stage2_session"',
    '"$stage3_session" "$terminate_dir"',
    'launch_restored_visual_session "$relaunch_dir/launch.log"',
    "--include-offscreen",
    "--require-offscreen",
    'finish_passive_frontmost_observer "$relaunch_pid" "may-run"',
    '"$stage4_session" "$final_terminate_dir"',
    'write_tab_session_aggregate_evidence',
    '"tab-close-right-neighbor" "tab-close-right-neighbor"',
    '"tab-close-left-neighbor" "tab-close-left-neighbor"',
    '--contains "E2E_RIGHT_NEIGHBOR"',
    '"pidChanged": int(initial_pid) != int(relaunch_pid)',
    '"initialNormalTermination": load(initial_termination_path)',
    '"passiveRelaunchLifecycle": load(relaunch_lifecycle_path)',
    '"restoredSession": load(relaunch_session_path)',
    '"finalNormalTermination": load(final_termination_path)',
):
    if required not in lifecycle:
        raise SystemExit(f"tab-session relaunch proof is incomplete: {required}")
if lifecycle.count("prove_normal_termination_session_flush") != 2:
    raise SystemExit("tab-session lifecycle must prove exactly two normal session flushes")
seed_layout = lifecycle.index('run_tab_session_phase "seed-layout" "$stage2_session"')
close_left_verify = lifecycle.index(
    '"close-left-seed" "$stage2_session" "$stage2_diagnostic"'
)
if seed_layout >= close_left_verify:
    raise SystemExit("close-left-seed was verified before seed-layout completed")
PY

python3 - \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" \
    "$TEMP_ROOT/root-evidence-foreground-lifecycle" <<'PY'
import json
import pathlib
import subprocess
import sys

runner_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
runner = runner_path.read_text(encoding="utf-8")
marker = '> "$OUTPUT/evidence.json" <<\'PY\'\n'
if marker not in runner:
    raise SystemExit("root evidence generator marker is missing")
generator = runner.rsplit(marker, 1)[1].split("\nPY\n", 1)[0]

sizes_root = root / "sizes"
size_root = sizes_root / "1180x760"
size_root.mkdir(parents=True)
lifecycle_assertions = [
    {"label": "tab-session-pre-relaunch-normal-termination"},
    {"label": "tab-session-passive-relaunch"},
    {"label": "tab-session-post-relaunch-normal-termination"},
]
manifest = {
    "visualStateLaunches": [],
    "interactionCoverage": {
        "applicable": True,
        "requestedBatchName": "tab-session-lifecycle",
        "phaseCount": 5,
        "perPhaseBudgetMs": 4000,
        "allPlannedActionsCompleted": True,
    },
    "foregroundReport": {
        "suite": "tab-session-lifecycle",
        "phaseCount": 5,
        "perPhaseBudgetMs": 4000,
    },
    "passiveLifecycleAssertions": lifecycle_assertions,
}
(size_root / "manifest.json").write_text(
    json.dumps(manifest),
    encoding="utf-8",
)
preflight_path = root / "preflight.json"
preflight_path.write_text(
    json.dumps({"sessionLocked": False}),
    encoding="utf-8",
)
digest = "a" * 64
command = [
    sys.executable,
    "-c",
    generator,
    "2026-07-15T00:00:00Z",
    "2026-07-15T00:00:01Z",
    digest,
    digest,
    digest,
    digest,
    digest,
    digest,
    digest,
    digest,
    digest,
    "1",
    "macOS synthetic",
    "0",
    "0",
    "0",
    "foreground-smoke",
    "tab-session-lifecycle",
    "synthetic-offline",
    "4",
    "0",
    "1180x760",
    "bounded-foreground-smoke",
    "0",
    "",
    str(preflight_path),
    str(sizes_root),
]
completed = subprocess.run(
    command,
    check=True,
    capture_output=True,
    text=True,
)
evidence = json.loads(completed.stdout)
assert evidence["interactionTier"] == "foreground-smoke"
assert evidence["foregroundBatchName"] == "tab-session-lifecycle"
assert evidence["interactionCoverage"]["phaseCount"] == 5
assert evidence["interactionCoverage"]["perPhaseBudgetMs"] == 4000
assert evidence["foregroundReport"]["phaseCount"] == 5
assert evidence["passiveLifecycleAssertions"] == lifecycle_assertions
assert evidence["requestedVisualStates"] == []
assert evidence["resolvedVisualStateLaunches"] == []
PY

python3 - \
    "$ROOT/Sources/MarkdownViewer/Sidebar/SidebarView.swift" \
    "$ROOT/Sources/MarkdownViewer/Sidebar/SidebarFilterPolicy.swift" \
    "$ROOT/Sources/MarkdownViewer/Editor/MarkdownAccessibilitySurface.swift" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import pathlib
import sys

sidebar = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
filter_policy = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
surface = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
runner = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
for required in (
    '.accessibilityIdentifier("sidebar-filter")',
    '.accessibilityIdentifier("sidebar-resize-handle")',
    "MarkdownAccessibilitySurface.sidebarSurface",
    "MarkdownAccessibilitySurface.sidebarFilterEmpty",
    "MarkdownAccessibilitySurface.sidebarNode(",
    "SidebarFilterPolicy.visibleNodes(",
    "resizeStartWidth + value.translation.width",
    "DragGesture(minimumDistance: 1, coordinateSpace: .global)",
    ".allowsHitTesting(false)",
    '"sidebar-resize-ended"',
):
    if required not in sidebar:
        raise SystemExit(f"sidebar AX or resize foundation is missing: {required}")
for required in (
    "node.name.lowercased().contains(query)",
    "path.lowercased().contains(query)",
):
    if required not in filter_policy:
        raise SystemExit(f"sidebar filter policy is incomplete: {required}")
for required in (
    'static let sidebarSurface = "sidebar-surface"',
    'static let sidebarFilterEmpty = "sidebar-filter-empty"',
    'return "sidebar-\\(nodeKind)-\\(valueToken(relativePath))"',
    "let encoded = value.utf8.map",
):
    if required not in surface:
        raise SystemExit(f"stable sidebar AX naming is missing: {required}")
semantic_start = runner.index("semantic_kinds = {")
semantic_end = runner.index("}", semantic_start)
semantic_block = runner[semantic_start:semantic_end]
for required in (
    '"element-check"',
    '"element-description-check"',
    '"element-drag"',
):
    if required not in semantic_block:
        raise SystemExit(f"runner does not audit semantic action: {required}")
PY

expect_runner_option_failure() {
    local label="$1"
    local expected="$2"
    shift 2
    if "$ROOT/scripts/e2e/run-real-app-e2e.sh" "$@" \
        > "$TEMP_ROOT/$label.out" \
        2> "$TEMP_ROOT/$label.err"; then
        echo "RealAppHarnessTests: invalid runner options succeeded: $label" >&2
        exit 1
    fi
    if ! rg -Fq -- "$expected" "$TEMP_ROOT/$label.err"; then
        echo "RealAppHarnessTests: runner option error was not precise: $label" >&2
        cat "$TEMP_ROOT/$label.err" >&2
        exit 1
    fi
}

expect_runner_option_failure \
    "probe-unknown-size" \
    "--probe-sizes contains unsupported value: 1024x768" \
    --probe-sizes 1024x768
expect_runner_option_failure \
    "probe-empty-state" \
    "--probe-states must be a nonempty comma-separated list" \
    --probe-states=preview,
expect_runner_option_failure \
    "probe-duplicate-state" \
    "--probe-states contains duplicate values" \
    --probe-states preview,preview
expect_runner_option_failure \
    "probe-repeated-option" \
    "--probe-sizes may be specified only once" \
    --probe-sizes 1180x760 --probe-sizes 860x560
expect_runner_option_failure \
    "probe-foreground-conflict" \
    "probe filters are available only for the passive tier" \
    --probe-states preview --foreground-smoke
expect_runner_option_failure \
    "probe-cache-conflict" \
    "probe filters cannot be combined with --prepare-driver-only" \
    --probe-states preview --prepare-driver-only
expect_runner_option_failure \
    "foreground-unknown-batch" \
    "unsupported foreground batch: unknown" \
    --foreground-batch unknown
expect_runner_option_failure \
    "foreground-batch-conflict" \
    "interaction tier options are mutually exclusive" \
    --foreground-smoke --foreground-batch table-controls

python3 - "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import pathlib
import re
import sys

script = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
scope_start = script.index('case "$INTERACTION_TIER:$PROBE_MODE" in')
scope_block = script[scope_start:].split("\nesac", 1)[0]
resolved = {
    selector: (scope, eligible == "1")
    for selector, scope, eligible in re.findall(
        r'^    ([a-z-]+:[01])\)\n'
        r'        RUN_SCOPE="([a-z-]+)"\n'
        r'        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=([01])$',
        scope_block,
        flags=re.MULTILINE,
    )
}
expected = {
    "passive:0": ("strict-acceptance-matrix", True),
    "passive:1": ("development-probe", False),
    "foreground-smoke:0": ("bounded-foreground-smoke", False),
    "keyboard-only:0": ("legacy-keyboard-interaction", False),
    "extended-full-pointer:0": ("legacy-extended-interaction", True),
}
if resolved != expected:
    raise SystemExit(
        f"run scope mapping does not match interaction-tier semantics: {resolved!r}"
    )

blocked_start = script.index('if [[ "$STATIC_ONLY" -ne 1 && "$KEYBOARD_ONLY" -ne 1 ]]')
blocked_end = script.index('\nif ! "$ROOT/scripts/build-debug.sh"', blocked_start)
blocked = script[blocked_start:blocked_end]
for required in (
    '"$RUN_SCOPE" "$STRICT_VISUAL_ACCEPTANCE_ELIGIBLE"',
    '"runScope": run_scope',
    '"strictVisualAcceptanceEligible": strict_visual_acceptance_eligible == "1"',
    '"foregroundBatchName": foreground_batch_name or None',
    '"coverage": {',
    '"strictMatrixComplete": False',
):
    if required not in blocked:
        raise SystemExit(f"blocked evidence is missing scope field: {required}")
PY
rg -Fq '"strictMatrixComplete"' \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh"

"$ROOT/scripts/run-debug.sh" --help > "$TEMP_ROOT/run-debug-help.txt"
if ! rg -Fq -- "--visual-test-restore-session" \
    "$TEMP_ROOT/run-debug-help.txt"; then
    echo "RealAppHarnessTests: Debug launcher help omits session restore" >&2
    exit 1
fi
if "$ROOT/scripts/run-debug.sh" \
    --reset \
    --visual-test-restore-session \
    > "$TEMP_ROOT/restore-reset-conflict.out" \
    2> "$TEMP_ROOT/restore-reset-conflict.err"; then
    echo "RealAppHarnessTests: restore and reset unexpectedly launched" >&2
    exit 1
fi
if ! rg -Fq -- \
    "--reset cannot be combined with --visual-test-restore-session" \
    "$TEMP_ROOT/restore-reset-conflict.err"; then
    echo "RealAppHarnessTests: restore/reset conflict error was not precise" >&2
    exit 1
fi

if "$ROOT/scripts/run-debug.sh" \
    --visual-test-state unsupported \
    > "$TEMP_ROOT/invalid-visual-state.out" \
    2> "$TEMP_ROOT/invalid-visual-state.err"; then
    echo "RealAppHarnessTests: invalid visual-test state unexpectedly launched" >&2
    exit 1
fi
if ! rg -q "invalid visual-test state: unsupported" \
    "$TEMP_ROOT/invalid-visual-state.err"; then
    echo "RealAppHarnessTests: invalid visual-test state error was not precise" >&2
    exit 1
fi

VISUAL_LAUNCH_ROOT="$TEMP_ROOT/visual-launch-state"
mkdir -p "$VISUAL_LAUNCH_ROOT"
python3 - "$VISUAL_LAUNCH_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
states = {
    "default": ("baseline", "edit", 0, {}),
    "palette": ("palette-open", "edit", 0, {"paletteVisible": True}),
    "find": ("find-open", "edit", 0, {"findPanelVisible": True}),
    "preview": ("preview-on", "preview", 0, {"previewActive": True}),
    "sidebar-hidden": (
        "sidebar-hidden", "edit", 0, {"sidebarVisible": False}
    ),
    "source-editor": (
        "source-editing", "edit", 0, {"sourceEditorVisible": True}
    ),
    "table-editor": (
        "table-grid", "edit", 2326, {"tableGridVisible": True}
    ),
}
for state, (label, mode, scroll_y, overrides) in states.items():
    profile = root / state / "profile"
    diagnostic = profile / "Diagnostics" / "state.json"
    diagnostic.parent.mkdir(parents=True)
    visual = {
        "documentVisible": True,
        "palettePresentation": "inline-passive",
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
        "anchors": {},
    }
    visual.update(overrides)
    visual["anchors"]["document-surface-frame"] = {
        "x": 216, "y": 44, "width": 964, "height": 716,
    }
    if state == "table-editor":
        visual["anchors"]["table-grid-frame"] = {
            "x": 375, "y": 377.796875, "width": 640, "height": 177,
        }
        visual["anchors"]["document-page-frame"] = {
            "x": 375, "y": -2282, "width": 640, "height": 3871.6875,
        }
    if state == "source-editor":
        visual["anchors"]["source-editor-frame"] = {
            "x": 375, "y": 84, "width": 640, "height": 43,
        }
    if state == "preview":
        visual["anchors"]["toast-frame"] = {
            "x": 501.265625, "y": 56, "width": 177.46875, "height": 29,
        }
    snapshot = {
        "schemaVersion": 1,
        "document": "格式示例.md",
        "blockID": None,
        "blockType": None,
        "mode": mode,
        "selection": None,
        "activeTableCell": None,
        "scrollY": scroll_y,
        "sessionPath": str(
            profile / "Application Support" / "MarkdownViewer" / "session.json"
        ),
        "visual": visual,
    }
    if state == "source-editor":
        snapshot.update({
            "blockID": "heading-1",
            "blockType": "heading",
            "selection": {"location": 16, "length": 0},
        })
    if state == "table-editor":
        snapshot.update({
            "blockID": "table-1",
            "blockType": "table",
            "activeTableCell": {"row": -1, "column": 0},
        })
    diagnostic.write_text(json.dumps(snapshot), encoding="utf-8")
    window = {
        "pid": 4242,
        "owner": "MarkdownViewerDebug",
        "title": "",
        "windowNumber": 101,
        "bounds": {"x": 10000, "y": 0, "width": 1180, "height": 760},
        "layer": 0,
        "onScreen": False,
    }
    (root / state / "window.json").write_text(
        json.dumps(window), encoding="utf-8"
    )
    (root / state / "process-windows.json").write_text(
        json.dumps([window]), encoding="utf-8"
    )
    (root / state / "expectation.json").write_text(json.dumps({
        "state": state,
        "label": label,
        "scrollY": scroll_y,
        "profile": str(profile),
    }), encoding="utf-8")
PY
for state in default palette find preview sidebar-hidden source-editor table-editor; do
    expectation="$VISUAL_LAUNCH_ROOT/$state/expectation.json"
    label="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["label"])' "$expectation")"
    scroll_y="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["scrollY"])' "$expectation")"
    profile="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profile"])' "$expectation")"
    python3 "$ROOT/scripts/e2e/verify-visual-launch-state.py" \
        --diagnostic "$profile/Diagnostics/state.json" \
        --window "$VISUAL_LAUNCH_ROOT/$state/window.json" \
        --process-windows "$VISUAL_LAUNCH_ROOT/$state/process-windows.json" \
        --profile-root "$profile" \
        --requested-state "$state" \
        --logical-size 1180x760 \
        --expected-scroll-y "$scroll_y" \
        --pid 4242 \
        --output "$VISUAL_LAUNCH_ROOT/$state/resolved.json"
    python3 - "$VISUAL_LAUNCH_ROOT/$state/resolved.json" "$state" "$label" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["schemaVersion"] == 1
assert record["kind"] == "deterministic-visual-test-launch"
assert record["requestedState"] == sys.argv[2]
assert record["resolvedState"] == sys.argv[2]
assert record["appLabel"] == sys.argv[3]
assert record["window"]["layer"] == 0
assert record["window"]["onScreen"] is False
assert record["processWindows"] == [record["window"]]
assert record["stableSampleCount"] >= 2
PY
done

python3 - "$VISUAL_LAUNCH_ROOT/preview/profile/Diagnostics/state.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
snapshot = json.loads(path.read_text(encoding="utf-8"))
snapshot["visual"]["anchors"].pop("toast-frame")
path.write_text(json.dumps(snapshot), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/verify-visual-launch-state.py" \
    --diagnostic "$VISUAL_LAUNCH_ROOT/preview/profile/Diagnostics/state.json" \
    --window "$VISUAL_LAUNCH_ROOT/preview/window.json" \
    --process-windows "$VISUAL_LAUNCH_ROOT/preview/process-windows.json" \
    --profile-root "$VISUAL_LAUNCH_ROOT/preview/profile" \
    --requested-state preview \
    --logical-size 1180x760 \
    --expected-scroll-y 0 \
    --pid 4242 \
    --output "$VISUAL_LAUNCH_ROOT/missing-toast-should-not-resolve.json" \
    --timeout 0.2 \
    > "$VISUAL_LAUNCH_ROOT/missing-toast.out" \
    2> "$VISUAL_LAUNCH_ROOT/missing-toast.err"; then
    echo "RealAppHarnessTests: preview without its real toast unexpectedly resolved" >&2
    exit 1
fi
if ! rg -q "preview toast-frame is missing or malformed" \
    "$VISUAL_LAUNCH_ROOT/missing-toast.err"; then
    echo "RealAppHarnessTests: missing preview toast error was not precise" >&2
    exit 1
fi

python3 - "$VISUAL_LAUNCH_ROOT/default/window.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
window = json.loads(path.read_text(encoding="utf-8"))
window["onScreen"] = True
path.write_text(json.dumps(window), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/verify-visual-launch-state.py" \
    --diagnostic "$VISUAL_LAUNCH_ROOT/default/profile/Diagnostics/state.json" \
    --window "$VISUAL_LAUNCH_ROOT/default/window.json" \
    --process-windows "$VISUAL_LAUNCH_ROOT/default/process-windows.json" \
    --profile-root "$VISUAL_LAUNCH_ROOT/default/profile" \
    --requested-state default \
    --logical-size 1180x760 \
    --expected-scroll-y 0 \
    --pid 4242 \
    --output "$VISUAL_LAUNCH_ROOT/on-screen-should-not-resolve.json" \
    > "$VISUAL_LAUNCH_ROOT/on-screen.out" \
    2> "$VISUAL_LAUNCH_ROOT/on-screen.err"; then
    echo "RealAppHarnessTests: on-screen passive window unexpectedly resolved" >&2
    exit 1
fi
if ! rg -q "selected main window is on screen" "$VISUAL_LAUNCH_ROOT/on-screen.err"; then
    echo "RealAppHarnessTests: on-screen passive window error was not precise" >&2
    exit 1
fi

python3 - \
    "$VISUAL_LAUNCH_ROOT/default/window.json" \
    "$VISUAL_LAUNCH_ROOT/default/process-windows.json" \
    "$VISUAL_LAUNCH_ROOT/default/process-windows-extra-on-screen.json" <<'PY'
import json
import pathlib
import sys

window_path, process_windows_path, unsafe_path = map(pathlib.Path, sys.argv[1:4])
window = json.loads(window_path.read_text(encoding="utf-8"))
window["onScreen"] = False
window_path.write_text(json.dumps(window), encoding="utf-8")
process_windows = json.loads(process_windows_path.read_text(encoding="utf-8"))
extra = dict(window)
extra.update({
    "title": "Unexpected visible panel",
    "windowNumber": 202,
    "layer": 3,
    "onScreen": True,
})
unsafe_path.write_text(json.dumps(process_windows + [extra]), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/verify-visual-launch-state.py" \
    --diagnostic "$VISUAL_LAUNCH_ROOT/default/profile/Diagnostics/state.json" \
    --window "$VISUAL_LAUNCH_ROOT/default/window.json" \
    --process-windows \
        "$VISUAL_LAUNCH_ROOT/default/process-windows-extra-on-screen.json" \
    --profile-root "$VISUAL_LAUNCH_ROOT/default/profile" \
    --requested-state default \
    --logical-size 1180x760 \
    --expected-scroll-y 0 \
    --pid 4242 \
    --output "$VISUAL_LAUNCH_ROOT/extra-on-screen-should-not-resolve.json" \
    > "$VISUAL_LAUNCH_ROOT/extra-on-screen.out" \
    2> "$VISUAL_LAUNCH_ROOT/extra-on-screen.err"; then
    echo "RealAppHarnessTests: extra on-screen process window unexpectedly resolved" >&2
    exit 1
fi
if ! rg -q "process window 1 is on screen" \
    "$VISUAL_LAUNCH_ROOT/extra-on-screen.err"; then
    echo "RealAppHarnessTests: extra on-screen process window error was not precise" >&2
    exit 1
fi

VISUAL_BUILDER_ROOT="$TEMP_ROOT/visual-evidence-builder"
mkdir -p "$VISUAL_BUILDER_ROOT/sizes/1180x760"
python3 - \
    "$VISUAL_BUILDER_ROOT/diagnostic.json" \
    "$VISUAL_BUILDER_ROOT/sizes/1180x760/baseline.png" \
    "$VISUAL_BUILDER_ROOT/sizes/1180x760/baseline.json" <<'PY'
import hashlib
import json
import pathlib
import sys

diagnostic_path, screenshot_path, metadata_path = map(pathlib.Path, sys.argv[1:4])
anchors = {
    name: {"x": index * 10, "y": index * 5, "width": 100, "height": 40}
    for index, name in enumerate((
        "sidebar-frame",
        "tab-bar-frame",
        "document-surface-frame",
        "document-page-frame",
        "outline-rail-frame",
    ))
}
diagnostic_path.write_text(json.dumps({
    "updatedAt": "2026-07-14T00:00:00Z",
    "visual": {
        "documentVisible": True,
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
        "anchors": anchors,
    },
}), encoding="utf-8")
screenshot_path.write_bytes(b"machine screenshot bytes")
metadata_path.write_text(json.dumps({
    "label": "baseline",
    "path": "sizes/1180x760/baseline.png",
    "sha256": hashlib.sha256(screenshot_path.read_bytes()).hexdigest(),
    "logicalSize": {"width": 1180, "height": 760},
    "pixelSize": {"width": 2360, "height": 1520},
    "backingScale": 2,
}), encoding="utf-8")
PY
python3 "$ROOT/scripts/e2e/build-visual-evidence.py" wait \
    --diagnostic "$VISUAL_BUILDER_ROOT/diagnostic.json" \
    --contract "$ROOT/scripts/visual/acceptance-contract.json" \
    --app-label baseline \
    --stable-samples 2 \
    --output "$VISUAL_BUILDER_ROOT/probe.json"
python3 "$ROOT/scripts/e2e/build-visual-evidence.py" bind \
    --probe "$VISUAL_BUILDER_ROOT/probe.json" \
    --metadata "$VISUAL_BUILDER_ROOT/sizes/1180x760/baseline.json" \
    --evidence-root "$VISUAL_BUILDER_ROOT" \
    --output "$VISUAL_BUILDER_ROOT/bound.json"
python3 - "$VISUAL_BUILDER_ROOT/bound.json" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
visual = record["visualEvidence"]
if visual["schemaVersion"] != 2 or visual["kind"] != "machine-captured-visual-evidence":
    raise SystemExit("visual evidence builder emitted the wrong schema")
if visual["screenshotSHA256"] != record["sha256"]:
    raise SystemExit("visual evidence was not bound to the screenshot hash")
if visual["stateEvaluation"]["status"] != "passed":
    raise SystemExit("visual state evaluation did not pass")
anchors = visual["geometryEvaluation"]["anchors"]
if len(anchors) != 5 or any(item["source"] != "combined-machine-probes" for item in anchors):
    raise SystemExit("visual geometry evidence is incomplete")
PY
python3 - "$VISUAL_BUILDER_ROOT/sizes/1180x760/baseline.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text(encoding="utf-8"))
record["sha256"] = "0" * 64
path.write_text(json.dumps(record), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/build-visual-evidence.py" bind \
    --probe "$VISUAL_BUILDER_ROOT/probe.json" \
    --metadata "$VISUAL_BUILDER_ROOT/sizes/1180x760/baseline.json" \
    --evidence-root "$VISUAL_BUILDER_ROOT" \
    --output "$VISUAL_BUILDER_ROOT/stale-bound.json" \
    > "$VISUAL_BUILDER_ROOT/stale.out" \
    2> "$VISUAL_BUILDER_ROOT/stale.err"; then
    echo "RealAppHarnessTests: stale screenshot hash unexpectedly bound" >&2
    exit 1
fi
if ! rg -q "screenshot metadata hash is stale" "$VISUAL_BUILDER_ROOT/stale.err"; then
    echo "RealAppHarnessTests: stale screenshot hash error was not precise" >&2
    exit 1
fi

for invalid_runner_budget in 2 4.01 10; do
    if "$ROOT/scripts/e2e/run-real-app-e2e.sh" \
        --foreground-smoke \
        --foreground-budget "$invalid_runner_budget" \
        --output "$TEMP_ROOT/invalid-runner-budget-$invalid_runner_budget" \
        > "$TEMP_ROOT/invalid-runner-budget-$invalid_runner_budget.out" \
        2> "$TEMP_ROOT/invalid-runner-budget-$invalid_runner_budget.err"; then
        echo "RealAppHarnessTests: non-4-second foreground smoke budget unexpectedly succeeded" >&2
        exit 1
    fi
    if ! rg -q "exactly 4 seconds" \
        "$TEMP_ROOT/invalid-runner-budget-$invalid_runner_budget.err"; then
        echo "RealAppHarnessTests: foreground smoke budget error was not precise" >&2
        exit 1
    fi
done
RECORDED_OUTPUT="$TEMP_ROOT/recorded-output"
mkdir -p "$RECORDED_OUTPUT/profiles/1180x760"
touch "$RECORDED_OUTPUT/.markdownviewer-real-app-e2e"
printf '%s\n' "$$" > "$RECORDED_OUTPUT/profiles/1180x760/app.pid"
if "$ROOT/scripts/e2e/run-real-app-e2e.sh" \
    --output "$RECORDED_OUTPUT" \
    > "$TEMP_ROOT/unresolved-output.out" \
    2> "$TEMP_ROOT/unresolved-output.err"; then
    echo "RealAppHarnessTests: unresolved live profile identity was erased" >&2
    exit 1
fi
if ! rg -q "without a launch token" "$TEMP_ROOT/unresolved-output.err"; then
    echo "RealAppHarnessTests: unresolved profile identity error was not precise" >&2
    exit 1
fi
if [[ ! -f "$RECORDED_OUTPUT/profiles/1180x760/app.pid" ]]; then
    echo "RealAppHarnessTests: unresolved profile identity was deleted" >&2
    exit 1
fi
xcrun swiftc -typecheck \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework ScreenCaptureKit \
    -framework Vision \
    "$ROOT/scripts/e2e/RealAppDriver.swift"

CACHE_OUTPUT_SENTINEL="$TEMP_ROOT/cache-output-must-not-change"
mkdir -p "$CACHE_OUTPUT_SENTINEL"
printf '%s\n' "preserve me" > "$CACHE_OUTPUT_SENTINEL/sentinel.txt"
"$ROOT/scripts/e2e/run-real-app-e2e.sh" \
    --prepare-driver-only \
    --output "$CACHE_OUTPUT_SENTINEL" \
    > "$TEMP_ROOT/driver-cache-first.json"
"$ROOT/scripts/e2e/run-real-app-e2e.sh" \
    --prepare-driver-only \
    --output "$CACHE_OUTPUT_SENTINEL" \
    > "$TEMP_ROOT/driver-cache-second.json"
python3 - \
    "$ROOT" "$CACHE_OUTPUT_SENTINEL" \
    "$TEMP_ROOT/driver-cache-first.json" "$TEMP_ROOT/driver-cache-second.json" <<'PY'
import hashlib
import json
import os
import pathlib
import platform
import sys

root = pathlib.Path(sys.argv[1]).resolve()
sentinel_root = pathlib.Path(sys.argv[2]).resolve()
first = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
second = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
if (sentinel_root / "sentinel.txt").read_text(encoding="utf-8") != "preserve me\n":
    raise SystemExit("driver cache warm-up modified the requested output")
if sorted(path.name for path in sentinel_root.iterdir()) != ["sentinel.txt"]:
    raise SystemExit("driver cache warm-up added files to the requested output")
if first["schemaVersion"] != 1 or second["schemaVersion"] != 1:
    raise SystemExit("unexpected driver cache warm-up schema")
if first["cacheStatus"] not in {"built", "hit"}:
    raise SystemExit("unexpected first driver cache status")
if second["cacheStatus"] != "hit":
    raise SystemExit("second driver cache warm-up did not hit the cache")
if first["cacheKey"] != second["cacheKey"]:
    raise SystemExit("stable driver inputs produced different cache keys")
if first["cachedBinary"] != second["cachedBinary"]:
    raise SystemExit("stable driver inputs produced different cache binaries")

binary = pathlib.Path(second["cachedBinary"]).resolve()
metadata_path = pathlib.Path(second["metadata"]).resolve()
cache_root = root / "build" / "e2e" / "real-app-driver-cache"
if os.path.commonpath([str(binary), str(cache_root)]) != str(cache_root):
    raise SystemExit("driver binary was cached outside build/e2e")
if os.path.commonpath([str(binary), str(sentinel_root)]) == str(sentinel_root):
    raise SystemExit("driver binary cache is inside the requested output")
if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("cached driver binary is missing or not executable")
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
if metadata["cacheKey"] != second["cacheKey"]:
    raise SystemExit("driver cache metadata key mismatch")
if metadata["driverSourceSHA256"] != hashlib.sha256(
    (root / "scripts" / "e2e" / "RealAppDriver.swift").read_bytes()
).hexdigest():
    raise SystemExit("driver cache metadata source hash mismatch")
if metadata["binarySHA256"] != hashlib.sha256(binary.read_bytes()).hexdigest():
    raise SystemExit("driver cache metadata binary hash mismatch")
if not metadata["swiftcPath"] or not metadata["swiftcVersion"]:
    raise SystemExit("driver cache metadata is missing the Swift compiler identity")
if not metadata["sdkPath"] or not metadata["sdkVersion"]:
    raise SystemExit("driver cache metadata is missing the SDK identity")
if metadata["hostArchitecture"] != platform.machine():
    raise SystemExit("driver cache metadata host architecture mismatch")
if metadata["compileArguments"] != [
    "-O",
    "-framework", "AppKit",
    "-framework", "ApplicationServices",
    "-framework", "CoreGraphics",
    "-framework", "ImageIO",
    "-framework", "ScreenCaptureKit",
    "-framework", "Vision",
]:
    raise SystemExit("driver cache metadata compile arguments mismatch")
PY

CONCURRENT_CACHE_ROOT="$ROOT/build/e2e/real-app-driver-cache-harness-$$"
rm -rf "$CONCURRENT_CACHE_ROOT"
mkdir -p "$CONCURRENT_CACHE_ROOT"
for worker in 1 2; do
    MARKDOWNVIEWER_E2E_DRIVER_CACHE_ROOT="$CONCURRENT_CACHE_ROOT" \
        "$ROOT/scripts/e2e/run-real-app-e2e.sh" \
        --prepare-driver-only \
        > "$TEMP_ROOT/driver-cache-concurrent-$worker.json" \
        2> "$TEMP_ROOT/driver-cache-concurrent-$worker.err" &
    concurrent_pids[$worker]="$!"
done
for worker in 1 2; do
    wait "${concurrent_pids[$worker]}"
done
python3 - \
    "$TEMP_ROOT/driver-cache-concurrent-1.json" \
    "$TEMP_ROOT/driver-cache-concurrent-2.json" <<'PY'
import json
import pathlib
import sys

reports = [
    json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
]
if sorted(report["cacheStatus"] for report in reports) != ["built", "hit"]:
    raise SystemExit("concurrent driver warm-up did not publish exactly one build")
if len({report["cacheKey"] for report in reports}) != 1:
    raise SystemExit("concurrent driver warm-up used inconsistent cache keys")
PY

CONCURRENT_CACHE_KEY="$(python3 - "$TEMP_ROOT/driver-cache-concurrent-1.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["cacheKey"])
PY
)"
SIGNAL_CACHE_ROOT="$ROOT/build/e2e/real-app-driver-cache-signal-$$"
SIGNAL_LOCK="$SIGNAL_CACHE_ROOT/$CONCURRENT_CACHE_KEY.lock"
mkdir -p "$SIGNAL_CACHE_ROOT"
/bin/sleep 20 &
LOCK_HOLDER_PID="$!"
if ! /usr/bin/shlock -f "$SIGNAL_LOCK" -p "$LOCK_HOLDER_PID"; then
    echo "RealAppHarnessTests: signal test lock holder could not publish its lock" >&2
    exit 1
fi
python3 - \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" "$SIGNAL_CACHE_ROOT" "$TEMP_ROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

runner, cache_root, output_root = sys.argv[1:]
environment = dict(os.environ)
environment["MARKDOWNVIEWER_E2E_DRIVER_CACHE_ROOT"] = cache_root
for name, sent_signal, expected_status in (
    ("int", signal.SIGINT, 130),
    ("term", signal.SIGTERM, 143),
):
    stdout = pathlib.Path(output_root) / f"driver-cache-signal-{name}.out"
    stderr = pathlib.Path(output_root) / f"driver-cache-signal-{name}.err"
    with stdout.open("wb") as output, stderr.open("wb") as error:
        process = subprocess.Popen(
            [runner, "--prepare-driver-only"],
            env=environment,
            stdout=output,
            stderr=error,
        )
        time.sleep(0.5)
        if process.poll() is not None:
            raise SystemExit(f"signal test runner exited before {name}")
        process.send_signal(sent_signal)
        status = process.wait(timeout=5)
    if status != expected_status:
        raise SystemExit(
            f"signal test {name} exited {status}, expected {expected_status}"
        )
PY
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""
rm -rf "$CONCURRENT_CACHE_ROOT" "$SIGNAL_CACHE_ROOT"

CACHED_DRIVER="$(python3 - "$TEMP_ROOT/driver-cache-second.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["cachedBinary"])
PY
)"
cp "$CACHED_DRIVER" "$TEMP_ROOT/RealAppDriver"
chmod +x "$TEMP_ROOT/RealAppDriver"

"$TEMP_ROOT/RealAppDriver" pasteboard-self-test \
    > "$TEMP_ROOT/pasteboard-self-test.json"
python3 - "$TEMP_ROOT/pasteboard-self-test.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report == {
    "schemaVersion": 1,
    "restored": True,
    "itemCount": 2,
    "typeCount": 3,
    "emptyPasteboardRestored": True,
}
PY

"$TEMP_ROOT/RealAppDriver" windows \
    --pid 2147483647 \
    --include-offscreen \
    > "$TEMP_ROOT/missing-process-windows.json"
python3 - "$TEMP_ROOT/missing-process-windows.json" <<'PY'
import json
import sys

if json.load(open(sys.argv[1], encoding="utf-8")) != []:
    raise SystemExit("missing process windows command did not return an empty list")
PY

if "$TEMP_ROOT/RealAppDriver" terminate-app \
    --pid 2147483647 \
    > "$TEMP_ROOT/terminate-missing.out" \
    2> "$TEMP_ROOT/terminate-missing.err"; then
    echo "RealAppHarnessTests: terminating a missing process unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -Fq "terminate-app target is not running: 2147483647" \
    "$TEMP_ROOT/terminate-missing.err"; then
    echo "RealAppHarnessTests: missing termination target error was not precise" >&2
    exit 1
fi

NONDEBUG_APP_PID="$(pgrep -x Finder 2>/dev/null | head -n 1 || true)"
if [[ ! "$NONDEBUG_APP_PID" =~ ^[0-9]+$ ]]; then
    echo "RealAppHarnessTests: could not locate the logged-in Finder process" >&2
    exit 1
fi
if "$TEMP_ROOT/RealAppDriver" terminate-app \
    --pid "$NONDEBUG_APP_PID" \
    --timeout 0.1 \
    > "$TEMP_ROOT/terminate-timeout.out" \
    2> "$TEMP_ROOT/terminate-timeout.err"; then
    echo "RealAppHarnessTests: invalid termination timeout unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -Fq -- "--timeout requires a number from 0.2 through 10 seconds" \
    "$TEMP_ROOT/terminate-timeout.err"; then
    echo "RealAppHarnessTests: termination timeout error was not precise" >&2
    exit 1
fi

if "$TEMP_ROOT/RealAppDriver" terminate-app \
    --pid "$NONDEBUG_APP_PID" \
    --timeout 0.2 \
    > "$TEMP_ROOT/terminate-nondebug.out" \
    2> "$TEMP_ROOT/terminate-nondebug.err"; then
    echo "RealAppHarnessTests: terminating a non-Debug process unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -Fq "terminate-app refuses non-Debug Markdown Viewer process $NONDEBUG_APP_PID" \
    "$TEMP_ROOT/terminate-nondebug.err"; then
    echo "RealAppHarnessTests: termination bundle safety error was not precise" >&2
    exit 1
fi

if "$TEMP_ROOT/RealAppDriver" window \
    --pid "$$" \
    --window-number 1 \
    --main-window-only \
    > "$TEMP_ROOT/window-selector-conflict.out" \
    2> "$TEMP_ROOT/window-selector-conflict.err"; then
    echo "RealAppHarnessTests: conflicting exact/main window selectors succeeded" >&2
    exit 1
fi
if ! rg -q "window-number cannot be combined" \
    "$TEMP_ROOT/window-selector-conflict.err"; then
    echo "RealAppHarnessTests: window selector conflict error was not precise" >&2
    exit 1
fi

FOREGROUND_PALETTE_ROOT="$TEMP_ROOT/foreground-palette-find-plan"
for phase in block-find palette-keyboard; do
    mkdir -p "$FOREGROUND_PALETTE_ROOT/$phase/raw"
    python3 "$ROOT/scripts/e2e/build-foreground-smoke-plan.py" \
        --phase "$phase" \
        --raw-dir "$FOREGROUND_PALETTE_ROOT/$phase/raw" \
        --output "$FOREGROUND_PALETTE_ROOT/$phase/plan.json"
    "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$FOREGROUND_PALETTE_ROOT/$phase/plan.json" \
        --budget 4 \
        > "$FOREGROUND_PALETTE_ROOT/$phase/validation.json"
done
# Later launch-token rejection checks need any already validated bounded plan.
FOREGROUND_SMOKE_ROOT="$FOREGROUND_PALETTE_ROOT/block-find"
python3 - "$FOREGROUND_PALETTE_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
phases = {}
for name in ("block-find", "palette-keyboard"):
    phase_root = root / name
    phases[name] = {
        "plan": json.loads((phase_root / "plan.json").read_text(encoding="utf-8")),
        "validation": json.loads(
            (phase_root / "validation.json").read_text(encoding="utf-8")
        ),
    }

block_actions = phases["block-find"]["plan"]["actions"]
palette_actions = phases["palette-keyboard"]["plan"]["actions"]
actions = block_actions + palette_actions
keys = [action.get("key") for action in actions if action["kind"] == "key"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]

def action_index(sequence, **expected):
    return next(
        index
        for index, action in enumerate(sequence)
        if all(action.get(key) == value for key, value in expected.items())
    )

def screenshot_index(sequence, name):
    return next(
        index
        for index, action in enumerate(sequence)
        if action["kind"] == "window-screenshot"
        and pathlib.Path(action["path"]).name == name
    )

assert all(phase["plan"]["schemaVersion"] == 1 for phase in phases.values())
assert all(1 <= len(phase["plan"]["actions"]) <= 64 for phase in phases.values())
assert keys.count("command+k") == 3
assert keys.count("command+f") == 2
assert "command+minus" in keys
assert "command+shift+equals" in keys
assert "down" in keys
assert keys.count("up") == 2
assert "return" in keys
assert "shift+return" in keys
assert sum(action["kind"] == "shift-tap" for action in actions) == 2
assert sum(action["kind"] == "window-click" for action in actions) == 2
assert sum(action["kind"] == "window-move" for action in actions) == 1
assert sum(action["kind"] == "move-safe-point" for action in actions) == 2
assert {action.get("control") for action in actions} >= {
    "disclosure",
    "whole-word",
    "query-field",
    "replace-field",
}
assert any(action.get("text") == "字号" for action in actions)
assert any(action.get("text") == "一级标题" for action in actions)
assert any(action.get("text") == "E2E_PALETTE_COMMIT" for action in actions)
assert any(action.get("text") == "E2E_REPLACE" for action in actions)
assert screenshots == [
    "active-edit-palette.png",
    "find-populated.png",
    "palette-filter-default.png",
    "palette-hover.png",
]
active_click = action_index(block_actions, kind="window-click", xFraction=0.44)
active_text = action_index(block_actions, kind="text", text="E2E_PALETTE_COMMIT")
active_palette = screenshot_index(block_actions, "active-edit-palette.png")
find_populated = screenshot_index(block_actions, "find-populated.png")
shift_indexes = [
    index
    for index, action in enumerate(palette_actions)
    if action["kind"] == "shift-tap"
]
filter_default = screenshot_index(palette_actions, "palette-filter-default.png")
hover_move = action_index(palette_actions, kind="window-move")
hover_capture = screenshot_index(palette_actions, "palette-hover.png")
block_command_k_indexes = [
    index for index, action in enumerate(actions)
    if action.get("key") == "command+k" and index < len(block_actions)
]
assert active_click < active_text < active_palette < find_populated
assert block_command_k_indexes[0] < active_palette < block_command_k_indexes[1]
assert action_index(block_actions, kind="key", key="command+f") < find_populated
assert palette_actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert palette_actions[1] == {"kind": "key", "key": "command+f", "waitMs": 80}
assert shift_indexes == [2, 3]
assert shift_indexes[-1] < filter_default < hover_move < hover_capture
assert [
    action.get("key")
    for action in palette_actions[hover_capture + 1:hover_capture + 5]
] == ["down", "up", "up", "return"]
assert action_index(
    palette_actions,
    kind="key",
    key="command+shift+equals",
) > hover_capture

expected_estimates = {"block-find": 2190, "palette-keyboard": 1690}
for name, phase in phases.items():
    validation = phase["validation"]
    kinds = [action["kind"] for action in phase["plan"]["actions"]]
    assert validation["valid"] is True
    assert validation["budgetMs"] == 4000
    assert validation["estimatedForegroundMs"] == expected_estimates[name]
    assert validation["cleanupReserveMs"] == 400
    assert validation["estimatedForegroundMs"] + 400 < 3600
    assert [action["kind"] for action in validation["actions"]] == kinds
assert sum(expected_estimates.values()) == 3880
PY

FOREGROUND_PALETTE_AGGREGATE_ROOT="$TEMP_ROOT/foreground-palette-find-aggregate"
PALETTE_FIXTURE_SHA="$(
    shasum -a 256 "$ROOT/ui/格式示例.md" | awk '{print $1}'
)"
for phase in block-find palette-keyboard; do
    mkdir -p "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase/raw"
    python3 "$ROOT/scripts/e2e/build-foreground-smoke-plan.py" \
        --phase "$phase" \
        --raw-dir "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase/raw" \
        --output "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase/foreground-plan.json"
    "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase/foreground-plan.json" \
        --budget 4 \
        > "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase/foreground-plan-validation.json"
done
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_PALETTE_AGGREGATE_ROOT" <<'PY'
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
marker = "E2E_PALETTE_COMMIT"
source = fixture.replace(
    "# Markdown 全格式示例",
    f"# Markdown 全格式示例{marker}",
    1,
)
if source.count(marker) != 1 or marker in fixture:
    raise SystemExit("synthetic palette marker setup drifted")
live_session = root / "live-session.json"
find_states = {
    "block-find": {
        "query": "一级标题",
        "display": "1/1",
        "matchCount": 1,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": True,
        "caseSensitive": False,
        "wholeWord": True,
        "regex": False,
    },
    "palette-keyboard": {
        "query": "",
        "display": "",
        "matchCount": 0,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": False,
        "caseSensitive": False,
        "wholeWord": True,
        "regex": False,
    },
}
for phase, font_index, duration in (
    ("block-find", 0, 1_800),
    ("palette-keyboard", 1, 1_400),
):
    phase_root = root / phase
    tab = {
        "id": "fixture-tab",
        "url": None,
        "name": "格式示例.md",
        "isMarkdown": True,
        "isDirty": True,
        "scrollY": 0,
        "text": source,
        "markdownDocument": {
            "blocks": [{
                "id": "fixture-block",
                "kind": "heading",
                "leadingTrivia": "",
                "source": source,
            }],
            "trailingTrivia": "",
        },
    }
    session = {
        "schemaVersion": 2,
        "tabs": [tab],
        "activeTabID": tab["id"],
        "fontIndex": font_index,
        "sidebarWidth": 216,
        "sidebarOpen": True,
        "directoryPath": None,
        "expandedFolderPaths": [],
    }
    diagnostic = {
        "schemaVersion": 1,
        "document": "格式示例.md",
        "blockID": None,
        "blockType": None,
        "mode": "edit",
        "selection": None,
        "activeTableCell": None,
        "dirty": True,
        "find": find_states[phase],
        "outline": {"headingCount": 15, "activeIndex": 0},
        "scrollY": 0,
        "sessionPath": str(live_session.resolve()),
        "parseCount": 2,
        "localMutationCount": 1,
        "renderedBlockUpdateCount": 2,
        "activeBlockRenderUpdateCount": 1,
        "renderedBlockUpdates": {"fixture-block": 2},
        "visual": {
            "documentVisible": True,
            "sidebarVisible": True,
            "paletteVisible": False,
            "findPanelVisible": phase == "block-find",
            "replaceRowVisible": phase == "block-find",
            "previewActive": False,
            "sourceEditorVisible": False,
            "tableGridVisible": False,
            "anchors": {},
        },
        "updatedAt": "2026-07-15T00:00:00Z",
    }
    (phase_root / "session.json").write_text(
        json.dumps(session, ensure_ascii=False),
        encoding="utf-8",
    )
    (phase_root / "diagnostic.json").write_text(
        json.dumps(diagnostic, ensure_ascii=False),
        encoding="utf-8",
    )
    plan = json.loads(
        (phase_root / "foreground-plan.json").read_text(encoding="utf-8")
    )
    actions = [{
        "index": index,
        "kind": action["kind"],
        "status": "completed",
        "durationMs": 40,
    } for index, action in enumerate(plan["actions"])]
    report = {
        "pid": 101,
        "durationMs": duration,
        "budgetMs": 4_000,
        "targetActivationRequestCount": 1,
        "completed": True,
        "actions": actions,
        "interference": {
            "detected": False,
            "pointerInputDetected": False,
            "pointerPositionInterferenceDetected": False,
            "eventTapReliable": True,
        },
        "deadlineExceeded": False,
        "focusRestore": {
            "attempted": True,
            "restored": True,
            "priorPID": 202,
        },
        "pointerRestore": {"attempted": True, "restored": True},
        "pasteboardRestore": {"attempted": False, "restored": True},
        "error": None,
    }
    (phase_root / "foreground-report.json").write_text(
        json.dumps(report, ensure_ascii=False),
        encoding="utf-8",
    )
    (phase_root / "foreground-window-after.json").write_text(
        json.dumps({"pid": 101, "onScreen": False, "layer": 0}),
        encoding="utf-8",
    )
PY

for phase in block-find palette-keyboard; do
    phase_root="$FOREGROUND_PALETTE_AGGREGATE_ROOT/$phase"
    python3 "$ROOT/scripts/e2e/verify-palette-find-phase.py" \
        --phase "$phase" \
        --session "$phase_root/session.json" \
        --expected-session-path "$FOREGROUND_PALETTE_AGGREGATE_ROOT/live-session.json" \
        --diagnostic "$phase_root/diagnostic.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --fixture-sha "$PALETTE_FIXTURE_SHA" \
        --output "$phase_root/phase-state.json"
done

python3 "$ROOT/scripts/e2e/aggregate-foreground-palette-find.py" \
    --phase-root "$FOREGROUND_PALETTE_AGGREGATE_ROOT" \
    --output-validation "$FOREGROUND_PALETTE_AGGREGATE_ROOT/aggregate-validation.json" \
    --output-report "$FOREGROUND_PALETTE_AGGREGATE_ROOT/aggregate-report.json" \
    --budget-ms 4000

for report_kind in session diagnostic; do
    python3 "$ROOT/scripts/e2e/verify-foreground-palette-find.py" \
        --session "$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/session.json" \
        --diagnostic "$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/diagnostic.json" \
        --foreground-report "$FOREGROUND_PALETTE_AGGREGATE_ROOT/aggregate-report.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --fixture-sha "$PALETTE_FIXTURE_SHA" \
        --output-root "$TEMP_ROOT" \
        --report-kind "$report_kind" \
        > "$FOREGROUND_PALETTE_AGGREGATE_ROOT/$report_kind-assertion.json"
done
python3 - "$FOREGROUND_PALETTE_AGGREGATE_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
validation = json.loads(
    (root / "aggregate-validation.json").read_text(encoding="utf-8")
)
report = json.loads((root / "aggregate-report.json").read_text(encoding="utf-8"))
assert validation["suite"] == "palette-find"
assert validation["phaseCount"] == 2
assert validation["perPhaseBudgetMs"] == 4000
assert validation["totalBudgetMs"] == 8000
assert validation["estimatedForegroundMs"] == 3880
assert validation["cleanupReserveMs"] == 800
assert report["targetActivationRequestCount"] == 2
assert report["pids"] == [101, 101]
assert report["durationMs"] == 3200
assert len(report["actions"]) == 35
assert [phase["name"] for phase in report["phases"]] == [
    "block-find",
    "palette-keyboard",
]
for kind in ("session", "diagnostic"):
    assertion = json.loads(
        (root / f"{kind}-assertion.json").read_text(encoding="utf-8")
    )
    assert assertion["label"] == f"foreground-palette-find-{kind}"
    assert assertion["phaseCount"] == 2
    assert all(assertion["assertions"].values())
PY

for negative_case in activation restore interference budget state; do
    case "$negative_case" in
        activation)
            negative_target="$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/foreground-report.json"
            expected_error="palette-keyboard report is not one bounded complete activation"
            ;;
        restore)
            negative_target="$FOREGROUND_PALETTE_AGGREGATE_ROOT/block-find/foreground-report.json"
            expected_error="block-find did not restore prior focus"
            ;;
        interference)
            negative_target="$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/foreground-report.json"
            expected_error="palette-keyboard report detected interference"
            ;;
        budget)
            negative_target="$FOREGROUND_PALETTE_AGGREGATE_ROOT/block-find/foreground-plan-validation.json"
            expected_error="block-find plan validation is inconsistent"
            ;;
        state)
            negative_target="$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/phase-state.json"
            expected_error="palette-keyboard persisted diagnostic proof is wrong"
            ;;
    esac
    negative_backup="$FOREGROUND_PALETTE_AGGREGATE_ROOT/$negative_case-backup.json"
    cp "$negative_target" "$negative_backup"
    python3 - "$negative_target" "$negative_case" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
value = json.loads(path.read_text(encoding="utf-8"))
if case == "activation":
    value["targetActivationRequestCount"] = 0
elif case == "restore":
    value["focusRestore"]["restored"] = False
elif case == "interference":
    value["interference"]["detected"] = True
elif case == "budget":
    value["budgetMs"] = 3_999
elif case == "state":
    value["diagnostic"]["find"]["query"] = "stale-query"
path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
PY
    if python3 "$ROOT/scripts/e2e/aggregate-foreground-palette-find.py" \
        --phase-root "$FOREGROUND_PALETTE_AGGREGATE_ROOT" \
        --output-validation "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-$negative_case-validation.json" \
        --output-report "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-$negative_case-report.json" \
        --budget-ms 4000 \
        > "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-$negative_case.out" \
        2> "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-$negative_case.err"; then
        echo "RealAppHarnessTests: invalid palette-find $negative_case proof passed" >&2
        exit 1
    fi
    mv "$negative_backup" "$negative_target"
    if ! rg -Fq "$expected_error" \
        "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-$negative_case.err"; then
        echo "RealAppHarnessTests: palette-find $negative_case error was not precise" >&2
        exit 1
    fi
done

python3 - \
    "$FOREGROUND_PALETTE_AGGREGATE_ROOT/aggregate-report.json" \
    "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-final-report.json" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
value = json.loads(source.read_text(encoding="utf-8"))
value["targetActivationRequestCount"] = 1
output.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/verify-foreground-palette-find.py" \
    --session "$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/session.json" \
    --diagnostic "$FOREGROUND_PALETTE_AGGREGATE_ROOT/palette-keyboard/diagnostic.json" \
    --foreground-report "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-final-report.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --fixture-sha "$PALETTE_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-final.out" \
    2> "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-final.err"; then
    echo "RealAppHarnessTests: incomplete palette-find aggregate passed final verifier" >&2
    exit 1
fi
if ! rg -Fq "aggregate did not prove two bounded activations" \
    "$FOREGROUND_PALETTE_AGGREGATE_ROOT/invalid-final.err"; then
    echo "RealAppHarnessTests: final palette-find aggregate error was not precise" >&2
    exit 1
fi

FOREGROUND_BLOCK_ACTIVATION_ROOT="$TEMP_ROOT/foreground-block-activation-plan"
mkdir -p "$FOREGROUND_BLOCK_ACTIVATION_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-block-activation-plan.py" \
    --raw-dir "$FOREGROUND_BLOCK_ACTIVATION_ROOT/raw" \
    --output "$FOREGROUND_BLOCK_ACTIVATION_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_BLOCK_ACTIVATION_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_BLOCK_ACTIVATION_ROOT/validation.json"
python3 - \
    "$FOREGROUND_BLOCK_ACTIVATION_ROOT/plan.json" \
    "$FOREGROUND_BLOCK_ACTIVATION_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
source = "# Markdown 全格式示例"
assert plan == {
    "schemaVersion": 1,
    "actions": [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "element-click",
            "identifier": "document-block-0-heading",
            "role": "AXButton",
            "waitMs": 80,
        },
        {
            "kind": "element-check",
            "identifier": "document-block-0-source-editor",
            "role": "AXTextArea",
            "expectedValue": source,
            "waitMs": 40,
        },
        {
            "kind": "focused-element-check",
            "identifier": "document-block-0-source-editor",
            "role": "AXTextArea",
            "expectedValue": source,
            "waitMs": 80,
        },
        {"kind": "key", "key": "escape", "waitMs": 40},
        {
            "kind": "element-click",
            "identifier": "document-block-1-paragraph",
            "role": "AXButton",
            "waitMs": 80,
        },
        {
            "kind": "element-check",
            "identifier": "document-block-1-source-editor",
            "role": "AXTextArea",
            "waitMs": 40,
        },
        {
            "kind": "focused-element-check",
            "identifier": "document-block-1-source-editor",
            "role": "AXTextArea",
            "waitMs": 80,
        },
    ],
}
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 1190
assert validation["cleanupReserveMs"] == 400
assert [action["kind"] for action in validation["actions"]] == [
    "move-safe-point",
    "element-click",
    "element-check",
    "focused-element-check",
    "key",
    "element-click",
    "element-check",
    "focused-element-check",
]
assert validation["actions"][1]["detail"] == (
    "identifier=document-block-0-heading,role=AXButton"
)
assert validation["actions"][2]["detail"] == (
    "identifier=document-block-0-source-editor,role=AXTextArea,"
    "expectedValueUTF16=16"
)
assert validation["actions"][3]["detail"] == validation["actions"][2]["detail"]
assert validation["actions"][4]["detail"] == "escape"
assert validation["actions"][5]["detail"] == (
    "identifier=document-block-1-paragraph,role=AXButton"
)
assert validation["actions"][6]["detail"] == (
    "identifier=document-block-1-source-editor,role=AXTextArea"
)
assert validation["actions"][7]["detail"] == validation["actions"][6]["detail"]
assert "block-activation) run_foreground_block_activation" in runner
assert "build-foreground-block-activation-plan.py" in runner
assert "foreground target window did not return offscreen at normal level" in runner
PY

if "$TEMP_ROOT/RealAppDriver" foreground-batch \
    --pid 2147483647 \
    --plan "$FOREGROUND_SMOKE_ROOT/plan.json" \
    --budget 4 \
    --width 1180 \
    --height 760 \
    > "$FOREGROUND_SMOKE_ROOT/missing-token.out" \
    2> "$FOREGROUND_SMOKE_ROOT/missing-token.err"; then
    echo "RealAppHarnessTests: foreground batch accepted a missing launch token" >&2
    exit 1
fi
rg -Fq -- "--launch-token requires a value" \
    "$FOREGROUND_SMOKE_ROOT/missing-token.err"

if "$TEMP_ROOT/RealAppDriver" foreground-batch \
    --pid 2147483647 \
    --launch-token not-a-uuid \
    --plan "$FOREGROUND_SMOKE_ROOT/plan.json" \
    --budget 4 \
    --width 1180 \
    --height 760 \
    > "$FOREGROUND_SMOKE_ROOT/malformed-token.out" \
    2> "$FOREGROUND_SMOKE_ROOT/malformed-token.err"; then
    echo "RealAppHarnessTests: foreground batch accepted a malformed launch token" >&2
    exit 1
fi
rg -Fq -- "--launch-token requires a UUID" \
    "$FOREGROUND_SMOKE_ROOT/malformed-token.err"

FOREGROUND_FIND_OPTIONS_ROOT="$TEMP_ROOT/foreground-find-options-plan"
mkdir -p "$FOREGROUND_FIND_OPTIONS_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-find-options-plan.py" \
    --raw-dir "$FOREGROUND_FIND_OPTIONS_ROOT/raw" \
    --output "$FOREGROUND_FIND_OPTIONS_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_FIND_OPTIONS_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_FIND_OPTIONS_ROOT/validation.json"
python3 - \
    "$FOREGROUND_FIND_OPTIONS_ROOT/plan.json" \
    "$FOREGROUND_FIND_OPTIONS_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 12
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+n", "command+f",
]
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "Red red redwood RED", "red",
]
assert [
    (action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] == "focused-element-check"
] == [
    ("document-block-0-source-editor", None),
    ("find-query", "AXTextField"),
]
assert [
    (action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] == "element-click"
] == [
    ("find-case-sensitive", "AXButton"),
    ("find-whole-word", "AXButton"),
]
assert screenshots == ["find-options-composed.png"]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 1470
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 1900
assert 'find-options) run_foreground_find_options' in runner
assert 'build-foreground-find-options-plan.py' in runner
assert 'assert_foreground_find_session "find-options"' in runner
PY

FOREGROUND_FIND_REGEX_ROOT="$TEMP_ROOT/foreground-find-regex-plan"
mkdir -p "$FOREGROUND_FIND_REGEX_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-find-regex-plan.py" \
    --raw-dir "$FOREGROUND_FIND_REGEX_ROOT/raw" \
    --output "$FOREGROUND_FIND_REGEX_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_FIND_REGEX_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_FIND_REGEX_ROOT/validation.json"
python3 - \
    "$FOREGROUND_FIND_REGEX_ROOT/plan.json" \
    "$FOREGROUND_FIND_REGEX_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 22
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+n", "command+f", "command+a",
]
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "Name:Ada Name:Bob Name:Cy",
    r"Name:(\w+)",
    "Current:$1",
    "All:$1",
]
assert [
    (action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] == "focused-element-check"
] == [
    ("document-block-0-source-editor", None),
    ("find-query", "AXTextField"),
    ("find-replacement", "AXTextField"),
    ("find-replacement", "AXTextField"),
]
assert [action["identifier"] for action in actions if action["kind"] == "element-click"] == [
    "find-regex",
    "find-toggle-replace",
    "find-replacement",
    "find-replace-current",
    "find-replacement",
    "find-replace-all",
]
assert screenshots == [
    "find-regex-current.png",
    "find-regex-final.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2850
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3300
assert 'find-regex-replace) run_foreground_find_regex_replace' in runner
assert 'build-foreground-find-regex-plan.py' in runner
assert 'assert_foreground_find_session "find-regex-replace"' in runner
PY

FOREGROUND_PREVIEW_CONTENT_ROOT="$TEMP_ROOT/foreground-preview-content-plan"
mkdir -p "$FOREGROUND_PREVIEW_CONTENT_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-preview-content-plan.py" \
    --raw-dir "$FOREGROUND_PREVIEW_CONTENT_ROOT/raw" \
    --output "$FOREGROUND_PREVIEW_CONTENT_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_PREVIEW_CONTENT_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_PREVIEW_CONTENT_ROOT/validation.json"
python3 - \
    "$FOREGROUND_PREVIEW_CONTENT_ROOT/plan.json" \
    "$FOREGROUND_PREVIEW_CONTENT_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 11
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+shift+p", "command+shift+p",
]
assert actions[3] == {
    "kind": "element-click",
    "identifier": "document-block-19-task-2-checkbox",
    "role": "AXButton",
    "waitMs": 80,
}
assert actions[5] == {
    "kind": "element-move",
    "identifier": "document-block-23-code-card",
    "waitMs": 80,
}
assert actions[6] == {
    "kind": "element-click",
    "identifier": "document-block-23-code-copy",
    "role": "AXButton",
    "waitMs": 80,
}
assert actions[7] == {
    "kind": "pasteboard-string-check",
    "text": "# 安装并运行\nnpx -y @dev/cli@latest --version",
    "waitMs": 40,
}
assert screenshots == [
    "preview-content-on.png",
    "preview-task-toggled.png",
    "preview-code-copied.png",
    "preview-content-returned.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2000
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] <= 2400
assert 'if [[ "$FOREGROUND_BATCH_NAME" == "preview-content" ]]' in runner
launch_branch = runner.split(
    'if [[ "$FOREGROUND_BATCH_NAME" == "preview-content" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 1600" in launch_branch
assert 'preview-content) run_foreground_preview_content' in runner
assert 'build-foreground-preview-content-plan.py' in runner
assert 'assert_foreground_preview_content_session' in runner
assert '"pasteboardRestore"' in runner
assert '"pasteboardRestored"' in runner
PY

FOREGROUND_PREVIEW_FOOTNOTES_ROOT="$TEMP_ROOT/foreground-preview-footnotes-plan"
mkdir -p "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-preview-footnotes-plan.py" \
    --raw-dir "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/raw" \
    --output "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/validation.json"
python3 - \
    "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/plan.json" \
    "$FOREGROUND_PREVIEW_FOOTNOTES_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 13
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+shift+p", "command+shift+p",
]
assert actions[3] == {
    "kind": "element-move",
    "identifier": "document-block-35-footnote-reference-1",
    "role": "AXLink",
    "waitMs": 80,
}
assert actions[5] == {
    "kind": "element-click",
    "identifier": "document-block-35-footnote-reference-1",
    "role": "AXLink",
    "waitMs": 80,
}
assert actions[6] == {"kind": "wait", "durationMs": 280}
assert actions[8] == {
    "kind": "element-click",
    "identifier": "footnote-back-1",
    "role": "AXButton",
    "waitMs": 80,
}
assert actions[9] == {"kind": "wait", "durationMs": 280}
assert screenshots == [
    "preview-footnotes-on.png",
    "preview-footnote-hover.png",
    "preview-footnote-definition.png",
    "preview-footnote-return.png",
    "preview-footnotes-returned.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2760
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3200
assert 'elif [[ "$FOREGROUND_BATCH_NAME" == "preview-footnotes" ]]' in runner
launch_branch = runner.split(
    'elif [[ "$FOREGROUND_BATCH_NAME" == "preview-footnotes" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 3000" in launch_branch
assert 'preview-footnotes) run_foreground_preview_footnotes' in runner
assert 'build-foreground-preview-footnotes-plan.py' in runner
assert 'assert_foreground_preview_footnotes_session' in runner
PY

FOREGROUND_OUTLINE_NAVIGATION_ROOT="$TEMP_ROOT/foreground-outline-navigation-plan"
mkdir -p "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-outline-navigation-plan.py" \
    --raw-dir "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/raw" \
    --output "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/validation.json"
python3 - \
    "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/plan.json" \
    "$FOREGROUND_OUTLINE_NAVIGATION_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 12
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert actions[1] == {
    "kind": "element-move",
    "identifier": "outline-heading-12",
    "role": "AXButton",
    "waitMs": 80,
}
assert actions[2] == {"kind": "wait", "durationMs": 320}
assert actions[4] == {
    "kind": "element-click",
    "identifier": "outline-heading-12",
    "role": "AXButton",
    "waitMs": 40,
}
assert [
    action["durationMs"]
    for action in actions
    if action["kind"] == "wait"
] == [320, 260, 400, 400]
assert screenshots == [
    "outline-expanded.png",
    "outline-jump-in-flight.png",
    "outline-wash-peak.png",
    "outline-wash-fading.png",
    "outline-wash-cleared.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 3210
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3650
assert 'elif [[ "$FOREGROUND_BATCH_NAME" == "outline-navigation" ]]' in runner
launch_branch = runner.split(
    'elif [[ "$FOREGROUND_BATCH_NAME" == "outline-navigation" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 650" in launch_branch
assert 'outline-navigation) run_foreground_outline_navigation' in runner
assert 'build-foreground-outline-navigation-plan.py' in runner
assert 'assert_foreground_outline_navigation_session' in runner
PY

FOREGROUND_SIDEBAR_FILTER_ROOT="$TEMP_ROOT/foreground-sidebar-filter-plan"
mkdir -p "$FOREGROUND_SIDEBAR_FILTER_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-sidebar-filter-plan.py" \
    --raw-dir "$FOREGROUND_SIDEBAR_FILTER_ROOT/raw" \
    --output "$FOREGROUND_SIDEBAR_FILTER_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_SIDEBAR_FILTER_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_SIDEBAR_FILTER_ROOT/validation.json"
python3 - \
    "$FOREGROUND_SIDEBAR_FILTER_ROOT/plan.json" \
    "$FOREGROUND_SIDEBAR_FILTER_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 26
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "格式", "docs/config", "NO_MATCH_7F2", ".md",
]
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+a", "command+a", "command+a", "down", "return", "up",
    "return", "command+a", "delete",
]
assert [
    (action["kind"], action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] in {
        "element-click", "element-check", "focused-element-check",
    }
] == [
    ("element-click", "sidebar-filter", "AXTextField"),
    ("focused-element-check", "sidebar-filter", "AXTextField"),
    (
        "element-check",
        "sidebar-file-docs%2F%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd",
        "AXButton",
    ),
    ("element-check", "sidebar-file-docs%2Fconfig%2Eyaml", "AXButton"),
    ("element-check", "sidebar-filter-empty", "AXStaticText"),
    ("focused-element-check", "sidebar-filter", "AXTextField"),
]
assert screenshots == [
    "sidebar-filter-name.png",
    "sidebar-filter-path.png",
    "sidebar-filter-empty.png",
    "sidebar-filter-readme.png",
    "sidebar-filter-fixture.png",
    "sidebar-filter-cleared.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 3150
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3600
assert "sidebar-filter-navigation) run_foreground_sidebar_filter_navigation" in runner
assert "build-foreground-sidebar-filter-plan.py" in runner
assert 'assert_foreground_sidebar_state "sidebar-filter-navigation"' in runner
assert "--visual-test-state default" in runner
assert "--visual-test-scroll 0" in runner
PY

FOREGROUND_SIDEBAR_LAYOUT_ROOT="$TEMP_ROOT/foreground-sidebar-layout-plan"
mkdir -p "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-sidebar-layout-plan.py" \
    --raw-dir "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/raw" \
    --output "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/validation.json"
python3 - \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/plan.json" \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 15
assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
assert [
    (action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] == "element-click"
] == [
    ("sidebar-folder-docs", "AXButton"),
    ("sidebar-folder-docs", "AXButton"),
]
assert [
    (action["identifier"], action.get("deltaX"), action.get("deltaY"))
    for action in actions
    if action["kind"] == "element-drag"
] == [
    ("sidebar-resize-handle", -120, None),
]
window_drag = next(action for action in actions if action["kind"] == "window-drag")
assert window_drag == {
    "kind": "window-drag",
    "xFraction": 175.5 / 1180,
    "yFraction": 0.5,
    "deltaX": 320,
    "waitMs": 40,
}
assert [
    (action["identifier"], action.get("role"))
    for action in actions
    if action["kind"] == "element-check"
] == [
    ("sidebar-file-docs%2Fconfig%2Eyaml", "AXButton"),
]
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+backslash", "command+backslash",
]
assert [action.get("durationMs") for action in actions if action["kind"] == "wait"] == [
    200, 200,
]
assert screenshots == [
    "sidebar-folder-collapsed.png",
    "sidebar-width-minimum.png",
    "sidebar-width-maximum.png",
    "sidebar-hidden.png",
    "sidebar-shown-maximum.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2850
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3600
assert "sidebar-layout-controls) run_foreground_sidebar_layout_controls" in runner
assert "build-foreground-sidebar-layout-plan.py" in runner
assert "aggregate-foreground-sidebar-layout.py" in runner
assert 'run_foreground_sidebar_layout_phase "collapse-minimum"' in runner
assert 'run_foreground_sidebar_layout_phase "maximum-toggle"' in runner
assert runner.count("sidebar-layout/collapse-minimum/foreground-report.json") >= 1
assert runner.count("sidebar-layout/maximum-toggle/foreground-report.json") >= 1
assert 'verify_foreground_sidebar_resize_phase "collapse-minimum"' in runner
assert 'verify_foreground_sidebar_resize_phase "maximum-toggle"' in runner
assert "verify-sidebar-resize-phase.py" in runner
assert 'assert_foreground_sidebar_state "sidebar-layout-controls"' in runner
assert '"element-check"' in runner
assert '"element-drag"' in runner
assert '"window-drag"' in runner
PY

for sidebar_layout_phase in collapse-minimum maximum-toggle; do
    phase_root="$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases/$sidebar_layout_phase"
    mkdir -p "$phase_root/raw"
    python3 "$ROOT/scripts/e2e/build-foreground-sidebar-layout-plan.py" \
        --phase "$sidebar_layout_phase" \
        --raw-dir "$phase_root/raw" \
        --output "$phase_root/foreground-plan.json"
    "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$phase_root/foreground-plan.json" \
        --budget 4 \
        > "$phase_root/foreground-plan-validation.json"
done
python3 - "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
collapse = json.loads(
    (root / "collapse-minimum" / "foreground-plan.json").read_text(
        encoding="utf-8"
    )
)
maximum = json.loads(
    (root / "maximum-toggle" / "foreground-plan.json").read_text(
        encoding="utf-8"
    )
)
collapse_validation = json.loads(
    (root / "collapse-minimum" / "foreground-plan-validation.json").read_text(
        encoding="utf-8"
    )
)
maximum_validation = json.loads(
    (root / "maximum-toggle" / "foreground-plan-validation.json").read_text(
        encoding="utf-8"
    )
)
assert len(collapse["actions"]) == 7
assert len(maximum["actions"]) == 9
assert collapse["actions"][0] == {"kind": "move-safe-point", "waitMs": 40}
assert maximum["actions"][0] == {"kind": "move-safe-point", "waitMs": 40}
assert [action["kind"] for action in collapse["actions"]] == [
    "move-safe-point",
    "element-click",
    "window-screenshot",
    "element-click",
    "element-check",
    "element-drag",
    "window-screenshot",
]
assert [action["kind"] for action in maximum["actions"]] == [
    "move-safe-point",
    "window-drag",
    "window-screenshot",
    "key",
    "wait",
    "window-screenshot",
    "key",
    "wait",
    "window-screenshot",
]
assert collapse["actions"][5] == {
    "kind": "element-drag",
    "identifier": "sidebar-resize-handle",
    "deltaX": -120,
    "waitMs": 40,
}
assert maximum["actions"][1] == {
    "kind": "window-drag",
    "xFraction": 175.5 / 1180,
    "yFraction": 0.5,
    "deltaX": 320,
    "waitMs": 40,
}
assert collapse_validation["estimatedForegroundMs"] == 1450
assert maximum_validation["estimatedForegroundMs"] == 1690
for validation in (collapse_validation, maximum_validation):
    assert validation["valid"] is True
    assert validation["budgetMs"] == 4000
    assert validation["cleanupReserveMs"] == 400
    assert validation["estimatedForegroundMs"] + 400 <= 2090
    assert validation["estimatedForegroundMs"] + 400 < 3600
PY

python3 - "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
durations = {
    "collapse-minimum": 1100,
    "maximum-toggle": 1400,
}
for phase, duration in durations.items():
    phase_root = root / phase
    plan = json.loads(
        (phase_root / "foreground-plan.json").read_text(encoding="utf-8")
    )
    report = {
        "pid": 101,
        "durationMs": duration,
        "budgetMs": 4000,
        "targetActivationRequestCount": 1,
        "completed": True,
        "actions": [
            {
                "index": index,
                "kind": action["kind"],
                "status": "completed",
                "durationMs": 40,
            }
            for index, action in enumerate(plan["actions"])
        ],
        "interference": {
            "detected": False,
            "pointerInputDetected": False,
            "pointerPositionInterferenceDetected": False,
            "eventTapReliable": True,
        },
        "deadlineExceeded": False,
        "focusRestore": {"attempted": True, "restored": True},
        "pointerRestore": {"attempted": True, "restored": True},
        "pasteboardRestore": {"attempted": False, "restored": True},
        "error": None,
    }
    for action in report["actions"]:
        if action["kind"] in {"element-drag", "window-drag"}:
            receipt = {
                "leftMouseDraggedCount": 2,
                "completeDragSequenceObserved": True,
            }
            action.update({
                "pointerClickReadiness": {"ready": True},
                "pointerDragEndpointReadiness": {"ready": True},
                "injectedPointerEvents": receipt,
                "targetInjectedPointerEvents": receipt,
            })
    (phase_root / "foreground-report.json").write_text(
        json.dumps(report, ensure_ascii=False),
        encoding="utf-8",
    )
    (phase_root / "foreground-window-after.json").write_text(
        json.dumps({"pid": 101, "onScreen": False, "layer": 0}),
        encoding="utf-8",
    )
    expected_end = 176 if phase == "collapse-minimum" else 440
    session_path = phase_root / "session.json"
    session_path.write_text(json.dumps({
        "schemaVersion": 2,
        "sidebarOpen": True,
        "sidebarWidth": expected_end,
    }), encoding="utf-8")
    (phase_root / "diagnostic.json").write_text(json.dumps({
        "schemaVersion": 1,
        "sessionPath": str(session_path.resolve()),
        "visual": {
            "sidebarVisible": True,
            "anchors": {
                "sidebar-frame": {
                    "x": 0,
                    "y": 0,
                    "width": expected_end,
                    "height": 760,
                },
            },
        },
    }), encoding="utf-8")
    if phase == "collapse-minimum":
        resize_widths = [
            ("trace-attached", None),
            ("sidebar-resize-began", 216),
            ("sidebar-resize-changed", 190),
            ("sidebar-resize-changed", 176),
            ("sidebar-resize-ended", 176),
        ]
    else:
        resize_widths = [
            ("trace-attached", None),
            ("sidebar-resize-began", 216),
            ("sidebar-resize-changed", 176),
            ("sidebar-resize-ended", 176),
            ("sidebar-resize-began", 176),
            ("sidebar-resize-changed", 360),
            ("sidebar-resize-changed", 440),
            ("sidebar-resize-ended", 440),
        ]
    entries = []
    for sequence, (trace_phase, sidebar_width) in enumerate(resize_widths):
        entry = {
            "sequence": sequence,
            "phase": trace_phase,
            "hitViewPath": [],
        }
        if sidebar_width is not None:
            entry["sidebarWidth"] = sidebar_width
        entries.append(entry)
    (phase_root / "pointer-trace.json").write_text(json.dumps({
        "schemaVersion": 1,
        "entries": entries,
    }), encoding="utf-8")
PY
for sidebar_layout_phase in collapse-minimum maximum-toggle; do
    phase_root="$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases/$sidebar_layout_phase"
    python3 "$ROOT/scripts/e2e/verify-sidebar-resize-phase.py" \
        --phase "$sidebar_layout_phase" \
        --session "$phase_root/session.json" \
        --diagnostic "$phase_root/diagnostic.json" \
        --pointer-trace "$phase_root/pointer-trace.json" \
        --output "$phase_root/resize-state.json"
done
python3 "$ROOT/scripts/e2e/aggregate-foreground-sidebar-layout.py" \
    --phase-root "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" \
    --output-validation "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/aggregate-validation.json" \
    --output-report "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/aggregate-report.json" \
    --budget-ms 4000
python3 - \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/aggregate-validation.json" \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/aggregate-report.json" <<'PY'
import json
import pathlib
import sys

validation = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert validation["schemaVersion"] == 1
assert validation["suite"] == "sidebar-layout-controls"
assert validation["valid"] is True
assert validation["phaseCount"] == 2
assert validation["perPhaseBudgetMs"] == 4000
assert validation["totalBudgetMs"] == 8000
assert validation["estimatedForegroundMs"] == 3140
assert validation["cleanupReserveMs"] == 800
assert len(validation["actions"]) == 16
assert report["schemaVersion"] == 1
assert report["suite"] == "sidebar-layout-controls"
assert report["phaseCount"] == 2
assert report["budgetMs"] == 8000
assert report["durationMs"] == 2500
assert report["targetActivationRequestCount"] == 2
assert report["pids"] == [101, 101]
assert report["completed"] is True
assert report["focusRestore"] == {"attempted": True, "restored": True}
assert report["pointerRestore"] == {"attempted": True, "restored": True}
assert [phase["name"] for phase in report["phases"]] == [
    "collapse-minimum",
    "maximum-toggle",
]
assert all(phase["resizeState"]["assertions"].values() for phase in report["phases"])
assert len(report["actions"]) == 16
assert [action["index"] for action in report["actions"]] == list(range(16))
assert [action["phaseIndex"] for action in report["actions"]] == [0] * 7 + [1] * 9
assert [action["phaseActionIndex"] for action in report["actions"]] == (
    list(range(7)) + list(range(9))
)
PY

python3 - "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "maximum-toggle" / "resize-state.json"
state = json.loads(path.read_text(encoding="utf-8"))
state["pointerTrace"]["latestResizeSegment"]["ended"]["sidebarWidth"] = 439
path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/aggregate-foreground-sidebar-layout.py" \
    --phase-root "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" \
    --output-validation "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-state-validation.json" \
    --output-report "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-state-report.json" \
    --budget-ms 4000 \
    > "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-state.out" \
    2> "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-state.err"; then
    echo "RealAppHarnessTests: invalid sidebar resize-state unexpectedly aggregated" >&2
    exit 1
fi
if ! rg -Fq "maximum-toggle resize-state latest segment proof is wrong" \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-state.err"; then
    echo "RealAppHarnessTests: sidebar resize-state aggregate error was not precise" >&2
    exit 1
fi
phase_root="$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases/maximum-toggle"
python3 "$ROOT/scripts/e2e/verify-sidebar-resize-phase.py" \
    --phase maximum-toggle \
    --session "$phase_root/session.json" \
    --diagnostic "$phase_root/diagnostic.json" \
    --pointer-trace "$phase_root/pointer-trace.json" \
    --output "$phase_root/resize-state.json"

python3 - "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "maximum-toggle" / "foreground-report.json"
report = json.loads(path.read_text(encoding="utf-8"))
report["pointerRestore"]["restored"] = False
path.write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/aggregate-foreground-sidebar-layout.py" \
    --phase-root "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/phases" \
    --output-validation "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-validation.json" \
    --output-report "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-report.json" \
    --budget-ms 4000 \
    > "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-aggregate.out" \
    2> "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-aggregate.err"; then
    echo "RealAppHarnessTests: unrestored sidebar phase unexpectedly aggregated" >&2
    exit 1
fi
if ! rg -Fq "maximum-toggle did not restore pointer" \
    "$FOREGROUND_SIDEBAR_LAYOUT_ROOT/invalid-aggregate.err"; then
    echo "RealAppHarnessTests: sidebar aggregate error was not precise" >&2
    exit 1
fi

FOREGROUND_TAB_SESSION_ROOT="$TEMP_ROOT/foreground-tab-session-plans"
mkdir -p "$FOREGROUND_TAB_SESSION_ROOT/raw"
python3 - "$FOREGROUND_TAB_SESSION_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
fixture_id = "11111111-1111-4111-8111-111111111111"
first_id = "22222222-2222-4222-8222-222222222222"
second_id = "33333333-3333-4333-8333-333333333333"


def tab(identifier, name, text):
    return {"id": identifier, "name": name, "text": text}


fixture = tab(fixture_id, "格式示例.md", "fixture")
first = tab(first_id, "未命名.md", "E2E_SWITCH_COMMIT")
second_source = "E2E_RIGHT_NEIGHBOR<br><br><br>" * 8
second = tab(second_id, "未命名 2.md", second_source)
sessions = {
    "switch-commit": {
        "activeTabID": fixture_id,
        "tabs": [fixture],
    },
    "close-right-reopen": {
        "activeTabID": first_id,
        "tabs": [fixture, first],
    },
    "close-left-seed": {
        "activeTabID": first_id,
        "tabs": [fixture, second, first],
    },
    "seed-layout": {
        "activeTabID": first_id,
        "tabs": [fixture, second, first],
    },
    "relaunch-scroll-check": {
        "activeTabID": second_id,
        "tabs": [fixture, second],
        "fontIndex": 2,
        "sidebarWidth": 312,
        "sidebarOpen": False,
        "expandedFolderPaths": [],
    },
}
for phase, session in sessions.items():
    (root / f"{phase}-session.json").write_text(
        json.dumps(session, ensure_ascii=False),
        encoding="utf-8",
    )
PY

for tab_phase in \
    switch-commit \
    close-right-reopen \
    close-left-seed \
    seed-layout \
    relaunch-scroll-check; do
    python3 "$ROOT/scripts/e2e/build-foreground-tab-session-plan.py" \
        --phase "$tab_phase" \
        --session "$FOREGROUND_TAB_SESSION_ROOT/$tab_phase-session.json" \
        --raw-dir "$FOREGROUND_TAB_SESSION_ROOT/raw" \
        --output "$FOREGROUND_TAB_SESSION_ROOT/$tab_phase-plan.json"
    "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$FOREGROUND_TAB_SESSION_ROOT/$tab_phase-plan.json" \
        --budget 4 \
        > "$FOREGROUND_TAB_SESSION_ROOT/$tab_phase-validation.json"
done

python3 - "$FOREGROUND_TAB_SESSION_ROOT" <<'PY'
import copy
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
second_source = "E2E_RIGHT_NEIGHBOR<br><br><br>" * 8
assert len(second_source) == 240
expected = {
    "switch-commit": {
        "count": 11,
        "estimated": 1640,
        "screenshots": [
            "tab-switch-fixture.png",
            "tab-switch-draft-restored.png",
        ],
        "values": ["", "E2E_SWITCH_COMMIT"],
        "selected": [],
    },
    "close-right-reopen": {
        "count": 18,
        "estimated": 2690,
        "screenshots": [
            "tab-close-right-confirm.png",
            "tab-close-right-neighbor.png",
            "tab-close-right-reopened.png",
        ],
        "values": [""],
        "selected": [True, True],
    },
    "close-left-seed": {
        "count": 14,
        "estimated": 2000,
        "screenshots": [
            "tab-close-left-confirm.png",
            "tab-close-left-neighbor.png",
        ],
        "values": [
            "# Markdown 全格式示例",
            "# Markdown 全格式示例",
        ],
        "selected": [True],
    },
    "seed-layout": {
        "count": 12,
        "estimated": 1660,
        "screenshots": ["tab-session-relaunch-seed.png"],
        "values": ["Markdown 全格式示例 E2ERELAUNCHUNSAVED"],
        "selected": [True],
    },
    "relaunch-scroll-check": {
        "count": 12,
        "estimated": 1880,
        "screenshots": ["tab-session-restored-scroll.png"],
        "values": [],
        "selected": [True, True],
    },
}
plans = {}
for phase, wanted in expected.items():
    plan = json.loads((root / f"{phase}-plan.json").read_text(encoding="utf-8"))
    validation = json.loads(
        (root / f"{phase}-validation.json").read_text(encoding="utf-8")
    )
    plans[phase] = plan
    actions = plan["actions"]
    assert plan["schemaVersion"] == 1
    assert len(actions) == wanted["count"]
    assert actions[0] == {"kind": "move-safe-point", "waitMs": 40}
    assert [
        pathlib.Path(action["path"]).name
        for action in actions
        if action["kind"] == "window-screenshot"
    ] == wanted["screenshots"]
    assert [
        action["expectedValue"]
        for action in actions
        if "expectedValue" in action
    ] == wanted["values"]
    assert [
        action["expectedSelected"]
        for action in actions
        if "expectedSelected" in action
    ] == wanted["selected"]
    assert validation["valid"] is True
    assert validation["budgetMs"] == 4000
    assert validation["estimatedForegroundMs"] == wanted["estimated"]
    assert validation["cleanupReserveMs"] == 400
    assert validation["estimatedForegroundMs"] + 400 <= 4000

right = plans["close-right-reopen"]["actions"]
first_id = "22222222-2222-4222-8222-222222222222"
assert [action.get("text") for action in right if action["kind"] == "text"] == [
    second_source,
]
assert [action.get("key") for action in right if action["kind"] == "key"] == [
    "command+n",
    "escape",
    "command+shift+t",
]
assert [action.get("deltaY") for action in right if action["kind"] == "scroll"] == [
    -800,
]
assert [
    (action["kind"], action.get("identifier"))
    for action in right
    if action["kind"].startswith("element-")
] == [
    ("element-click", f"tab-{first_id}"),
    ("element-click", f"tab-close-{first_id}"),
    ("element-check", f"tab-confirm-close-{first_id}"),
    ("element-click", f"tab-confirm-close-{first_id}"),
    ("element-description-check", None),
    ("element-check", "document-block-0-paragraph"),
    ("element-check", f"tab-{first_id}"),
]
dynamic_second_tab = next(
    action for action in right
    if action["kind"] == "element-description-check"
)
assert dynamic_second_tab == {
    "kind": "element-description-check",
    "description": "未命名 2.md",
    "role": "AXButton",
    "waitMs": 40,
    "expectedSelected": True,
}
assert [
    action.get("key")
    for action in plans["close-left-seed"]["actions"]
    if action["kind"] == "key"
] == [
    "command+w",
    "command+w",
    "escape",
]
assert [
    action.get("key")
    for action in plans["seed-layout"]["actions"]
    if action["kind"] == "key"
] == [
    "command+shift+equals",
    "command+backslash",
]
assert [
    (action["kind"], action.get("identifier"), action.get("deltaX"))
    for action in plans["close-left-seed"]["actions"]
    if action["kind"] in {"element-drag", "element-check"}
] == [
    (
        "element-check",
        "tab-confirm-close-22222222-2222-4222-8222-222222222222",
        None,
    ),
    (
        "element-check",
        "tab-33333333-3333-4333-8333-333333333333",
        None,
    ),
    ("element-check", "document-block-0-paragraph", None),
    ("element-check", "document-block-0-source-editor", None),
]
seed_layout = plans["seed-layout"]["actions"]
assert seed_layout[1] == {
    "kind": "element-check",
    "identifier": "tab-11111111-1111-4111-8111-111111111111",
    "role": "AXButton",
    "waitMs": 40,
    "expectedSelected": True,
}
assert seed_layout[2] == {
    "kind": "element-check",
    "identifier": "document-block-0-heading",
    "role": "AXButton",
    "waitMs": 40,
    "expectedValue": "Markdown 全格式示例 E2ERELAUNCHUNSAVED",
}
assert [action["kind"] for action in seed_layout[3:]] == [
    "scroll",
    "scroll",
    "wait",
    "key",
    "element-click",
    "element-drag",
    "key",
    "element-click",
    "window-screenshot",
]
assert [
    (action["kind"], action.get("identifier"), action.get("deltaX"))
    for action in seed_layout
    if action["kind"] in {"element-drag", "element-check"}
] == [
    (
        "element-check",
        "tab-11111111-1111-4111-8111-111111111111",
        None,
    ),
    ("element-check", "document-block-0-heading", None),
    ("element-drag", "sidebar-resize-handle", 96),
]
assert [
    (action["kind"], action.get("identifier"), action.get("expectedSelected"))
    for action in plans["relaunch-scroll-check"]["actions"]
    if action["kind"].startswith("element-")
] == [
    (
        "element-check",
        "tab-33333333-3333-4333-8333-333333333333",
        True,
    ),
    (
        "element-check",
        "tab-11111111-1111-4111-8111-111111111111",
        None,
    ),
    ("element-check", "document-block-0-paragraph", None),
    ("element-check", "sidebar-surface", None),
    ("element-click", "sidebar-folder-docs", None),
    (
        "element-click",
        "sidebar-file-docs%2F%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd",
        None,
    ),
    (
        "element-check",
        "tab-11111111-1111-4111-8111-111111111111",
        True,
    ),
]

invalid_selected = copy.deepcopy(plans["close-right-reopen"])
next(
    action for action in invalid_selected["actions"]
    if "expectedSelected" in action
)["expectedSelected"] = 1
(root / "invalid-expected-selected.json").write_text(
    json.dumps(invalid_selected, ensure_ascii=False),
    encoding="utf-8",
)

invalid_value = copy.deepcopy(plans["switch-commit"])
next(
    action for action in invalid_value["actions"]
    if "expectedValue" in action
)["expectedValue"] = 17
(root / "invalid-expected-value.json").write_text(
    json.dumps(invalid_value, ensure_ascii=False),
    encoding="utf-8",
)

oversized_value = copy.deepcopy(plans["switch-commit"])
next(
    action for action in oversized_value["actions"]
    if "expectedValue" in action
)["expectedValue"] = "x" * 4097
(root / "oversized-expected-value.json").write_text(
    json.dumps(oversized_value, ensure_ascii=False),
    encoding="utf-8",
)
PY

for invalid_ax_case in \
    invalid-expected-selected \
    invalid-expected-value \
    oversized-expected-value; do
    if "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$FOREGROUND_TAB_SESSION_ROOT/$invalid_ax_case.json" \
        --budget 4 \
        > "$FOREGROUND_TAB_SESSION_ROOT/$invalid_ax_case.out" \
        2> "$FOREGROUND_TAB_SESSION_ROOT/$invalid_ax_case.err"; then
        echo "RealAppHarnessTests: invalid exact AX assertion succeeded: $invalid_ax_case" >&2
        exit 1
    fi
done
if ! rg -Fq "expectedSelected requires a boolean" \
    "$FOREGROUND_TAB_SESSION_ROOT/invalid-expected-selected.err"; then
    echo "RealAppHarnessTests: expectedSelected type error was not precise" >&2
    exit 1
fi
for invalid_value_case in invalid-expected-value oversized-expected-value; do
    if ! rg -Fq "expectedValue requires at most 4096 UTF-16 code units" \
        "$FOREGROUND_TAB_SESSION_ROOT/$invalid_value_case.err"; then
        echo "RealAppHarnessTests: expectedValue error was not precise: $invalid_value_case" >&2
        exit 1
    fi
done

FOREGROUND_TABLE_ROOT="$TEMP_ROOT/foreground-table-plan"
mkdir -p "$FOREGROUND_TABLE_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-table-plan.py" \
    --raw-dir "$FOREGROUND_TABLE_ROOT/raw" \
    --output "$FOREGROUND_TABLE_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_TABLE_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_TABLE_ROOT/validation.json"
python3 - \
    "$FOREGROUND_TABLE_ROOT/plan.json" \
    "$FOREGROUND_TABLE_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
element_actions = [
    action for action in actions
    if action["kind"] in {"element-move", "element-click"}
]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 18
assert actions[2] == {
    "kind": "element-move",
    "identifier": "document-block-28-table-row-0-column-0",
    "role": "AXButton",
    "waitMs": 80,
}
assert actions[4] == {
    "kind": "element-click",
    "identifier": "document-block-28-table-row-0-column-0",
    "role": "AXButton",
    "waitMs": 80,
}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "command+a", "tab", "escape",
]
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "E2E_TABLE",
]
assert [action["identifier"] for action in element_actions].count(
    "table-cycle-alignment"
) == 3
assert {action["identifier"] for action in element_actions} >= {
    "table-add-row",
    "table-delete-row",
    "table-add-column",
    "table-delete-column",
}
assert all(action.get("role") == "AXButton" for action in element_actions)
assert screenshots == [
    "table-reading-rest.png",
    "table-reading-hover.png",
    "table-controls-final.png",
    "table-committed.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 3220
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3650
assert 'FOREGROUND_BATCH_NAME="table-controls"' not in runner
assert 'if [[ "$FOREGROUND_BATCH_NAME" == "table-controls" ]]' in runner
launch_branch = runner.split(
    'if [[ "$FOREGROUND_BATCH_NAME" == "table-controls" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 2326" in launch_branch
assert 'table-controls) run_foreground_table_controls' in runner
assert 'frozenset({"baseline", "table-reading-rest"})' in runner
assert runner.count(
    '"visualCoverageApplicable": interaction_tier == "passive"'
) == 3
assert '"interactionCoverage": {' in runner
assert '"allPlannedActionsCompleted"' in runner
assert '"plannedActionCount"' in runner
assert '"completedActionCount"' in runner
PY

FOREGROUND_TABLE_NAVIGATION_ROOT="$TEMP_ROOT/foreground-table-navigation-plan"
mkdir -p "$FOREGROUND_TABLE_NAVIGATION_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-table-navigation-plan.py" \
    --raw-dir "$FOREGROUND_TABLE_NAVIGATION_ROOT/raw" \
    --output "$FOREGROUND_TABLE_NAVIGATION_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_TABLE_NAVIGATION_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_TABLE_NAVIGATION_ROOT/validation.json"
python3 - \
    "$FOREGROUND_TABLE_NAVIGATION_ROOT/plan.json" \
    "$FOREGROUND_TABLE_NAVIGATION_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
focused = [
    action["identifier"]
    for action in actions
    if action["kind"] == "focused-element-check"
]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 24
assert actions[1] == {
    "kind": "element-click",
    "identifier": "document-block-28-table-row-0-column-0",
    "role": "AXButton",
    "waitMs": 80,
}
assert focused == [
    "table-cell-0-0",
    "table-cell-0-1",
    "table-cell-0-0",
    "table-cell-1-0",
    "table-cell-3-2",
    "table-cell-4-0",
]
keys = [action.get("key") for action in actions if action["kind"] == "key"]
assert keys[:3] == ["tab", "shift+tab", "return"]
assert keys.count("tab") == 10
assert keys[-1] == "escape"
assert screenshots == [
    "table-navigation-last.png",
    "table-navigation-auto-row.png",
    "table-navigation-committed.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2560
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3000
assert 'elif [[ "$FOREGROUND_BATCH_NAME" == "table-navigation" ]]' in runner
launch_branch = runner.split(
    'elif [[ "$FOREGROUND_BATCH_NAME" == "table-navigation" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 2326" in launch_branch
assert 'table-navigation) run_foreground_table_navigation' in runner
assert '"focused-element-check"' in runner
PY

FOREGROUND_EDITOR_ROOT="$TEMP_ROOT/foreground-editor-plan"
mkdir -p "$FOREGROUND_EDITOR_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-editor-plan.py" \
    --raw-dir "$FOREGROUND_EDITOR_ROOT/raw" \
    --output "$FOREGROUND_EDITOR_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_EDITOR_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_EDITOR_ROOT/validation.json"
python3 - \
    "$FOREGROUND_EDITOR_ROOT/plan.json" \
    "$FOREGROUND_EDITOR_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 19
assert actions[1] == {
    "kind": "element-click",
    "identifier": "document-block-12-quote",
    "waitMs": 80,
}
assert actions[6] == {
    "kind": "element-click",
    "identifier": "document-block-15-list",
    "waitMs": 80,
}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "return",
    "escape",
    "return",
    "tab",
    "shift+tab",
    "command+b",
    "escape",
    "command+z",
    "command+shift+z",
]
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "E2E_QUOTE", "E2E_LIST ", "BOLD",
]
assert screenshots == [
    "quote-source-edited.png",
    "list-source-edited.png",
    "list-undone.png",
    "editor-structure-final.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 2630
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 3050
assert 'elif [[ "$FOREGROUND_BATCH_NAME" == "editor-structure" ]]' in runner
launch_branch = runner.split(
    'elif [[ "$FOREGROUND_BATCH_NAME" == "editor-structure" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 650" in launch_branch
assert 'editor-structure) run_foreground_editor_structure' in runner
PY

FOREGROUND_EDITOR_BOUNDARIES_ROOT="$TEMP_ROOT/foreground-editor-boundaries-plan"
mkdir -p "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/raw"
python3 "$ROOT/scripts/e2e/build-foreground-editor-boundaries-plan.py" \
    --raw-dir "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/raw" \
    --output "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/plan.json"
"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/plan.json" \
    --budget 4 \
    > "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/validation.json"
python3 - \
    "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/plan.json" \
    "$FOREGROUND_EDITOR_BOUNDARIES_ROOT/validation.json" \
    "$ROOT/scripts/e2e/run-real-app-e2e.sh" \
    "$ROOT/ui/格式示例.md" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
validation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
runner = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
fixture = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
actions = plan["actions"]
screenshots = [
    pathlib.Path(action["path"]).name
    for action in actions
    if action["kind"] == "window-screenshot"
]
assert plan["schemaVersion"] == 1
assert len(actions) == 14
assert actions[1] == {
    "kind": "element-click",
    "identifier": "document-block-10-paragraph",
    "waitMs": 80,
}
assert [action.get("key") for action in actions if action["kind"] == "key"] == [
    "down",
    "command+i",
    "up",
    "command+e",
    "down",
    "backspace",
    "escape",
]
assert [action.get("text") for action in actions if action["kind"] == "text"] == [
    "E2E_ITALIC", "E2E_CODE",
]
assert screenshots == [
    "boundary-next-italic.png",
    "boundary-previous-code.png",
    "boundary-merged.png",
]
assert validation["valid"] is True
assert validation["budgetMs"] == 4000
assert validation["estimatedForegroundMs"] == 1940
assert validation["cleanupReserveMs"] == 400
assert validation["estimatedForegroundMs"] + validation["cleanupReserveMs"] < 2350
assert 'elif [[ "$FOREGROUND_BATCH_NAME" == "editor-boundaries" ]]' in runner
launch_branch = runner.split(
    'elif [[ "$FOREGROUND_BATCH_NAME" == "editor-boundaries" ]]',
    1,
)[1].split("fi", 1)[0]
assert "--visual-test-state default" in launch_branch
assert "--visual-test-scroll 500" in launch_branch
assert 'editor-boundaries) run_foreground_editor_boundaries' in runner
p10 = (
    "正文里可以有 **加粗**、*斜体*、***粗斜体***、~~删除线~~、<u>下划线</u>，"
    "以及行内代码 `const answer = 42`。还支持上标 x<sup>2</sup>、下标 "
    "H<sub>2</sub>O，和 emoji 😀 🎉 ✅。"
)
p11 = (
    "转义与边界：带空格的星号不会被误当作强调 \u2014\u2014 2 * 3 = 6、4 * 5 = 20；"
    "需要字面标记时用反斜杠转义，如 \\*星号\\*、\\_下划线\\_、\\`反引号\\`。"
)
assert fixture.count(p10 + "\n\n" + p11) == 1
PY

"$TEMP_ROOT/RealAppDriver" preflight > "$TEMP_ROOT/preflight.json"
python3 - "$TEMP_ROOT/preflight.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
expected = {
    "accessibilityTrusted", "listenEventAccess", "postEventAccess",
    "screenCaptureAccess", "sessionLocked",
}
if set(report) != expected:
    raise SystemExit(f"unexpected preflight keys: {sorted(report)}")
if not all(isinstance(report[key], bool) for key in expected):
    raise SystemExit("preflight values must be booleans")
PY

"$TEMP_ROOT/RealAppDriver" desktop-state > "$TEMP_ROOT/desktop-state.json"
python3 - "$TEMP_ROOT/desktop-state.json" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
if not set(report).issubset({"frontmostPID", "pointer"}) or "pointer" not in report:
    raise SystemExit(f"unexpected desktop-state keys: {sorted(report)}")
if "frontmostPID" in report and not isinstance(report["frontmostPID"], int):
    raise SystemExit("frontmostPID must be an integer when present")
if set(report["pointer"]) != {"x", "y"}:
    raise SystemExit("desktop pointer must contain x and y")
if not all(
    isinstance(report["pointer"][axis], (int, float))
    and math.isfinite(report["pointer"][axis])
    for axis in ("x", "y")
):
    raise SystemExit("desktop pointer coordinates must be finite numbers")
PY

OBSERVER_ROOT="$TEMP_ROOT/frontmost-observer"
mkdir -p "$OBSERVER_ROOT"
for invalid_case in missing timeout relative collision; do
    case "$invalid_case" in
        missing)
            observer_arguments=(
                --target-pid-file "$OBSERVER_ROOT/missing-target.pid"
                --ready-file "$OBSERVER_ROOT/missing-ready.json"
                --stop-file "$OBSERVER_ROOT/missing-stop"
            )
            expected_error="requires --target-pid-file"
            ;;
        timeout)
            observer_arguments=(
                --target-pid-file "$OBSERVER_ROOT/timeout-target.pid"
                --ready-file "$OBSERVER_ROOT/timeout-ready.json"
                --stop-file "$OBSERVER_ROOT/timeout-stop"
                --timeout 0.5
            )
            expected_error="from 1 through 300 seconds"
            ;;
        relative)
            observer_arguments=(
                --target-pid-file "$OBSERVER_ROOT/relative-target.pid"
                --ready-file "relative-ready.json"
                --stop-file "$OBSERVER_ROOT/relative-stop"
                --timeout 5
            )
            expected_error="--ready-file requires an absolute path"
            ;;
        collision)
            observer_arguments=(
                --target-pid-file "$OBSERVER_ROOT/collision-control"
                --ready-file "$OBSERVER_ROOT/collision-control"
                --stop-file "$OBSERVER_ROOT/collision-stop"
                --timeout 5
            )
            expected_error="control file paths must be distinct"
            ;;
    esac
    if "$TEMP_ROOT/RealAppDriver" observe-frontmost \
        "${observer_arguments[@]}" \
        > "$OBSERVER_ROOT/$invalid_case.out" \
        2> "$OBSERVER_ROOT/$invalid_case.err"; then
        echo "RealAppHarnessTests: invalid frontmost observer unexpectedly succeeded: $invalid_case" >&2
        exit 1
    fi
    if ! rg -q -- "$expected_error" "$OBSERVER_ROOT/$invalid_case.err"; then
        echo "RealAppHarnessTests: frontmost observer error was not precise: $invalid_case" >&2
        exit 1
    fi
done

OBSERVER_TARGET="$OBSERVER_ROOT/target.pid"
OBSERVER_READY="$OBSERVER_ROOT/ready.json"
OBSERVER_STOP="$OBSERVER_ROOT/stop"
OBSERVER_REPORT="$OBSERVER_ROOT/report.json"
OBSERVER_ERROR="$OBSERVER_ROOT/observer.err"
"$TEMP_ROOT/RealAppDriver" observe-frontmost \
    --target-pid-file "$OBSERVER_TARGET" \
    --ready-file "$OBSERVER_READY" \
    --stop-file "$OBSERVER_STOP" \
    --timeout 5 \
    > "$OBSERVER_REPORT" \
    2> "$OBSERVER_ERROR" &
OBSERVER_PID="$!"
for _ in {1..80}; do
    [[ -s "$OBSERVER_READY" ]] && break
    if ! kill -0 "$OBSERVER_PID" 2>/dev/null; then
        echo "RealAppHarnessTests: frontmost observer exited before ready" >&2
        cat "$OBSERVER_ERROR" >&2
        exit 1
    fi
    sleep 0.025
done
if [[ ! -s "$OBSERVER_READY" ]]; then
    echo "RealAppHarnessTests: frontmost observer did not publish ready" >&2
    exit 1
fi
printf '2147483647\n' > "$OBSERVER_TARGET.tmp"
mv "$OBSERVER_TARGET.tmp" "$OBSERVER_TARGET"
sleep 0.12
: > "$OBSERVER_STOP.tmp"
mv "$OBSERVER_STOP.tmp" "$OBSERVER_STOP"
if wait "$OBSERVER_PID"; then
    OBSERVER_PID=""
else
    observer_status="$?"
    OBSERVER_PID=""
    echo "RealAppHarnessTests: frontmost observer failed with $observer_status" >&2
    cat "$OBSERVER_ERROR" >&2
    exit 1
fi
python3 - "$OBSERVER_READY" "$OBSERVER_REPORT" <<'PY'
import json
import pathlib
import sys

ready = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert ready["schemaVersion"] == 1
assert ready["notificationObserverRegistered"] is True
assert ready["sampleIntervalMs"] == 25
assert report["schemaVersion"] == 1
assert report["observerPID"] == ready["observerPID"]
assert report["notificationObserverRegistered"] is True
assert report["readyFileCreated"] is True
assert report["stopFileObserved"] is True
assert report["timedOut"] is False
assert report["targetPID"] == 2147483647
assert isinstance(report["targetPIDLoadedAtMs"], int)
assert report["targetBecameFrontmost"] is False
assert report.get("firstTargetFrontmostObservation") is None
assert report["sampleIntervalMs"] == 25
assert report["sampleCount"] >= 2
assert report["durationMs"] >= report["targetPIDLoadedAtMs"]
assert report["transitions"][0]["source"] == "initial"
assert report["transitions"][-1]["source"] == "stop"
assert not any(
    item.get("frontmostPID") == 2147483647
    for item in report["transitions"]
)
PY

cp "$TEMP_ROOT/desktop-state.json" "$OBSERVER_ROOT/lifecycle-before.json"
cp "$TEMP_ROOT/desktop-state.json" "$OBSERVER_ROOT/lifecycle-after.json"
python3 "$ROOT/scripts/e2e/verify-passive-lifecycle.py" \
    --before "$OBSERVER_ROOT/lifecycle-before.json" \
    --after "$OBSERVER_ROOT/lifecycle-after.json" \
    --ready "$OBSERVER_READY" \
    --observer "$OBSERVER_REPORT" \
    --target-pid 2147483647 \
    --output "$OBSERVER_ROOT/lifecycle-passed.json"
python3 - "$OBSERVER_ROOT/lifecycle-passed.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["targetPID"] == 2147483647
assert record["targetNeverFrontmost"] is True
assert record["pointerUnchanged"] is True
assert record["endpointObservations"]["pointerChangedBetweenEndpoints"] is False
PY
python3 - "$OBSERVER_ROOT/lifecycle-after.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text(encoding="utf-8"))
record["pointer"]["x"] += 1
path.write_text(json.dumps(record), encoding="utf-8")
PY
if python3 "$ROOT/scripts/e2e/verify-passive-lifecycle.py" \
    --before "$OBSERVER_ROOT/lifecycle-before.json" \
    --after "$OBSERVER_ROOT/lifecycle-after.json" \
    --ready "$OBSERVER_READY" \
    --observer "$OBSERVER_REPORT" \
    --target-pid 2147483647 \
    --output "$OBSERVER_ROOT/lifecycle-pointer-moved.json" \
    > "$OBSERVER_ROOT/lifecycle-pointer-moved.out" \
    2> "$OBSERVER_ROOT/lifecycle-pointer-moved.err"; then
    echo "RealAppHarnessTests: changed passive pointer unexpectedly passed" >&2
    exit 1
fi
if ! rg -q "passive tier changed the pointer position" \
    "$OBSERVER_ROOT/lifecycle-pointer-moved.err"; then
    echo "RealAppHarnessTests: changed passive pointer error was not precise" >&2
    exit 1
fi

FRONTMOST_PID="$(python3 - "$TEMP_ROOT/desktop-state.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["frontmostPID"])
PY
)"
ACTIVE_TARGET="$OBSERVER_ROOT/active-target.pid"
ACTIVE_READY="$OBSERVER_ROOT/active-ready.json"
ACTIVE_STOP="$OBSERVER_ROOT/active-stop"
ACTIVE_REPORT="$OBSERVER_ROOT/active-report.json"
"$TEMP_ROOT/RealAppDriver" observe-frontmost \
    --target-pid-file "$ACTIVE_TARGET" \
    --ready-file "$ACTIVE_READY" \
    --stop-file "$ACTIVE_STOP" \
    --timeout 5 \
    > "$ACTIVE_REPORT" \
    2> "$OBSERVER_ROOT/active-observer.err" &
OBSERVER_PID="$!"
for _ in {1..80}; do
    [[ -s "$ACTIVE_READY" ]] && break
    if ! kill -0 "$OBSERVER_PID" 2>/dev/null; then
        echo "RealAppHarnessTests: active-target observer exited before ready" >&2
        exit 1
    fi
    sleep 0.025
done
printf '%s\n' "$FRONTMOST_PID" > "$ACTIVE_TARGET.tmp"
mv "$ACTIVE_TARGET.tmp" "$ACTIVE_TARGET"
sleep 0.08
: > "$ACTIVE_STOP.tmp"
mv "$ACTIVE_STOP.tmp" "$ACTIVE_STOP"
wait "$OBSERVER_PID"
OBSERVER_PID=""
python3 - "$ACTIVE_REPORT" "$FRONTMOST_PID" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
target_pid = int(sys.argv[2])
assert report["targetPID"] == target_pid
assert report["targetBecameFrontmost"] is True
assert report["firstTargetFrontmostObservation"]["frontmostPID"] == target_pid
assert any(item.get("frontmostPID") == target_pid for item in report["transitions"])
PY

python3 - "$TEMP_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
valid = {
    "schemaVersion": 1,
    "actions": [
        {"kind": "move-safe-point"},
        {"kind": "move-outline", "waitMs": 80},
        {"kind": "window-move", "xFraction": 0.4, "yFraction": 0.2},
        {"kind": "window-click", "xFraction": 0.5, "yFraction": 0.3},
        {
            "kind": "element-move",
            "identifier": "fixture-shared-control",
            "role": "AXButton",
        },
        {
            "kind": "element-click",
            "identifier": "fixture-shared-control",
            "xFraction": 0.25,
            "yFraction": 0.75,
        },
        {
            "kind": "element-check",
            "identifier": "fixture-state-surface",
            "role": "AXGroup",
        },
        {
            "kind": "element-description-check",
            "description": "Dynamic document tab",
            "role": "AXButton",
            "expectedSelected": True,
        },
        {
            "kind": "element-drag",
            "identifier": "fixture-drag-handle",
            "deltaX": -120,
        },
        {
            "kind": "focused-element-check",
            "identifier": "fixture-focused-control",
            "role": "AXTextField",
        },
        {"kind": "scroll", "deltaY": -650},
        {"kind": "shift-tap", "waitMs": 40},
        {"kind": "key", "key": "command+f"},
        {"kind": "text", "text": "red", "waitMs": 40},
        {
            "kind": "pasteboard-string-check",
            "text": "expected clipboard value",
            "waitMs": 40,
        },
        {"kind": "find-control-click", "control": "query-field"},
        {"kind": "wait", "durationMs": 120},
        {"kind": "window-screenshot", "path": str(root / "batch-checkpoint.png")},
    ],
}
(root / "foreground-valid.json").write_text(
    json.dumps(valid, ensure_ascii=False),
    encoding="utf-8",
)

unknown_field = json.loads(json.dumps(valid))
unknown_field["actions"][2]["unexpected"] = True
(root / "foreground-unknown-field.json").write_text(
    json.dumps(unknown_field),
    encoding="utf-8",
)

bad_wait = json.loads(json.dumps(valid))
bad_wait["actions"][0]["waitMs"] = 39
(root / "foreground-bad-wait.json").write_text(
    json.dumps(bad_wait),
    encoding="utf-8",
)

bad_fraction = json.loads(json.dumps(valid))
bad_fraction["actions"][2]["xFraction"] = 1.01
(root / "foreground-bad-fraction.json").write_text(
    json.dumps(bad_fraction),
    encoding="utf-8",
)

invalid_plans = {
    "foreground-missing-identifier.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "element-move"}],
    },
    "foreground-empty-identifier.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "element-click", "identifier": "  "}],
    },
    "foreground-empty-role.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-move",
            "identifier": "fixture-control",
            "role": "",
        }],
    },
    "foreground-description-missing.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "element-description-check"}],
    },
    "foreground-description-empty.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-description-check",
            "description": "  ",
        }],
    },
    "foreground-selector-unknown-field.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "identifierPrefix": "fixture",
        }],
    },
    "foreground-element-click-missing-y-fraction.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "xFraction": 0.25,
        }],
    },
    "foreground-element-click-missing-x-fraction.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "yFraction": 0.75,
        }],
    },
    "foreground-element-click-bad-x-fraction.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "xFraction": -0.01,
            "yFraction": 0.75,
        }],
    },
    "foreground-element-click-bad-y-fraction.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "xFraction": 0.25,
            "yFraction": 1.01,
        }],
    },
    "foreground-element-click-nonnumeric-x-fraction.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-click",
            "identifier": "fixture-control",
            "xFraction": "left",
            "yFraction": 0.75,
        }],
    },
    "foreground-focused-missing-identifier.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "focused-element-check"}],
    },
    "foreground-check-missing-identifier.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "element-check"}],
    },
    "foreground-drag-zero-delta.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "element-drag", "identifier": "fixture-handle"}],
    },
    "foreground-drag-large-delta.json": {
        "schemaVersion": 1,
        "actions": [{
            "kind": "element-drag",
            "identifier": "fixture-handle",
            "deltaX": 2001,
        }],
    },
    "foreground-empty-pasteboard.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "pasteboard-string-check", "text": ""}],
    },
    "foreground-zero-scroll.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "scroll", "deltaY": 0}],
    },
    "foreground-large-scroll.json": {
        "schemaVersion": 1,
        "actions": [{"kind": "scroll", "deltaY": 2001}],
    },
}
for name, plan in invalid_plans.items():
    (root / name).write_text(json.dumps(plan), encoding="utf-8")

too_long = {
    "schemaVersion": 1,
    "actions": [{"kind": "wait", "durationMs": 400} for _ in range(64)],
}
(root / "foreground-too-long.json").write_text(
    json.dumps(too_long),
    encoding="utf-8",
)
PY

"$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
    --plan "$TEMP_ROOT/foreground-valid.json" \
    --budget 3 \
    > "$TEMP_ROOT/foreground-plan.json"
python3 - "$TEMP_ROOT/foreground-plan.json" "$TEMP_ROOT/batch-checkpoint.png" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["valid"] is True
assert report["budgetMs"] == 3000
assert report["cleanupReserveMs"] == 400
assert 0 < report["estimatedForegroundMs"] < 2300
assert [action["kind"] for action in report["actions"]] == [
    "move-safe-point",
    "move-outline",
    "window-move",
    "window-click",
    "element-move",
    "element-click",
    "element-check",
    "element-description-check",
    "element-drag",
    "focused-element-check",
    "scroll",
    "shift-tap",
    "key",
    "text",
    "pasteboard-string-check",
    "find-control-click",
    "wait",
    "window-screenshot",
]
assert report["actions"][1]["waitMs"] == 80
assert report["actions"][2]["detail"] == "0.4000,0.2000"
assert report["actions"][3]["detail"] == "0.5000,0.3000"
assert report["actions"][4]["detail"] == (
    "identifier=fixture-shared-control,role=AXButton"
)
assert report["actions"][5]["detail"] == (
    "identifier=fixture-shared-control,xFraction=0.2500,yFraction=0.7500"
)
assert report["actions"][6]["detail"] == (
    "identifier=fixture-state-surface,role=AXGroup"
)
assert report["actions"][7]["detail"] == (
    "description=Dynamic document tab,role=AXButton,expectedSelected=true"
)
assert report["actions"][8]["detail"] == (
    "identifier=fixture-drag-handle,deltaX=-120,deltaY=0"
)
assert report["actions"][9]["detail"] == (
    "identifier=fixture-focused-control,role=AXTextField"
)
assert report["actions"][10]["detail"] == "-650 pixels"
assert report["actions"][14]["detail"] == (
    "exact string with 24 UTF-16 code units"
)
assert report["actions"][16]["durationMs"] == 120
if pathlib.Path(sys.argv[2]).exists():
    raise SystemExit("foreground plan validation unexpectedly captured a screenshot")
PY

for invalid_case in \
    "foreground-unknown-field.json:unknown fields" \
    "foreground-bad-wait.json:waitMs must be from 40 through 80" \
    "foreground-bad-fraction.json:xFraction must be from 0 through 1" \
    "foreground-missing-identifier.json:missing fields" \
    "foreground-empty-identifier.json:identifier requires 1 through 256" \
    "foreground-empty-role.json:role requires 1 through 128" \
    "foreground-description-missing.json:missing fields" \
    "foreground-description-empty.json:description requires 1 through 256" \
    "foreground-selector-unknown-field.json:unknown fields" \
    "foreground-element-click-missing-y-fraction.json:element-click requires xFraction and yFraction together" \
    "foreground-element-click-missing-x-fraction.json:element-click requires xFraction and yFraction together" \
    "foreground-element-click-bad-x-fraction.json:element-click fractions must be from 0 through 1" \
    "foreground-element-click-bad-y-fraction.json:element-click fractions must be from 0 through 1" \
    "foreground-element-click-nonnumeric-x-fraction.json:xFraction requires a finite number" \
    "foreground-focused-missing-identifier.json:missing fields" \
    "foreground-check-missing-identifier.json:missing fields" \
    "foreground-drag-zero-delta.json:requires a nonzero deltaX or deltaY" \
    "foreground-drag-large-delta.json:requires a nonzero deltaX or deltaY" \
    "foreground-empty-pasteboard.json:text requires 1 through 4096" \
    "foreground-zero-scroll.json:deltaY must be a nonzero integer" \
    "foreground-large-scroll.json:deltaY must be a nonzero integer" \
    "foreground-too-long.json:exceeding the 2000 ms budget"; do
    plan_file="${invalid_case%%:*}"
    expected_error="${invalid_case#*:}"
    if "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$TEMP_ROOT/$plan_file" \
        --budget 2 \
        > "$TEMP_ROOT/$plan_file.out" \
        2> "$TEMP_ROOT/$plan_file.err"; then
        echo "RealAppHarnessTests: invalid foreground plan unexpectedly succeeded: $plan_file" >&2
        exit 1
    fi
    if ! rg -q "$expected_error" "$TEMP_ROOT/$plan_file.err"; then
        echo "RealAppHarnessTests: foreground plan error was not precise: $plan_file" >&2
        exit 1
    fi
done

python3 - "$ROOT/scripts/e2e/RealAppDriver.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
resolver_start = source.index("private func resolveForegroundElement(")
resolver_end = source.index("private func foregroundElementPoint(", resolver_start)
resolver = source[resolver_start:resolver_end]
for required in (
    "identifier == selector.identifier",
    "selector.role == nil || role == selector.role",
    "guard matches.count == 1",
):
    if required not in resolver:
        raise SystemExit(f"foreground element resolution lost uniqueness rule: {required}")

point_start = source.index("private func foregroundElementPoint(")
point_end = source.index("private func sidebarFilterElement(", point_start)
point = source[point_start:point_end]
for required in (
    "if let xFraction = action.xFraction, let yFraction = action.yFraction",
    "element.frame.width * xFraction",
    "element.frame.height * yFraction",
    "point = element.activationPoint.map",
    "inside window: WindowReport",
    "point.x >= bounds.x",
    "point.y >= bounds.y",
    "accessibility element center is outside the target window",
    "private func foregroundElementDragPoints(",
    "let start = element.activationPoint.map",
    "element-drag endpoint is outside the target window",
):
    if required not in point:
        raise SystemExit(f"foreground element point lost selection or confinement: {required}")

event_start = source.index("private let foregroundObservedEventTypes")
event_end = source.index("private func foregroundEventMask()", event_start)
if ".keyUp" not in source[event_start:event_end]:
    raise SystemExit("foreground interference mask does not observe key-up")

scroll_start = source.index("private func postForegroundScroll(")
scroll_end = source.index("private func foregroundWindowPoint(", scroll_start)
scroll = source[scroll_start:scroll_end]
for required in ("input.tag(moved)", "input.tag(scroll)", "input.lastInjectedPointer"):
    if required not in scroll:
        raise SystemExit(f"foreground scroll lost tagged pointer safety: {required}")

monitor_start = source.index("private struct ForegroundInjectedPointerAccumulator")
monitor_end = source.index("private let foregroundEventTapCallback", monitor_start)
monitor = source[monitor_start:monitor_end]
for required in (
    "if tag == nonce",
    "sessionInjectedPointerEvents.observe(type: type, location: event.location)",
    "targetInjectedPointerEvents.observe(type: type, location: event.location)",
    "CGEvent.tapCreateForPid(",
    "case .mouseMoved:",
    "case .leftMouseDown:",
    "case .leftMouseDragged:",
    "case .leftMouseUp:",
    "completeClickSequenceObserved: reportedMoveCount > 0",
    "completeDragSequenceObserved: reportedMoveCount > 0",
):
    if required not in monitor:
        raise SystemExit(f"same-nonce pointer delivery evidence is incomplete: {required}")
same_nonce = monitor.split("if tag == nonce", 1)[1].split(
    "if foregroundEventUsesPointer(type)", 1
)[0]
if "return" not in same_nonce:
    raise SystemExit("same-nonce injected events can fall through as user interference")

schema_start = source.index("private struct ForegroundInjectedPointerEventsReport")
schema_end = source.index("private struct ForegroundFocusRestoreReport", schema_start)
schema = source[schema_start:schema_end]
for required in (
    "let moveCount: Int",
    "let leftMouseDownCount: Int",
    "let leftMouseDraggedCount: Int",
    "let leftMouseUpCount: Int",
    "let lastMoveLocation: DesktopPointerReport?",
    "let lastLeftMouseDownLocation: DesktopPointerReport?",
    "let lastLeftMouseDraggedLocation: DesktopPointerReport?",
    "let lastLeftMouseUpLocation: DesktopPointerReport?",
    "let completeDragSequenceObserved: Bool",
    "let topmostWindow: WindowReport?",
    "let targetOwnerPIDMatches: Bool",
    "let targetWindowNumberMatches: Bool",
    "let accessibilityHit: ForegroundAccessibilityHitReport",
    "let targetPIDMatches: Bool",
    "let axFocusedWindow: ForegroundAXFocusedWindowReadinessReport",
):
    if required not in schema:
        raise SystemExit(f"foreground pointer evidence schema is incomplete: {required}")

topmost_start = source.index("private func topmostOnScreenWindow(")
topmost_end = source.index("private func windowInfo(", topmost_start)
topmost = source[topmost_start:topmost_end]
for required in (
    ".optionOnScreenOnly",
    ".excludeDesktopElements",
    "for item in windows",
    'report.owner == "Window Server"',
    'report.title == "Cursor"',
    "alpha > 0",
    "return report",
):
    if required not in topmost:
        raise SystemExit(f"topmost click-window evidence is incomplete: {required}")
if ".sorted" in topmost or "report.layer == 0" in topmost:
    raise SystemExit("topmost click-window lookup must preserve front-to-back overlays")

readiness_start = source.index("private func foregroundAXFocusedWindowReadiness(")
readiness_end = source.index("private func foregroundElementPoint(", readiness_start)
readiness = source[readiness_start:readiness_end]
for required in (
    "kAXFocusedWindowAttribute",
    "kAXPositionAttribute",
    "kAXSizeAttribute",
    "AXUIElementCopyElementAtPosition(",
    "AXUIElementGetPid(element, &pid)",
    "matchesTargetWindowGeometry",
    "topmostOnScreenWindow(at: point)",
    "targetOwnerPIDMatches",
    "targetWindowNumberMatches",
    "accessibilityHit.targetPIDMatches",
    "validateForegroundPointerClickReadiness",
    "validateForegroundInjectedPointerClick",
    "validateForegroundInjectedPointerDrag",
):
    if required not in readiness:
        raise SystemExit(f"strict pointer click readiness is incomplete: {required}")
if "ready: targetOwnerPIDMatches" not in readiness:
    raise SystemExit("bounded foreground clicks must require the target to be visually topmost")

batch_start = source.index("private func runForegroundBatch(")
batch_end = source.index("private func inspectElement(", batch_start)
batch = source[batch_start:batch_end]
active_window_ready = batch.index(
    '"target window did not restore its logical geometry after activation"'
)
pointer_frontmost_sync = batch.index("try setApplicationFrontmost(pid: pid)")
action_loop = batch.index("for (index, action) in plan.actions.enumerated()")
if not active_window_ready < pointer_frontmost_sync < action_loop:
    raise SystemExit("bounded pointer routing is not synchronized after window activation")
delivery_validation = batch.index("validateForegroundInjectedPointerClick(")
action_wait = batch.rindex("try foregroundWait(", 0, delivery_validation)
target_delivery_validation = batch.index(
    'deliveryLayer: "target-process event tap"',
    delivery_validation,
)
action_complete = batch.index('status: "completed"', delivery_validation)
if not action_wait < delivery_validation < target_delivery_validation < action_complete:
    raise SystemExit(
        "session and target same-nonce click delivery are not validated after wait"
    )
for required in (
    "let injectedPointerEvents: ForegroundInjectedPointerEventsReport",
    "let targetInjectedPointerEvents: ForegroundInjectedPointerEventsReport",
    "let pointerClickReadiness: ForegroundPointerClickReadinessReport?",
    "let pointerDragEndpointReadiness: ForegroundPointerClickReadinessReport?",
    "injectedPointerEvents: monitor.injectedPointerEvents()",
    "targetInjectedPointerEvents: monitor.targetInjectedPointerEventsReport()",
):
    if required not in source:
        raise SystemExit(f"foreground report lost pointer delivery evidence: {required}")
PY

for invalid_budget in 1.99 10.01; do
    if "$TEMP_ROOT/RealAppDriver" foreground-batch-plan \
        --plan "$TEMP_ROOT/foreground-valid.json" \
        --budget "$invalid_budget" \
        > "$TEMP_ROOT/foreground-budget-$invalid_budget.out" \
        2> "$TEMP_ROOT/foreground-budget-$invalid_budget.err"; then
        echo "RealAppHarnessTests: invalid foreground budget unexpectedly succeeded" >&2
        exit 1
    fi
    if ! rg -q "from 2 through 10 seconds" \
        "$TEMP_ROOT/foreground-budget-$invalid_budget.err"; then
        echo "RealAppHarnessTests: foreground budget error was not precise" >&2
        exit 1
    fi
done

# Full plan validation happens before any permission check, window lookup, activation,
# or event posting. The impossible PID makes this safe to exercise on the host desktop.
if "$TEMP_ROOT/RealAppDriver" foreground-batch \
    --pid 2147483647 \
    --plan "$TEMP_ROOT/foreground-unknown-field.json" \
    --budget 2 \
    > "$TEMP_ROOT/foreground-validation-order.out" \
    2> "$TEMP_ROOT/foreground-validation-order.err"; then
    echo "RealAppHarnessTests: invalid foreground batch unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -q "unknown fields" "$TEMP_ROOT/foreground-validation-order.err"; then
    echo "RealAppHarnessTests: foreground batch did not validate its plan first" >&2
    exit 1
fi

for control in disclosure whole-word query-field replace-field replace-current replace-all; do
    "$TEMP_ROOT/RealAppDriver" find-control-point \
        --control "$control" \
        --width 1180 \
        --height 760 \
        > "$TEMP_ROOT/find-point-$control.json"
done
python3 - "$TEMP_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "disclosure": (724, 74),
    "whole-word": (1021, 74),
    "query-field": (860, 74),
    "replace-field": (860, 108),
    "replace-current": (1058, 108),
    "replace-all": (1121, 108),
}
for control, point in expected.items():
    report = json.loads((root / f"find-point-{control}.json").read_text(encoding="utf-8"))
    assert report["control"] == control
    assert report["windowWidth"] == 1180
    assert report["windowHeight"] == 760
    assert (report["relativeX"], report["relativeY"]) == point
    assert 0 <= report["relativeX"] < report["windowWidth"]
    assert 0 <= report["relativeY"] < report["windowHeight"]
PY

if "$TEMP_ROOT/RealAppDriver" find-control-point \
    --control unknown \
    > "$TEMP_ROOT/invalid-find-point.out" \
    2> "$TEMP_ROOT/invalid-find-point.err"; then
    echo "RealAppHarnessTests: unknown find control unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -q "unsupported find control" "$TEMP_ROOT/invalid-find-point.err"; then
    echo "RealAppHarnessTests: unknown find control error was not precise" >&2
    exit 1
fi

python3 - "$ROOT/ui/格式示例.md" "$TEMP_ROOT" <<'PY'
import json
import pathlib
import sys

fixture = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
root = pathlib.Path(sys.argv[2])
states = {
    "clean": fixture,
    "table": fixture.replace(
        "| 快捷键 | 功能 | 平台 |",
        "| E2E_TABLE | 功能 | 平台 |",
        1,
    ),
}
states["table-source"] = states["table"].replace(
    "# Markdown 全格式示例",
    "# Markdown 全格式示例 E2E_SOURCE",
    1,
)
for state, source in states.items():
    tab = {
        "id": "fixture-tab",
        "name": "格式示例.md",
        "isMarkdown": True,
        "isDirty": state != "clean",
        "text": source,
        "markdownDocument": {
            "blocks": [{
                "id": "fixture-block",
                "kind": "paragraph",
                "leadingTrivia": "",
                "source": source,
            }],
            "trailingTrivia": "",
        },
    }
    (root / f"session-{state}.json").write_text(
        json.dumps({"activeTabID": tab["id"], "tabs": [tab]}, ensure_ascii=False),
        encoding="utf-8",
    )
PY

for state in clean table table-source; do
    python3 "$ROOT/scripts/e2e/verify-fixture-session.py" \
        --session "$TEMP_ROOT/session-$state.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --state "$state" \
        --label "test-$state" \
        --evidence-root "$TEMP_ROOT" \
        > "$TEMP_ROOT/assertion-$state.json"
    python3 - "$TEMP_ROOT/assertion-$state.json" "$state" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["state"] == sys.argv[2]
assert record["structuredSourceMatchesText"] is True
assert len(record["sourceSHA256"]) == 64
PY
done

python3 - "$TEMP_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sources = {
    "initial": "red red RED redwood red",
    "replace-current": "blue red RED redwood red",
    "replace-all": "blue blue blue redwood blue",
}
for state, source in sources.items():
    tab = {
        "id": "find-tab",
        "url": None,
        "name": "未命名.md",
        "isMarkdown": True,
        "isDirty": True,
        "text": source,
        "markdownDocument": {
            "blocks": [{
                "id": "find-block",
                "kind": "paragraph",
                "leadingTrivia": "",
                "source": source,
            }],
            "trailingTrivia": "",
        },
    }
    (root / f"session-find-{state}.json").write_text(
        json.dumps({"activeTabID": tab["id"], "tabs": [tab]}, ensure_ascii=False),
        encoding="utf-8",
    )

profile = root / "find-profile"
session_path = profile / "Application Support" / "MarkdownViewer" / "session.json"
diagnostic = {
    "schemaVersion": 1,
    "document": "未命名.md",
    "blockID": None,
    "blockType": None,
    "mode": "edit",
    "selection": None,
    "activeTableCell": None,
    "dirty": True,
    "find": {
        "query": "red",
        "display": "1/4",
        "matchCount": 4,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": True,
        "caseSensitive": False,
        "wholeWord": True,
        "regex": False,
    },
    "outline": {"headingCount": 0, "activeIndex": 0},
    "scrollY": 0,
    "sessionPath": str(session_path),
    "parseCount": 2,
    "localMutationCount": 1,
    "renderedBlockUpdateCount": 3,
    "activeBlockRenderUpdateCount": 0,
    "renderedBlockUpdates": {"fixture-block": 2, "find-block": 1},
    "visual": {
        "documentVisible": True,
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": True,
        "replaceRowVisible": True,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
        "anchors": {},
    },
    "updatedAt": "2026-07-13T00:00:00Z",
}
(root / "diagnostic-find.json").write_text(
    json.dumps(diagnostic, ensure_ascii=False),
    encoding="utf-8",
)
PY

for state in initial replace-current replace-all; do
    python3 "$ROOT/scripts/e2e/verify-find-replace-session.py" \
        --session "$TEMP_ROOT/session-find-$state.json" \
        --state "$state" \
        --label "test-find-$state" \
        --evidence-root "$TEMP_ROOT" \
        > "$TEMP_ROOT/assertion-find-$state.json"
    python3 - "$TEMP_ROOT/assertion-find-$state.json" "$state" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["state"] == sys.argv[2]
assert record["structuredSourceMatchesText"] is True
assert len(record["sourceSHA256"]) == 64
PY
done

python3 "$ROOT/scripts/e2e/verify-find-diagnostic.py" \
    --snapshot "$TEMP_ROOT/diagnostic-find.json" \
    --profile-root "$TEMP_ROOT/find-profile" \
    --label test-find-diagnostic \
    --query red \
    --display "1/4" \
    --match-count 4 \
    --current-index 0 \
    --replace-expanded true \
    --whole-word true \
    > "$TEMP_ROOT/assertion-find-diagnostic.json"

FOREGROUND_FIND_VERIFY_ROOT="$TEMP_ROOT/foreground-find-verifier"
mkdir -p "$FOREGROUND_FIND_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_FIND_VERIFY_ROOT" <<'PY'
import json
import pathlib
import shutil
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
shutil.copyfile(fixture_path, root / "workspace-fixture.md")
scenarios = {
    "find-options": {
        "source": "Red red redwood RED",
        "selection": None,
        "local": 1,
        "parse": 2,
        "find": {
            "query": "red",
            "display": "1/1",
            "matchCount": 1,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": False,
            "caseSensitive": True,
            "wholeWord": True,
            "regex": False,
        },
    },
    "find-regex-replace": {
        "source": "Current:Ada All:Bob All:Cy",
        "selection": None,
        "local": 3,
        "parse": 4,
        "find": {
            "query": r"Name:(\w+)",
            "display": "无结果",
            "matchCount": 0,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": True,
            "caseSensitive": False,
            "wholeWord": False,
            "regex": True,
        },
    },
}
for scenario, expected in scenarios.items():
    block_id = f"{scenario}-block"
    fixture_tab = {
        "id": "fixture-tab",
        "url": None,
        "name": "格式示例.md",
        "isMarkdown": True,
        "isDirty": False,
        "text": fixture,
        "markdownDocument": {
            "blocks": [{
                "id": "fixture-block",
                "kind": "paragraph",
                "leadingTrivia": "",
                "source": fixture,
            }],
            "trailingTrivia": "",
        },
    }
    active = {
        "id": f"{scenario}-tab",
        "url": None,
        "name": "未命名.md",
        "isMarkdown": True,
        "isDirty": True,
        "scrollY": 0,
        "text": expected["source"],
        "markdownDocument": {
            "blocks": [{
                "id": block_id,
                "kind": "paragraph",
                "leadingTrivia": "",
                "source": expected["source"],
            }],
            "trailingTrivia": "",
        },
    }
    session = {
        "activeTabID": active["id"],
        "tabs": [fixture_tab, active],
    }
    diagnostic = {
        "schemaVersion": 1,
        "document": "未命名.md",
        "blockID": None,
        "blockType": None,
        "mode": "edit",
        "selection": expected["selection"],
        "activeTableCell": None,
        "dirty": True,
        "find": expected["find"],
        "scrollY": 0,
        "parseCount": expected["parse"],
        "localMutationCount": expected["local"],
        "sessionPath": str(root / f"{scenario}-session.json"),
        "visual": {
            "documentVisible": True,
            "sidebarVisible": True,
            "paletteVisible": False,
            "findPanelVisible": True,
            "replaceRowVisible": expected["find"]["replaceExpanded"],
            "previewActive": False,
            "sourceEditorVisible": False,
            "tableGridVisible": False,
        },
    }
    (root / f"{scenario}-session.json").write_text(
        json.dumps(session, ensure_ascii=False),
        encoding="utf-8",
    )
    (root / f"{scenario}-diagnostic.json").write_text(
        json.dumps(diagnostic, ensure_ascii=False),
        encoding="utf-8",
    )
PY

FOREGROUND_FIND_FIXTURE_SHA="$(
    shasum -a 256 "$ROOT/ui/格式示例.md" | awk '{print $1}'
)"
for scenario in find-options find-regex-replace; do
    verifier_args=(
        --scenario "$scenario"
        --session "$FOREGROUND_FIND_VERIFY_ROOT/$scenario-session.json"
        --diagnostic "$FOREGROUND_FIND_VERIFY_ROOT/$scenario-diagnostic.json"
        --fixture "$ROOT/ui/格式示例.md"
        --workspace-fixture "$FOREGROUND_FIND_VERIFY_ROOT/workspace-fixture.md"
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
        --output-root "$TEMP_ROOT"
    )
    python3 "$ROOT/scripts/e2e/verify-foreground-find-session.py" \
        "${verifier_args[@]}" \
        --check-only
    for report_kind in session diagnostic; do
        python3 "$ROOT/scripts/e2e/verify-foreground-find-session.py" \
            "${verifier_args[@]}" \
            --report-kind "$report_kind" \
            > "$FOREGROUND_FIND_VERIFY_ROOT/$scenario-$report_kind-report.json"
    done
done

python3 - "$FOREGROUND_FIND_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for scenario in ("find-options", "find-regex-replace"):
    session = json.loads(
        (root / f"{scenario}-session-report.json").read_text(encoding="utf-8")
    )
    diagnostic = json.loads(
        (root / f"{scenario}-diagnostic-report.json").read_text(encoding="utf-8")
    )
    assert session["label"] == f"foreground-{scenario}-session"
    assert all(session["assertions"].values())
    assert diagnostic["label"] == f"foreground-{scenario}-diagnostic"
    assert all(diagnostic["assertions"].values())

invalid = json.loads(
    (root / "find-options-diagnostic.json").read_text(encoding="utf-8")
)
invalid["find"]["display"] = "1/2"
(root / "find-options-invalid-diagnostic.json").write_text(
    json.dumps(invalid, ensure_ascii=False),
    encoding="utf-8",
)
PY

if python3 "$ROOT/scripts/e2e/verify-foreground-find-session.py" \
    --scenario find-options \
    --session "$FOREGROUND_FIND_VERIFY_ROOT/find-options-session.json" \
    --diagnostic "$FOREGROUND_FIND_VERIFY_ROOT/find-options-invalid-diagnostic.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$FOREGROUND_FIND_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_FIND_VERIFY_ROOT/invalid.out" \
    2> "$FOREGROUND_FIND_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: mismatched foreground Find diagnostic unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "Find diagnostic mismatch" \
    "$FOREGROUND_FIND_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: foreground Find verifier error was not precise" >&2
    exit 1
fi

FOREGROUND_PREVIEW_VERIFY_ROOT="$TEMP_ROOT/foreground-preview-content-verifier"
mkdir -p "$FOREGROUND_PREVIEW_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_PREVIEW_VERIFY_ROOT" <<'PY'
import json
import pathlib
import shutil
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
task_before = "\n".join([
    "- [x] 实时渲染",
    "- [x] 语法即时高亮",
    "- [ ] 协同编辑",
    "- [ ] 导出 PDF",
])
task_after = task_before.replace("- [ ] 协同编辑", "- [x] 协同编辑")
assert fixture.count(task_before) == 1
source = fixture.replace(task_before, task_after, 1)
prefix, suffix = source.split(task_after, 1)
blocks = []
for index in range(37):
    block_source = ""
    if index == 18:
        block_source = prefix
    elif index == 19:
        block_source = task_after
    elif index == 20:
        block_source = suffix
    blocks.append({
        "id": f"preview-block-{index}",
        "kind": "list" if index == 19 else "paragraph",
        "leadingTrivia": "",
        "source": block_source,
    })
tab = {
    "id": "fixture-tab",
    "url": None,
    "name": "格式示例.md",
    "isMarkdown": True,
    "isDirty": True,
    "scrollY": 1600,
    "text": source,
    "markdownDocument": {"blocks": blocks, "trailingTrivia": ""},
}
session_path = root / "session.json"
session_path.write_text(
    json.dumps({"activeTabID": tab["id"], "tabs": [tab]}, ensure_ascii=False),
    encoding="utf-8",
)
diagnostic = {
    "schemaVersion": 1,
    "document": "格式示例.md",
    "blockID": None,
    "blockType": None,
    "mode": "edit",
    "selection": None,
    "activeTableCell": None,
    "dirty": True,
    "find": {
        "query": "",
        "display": "",
        "matchCount": 0,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": False,
        "caseSensitive": False,
        "wholeWord": False,
        "regex": False,
    },
    "outline": {"headingCount": 15, "activeIndex": 9},
    "scrollY": 1600,
    "sessionPath": str(session_path),
    "parseCount": 2,
    "localMutationCount": 1,
    "visual": {
        "documentVisible": True,
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
    },
}
(root / "diagnostic.json").write_text(
    json.dumps(diagnostic, ensure_ascii=False),
    encoding="utf-8",
)
shutil.copyfile(fixture_path, root / "workspace-fixture.md")
PY

preview_verifier_args=(
    --session "$FOREGROUND_PREVIEW_VERIFY_ROOT/session.json"
    --diagnostic "$FOREGROUND_PREVIEW_VERIFY_ROOT/diagnostic.json"
    --fixture "$ROOT/ui/格式示例.md"
    --workspace-fixture "$FOREGROUND_PREVIEW_VERIFY_ROOT/workspace-fixture.md"
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
    --output-root "$TEMP_ROOT"
)
python3 "$ROOT/scripts/e2e/verify-foreground-preview-content.py" \
    "${preview_verifier_args[@]}" \
    --check-only
for report_kind in session diagnostic; do
    python3 "$ROOT/scripts/e2e/verify-foreground-preview-content.py" \
        "${preview_verifier_args[@]}" \
        --report-kind "$report_kind" \
        > "$FOREGROUND_PREVIEW_VERIFY_ROOT/$report_kind-report.json"
done
python3 - "$FOREGROUND_PREVIEW_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for report_kind in ("session", "diagnostic"):
    report = json.loads(
        (root / f"{report_kind}-report.json").read_text(encoding="utf-8")
    )
    assert report["label"] == f"foreground-preview-content-{report_kind}"
    assert all(report["assertions"].values())
invalid = json.loads((root / "diagnostic.json").read_text(encoding="utf-8"))
invalid["parseCount"] = 99
(root / "invalid-diagnostic.json").write_text(
    json.dumps(invalid, ensure_ascii=False),
    encoding="utf-8",
)
PY
if python3 "$ROOT/scripts/e2e/verify-foreground-preview-content.py" \
    --session "$FOREGROUND_PREVIEW_VERIFY_ROOT/session.json" \
    --diagnostic "$FOREGROUND_PREVIEW_VERIFY_ROOT/invalid-diagnostic.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$FOREGROUND_PREVIEW_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_PREVIEW_VERIFY_ROOT/invalid.out" \
    2> "$FOREGROUND_PREVIEW_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: mismatched preview diagnostic unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "editor, outline, or visual diagnostic mismatch" \
    "$FOREGROUND_PREVIEW_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: preview verifier error was not precise" >&2
    exit 1
fi

FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT="$TEMP_ROOT/foreground-preview-footnotes-verifier"
mkdir -p "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT" <<'PY'
import json
import pathlib
import shutil
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
reference = (
    "Markdown 是一种轻量级标记语言[^1]，本编辑器实现了其中最常用的子集[^scope]。"
)
definitions = "\n".join([
    "[^1]: 由 John Gruber 于 2004 年提出。",
    "[^scope]: 标题、列表、代码、表格、链接、脚注等。",
])
prefix, remainder = fixture.split(reference, 1)
between, suffix = remainder.split(definitions, 1)
assert suffix == ""
blocks = []
for index in range(37):
    block = {
        "id": f"preview-footnote-block-{index}",
        "kind": "paragraph",
        "leadingTrivia": "",
        "source": "",
    }
    if index == 0:
        block["source"] = prefix
    elif index == 35:
        block["source"] = reference
    elif index == 36:
        block["kind"] = "footnotes"
        block["leadingTrivia"] = between
        block["source"] = definitions
    blocks.append(block)
tab = {
    "id": "fixture-tab",
    "url": None,
    "name": "格式示例.md",
    "isMarkdown": True,
    "isDirty": False,
    "scrollY": 3106.7,
    "text": fixture,
    "markdownDocument": {"blocks": blocks, "trailingTrivia": ""},
}
session_path = root / "session.json"
session_path.write_text(
    json.dumps({"activeTabID": tab["id"], "tabs": [tab]}, ensure_ascii=False),
    encoding="utf-8",
)
diagnostic = {
    "schemaVersion": 1,
    "document": "格式示例.md",
    "blockID": None,
    "blockType": None,
    "mode": "edit",
    "selection": None,
    "activeTableCell": None,
    "dirty": False,
    "find": {
        "query": "",
        "display": "",
        "matchCount": 0,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": False,
        "caseSensitive": False,
        "wholeWord": False,
        "regex": False,
    },
    "outline": {"headingCount": 15, "activeIndex": 13},
    "scrollY": 3106.7,
    "sessionPath": str(session_path),
    "parseCount": 1,
    "localMutationCount": 0,
    "visual": {
        "documentVisible": True,
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
    },
}
(root / "diagnostic.json").write_text(
    json.dumps(diagnostic, ensure_ascii=False),
    encoding="utf-8",
)
shutil.copyfile(fixture_path, root / "workspace-fixture.md")
PY

preview_footnotes_verifier_args=(
    --session "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/session.json"
    --diagnostic "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/diagnostic.json"
    --fixture "$ROOT/ui/格式示例.md"
    --workspace-fixture "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/workspace-fixture.md"
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
    --output-root "$TEMP_ROOT"
)
python3 "$ROOT/scripts/e2e/verify-foreground-preview-footnotes.py" \
    "${preview_footnotes_verifier_args[@]}" \
    --check-only
for report_kind in session diagnostic; do
    python3 "$ROOT/scripts/e2e/verify-foreground-preview-footnotes.py" \
        "${preview_footnotes_verifier_args[@]}" \
        --report-kind "$report_kind" \
        > "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/$report_kind-report.json"
done
python3 - "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for report_kind in ("session", "diagnostic"):
    report = json.loads(
        (root / f"{report_kind}-report.json").read_text(encoding="utf-8")
    )
    assert report["label"] == f"foreground-preview-footnotes-{report_kind}"
    assert all(report["assertions"].values())
diagnostic = json.loads((root / "diagnostic-report.json").read_text(encoding="utf-8"))
assert diagnostic["acceptedScrollRange"] == {
    "minimum": 2990,
    "maximum": 3120,
    "reason": (
        "launch starts at 3000 and bottom-clamped animated footnote jumps "
        "settle near the 1180x760 document maximum"
    ),
}
invalid = json.loads((root / "diagnostic.json").read_text(encoding="utf-8"))
invalid["localMutationCount"] = 1
(root / "invalid-diagnostic.json").write_text(
    json.dumps(invalid, ensure_ascii=False),
    encoding="utf-8",
)
PY
if python3 "$ROOT/scripts/e2e/verify-foreground-preview-footnotes.py" \
    --session "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/session.json" \
    --diagnostic "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/invalid-diagnostic.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/invalid.out" \
    2> "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: mutated preview-footnotes diagnostic unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "editor, outline, or visual diagnostic mismatch" \
    "$FOREGROUND_PREVIEW_FOOTNOTES_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: preview-footnotes verifier error was not precise" >&2
    exit 1
fi

FOREGROUND_OUTLINE_VERIFY_ROOT="$TEMP_ROOT/foreground-outline-navigation-verifier"
mkdir -p "$FOREGROUND_OUTLINE_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_OUTLINE_VERIFY_ROOT" <<'PY'
import json
import pathlib
import shutil
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
target = "## 表格"
prefix, suffix = fixture.split(target, 1)
heading_indexes = {0, 2, 3, 4, 5, 6, 7, 8, 9, 13, 20, 24, 27, 31, 34}
blocks = []
for index in range(37):
    source = ""
    if index == 0:
        source = prefix
    elif index == 27:
        source = target
    elif index == 28:
        source = suffix
    blocks.append({
        "id": f"outline-block-{index}",
        "kind": "heading" if index in heading_indexes else "paragraph",
        "leadingTrivia": "",
        "source": source,
    })
tab = {
    "id": "fixture-tab",
    "url": None,
    "name": "格式示例.md",
    "isMarkdown": True,
    "isDirty": False,
    "scrollY": 2563.45,
    "text": fixture,
    "markdownDocument": {"blocks": blocks, "trailingTrivia": ""},
}
session_path = root / "session.json"
session_path.write_text(
    json.dumps({"activeTabID": tab["id"], "tabs": [tab]}, ensure_ascii=False),
    encoding="utf-8",
)
diagnostic = {
    "schemaVersion": 1,
    "document": "格式示例.md",
    "blockID": None,
    "blockType": None,
    "mode": "edit",
    "selection": None,
    "activeTableCell": None,
    "dirty": False,
    "find": {
        "query": "",
        "display": "",
        "matchCount": 0,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": False,
        "caseSensitive": False,
        "wholeWord": False,
        "regex": False,
    },
    "outline": {"headingCount": 15, "activeIndex": 12},
    "scrollY": 2563.45,
    "sessionPath": str(session_path),
    "parseCount": 1,
    "localMutationCount": 0,
    "visual": {
        "documentVisible": True,
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
    },
}
(root / "diagnostic.json").write_text(
    json.dumps(diagnostic, ensure_ascii=False),
    encoding="utf-8",
)
shutil.copyfile(fixture_path, root / "workspace-fixture.md")
PY

outline_verifier_args=(
    --session "$FOREGROUND_OUTLINE_VERIFY_ROOT/session.json"
    --diagnostic "$FOREGROUND_OUTLINE_VERIFY_ROOT/diagnostic.json"
    --fixture "$ROOT/ui/格式示例.md"
    --workspace-fixture "$FOREGROUND_OUTLINE_VERIFY_ROOT/workspace-fixture.md"
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
    --output-root "$TEMP_ROOT"
)
python3 "$ROOT/scripts/e2e/verify-foreground-outline-navigation.py" \
    "${outline_verifier_args[@]}" \
    --check-only
for report_kind in session diagnostic; do
    python3 "$ROOT/scripts/e2e/verify-foreground-outline-navigation.py" \
        "${outline_verifier_args[@]}" \
        --report-kind "$report_kind" \
        > "$FOREGROUND_OUTLINE_VERIFY_ROOT/$report_kind-report.json"
done
python3 - "$FOREGROUND_OUTLINE_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for report_kind in ("session", "diagnostic"):
    report = json.loads(
        (root / f"{report_kind}-report.json").read_text(encoding="utf-8")
    )
    assert report["label"] == f"foreground-outline-navigation-{report_kind}"
    assert all(report["assertions"].values())
diagnostic_report = json.loads(
    (root / "diagnostic-report.json").read_text(encoding="utf-8")
)
assert diagnostic_report["acceptedScrollRange"] == {
    "minimum": 2548,
    "maximum": 2580,
    "reason": (
        "the fixed 1180x760 fixture places block 27 at y=2607.45 "
        "with the document viewport starting at y=44; top-anchored "
        "navigation settles at 2563.45 with a narrow allowance for "
        "SwiftUI layout rounding"
    ),
}
invalid = json.loads((root / "diagnostic.json").read_text(encoding="utf-8"))
invalid["outline"]["activeIndex"] = 11
(root / "invalid-diagnostic.json").write_text(
    json.dumps(invalid, ensure_ascii=False),
    encoding="utf-8",
)
PY
if python3 "$ROOT/scripts/e2e/verify-foreground-outline-navigation.py" \
    --session "$FOREGROUND_OUTLINE_VERIFY_ROOT/session.json" \
    --diagnostic "$FOREGROUND_OUTLINE_VERIFY_ROOT/invalid-diagnostic.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$FOREGROUND_OUTLINE_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_OUTLINE_VERIFY_ROOT/invalid.out" \
    2> "$FOREGROUND_OUTLINE_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: mismatched outline diagnostic unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "editor, outline, or visual diagnostic mismatch" \
    "$FOREGROUND_OUTLINE_VERIFY_ROOT/invalid.err"; then
    echo "RealAppHarnessTests: outline verifier error was not precise" >&2
    exit 1
fi

FOREGROUND_SIDEBAR_VERIFY_ROOT="$TEMP_ROOT/foreground-sidebar-verifier"
mkdir -p "$FOREGROUND_SIDEBAR_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$FOREGROUND_SIDEBAR_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
heading_indexes = {0, 2, 3, 4, 5, 6, 7, 8, 9, 13, 20, 24, 27, 31, 34}


def element_action(index, kind, identifier, role, width=120):
    action = {
        "index": index,
        "kind": kind,
        "status": "completed",
        "durationMs": 40,
        "detail": identifier,
        "element": {
            "identifier": identifier,
            "role": role,
            "frame": {"x": 10, "y": 10, "width": width, "height": 24},
            "activationPoint": None,
        },
    }
    if kind == "element-drag":
        receipt = {
            "leftMouseDraggedCount": 2,
            "completeDragSequenceObserved": True,
        }
        action.update({
            "injectedPointerEvents": receipt,
            "targetInjectedPointerEvents": receipt,
            "pointerClickReadiness": {"ready": True},
            "pointerDragEndpointReadiness": {"ready": True},
        })
    return action


def completed_action(index, kind):
    return {
        "index": index,
        "kind": kind,
        "status": "completed",
        "durationMs": 40,
    }


def fixture_tab():
    blocks = []
    for index in range(37):
        blocks.append({
            "id": f"sidebar-fixture-block-{index}",
            "kind": "heading" if index in heading_indexes else "paragraph",
            "leadingTrivia": "",
            "source": fixture if index == 0 else "",
        })
    return {
        "id": "fixture-tab",
        "url": None,
        "name": "格式示例.md",
        "isMarkdown": True,
        "isDirty": False,
        "scrollY": 0,
        "text": fixture,
        "markdownDocument": {"blocks": blocks, "trailingTrivia": ""},
    }


def diagnostic(session_path):
    return {
        "schemaVersion": 1,
        "document": "格式示例.md",
        "blockID": None,
        "blockType": None,
        "mode": "edit",
        "selection": None,
        "activeTableCell": None,
        "dirty": False,
        "find": {
            "query": "",
            "display": "",
            "matchCount": 0,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": False,
            "caseSensitive": False,
            "wholeWord": False,
            "regex": False,
        },
        "outline": {"headingCount": 15, "activeIndex": 0},
        "scrollY": 0,
        "sessionPath": str(session_path),
        "parseCount": 1,
        "localMutationCount": 0,
        "visual": {
            "documentVisible": True,
            "sidebarVisible": True,
            "paletteVisible": False,
            "findPanelVisible": False,
            "replaceRowVisible": False,
            "previewActive": False,
            "sourceEditorVisible": False,
            "tableGridVisible": False,
        },
    }


def foreground_report(actions):
    return {
        "pid": 101,
        "durationMs": 3000,
        "budgetMs": 4000,
        "targetActivationRequestCount": 1,
        "completed": True,
        "actions": actions,
        "interference": {
            "detected": False,
            "pointerInputDetected": False,
            "pointerPositionInterferenceDetected": False,
            "eventTapReliable": True,
        },
        "deadlineExceeded": False,
        "focusRestore": {"attempted": True, "restored": True},
        "pointerRestore": {"attempted": True, "restored": True},
        "pasteboardRestore": {"attempted": False, "restored": True},
        "error": None,
    }


def synthetic_resize_state(name, begin_width, end_width, sequence_offset):
    phase_root = root / "sidebar-layout-controls" / name
    live_session = root / "sidebar-layout-controls" / "live-session.json"
    return {
        "schemaVersion": 1,
        "suite": "sidebar-layout-controls",
        "phase": name,
        "expectedBeginWidth": begin_width,
        "expectedEndWidth": end_width,
        "assertions": {
            "persistedWidthReached": True,
            "sidebarRemainedOpen": True,
            "diagnosticAnchorReached": True,
            "diagnosticAnchorHeightExact": True,
            "latestResizeBeganAtExpectedWidth": True,
            "latestResizeChangedThroughExpectedWidth": True,
            "latestResizeEndedAtExpectedWidth": True,
        },
        "session": {
            "path": str((phase_root / "session.json").resolve()),
            "expectedLivePath": str(live_session.resolve()),
            "schemaVersion": 2,
            "sidebarOpen": True,
            "sidebarWidth": end_width,
        },
        "diagnostic": {
            "path": str((phase_root / "diagnostic.json").resolve()),
            "schemaVersion": 1,
            "sessionPath": str(live_session.resolve()),
            "sidebarVisible": True,
            "sidebarAnchor": {
                "x": 0,
                "y": 0,
                "width": end_width,
                "height": 760,
            },
        },
        "pointerTrace": {
            "path": str((phase_root / "pointer-trace.json").resolve()),
            "schemaVersion": 1,
            "entryCount": sequence_offset + 4,
            "latestResizeSegment": {
                "began": {
                    "sequence": sequence_offset,
                    "sidebarWidth": begin_width,
                },
                "changed": [{
                    "sequence": sequence_offset + 1,
                    "sidebarWidth": end_width,
                }, {
                    "sequence": sequence_offset + 2,
                    "sidebarWidth": end_width,
                }],
                "ended": {
                    "sequence": sequence_offset + 3,
                    "sidebarWidth": end_width,
                },
            },
        },
    }


def layout_phase_evidence(
    name,
    plan_actions,
    report_actions,
    duration,
    estimate,
    resize_state,
):
    report = foreground_report(report_actions)
    report["durationMs"] = duration
    validation = {
        "valid": True,
        "budgetMs": 4000,
        "estimatedForegroundMs": estimate,
        "cleanupReserveMs": 400,
        "actions": [
            {"index": index, "kind": action["kind"]}
            for index, action in enumerate(plan_actions)
        ],
    }
    return {
        "name": name,
        "plan": {"schemaVersion": 1, "actions": plan_actions},
        "planValidation": validation,
        "report": report,
        "windowAfter": {"pid": 101, "onScreen": False, "layer": 0},
        "resizeState": resize_state,
    }


def layout_foreground_report():
    collapse_plan = [
        {"kind": "move-safe-point"},
        {"kind": "element-click"},
        {"kind": "window-screenshot"},
        {"kind": "element-click"},
        {"kind": "element-check"},
        {
            "kind": "element-drag",
            "identifier": "sidebar-resize-handle",
            "deltaX": -120,
        },
        {"kind": "window-screenshot"},
    ]
    collapse_actions = [
        completed_action(0, "move-safe-point"),
        element_action(1, "element-click", "sidebar-folder-docs", "AXButton", 180),
        completed_action(2, "window-screenshot"),
        element_action(3, "element-click", "sidebar-folder-docs", "AXButton", 180),
        element_action(
            4,
            "element-check",
            "sidebar-file-docs%2Fconfig%2Eyaml",
            "AXButton",
            160,
        ),
        element_action(5, "element-drag", "sidebar-resize-handle", "AXGroup", 9),
        completed_action(6, "window-screenshot"),
    ]
    maximum_plan = [
        {"kind": "move-safe-point"},
        {
            "kind": "window-drag",
            "xFraction": 175.5 / 1180,
            "yFraction": 0.5,
            "deltaX": 320,
        },
        {"kind": "window-screenshot"},
        {"kind": "key"},
        {"kind": "wait"},
        {"kind": "window-screenshot"},
        {"kind": "key"},
        {"kind": "wait"},
        {"kind": "window-screenshot"},
    ]
    window_drag = completed_action(1, "window-drag")
    drag_receipt = {
        "leftMouseDraggedCount": 2,
        "completeDragSequenceObserved": True,
    }
    window_drag.update({
        "pointerClickReadiness": {"ready": True},
        "pointerDragEndpointReadiness": {"ready": True},
        "injectedPointerEvents": drag_receipt,
        "targetInjectedPointerEvents": drag_receipt,
    })
    maximum_actions = [
        completed_action(0, "move-safe-point"),
        window_drag,
        completed_action(2, "window-screenshot"),
        completed_action(3, "key"),
        completed_action(4, "wait"),
        completed_action(5, "window-screenshot"),
        completed_action(6, "key"),
        completed_action(7, "wait"),
        completed_action(8, "window-screenshot"),
    ]
    phases = [
        layout_phase_evidence(
            "collapse-minimum",
            collapse_plan,
            collapse_actions,
            1100,
            1450,
            synthetic_resize_state("collapse-minimum", 216, 176, 1),
        ),
        layout_phase_evidence(
            "maximum-toggle",
            maximum_plan,
            maximum_actions,
            1400,
            1690,
            synthetic_resize_state("maximum-toggle", 176, 440, 5),
        ),
    ]
    flat_actions = []
    for phase_index, phase in enumerate(phases):
        for phase_action_index, action in enumerate(phase["report"]["actions"]):
            flat_actions.append({
                **action,
                "index": len(flat_actions),
                "phase": phase["name"],
                "phaseIndex": phase_index,
                "phaseActionIndex": phase_action_index,
            })
    return {
        "schemaVersion": 1,
        "suite": "sidebar-layout-controls",
        "pid": 101,
        "pids": [101, 101],
        "phaseCount": 2,
        "perPhaseBudgetMs": 4000,
        "totalBudgetMs": 8000,
        "durationMs": 2500,
        "budgetMs": 8000,
        "targetActivationRequestCount": 2,
        "completed": True,
        "actions": flat_actions,
        "interference": {"detected": False},
        "deadlineExceeded": False,
        "focusRestore": {"restored": True},
        "pointerRestore": {"restored": True},
        "pasteboardRestore": {"restored": True},
        "error": None,
        "phases": phases,
    }


for scenario, width in (
    ("sidebar-filter-navigation", 216),
    ("sidebar-layout-controls", 440),
):
    scenario_root = root / scenario
    workspace = scenario_root / "workspace"
    docs = workspace / "docs"
    docs.mkdir(parents=True)
    (docs / "config.yaml").write_text(
        "model: gpt-4o\ntemperature: 0.2\n",
        encoding="utf-8",
    )
    (docs / fixture_path.name).write_text(fixture, encoding="utf-8")
    (workspace / "README.md").write_text("# Markdown Editor\n", encoding="utf-8")
    (workspace / "更新日志.md").write_text("# 更新日志\n", encoding="utf-8")

    tabs = [fixture_tab()]
    if scenario == "sidebar-filter-navigation":
        tabs.append({
            "id": "readme-tab",
            "url": str(workspace / "README.md"),
            "name": "README.md",
            "isMarkdown": True,
            "isDirty": False,
            "scrollY": 0,
            "text": "# Markdown Editor\n",
            "markdownDocument": {
                "blocks": [{
                    "id": "readme-block",
                    "kind": "heading",
                    "leadingTrivia": "",
                    "source": "# Markdown Editor",
                }],
                "trailingTrivia": "\n",
            },
        })
    session_path = scenario_root / "session.json"
    session_path.write_text(json.dumps({
        "schemaVersion": 2,
        "tabs": tabs,
        "activeTabID": "fixture-tab",
        "fontIndex": 1,
        "sidebarWidth": width,
        "sidebarOpen": True,
        "directoryPath": str(workspace),
        "expandedFolderPaths": [str(docs)],
    }, ensure_ascii=False), encoding="utf-8")
    (scenario_root / "diagnostic.json").write_text(
        json.dumps(diagnostic(session_path), ensure_ascii=False),
        encoding="utf-8",
    )

    if scenario == "sidebar-filter-navigation":
        specs = [
            ("element-click", "sidebar-filter", "AXTextField", 180),
            ("focused-element-check", "sidebar-filter", "AXTextField", 180),
            (
                "element-check",
                "sidebar-file-docs%2F%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd",
                "AXButton",
                160,
            ),
            (
                "element-check",
                "sidebar-file-docs%2Fconfig%2Eyaml",
                "AXButton",
                160,
            ),
            ("element-check", "sidebar-filter-empty", "AXStaticText", 160),
            ("focused-element-check", "sidebar-filter", "AXTextField", 180),
        ]
        actions = [
            element_action(index, kind, identifier, role, element_width)
            for index, (kind, identifier, role, element_width) in enumerate(specs)
        ]
        report = foreground_report(actions)
    else:
        report = layout_foreground_report()
    (scenario_root / "foreground-report.json").write_text(
        json.dumps(report, ensure_ascii=False),
        encoding="utf-8",
    )
PY

for sidebar_scenario in sidebar-filter-navigation sidebar-layout-controls; do
    sidebar_root="$FOREGROUND_SIDEBAR_VERIFY_ROOT/$sidebar_scenario"
    sidebar_verifier_args=(
        --scenario "$sidebar_scenario"
        --session "$sidebar_root/session.json"
        --diagnostic "$sidebar_root/diagnostic.json"
        --foreground-report "$sidebar_root/foreground-report.json"
        --fixture "$ROOT/ui/格式示例.md"
        --workspace-root "$sidebar_root/workspace"
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
        --output-root "$TEMP_ROOT"
    )
    python3 "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
        "${sidebar_verifier_args[@]}" \
        --check-only
    for report_kind in session diagnostic; do
        python3 "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
            "${sidebar_verifier_args[@]}" \
            --report-kind "$report_kind" \
            > "$sidebar_root/$report_kind-report.json"
    done
    python3 - "$sidebar_root" "$sidebar_scenario" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
scenario = sys.argv[2]
for report_kind in ("session", "diagnostic"):
    report = json.loads(
        (root / f"{report_kind}-report.json").read_text(encoding="utf-8")
    )
    assert report["label"] == f"foreground-{scenario}-{report_kind}"
    assert all(report["assertions"].values())
PY
done

python3 - "$FOREGROUND_SIDEBAR_VERIFY_ROOT" <<'PY'
import copy
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
filter_root = root / "sidebar-filter-navigation"
invalid_session = json.loads((filter_root / "session.json").read_text(encoding="utf-8"))
invalid_session["activeTabID"] = "readme-tab"
(filter_root / "invalid-session.json").write_text(
    json.dumps(invalid_session, ensure_ascii=False),
    encoding="utf-8",
)

layout_root = root / "sidebar-layout-controls"
layout_report = json.loads(
    (layout_root / "foreground-report.json").read_text(encoding="utf-8")
)
assert json.loads(
    (filter_root / "foreground-report.json").read_text(encoding="utf-8")
)["targetActivationRequestCount"] == 1
assert layout_report["targetActivationRequestCount"] == 2

invalid_report = copy.deepcopy(layout_report)
invalid_report["phases"][1]["resizeState"]["session"]["sidebarWidth"] = 438
(layout_root / "invalid-report.json").write_text(
    json.dumps(invalid_report, ensure_ascii=False),
    encoding="utf-8",
)

invalid_activation = copy.deepcopy(layout_report)
invalid_activation["targetActivationRequestCount"] = 1
(layout_root / "invalid-activation-report.json").write_text(
    json.dumps(invalid_activation, ensure_ascii=False),
    encoding="utf-8",
)

invalid_restore = copy.deepcopy(layout_report)
invalid_restore["phases"][0]["report"]["focusRestore"]["restored"] = False
(layout_root / "invalid-restore-report.json").write_text(
    json.dumps(invalid_restore, ensure_ascii=False),
    encoding="utf-8",
)
PY

if python3 "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
    --scenario sidebar-filter-navigation \
    --session "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-filter-navigation/invalid-session.json" \
    --diagnostic "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-filter-navigation/diagnostic.json" \
    --foreground-report "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-filter-navigation/foreground-report.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-root "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-filter-navigation/workspace" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-filter.out" \
    2> "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-filter.err"; then
    echo "RealAppHarnessTests: mismatched sidebar filter session unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "fixture tab metadata or active identity changed" \
    "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-filter.err"; then
    echo "RealAppHarnessTests: sidebar filter verifier error was not precise" >&2
    exit 1
fi

if python3 "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
    --scenario sidebar-layout-controls \
    --session "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/session.json" \
    --diagnostic "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/diagnostic.json" \
    --foreground-report "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/invalid-report.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-root "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/workspace" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-layout.out" \
    2> "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-layout.err"; then
    echo "RealAppHarnessTests: mismatched sidebar layout report unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "maximum-toggle resize-state session proof is wrong" \
    "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-layout.err"; then
    echo "RealAppHarnessTests: sidebar layout verifier error was not precise" >&2
    exit 1
fi

for invalid_layout_case in activation restore; do
    if python3 "$ROOT/scripts/e2e/verify-foreground-sidebar.py" \
        --scenario sidebar-layout-controls \
        --session "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/session.json" \
        --diagnostic "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/diagnostic.json" \
        --foreground-report "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/invalid-$invalid_layout_case-report.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --workspace-root "$FOREGROUND_SIDEBAR_VERIFY_ROOT/sidebar-layout-controls/workspace" \
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
        --output-root "$TEMP_ROOT" \
        --check-only \
        > "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-$invalid_layout_case.out" \
        2> "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-$invalid_layout_case.err"; then
        echo "RealAppHarnessTests: invalid sidebar $invalid_layout_case proof passed" >&2
        exit 1
    fi
done
if ! rg -Fq "did not prove bounded, restored completion" \
    "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-activation.err"; then
    echo "RealAppHarnessTests: sidebar activation error was not precise" >&2
    exit 1
fi
if ! rg -Fq "collapse-minimum did not restore focus and pointer" \
    "$FOREGROUND_SIDEBAR_VERIFY_ROOT/invalid-restore.err"; then
    echo "RealAppHarnessTests: sidebar phase restore error was not precise" >&2
    exit 1
fi

TAB_SESSION_VERIFY_ROOT="$TEMP_ROOT/tab-session-lifecycle-verifier"
mkdir -p "$TAB_SESSION_VERIFY_ROOT"
python3 - \
    "$ROOT/ui/格式示例.md" \
    "$TAB_SESSION_VERIFY_ROOT" <<'PY'
import copy
import json
import pathlib
import shutil
import sys

fixture_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
fixture = fixture_path.read_text(encoding="utf-8")
heading_before = "# Markdown 全格式示例"
heading_after = "# Markdown 全格式示例 E2E_RELAUNCH_UNSAVED"
if not fixture.startswith(heading_before) or fixture.count(heading_before) != 1:
    raise SystemExit("tab lifecycle fixture heading drifted")

fixture_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
first_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
second_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
first_source = "E2E_SWITCH_COMMIT"
second_source = "E2E_RIGHT_NEIGHBOR<br><br><br>" * 8
if len(second_source) != 240 or "\n" in second_source:
    raise SystemExit("second draft lifecycle source length drifted")
workspace_fixture = root / "workspace-fixture.md"
shutil.copyfile(fixture_path, workspace_fixture)


def fixture_blocks(mutated=False):
    first_source_value = heading_after if mutated else heading_before
    blocks = [{
        "id": "fixture-block-0",
        "kind": "heading",
        "leadingTrivia": "",
        "source": first_source_value,
    }, {
        "id": "fixture-block-1",
        "kind": "paragraph",
        "leadingTrivia": "",
        "source": fixture[len(heading_before):],
    }]
    for index in range(2, 37):
        blocks.append({
            "id": f"fixture-block-{index}",
            "kind": "paragraph",
            "leadingTrivia": "",
            "source": "",
        })
    return blocks


def fixture_tab(mutated=False, scroll_y=0):
    source = fixture.replace(heading_before, heading_after, 1) if mutated else fixture
    return {
        "id": fixture_id,
        "url": None,
        "name": "格式示例.md",
        "isMarkdown": True,
        "isDirty": mutated,
        "scrollY": scroll_y,
        "selectionLocation": 0,
        "selectionLength": 0,
        "text": source,
        "markdownDocument": {
            "blocks": fixture_blocks(mutated),
            "trailingTrivia": "",
        },
    }


def draft_tab(identifier, name, source, scroll_y=0, selection_location=None):
    if selection_location is None:
        selection_location = len(source)
    return {
        "id": identifier,
        "url": None,
        "name": name,
        "isMarkdown": True,
        "isDirty": True,
        "scrollY": scroll_y,
        "selectionLocation": selection_location,
        "selectionLength": 0,
        "text": source,
        "markdownDocument": {
            "blocks": [{
                "id": f"{identifier}-block",
                "kind": "paragraph",
                "leadingTrivia": "",
                "source": source,
            }],
            "trailingTrivia": "",
        },
    }


def session(
    tabs,
    active_id,
    font_index=1,
    sidebar_width=216,
    sidebar_open=True,
    expanded=None,
):
    if expanded is None:
        expanded = [str(root / "workspace" / "docs")]
    return {
        "schemaVersion": 2,
        "tabs": tabs,
        "activeTabID": active_id,
        "fontIndex": font_index,
        "sidebarWidth": sidebar_width,
        "sidebarOpen": sidebar_open,
        "directoryPath": str(root / "workspace"),
        "expandedFolderPaths": expanded,
    }


def visual(source_editor_visible, sidebar_visible=True, sidebar_width=216):
    return {
        "documentVisible": True,
        "sidebarVisible": sidebar_visible,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": source_editor_visible,
        "tableGridVisible": False,
        "anchors": {
            "document-content-0-paragraph": {
                "x": 375,
                "y": 100,
                "width": 640,
                "height": 980,
            },
            "sidebar-frame": {
                "x": 0,
                "y": 0,
                "width": sidebar_width,
                "height": 760,
            },
        },
    }


def find_state():
    return {
        "query": "",
        "display": "",
        "matchCount": 0,
        "currentIndex": 0,
        "invalidRegex": False,
        "replaceExpanded": False,
        "caseSensitive": False,
        "wholeWord": False,
        "regex": False,
    }


def diagnostic(
    session_path,
    document,
    dirty,
    parse_count,
    mutation_count,
    scroll_y,
    outline,
    block_id=None,
    block_type=None,
    selection=None,
    source_editor_visible=False,
    sidebar_visible=True,
    sidebar_width=216,
):
    return {
        "schemaVersion": 1,
        "document": document,
        "blockID": block_id,
        "blockType": block_type,
        "mode": "edit",
        "selection": selection,
        "activeTableCell": None,
        "dirty": dirty,
        "find": find_state(),
        "outline": outline,
        "scrollY": scroll_y,
        "sessionPath": str(session_path),
        "parseCount": parse_count,
        "localMutationCount": mutation_count,
        "visual": visual(source_editor_visible, sidebar_visible, sidebar_width),
    }


stage1_first = draft_tab(first_id, "未命名.md", first_source)
stage1 = session([fixture_tab(), stage1_first], first_id)
stage2_first = copy.deepcopy(stage1_first)
stage2_second = draft_tab(
    second_id,
    "未命名 2.md",
    second_source,
    scroll_y=640,
    selection_location=0,
)
stage2 = session([fixture_tab(), stage2_second, stage2_first], first_id)
stage3_second = copy.deepcopy(stage2_second)
stage3 = session(
    [fixture_tab(mutated=True, scroll_y=2400), stage3_second],
    second_id,
    font_index=2,
    sidebar_width=312,
    sidebar_open=False,
    expanded=[],
)
relaunch = copy.deepcopy(stage3)
relaunch_scroll_check = copy.deepcopy(relaunch)
relaunch_scroll_check["activeTabID"] = fixture_id
relaunch_scroll_check["sidebarOpen"] = True
relaunch_scroll_check["expandedFolderPaths"] = [
    str(root / "workspace" / "docs")
]

stages = {
    "switch-commit": (
        stage1,
        {
            "document": "未命名.md",
            "dirty": True,
            "parse_count": 2,
            "mutation_count": 1,
            "scroll_y": 0,
            "outline": {"headingCount": 0, "activeIndex": 0},
            "block_id": f"{first_id}-block",
            "block_type": "paragraph",
            "selection": {"location": len(first_source), "length": 0},
            "source_editor_visible": True,
        },
    ),
    "close-right-reopen": (
        stage2,
        {
            "document": "未命名.md",
            "dirty": True,
            "parse_count": 1,
            "mutation_count": 0,
            "scroll_y": 0,
            "outline": {"headingCount": 0, "activeIndex": 0},
        },
    ),
    "close-left-seed": (
        stage3,
        {
            "document": "未命名 2.md",
            "dirty": True,
            "parse_count": 2,
            "mutation_count": 1,
            "scroll_y": 640,
            "outline": {"headingCount": 0, "activeIndex": 0},
            "sidebar_visible": False,
            "sidebar_width": 312,
        },
    ),
    "relaunch": (
        relaunch,
        {
            "document": "未命名 2.md",
            "dirty": True,
            "parse_count": 1,
            "mutation_count": 0,
            "scroll_y": 640,
            "outline": {"headingCount": 0, "activeIndex": 0},
            "sidebar_visible": False,
            "sidebar_width": 312,
        },
    ),
    "relaunch-scroll-check": (
        relaunch_scroll_check,
        {
            "document": "格式示例.md",
            "dirty": True,
            "parse_count": 1,
            "mutation_count": 0,
            "scroll_y": 2400,
            "outline": {"headingCount": 15, "activeIndex": 12},
            "sidebar_width": 312,
        },
    ),
}
live_session_path = (
    root / "profile" / "Application Support" / "MarkdownViewer" / "session.json"
)
for stage, (session_value, diagnostic_options) in stages.items():
    stage_root = root / stage
    stage_root.mkdir()
    session_path = stage_root / "session.json"
    session_path.write_text(
        json.dumps(session_value, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    diagnostic_value = diagnostic(live_session_path, **diagnostic_options)
    (stage_root / "diagnostic.json").write_text(
        json.dumps(diagnostic_value, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

invalid_stable = copy.deepcopy(stage3)
invalid_stable["tabs"][0]["markdownDocument"]["blocks"][2]["id"] = "changed-block-id"
(root / "invalid-stable-session.json").write_text(
    json.dumps(invalid_stable, ensure_ascii=False),
    encoding="utf-8",
)
invalid_relaunch = copy.deepcopy(relaunch)
invalid_relaunch["sidebarWidth"] = 217
(root / "invalid-relaunch-session.json").write_text(
    json.dumps(invalid_relaunch, ensure_ascii=False),
    encoding="utf-8",
)
invalid_visual = json.loads(
    (root / "relaunch" / "diagnostic.json").read_text(encoding="utf-8")
)
invalid_visual["visual"]["paletteVisible"] = True
(root / "invalid-relaunch-diagnostic.json").write_text(
    json.dumps(invalid_visual, ensure_ascii=False),
    encoding="utf-8",
)
invalid_seeded_state = copy.deepcopy(stage3)
invalid_seeded_state["fontIndex"] = 1
(root / "invalid-seeded-state-session.json").write_text(
    json.dumps(invalid_seeded_state, ensure_ascii=False),
    encoding="utf-8",
)
invalid_seeded_active = copy.deepcopy(stage3)
invalid_seeded_active["activeTabID"] = fixture_id
(root / "invalid-seeded-active-session.json").write_text(
    json.dumps(invalid_seeded_active, ensure_ascii=False),
    encoding="utf-8",
)
PY

TAB_SESSION_EXPECTED_PATH="$TAB_SESSION_VERIFY_ROOT/profile/Application Support/MarkdownViewer/session.json"
for tab_stage in \
    switch-commit \
    close-right-reopen \
    close-left-seed \
    relaunch \
    relaunch-scroll-check; do
    tab_stage_root="$TAB_SESSION_VERIFY_ROOT/$tab_stage"
    tab_verifier_args=(
        --stage "$tab_stage"
        --session "$tab_stage_root/session.json"
        --expected-session-path "$TAB_SESSION_EXPECTED_PATH"
        --diagnostic "$tab_stage_root/diagnostic.json"
        --fixture "$ROOT/ui/格式示例.md"
        --workspace-fixture "$TAB_SESSION_VERIFY_ROOT/workspace-fixture.md"
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA"
        --output-root "$TEMP_ROOT"
    )
    case "$tab_stage" in
        close-right-reopen)
            tab_verifier_args+=(
                --previous-session "$TAB_SESSION_VERIFY_ROOT/switch-commit/session.json"
            )
            ;;
        close-left-seed)
            tab_verifier_args+=(
                --previous-session "$TAB_SESSION_VERIFY_ROOT/close-right-reopen/session.json"
            )
            ;;
        relaunch)
            tab_verifier_args+=(
                --previous-session "$TAB_SESSION_VERIFY_ROOT/close-left-seed/session.json"
                --previous-diagnostic "$TAB_SESSION_VERIFY_ROOT/close-left-seed/diagnostic.json"
            )
            ;;
        relaunch-scroll-check)
            tab_verifier_args+=(
                --previous-session "$TAB_SESSION_VERIFY_ROOT/close-left-seed/session.json"
            )
            ;;
    esac
    python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
        "${tab_verifier_args[@]}" \
        --check-only
    for report_kind in session diagnostic; do
        python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
            "${tab_verifier_args[@]}" \
            --report-kind "$report_kind" \
            > "$tab_stage_root/$report_kind-report.json"
    done
done

python3 - "$TAB_SESSION_VERIFY_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected_documents = {
    "switch-commit": "未命名.md",
    "close-right-reopen": "未命名.md",
    "close-left-seed": "未命名 2.md",
    "relaunch": "未命名 2.md",
    "relaunch-scroll-check": "格式示例.md",
}
for stage, document in expected_documents.items():
    stage_root = root / stage
    session_report = json.loads(
        (stage_root / "session-report.json").read_text(encoding="utf-8")
    )
    diagnostic_report = json.loads(
        (stage_root / "diagnostic-report.json").read_text(encoding="utf-8")
    )
    assert session_report["label"] == f"tab-session-{stage}-session"
    assert diagnostic_report["label"] == f"tab-session-{stage}-diagnostic"
    assert session_report["activeDocument"] == document
    assert all(session_report["assertions"].values())
    assert all(diagnostic_report["assertions"].values())
    assert session_report["fixtureSHA256"] == session_report["workspaceFixtureSHA256"]
    assert pathlib.Path(session_report["sessionArtifact"]).name == "session.json"
    assert session_report["sessionArtifact"] != session_report["sessionPath"]
PY

if python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
    --stage close-left-seed \
    --session "$TAB_SESSION_VERIFY_ROOT/invalid-stable-session.json" \
    --expected-session-path "$TAB_SESSION_EXPECTED_PATH" \
    --diagnostic "$TAB_SESSION_VERIFY_ROOT/close-left-seed/diagnostic.json" \
    --previous-session "$TAB_SESSION_VERIFY_ROOT/close-right-reopen/session.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$TAB_SESSION_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$TAB_SESSION_VERIFY_ROOT/invalid-stable.out" \
    2> "$TAB_SESSION_VERIFY_ROOT/invalid-stable.err"; then
    echo "RealAppHarnessTests: changed stable block ID unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "editing the heading changed an untouched block or stable block ID" \
    "$TAB_SESSION_VERIFY_ROOT/invalid-stable.err"; then
    echo "RealAppHarnessTests: stable block verifier error was not precise" >&2
    exit 1
fi

for invalid_seeded_kind in state active; do
    invalid_seeded_session="$TAB_SESSION_VERIFY_ROOT/invalid-seeded-$invalid_seeded_kind-session.json"
    expected_error="non-default font, sidebar, or folder state was not seeded"
    if [[ "$invalid_seeded_kind" == "active" ]]; then
        expected_error="the non-first draft tab is not active after relaunch seeding"
    fi
    if python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
        --stage close-left-seed \
        --session "$invalid_seeded_session" \
        --expected-session-path "$TAB_SESSION_EXPECTED_PATH" \
        --diagnostic "$TAB_SESSION_VERIFY_ROOT/close-left-seed/diagnostic.json" \
        --previous-session "$TAB_SESSION_VERIFY_ROOT/close-right-reopen/session.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --workspace-fixture "$TAB_SESSION_VERIFY_ROOT/workspace-fixture.md" \
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
        --output-root "$TEMP_ROOT" \
        --check-only \
        > "$TAB_SESSION_VERIFY_ROOT/invalid-seeded-$invalid_seeded_kind.out" \
        2> "$TAB_SESSION_VERIFY_ROOT/invalid-seeded-$invalid_seeded_kind.err"; then
        echo "RealAppHarnessTests: invalid seeded $invalid_seeded_kind unexpectedly passed" >&2
        exit 1
    fi
    if ! rg -Fq "$expected_error" \
        "$TAB_SESSION_VERIFY_ROOT/invalid-seeded-$invalid_seeded_kind.err"; then
        echo "RealAppHarnessTests: seeded $invalid_seeded_kind error was not precise" >&2
        exit 1
    fi
done

for invalid_relaunch_kind in session diagnostic; do
    invalid_session="$TAB_SESSION_VERIFY_ROOT/relaunch/session.json"
    invalid_diagnostic="$TAB_SESSION_VERIFY_ROOT/relaunch/diagnostic.json"
    expected_error="normal terminate and relaunch did not preserve the exact session snapshot"
    if [[ "$invalid_relaunch_kind" == "session" ]]; then
        invalid_session="$TAB_SESSION_VERIFY_ROOT/invalid-relaunch-session.json"
    else
        invalid_diagnostic="$TAB_SESSION_VERIFY_ROOT/invalid-relaunch-diagnostic.json"
        expected_error="diagnostic visual state mismatch"
    fi
    if python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
        --stage relaunch \
        --session "$invalid_session" \
        --expected-session-path "$TAB_SESSION_EXPECTED_PATH" \
        --diagnostic "$invalid_diagnostic" \
        --previous-session "$TAB_SESSION_VERIFY_ROOT/close-left-seed/session.json" \
        --previous-diagnostic "$TAB_SESSION_VERIFY_ROOT/close-left-seed/diagnostic.json" \
        --fixture "$ROOT/ui/格式示例.md" \
        --workspace-fixture "$TAB_SESSION_VERIFY_ROOT/workspace-fixture.md" \
        --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
        --output-root "$TEMP_ROOT" \
        --check-only \
        > "$TAB_SESSION_VERIFY_ROOT/invalid-relaunch-$invalid_relaunch_kind.out" \
        2> "$TAB_SESSION_VERIFY_ROOT/invalid-relaunch-$invalid_relaunch_kind.err"; then
        echo "RealAppHarnessTests: invalid relaunch $invalid_relaunch_kind unexpectedly passed" >&2
        exit 1
    fi
    if ! rg -Fq "$expected_error" \
        "$TAB_SESSION_VERIFY_ROOT/invalid-relaunch-$invalid_relaunch_kind.err"; then
        echo "RealAppHarnessTests: relaunch $invalid_relaunch_kind error was not precise" >&2
        exit 1
    fi
done

if python3 "$ROOT/scripts/e2e/verify-tab-session-lifecycle.py" \
    --stage switch-commit \
    --session "$TAB_SESSION_VERIFY_ROOT/switch-commit/session.json" \
    --expected-session-path "$TAB_SESSION_VERIFY_ROOT/wrong-live-session.json" \
    --diagnostic "$TAB_SESSION_VERIFY_ROOT/switch-commit/diagnostic.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --workspace-fixture "$TAB_SESSION_VERIFY_ROOT/workspace-fixture.md" \
    --fixture-sha "$FOREGROUND_FIND_FIXTURE_SHA" \
    --output-root "$TEMP_ROOT" \
    --check-only \
    > "$TAB_SESSION_VERIFY_ROOT/invalid-expected-path.out" \
    2> "$TAB_SESSION_VERIFY_ROOT/invalid-expected-path.err"; then
    echo "RealAppHarnessTests: wrong live session path unexpectedly passed" >&2
    exit 1
fi
if ! rg -Fq "diagnostic session path does not match the isolated profile" \
    "$TAB_SESSION_VERIFY_ROOT/invalid-expected-path.err"; then
    echo "RealAppHarnessTests: expected session path error was not precise" >&2
    exit 1
fi

if python3 "$ROOT/scripts/e2e/verify-find-replace-session.py" \
    --session "$TEMP_ROOT/session-find-replace-current.json" \
    --state replace-all \
    --label invalid-find-session \
    --evidence-root "$TEMP_ROOT" \
    > "$TEMP_ROOT/invalid-find-session.out" \
    2> "$TEMP_ROOT/invalid-find-session.err"; then
    echo "RealAppHarnessTests: mismatched find session unexpectedly passed" >&2
    exit 1
fi

if python3 "$ROOT/scripts/e2e/verify-find-diagnostic.py" \
    --snapshot "$TEMP_ROOT/diagnostic-find.json" \
    --profile-root "$TEMP_ROOT/find-profile" \
    --label invalid-find-diagnostic \
    --query red \
    --display "4/4" \
    --match-count 4 \
    --current-index 3 \
    --replace-expanded true \
    --whole-word true \
    > "$TEMP_ROOT/invalid-find-diagnostic.out" \
    2> "$TEMP_ROOT/invalid-find-diagnostic.err"; then
    echo "RealAppHarnessTests: mismatched find diagnostic unexpectedly passed" >&2
    exit 1
fi

if python3 "$ROOT/scripts/e2e/verify-fixture-session.py" \
    --session "$TEMP_ROOT/session-table.json" \
    --fixture "$ROOT/ui/格式示例.md" \
    --state clean \
    --label invalid \
    --evidence-root "$TEMP_ROOT" \
    > "$TEMP_ROOT/invalid-fixture.out" \
    2> "$TEMP_ROOT/invalid-fixture.err"; then
    echo "RealAppHarnessTests: mismatched fixture state unexpectedly passed" >&2
    exit 1
fi

start_seconds="$(date +%s)"
if "$TEMP_ROOT/RealAppDriver" sidebar \
    --passive \
    --pid 2147483647 \
    --screenshot "$TEMP_ROOT/not-read.png" \
    > "$TEMP_ROOT/passive-sidebar.out" \
    2> "$TEMP_ROOT/passive-sidebar.err"; then
    echo "RealAppHarnessTests: passive sidebar with a missing window unexpectedly succeeded" >&2
    exit 1
fi
elapsed_seconds="$(( $(date +%s) - start_seconds ))"
if [[ "$elapsed_seconds" -gt 3 ]]; then
    echo "RealAppHarnessTests: passive-sidebar window lookup exceeded its bound" >&2
    exit 1
fi
if ! rg -q "no on-screen app window" "$TEMP_ROOT/passive-sidebar.err"; then
    echo "RealAppHarnessTests: passive sidebar option path was not accepted" >&2
    exit 1
fi

start_seconds="$(date +%s)"
if "$TEMP_ROOT/RealAppDriver" window --pid 2147483647 --timeout 0.2 \
    > "$TEMP_ROOT/missing-window.out" \
    2> "$TEMP_ROOT/missing-window.err"; then
    echo "RealAppHarnessTests: missing window unexpectedly succeeded" >&2
    exit 1
fi
elapsed_seconds="$(( $(date +%s) - start_seconds ))"
if [[ "$elapsed_seconds" -gt 2 ]]; then
    echo "RealAppHarnessTests: missing-window timeout exceeded its bound" >&2
    exit 1
fi
if ! rg -q "no on-screen app window" "$TEMP_ROOT/missing-window.err"; then
    echo "RealAppHarnessTests: missing-window error was not precise" >&2
    exit 1
fi

if "$TEMP_ROOT/RealAppDriver" capture-window \
    --pid "$$" \
    --window-number 0 \
    --output "$TEMP_ROOT/invalid-window-number.png" \
    > "$TEMP_ROOT/invalid-window-number.out" \
    2> "$TEMP_ROOT/invalid-window-number.err"; then
    echo "RealAppHarnessTests: invalid capture window number unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -q -- "--window-number requires a positive window number" \
    "$TEMP_ROOT/invalid-window-number.err"; then
    echo "RealAppHarnessTests: invalid capture window number error was not precise" >&2
    exit 1
fi

if "$TEMP_ROOT/RealAppDriver" capture-window \
    --pid "$$" \
    --window-number 1 \
    --output relative-capture.png \
    > "$TEMP_ROOT/relative-capture.out" \
    2> "$TEMP_ROOT/relative-capture.err"; then
    echo "RealAppHarnessTests: relative capture output unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -q -- "--output path must be absolute" "$TEMP_ROOT/relative-capture.err"; then
    echo "RealAppHarnessTests: relative capture output error was not precise" >&2
    exit 1
fi

start_seconds="$(date +%s)"
if "$TEMP_ROOT/RealAppDriver" capture-window \
    --pid "$$" \
    --window-number 4294967295 \
    --output "$TEMP_ROOT/missing-capture-window.png" \
    --timeout 0.2 \
    > "$TEMP_ROOT/missing-capture-window.out" \
    2> "$TEMP_ROOT/missing-capture-window.err"; then
    echo "RealAppHarnessTests: missing capture window unexpectedly succeeded" >&2
    exit 1
fi
elapsed_seconds="$(( $(date +%s) - start_seconds ))"
if [[ "$elapsed_seconds" -gt 2 ]]; then
    echo "RealAppHarnessTests: missing capture window lookup exceeded its bound" >&2
    exit 1
fi
if ! rg -q "no on-screen window 4294967295 for pid $$" \
    "$TEMP_ROOT/missing-capture-window.err"; then
    echo "RealAppHarnessTests: missing capture window error was not precise" >&2
    exit 1
fi
if [[ -e "$TEMP_ROOT/missing-capture-window.png" ]]; then
    echo "RealAppHarnessTests: missing capture window created an output file" >&2
    exit 1
fi

if "$TEMP_ROOT/RealAppDriver" send --pid 0 -- "key:command+f" \
    > "$TEMP_ROOT/bad-pid.out" \
    2> "$TEMP_ROOT/bad-pid.err"; then
    echo "RealAppHarnessTests: invalid pid unexpectedly succeeded" >&2
    exit 1
fi
if ! rg -q -- "--pid requires a positive process id" "$TEMP_ROOT/bad-pid.err"; then
    echo "RealAppHarnessTests: invalid-pid error was not precise" >&2
    exit 1
fi

echo "Real-App harness infrastructure tests passed"
