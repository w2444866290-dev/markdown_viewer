#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib


SCENARIOS = {
    "sidebar-filter-navigation": {
        "sidebarWidth": 216,
        "tabNames": ["格式示例.md", "README.md"],
        "foregroundBudgetMs": 4_000,
        "targetActivationRequestCount": 1,
    },
    "sidebar-layout-controls": {
        "sidebarWidth": 440,
        "tabNames": ["格式示例.md"],
        "foregroundBudgetMs": 8_000,
        "targetActivationRequestCount": 2,
    },
}

FIXTURE_ROW = (
    "sidebar-file-docs%2F"
    "%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd"
)
CONFIG_ROW = "sidebar-file-docs%2Fconfig%2Eyaml"
DOCS_FOLDER = "sidebar-folder-docs"
FILTER_FIELD = "sidebar-filter"
EMPTY_RESULT = "sidebar-filter-empty"
RESIZE_HANDLE = "sidebar-resize-handle"

EXPECTED_FIND = {
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

LAYOUT_PHASES = (
    "collapse-minimum",
    "maximum-toggle",
)
LAYOUT_PHASE_ACTION_KINDS = {
    "collapse-minimum": [
        "move-safe-point",
        "element-click",
        "window-screenshot",
        "element-click",
        "element-check",
        "element-drag",
        "window-screenshot",
    ],
    "maximum-toggle": [
        "move-safe-point",
        "window-drag",
        "window-screenshot",
        "key",
        "wait",
        "window-screenshot",
        "key",
        "wait",
        "window-screenshot",
    ],
}
LAYOUT_PHASE_ESTIMATES = {
    "collapse-minimum": 1_450,
    "maximum-toggle": 1_690,
}
LAYOUT_PHASE_WIDTHS = {
    "collapse-minimum": (216.0, 176.0),
    "maximum-toggle": (176.0, 440.0),
}
MINIMUM_BOUNDARY_X_FRACTION = 175.5 / 1180


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify bounded real-App sidebar foreground interactions."
    )
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--foreground-report", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--workspace-root", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument(
        "--report-kind",
        choices=["session", "diagnostic"],
        default="session",
    )
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def load_json(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is not readable JSON: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must contain a JSON object")
    return value


def fail(message: str) -> None:
    raise SystemExit(f"foreground sidebar verification failed: {message}")


def finite_number(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def exact_integer(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def close(actual: object, expected: float) -> bool:
    number = finite_number(actual)
    return number is not None and math.isclose(number, expected, abs_tol=0.5)


def markdown_round_trip(tab: dict[str, object], expected_source: str) -> list[dict[str, object]]:
    markdown = tab.get("markdownDocument")
    if not isinstance(markdown, dict):
        fail(f"{tab.get('name')} has no structured Markdown document")
    blocks = markdown.get("blocks")
    if not isinstance(blocks, list) \
            or not blocks \
            or any(not isinstance(block, dict) for block in blocks):
        fail(f"{tab.get('name')} has invalid structured Markdown blocks")
    rebuilt = "".join(
        str(block.get("leadingTrivia", "")) + str(block.get("source", ""))
        for block in blocks
    ) + str(markdown.get("trailingTrivia", ""))
    block_ids = [block.get("id") for block in blocks]
    if rebuilt != expected_source \
            or tab.get("text") != expected_source \
            or any(not isinstance(block_id, str) or not block_id for block_id in block_ids) \
            or len(block_ids) != len(set(block_ids)):
        fail(f"{tab.get('name')} block model does not round trip exactly")
    return blocks


def validate_workspace(
    workspace: pathlib.Path,
    fixture_name: str,
    fixture: str,
) -> dict[str, str]:
    workspace = workspace.resolve()
    if not workspace.is_dir():
        fail("workspace root is missing")
    expected = {
        "README.md": "# Markdown Editor\n",
        "docs/config.yaml": "model: gpt-4o\ntemperature: 0.2\n",
        f"docs/{fixture_name}": fixture,
        "更新日志.md": "# 更新日志\n",
    }
    observed_files: dict[str, pathlib.Path] = {}
    for path in workspace.rglob("*"):
        if path.is_symlink():
            fail(f"workspace contains a symlink: {path}")
        if path.is_file():
            observed_files[path.relative_to(workspace).as_posix()] = path
    if set(observed_files) != set(expected):
        fail(f"workspace file set changed: {sorted(observed_files)!r}")
    hashes: dict[str, str] = {}
    for relative_path, expected_text in expected.items():
        path = observed_files[relative_path]
        try:
            actual_text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"workspace file is unreadable: {relative_path}: {error}")
        if actual_text != expected_text:
            fail(f"workspace file content changed: {relative_path}")
        hashes[relative_path] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def element_sequence(report: dict[str, object]) -> list[tuple[str, str, str]]:
    raw_actions = report.get("actions")
    if not isinstance(raw_actions, list):
        fail("foreground report actions are missing")
    sequence: list[tuple[str, str, str]] = []
    for index, action in enumerate(raw_actions):
        if not isinstance(action, dict) \
                or action.get("index") != index \
                or action.get("status") != "completed":
            fail("foreground report action order or status is wrong")
        element = action.get("element")
        if action.get("kind") not in {
            "element-move",
            "element-click",
            "element-check",
            "element-drag",
            "focused-element-check",
        }:
            if element is not None:
                fail("non-element action unexpectedly resolved an AX element")
            continue
        if not isinstance(element, dict):
            fail("semantic foreground action has no AX element report")
        frame = element.get("frame")
        if not isinstance(frame, dict):
            fail("AX element report has no frame")
        numbers = [finite_number(frame.get(key)) for key in ("x", "y", "width", "height")]
        if any(number is None for number in numbers) \
                or numbers[2] is None \
                or numbers[3] is None \
                or numbers[2] <= 0 \
                or numbers[3] <= 0:
            fail("AX element frame is not finite and positive")
        identifier = element.get("identifier")
        role = element.get("role")
        if not isinstance(identifier, str) or not identifier \
                or not isinstance(role, str) or not role:
            fail("AX element identifier or role is empty")
        sequence.append((str(action.get("kind")), identifier, role))
    return sequence


def validate_embedded_resize_state(
    phase: str,
    state: object,
) -> None:
    expected_begin, expected_end = LAYOUT_PHASE_WIDTHS[phase]
    if not isinstance(state, dict):
        fail(f"sidebar layout {phase} resize-state is missing")
    assertions = state.get("assertions")
    session = state.get("session")
    diagnostic = state.get("diagnostic")
    pointer_trace = state.get("pointerTrace")
    if state.get("schemaVersion") != 1 \
            or state.get("suite") != "sidebar-layout-controls" \
            or state.get("phase") != phase \
            or not close(state.get("expectedBeginWidth"), expected_begin) \
            or not close(state.get("expectedEndWidth"), expected_end) \
            or not isinstance(assertions, dict) \
            or set(assertions) != {
                "persistedWidthReached",
                "sidebarRemainedOpen",
                "diagnosticAnchorReached",
                "diagnosticAnchorHeightExact",
                "latestResizeBeganAtExpectedWidth",
                "latestResizeChangedThroughExpectedWidth",
                "latestResizeEndedAtExpectedWidth",
            } \
            or any(value is not True for value in assertions.values()):
        fail(f"sidebar layout {phase} resize-state assertions are incomplete")
    if not isinstance(session, dict) \
            or session.get("schemaVersion") != 2 \
            or session.get("sidebarOpen") is not True \
            or not close(session.get("sidebarWidth"), expected_end) \
            or not isinstance(session.get("path"), str) \
            or not isinstance(session.get("expectedLivePath"), str):
        fail(f"sidebar layout {phase} resize-state session proof is wrong")
    anchor = diagnostic.get("sidebarAnchor") \
        if isinstance(diagnostic, dict) else None
    if not isinstance(diagnostic, dict) \
            or diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("sessionPath") != session["expectedLivePath"] \
            or diagnostic.get("sidebarVisible") is not True \
            or not isinstance(anchor, dict) \
            or not close(anchor.get("x"), 0.0) \
            or not close(anchor.get("y"), 0.0) \
            or not close(anchor.get("width"), expected_end) \
            or not close(anchor.get("height"), 760.0):
        fail(f"sidebar layout {phase} resize-state diagnostic proof is wrong")
    segment = pointer_trace.get("latestResizeSegment") \
        if isinstance(pointer_trace, dict) else None
    if not isinstance(pointer_trace, dict) \
            or pointer_trace.get("schemaVersion") != 1 \
            or exact_integer(pointer_trace.get("entryCount")) is None \
            or pointer_trace["entryCount"] <= 0 \
            or not isinstance(segment, dict):
        fail(f"sidebar layout {phase} resize-state pointer proof is wrong")
    began = segment.get("began")
    changed = segment.get("changed")
    ended = segment.get("ended")
    if not isinstance(began, dict) \
            or not isinstance(changed, list) \
            or not changed \
            or any(not isinstance(entry, dict) for entry in changed) \
            or not isinstance(ended, dict) \
            or not close(began.get("sidebarWidth"), expected_begin) \
            or not any(
                close(entry.get("sidebarWidth"), expected_end)
                for entry in changed
            ) \
            or not close(ended.get("sidebarWidth"), expected_end):
        fail(f"sidebar layout {phase} latest resize segment proof is wrong")
    sequences = [
        began.get("sequence"),
        *(entry.get("sequence") for entry in changed),
        ended.get("sequence"),
    ]
    if any(exact_integer(value) is None for value in sequences) \
            or sequences != sorted(set(sequences)):
        fail(f"sidebar layout {phase} resize segment order is wrong")


def validate_layout_phase_aggregate(report: dict[str, object]) -> None:
    phases = report.get("phases")
    flat_actions = report.get("actions")
    root_pid = report.get("pid")
    if report.get("schemaVersion") != 1 \
            or report.get("suite") != "sidebar-layout-controls" \
            or report.get("phaseCount") != 2 \
            or report.get("perPhaseBudgetMs") != 4_000 \
            or report.get("totalBudgetMs") != 8_000 \
            or not isinstance(phases, list) \
            or len(phases) != len(LAYOUT_PHASES) \
            or not isinstance(flat_actions, list):
        fail("sidebar layout aggregate schema is wrong")
    if not isinstance(root_pid, int) \
            or isinstance(root_pid, bool) \
            or root_pid <= 0 \
            or report.get("pids") != [root_pid, root_pid]:
        fail("sidebar layout aggregate process identity is wrong")

    expected_flat_actions = []
    phase_duration_ms = 0.0
    for phase_index, (phase_name, phase_evidence) in enumerate(
        zip(LAYOUT_PHASES, phases)
    ):
        if not isinstance(phase_evidence, dict) \
                or phase_evidence.get("name") != phase_name:
            fail("sidebar layout aggregate phase order is wrong")
        plan = phase_evidence.get("plan")
        validation = phase_evidence.get("planValidation")
        phase_report = phase_evidence.get("report")
        window_after = phase_evidence.get("windowAfter")
        resize_state = phase_evidence.get("resizeState")
        expected_kinds = LAYOUT_PHASE_ACTION_KINDS[phase_name]
        if not isinstance(plan, dict) \
                or plan.get("schemaVersion") != 1 \
                or not isinstance(plan.get("actions"), list) \
                or [action.get("kind") for action in plan["actions"]] \
                    != expected_kinds:
            fail(f"sidebar layout {phase_name} plan changed")
        if phase_name == "collapse-minimum":
            drag = plan["actions"][5]
            if drag.get("identifier") != RESIZE_HANDLE \
                    or drag.get("deltaX") != -120:
                fail("sidebar layout collapse-minimum drag contract changed")
        else:
            drag = plan["actions"][1]
            x_fraction = finite_number(drag.get("xFraction"))
            if x_fraction is None \
                    or not math.isclose(
                        x_fraction,
                        MINIMUM_BOUNDARY_X_FRACTION,
                        abs_tol=1e-15,
                    ) \
                    or drag.get("yFraction") != 0.5 \
                    or drag.get("deltaX") != 320:
                fail("sidebar layout maximum-toggle window drag contract changed")

        if not isinstance(validation, dict) \
                or validation.get("valid") is not True \
                or validation.get("budgetMs") != 4_000 \
                or validation.get("cleanupReserveMs") != 400 \
                or validation.get("estimatedForegroundMs") \
                    != LAYOUT_PHASE_ESTIMATES[phase_name] \
                or not isinstance(validation.get("actions"), list) \
                or len(validation["actions"]) != len(expected_kinds):
            fail(f"sidebar layout {phase_name} validation changed")
        if [action.get("kind") for action in validation["actions"]] \
                != expected_kinds \
                or [action.get("index") for action in validation["actions"]] \
                != list(range(len(expected_kinds))):
            fail(f"sidebar layout {phase_name} validated actions changed")

        if not isinstance(phase_report, dict):
            fail(f"sidebar layout {phase_name} report is missing")
        phase_actions = phase_report.get("actions")
        phase_interference = phase_report.get("interference")
        phase_focus = phase_report.get("focusRestore")
        phase_pointer = phase_report.get("pointerRestore")
        phase_duration = finite_number(phase_report.get("durationMs"))
        if phase_report.get("pid") != root_pid \
                or phase_report.get("budgetMs") != 4_000 \
                or phase_report.get("targetActivationRequestCount") != 1 \
                or phase_report.get("completed") is not True \
                or phase_report.get("deadlineExceeded") is not False \
                or phase_report.get("error") not in {None, ""} \
                or phase_duration is None \
                or not 0 <= phase_duration <= 4_000 \
                or not isinstance(phase_actions, list) \
                or len(phase_actions) != len(expected_kinds):
            fail(f"sidebar layout {phase_name} did not complete within its budget")
        if not isinstance(phase_interference, dict) \
                or phase_interference.get("detected") is not False \
                or phase_interference.get("pointerInputDetected") is not False \
                or phase_interference.get(
                    "pointerPositionInterferenceDetected"
                ) is not False \
                or phase_interference.get("eventTapReliable") is not True:
            fail(f"sidebar layout {phase_name} detected interference")
        if not isinstance(phase_focus, dict) \
                or phase_focus.get("attempted") is not True \
                or phase_focus.get("restored") is not True \
                or not isinstance(phase_pointer, dict) \
                or phase_pointer.get("attempted") is not True \
                or phase_pointer.get("restored") is not True:
            fail(f"sidebar layout {phase_name} did not restore focus and pointer")
        if [action.get("kind") for action in phase_actions] != expected_kinds \
                or [action.get("index") for action in phase_actions] \
                    != list(range(len(expected_kinds))) \
                or any(action.get("status") != "completed" for action in phase_actions):
            fail(f"sidebar layout {phase_name} action sequence is incomplete")
        for action in phase_actions:
            if action.get("kind") not in {"element-drag", "window-drag"}:
                continue
            start_readiness = action.get("pointerClickReadiness")
            endpoint_readiness = action.get("pointerDragEndpointReadiness")
            if not isinstance(start_readiness, dict) \
                    or start_readiness.get("ready") is not True \
                    or not isinstance(endpoint_readiness, dict) \
                    or endpoint_readiness.get("ready") is not True:
                fail(f"sidebar layout {phase_name} drag endpoints were not ready")
            for receipt_name in (
                "injectedPointerEvents",
                "targetInjectedPointerEvents",
            ):
                receipt = action.get(receipt_name)
                drag_count = (
                    receipt.get("leftMouseDraggedCount")
                    if isinstance(receipt, dict) else None
                )
                if not isinstance(receipt, dict) \
                        or receipt.get("completeDragSequenceObserved") is not True \
                        or not isinstance(drag_count, int) \
                        or isinstance(drag_count, bool) \
                        or drag_count < 2:
                    fail(
                        f"sidebar layout {phase_name} drag has no complete "
                        f"{receipt_name} receipt"
                    )
        if not isinstance(window_after, dict) \
                or window_after.get("pid") != root_pid \
                or window_after.get("onScreen") is not False \
                or window_after.get("layer") != 0:
            fail(f"sidebar layout {phase_name} window was not restored offscreen")
        validate_embedded_resize_state(phase_name, resize_state)

        phase_duration_ms += phase_duration
        for phase_action_index, action in enumerate(phase_actions):
            expected_flat_actions.append({
                **action,
                "index": len(expected_flat_actions),
                "phase": phase_name,
                "phaseIndex": phase_index,
                "phaseActionIndex": phase_action_index,
            })

    aggregate_duration = finite_number(report.get("durationMs"))
    if flat_actions != expected_flat_actions:
        fail("sidebar layout flattened action evidence is inconsistent")
    if aggregate_duration is None \
            or not math.isclose(aggregate_duration, phase_duration_ms, abs_tol=0.001):
        fail("sidebar layout aggregate duration is inconsistent")


def validate_foreground_report(
    report: dict[str, object],
    scenario: str,
) -> None:
    expected = SCENARIOS[scenario]
    interference = report.get("interference")
    focus_restore = report.get("focusRestore")
    pointer_restore = report.get("pointerRestore")
    if report.get("completed") is not True \
            or report.get("budgetMs") != expected["foregroundBudgetMs"] \
            or report.get("targetActivationRequestCount") \
                != expected["targetActivationRequestCount"] \
            or report.get("deadlineExceeded") is not False \
            or report.get("error") not in {None, ""} \
            or not isinstance(interference, dict) \
            or interference.get("detected") is not False \
            or not isinstance(focus_restore, dict) \
            or focus_restore.get("restored") is not True \
            or not isinstance(pointer_restore, dict) \
            or pointer_restore.get("restored") is not True:
        fail("foreground report did not prove bounded, restored completion")

    sequence = element_sequence(report)
    if scenario == "sidebar-filter-navigation":
        expected = [
            ("element-click", FILTER_FIELD, "AXTextField"),
            ("focused-element-check", FILTER_FIELD, "AXTextField"),
            ("element-check", FIXTURE_ROW, "AXButton"),
            ("element-check", CONFIG_ROW, "AXButton"),
            ("element-check", EMPTY_RESULT, "AXStaticText"),
            ("focused-element-check", FILTER_FIELD, "AXTextField"),
        ]
        if sequence != expected:
            fail(f"sidebar filter AX sequence changed: {sequence!r}")
        return

    validate_layout_phase_aggregate(report)

    expected_identifiers = [
        ("element-click", DOCS_FOLDER),
        ("element-click", DOCS_FOLDER),
        ("element-check", CONFIG_ROW),
        ("element-drag", RESIZE_HANDLE),
    ]
    if [(kind, identifier) for kind, identifier, _ in sequence] != expected_identifiers:
        fail(f"sidebar layout AX sequence changed: {sequence!r}")
    for kind, identifier, role in sequence:
        if identifier in {DOCS_FOLDER, CONFIG_ROW} and role != "AXButton":
            fail(f"sidebar row has the wrong AX role: {identifier} {role}")

    drag_actions = [
        action for action in report["actions"]
        if action.get("kind") in {"element-drag", "window-drag"}
    ]
    for action in drag_actions:
        start_readiness = action.get("pointerClickReadiness")
        end_readiness = action.get("pointerDragEndpointReadiness")
        if not isinstance(start_readiness, dict) \
                or start_readiness.get("ready") is not True \
                or not isinstance(end_readiness, dict) \
                or end_readiness.get("ready") is not True:
            fail("sidebar drag endpoints were not both routing-ready")
        for receipt_name in (
            "injectedPointerEvents",
            "targetInjectedPointerEvents",
        ):
            receipt = action.get(receipt_name)
            if not isinstance(receipt, dict) \
                    or receipt.get("completeDragSequenceObserved") is not True \
                    or not isinstance(receipt.get("leftMouseDraggedCount"), int) \
                    or receipt["leftMouseDraggedCount"] < 2:
                fail(f"sidebar drag has no complete {receipt_name} receipt")



def validate_diagnostic(
    diagnostic: dict[str, object],
    session_path: pathlib.Path,
) -> None:
    find = diagnostic.get("find")
    outline = diagnostic.get("outline")
    visual = diagnostic.get("visual")
    if not isinstance(find, dict) \
            or not isinstance(outline, dict) \
            or not isinstance(visual, dict):
        fail("diagnostic Find, outline, or visual state is missing")
    if any(find.get(key) != value for key, value in EXPECTED_FIND.items()):
        fail(f"Find diagnostic changed: {find!r}")
    diagnostic_session_path = pathlib.Path(
        str(diagnostic.get("sessionPath", ""))
    ).resolve()
    scroll_y = finite_number(diagnostic.get("scrollY"))
    if diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("activeTableCell") is not None \
            or diagnostic.get("dirty") is not False \
            or diagnostic.get("localMutationCount") != 0 \
            or diagnostic.get("parseCount") != 1 \
            or diagnostic_session_path != session_path.resolve() \
            or scroll_y is None \
            or not math.isclose(scroll_y, 0, abs_tol=0.5) \
            or outline.get("headingCount") != 15 \
            or outline.get("activeIndex") != 0 \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("paletteVisible") is not False \
            or visual.get("findPanelVisible") is not False \
            or visual.get("replaceRowVisible") is not False \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False:
        fail("final editor, outline, or visual diagnostic mismatch")


def main() -> None:
    arguments = parse_args()
    scenario = arguments.scenario
    expected = SCENARIOS[scenario]
    session_path = pathlib.Path(arguments.session)
    diagnostic_path = pathlib.Path(arguments.diagnostic)
    foreground_report_path = pathlib.Path(arguments.foreground_report)
    fixture_path = pathlib.Path(arguments.fixture)
    workspace = pathlib.Path(arguments.workspace_root).resolve()
    output_root = pathlib.Path(arguments.output_root)

    session = load_json(session_path, "session")
    diagnostic = load_json(diagnostic_path, "diagnostic")
    foreground_report = load_json(foreground_report_path, "foreground report")
    try:
        fixture = fixture_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"fixture is unreadable: {error}")

    workspace_hashes = validate_workspace(workspace, fixture_path.name, fixture)
    validate_foreground_report(foreground_report, scenario)

    tabs = session.get("tabs")
    if not isinstance(tabs, list) \
            or any(not isinstance(tab, dict) for tab in tabs) \
            or [tab.get("name") for tab in tabs] != expected["tabNames"]:
        fail(f"session tab set or order is wrong: {tabs!r}")
    fixture_tab = tabs[0]
    fixture_scroll = finite_number(fixture_tab.get("scrollY"))
    if session.get("activeTabID") != fixture_tab.get("id") \
            or fixture_tab.get("url") is not None \
            or fixture_tab.get("isMarkdown") is not True \
            or fixture_tab.get("isDirty") is not False \
            or fixture_scroll is None \
            or not math.isclose(fixture_scroll, 0, abs_tol=0.5):
        fail("fixture tab metadata or active identity changed")
    fixture_blocks = markdown_round_trip(fixture_tab, fixture)
    if len(fixture_blocks) != 37 \
            or sum(block.get("kind") == "heading" for block in fixture_blocks) != 15:
        fail("fixture block structure changed")

    if scenario == "sidebar-filter-navigation":
        readme_tab = tabs[1]
        readme_path = workspace / "README.md"
        readme_scroll = finite_number(readme_tab.get("scrollY"))
        if pathlib.Path(str(readme_tab.get("url", ""))).resolve() != readme_path.resolve() \
                or readme_tab.get("isMarkdown") is not True \
                or readme_tab.get("isDirty") is not False \
                or readme_scroll is None \
                or not math.isclose(readme_scroll, 0, abs_tol=0.5):
            fail("README tab metadata changed")
        readme_blocks = markdown_round_trip(readme_tab, "# Markdown Editor\n")
        if len(readme_blocks) != 1 \
                or readme_blocks[0].get("kind") != "heading" \
                or readme_blocks[0].get("source") != "# Markdown Editor":
            fail("README structured Markdown changed")

    expected_sidebar_width = float(expected["sidebarWidth"])
    sidebar_width = finite_number(session.get("sidebarWidth"))
    docs_path = (workspace / "docs").resolve()
    if session.get("schemaVersion") != 2:
        fail(f"session schema version is wrong: {session.get('schemaVersion')!r}")
    if session.get("fontIndex") != 1:
        fail(f"persisted font index changed: {session.get('fontIndex')!r}")
    if sidebar_width is None \
            or not math.isclose(sidebar_width, expected_sidebar_width, abs_tol=0.5):
        fail(
            "persisted sidebar width is wrong: "
            f"{session.get('sidebarWidth')!r} != {expected_sidebar_width}"
        )
    if session.get("sidebarOpen") is not True:
        fail(f"persisted sidebar visibility is wrong: {session.get('sidebarOpen')!r}")
    persisted_directory = pathlib.Path(
        str(session.get("directoryPath", ""))
    ).resolve()
    if persisted_directory != workspace:
        fail(f"persisted workspace is wrong: {persisted_directory} != {workspace}")
    expanded_paths = session.get("expandedFolderPaths")
    expanded_paths_match = (
        isinstance(expanded_paths, list)
        and len(expanded_paths) == 1
        and isinstance(expanded_paths[0], str)
        and pathlib.Path(expanded_paths[0]).resolve() == docs_path
    )
    if not expanded_paths_match:
        fail(
            "persisted folder expansion is wrong: "
            f"{session.get('expandedFolderPaths')!r} != {[str(docs_path)]!r}"
        )

    validate_diagnostic(diagnostic, session_path)
    fixture_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
    workspace_fixture_hash = workspace_hashes[f"docs/{fixture_path.name}"]
    if fixture_hash != arguments.fixture_sha \
            or workspace_fixture_hash != arguments.fixture_sha:
        fail("bundle or workspace fixture bytes changed")
    if arguments.check_only:
        return

    if arguments.report_kind == "session":
        payload = {
            "label": f"foreground-{scenario}-session",
            "assertions": {
                "activeFixtureSourceExact": fixture_tab["text"] == fixture,
                "fixtureBlockModelRoundTripsExactly": (
                    len(fixture_blocks) == 37
                    and sum(
                        block.get("kind") == "heading"
                        for block in fixture_blocks
                    ) == 15
                ),
                "tabSetExact": [tab["name"] for tab in tabs] == expected["tabNames"],
                "sidebarWidthExact": math.isclose(
                    sidebar_width,
                    expected_sidebar_width,
                    abs_tol=0.5,
                ),
                "sidebarVisible": session["sidebarOpen"] is True,
                "docsFolderExpanded": expanded_paths_match,
                "workspaceFilesExact": len(workspace_hashes) == 4,
                "bundleFixtureUnchanged": fixture_hash == arguments.fixture_sha,
                "workspaceFixtureUnchanged": (
                    workspace_fixture_hash == arguments.fixture_sha
                ),
            },
            "activeDocument": fixture_tab["name"],
            "sidebarWidth": sidebar_width,
            "sessionPath": os.path.relpath(session_path, output_root),
            "fixtureSHA256": fixture_hash,
            "workspaceFixtureSHA256": workspace_fixture_hash,
            "workspaceFileSHA256": workspace_hashes,
        }
    else:
        payload = {
            "label": f"foreground-{scenario}-diagnostic",
            "assertions": {
                "editingSurfacesClosed": (
                    diagnostic["blockID"] is None
                    and diagnostic["activeTableCell"] is None
                    and diagnostic["visual"]["sourceEditorVisible"] is False
                    and diagnostic["visual"]["tableGridVisible"] is False
                ),
                "navigationDidNotMutateSource": (
                    diagnostic["dirty"] is False
                    and diagnostic["localMutationCount"] == 0
                    and diagnostic["parseCount"] == 1
                ),
                "sidebarVisibleAfterBatch": diagnostic["visual"]["sidebarVisible"] is True,
                "foregroundBatchRestoredDesktop": (
                    foreground_report["focusRestore"]["restored"] is True
                    and foreground_report["pointerRestore"]["restored"] is True
                ),
            },
            "snapshot": diagnostic,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
