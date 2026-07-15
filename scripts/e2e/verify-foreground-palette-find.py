#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib


MARKER = "E2E_PALETTE_COMMIT"
PHASES = ("block-find", "palette-keyboard")
PHASE_ESTIMATES = {"block-find": 2_190, "palette-keyboard": 1_690}
PHASE_KINDS = {
    "block-find": [
        "move-safe-point",
        "wait",
        "window-click",
        "wait",
        "text",
        "key",
        "window-screenshot",
        "key",
        "key",
        "key",
        "wait",
        "find-control-click",
        "find-control-click",
        "text",
        "key",
        "key",
        "find-control-click",
        "find-control-click",
        "text",
        "window-screenshot",
    ],
    "palette-keyboard": [
        "move-safe-point",
        "key",
        "shift-tap",
        "shift-tap",
        "text",
        "window-screenshot",
        "window-move",
        "window-screenshot",
        "key",
        "key",
        "key",
        "key",
        "key",
        "key",
        "window-click",
    ],
}
EXPECTED_FIND = {
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
PHASE_ASSERTIONS = {
    "activeEditCommittedExactlyOnce",
    "structuredSourceRoundTrips",
    "readOnlyFixtureUnchanged",
    "fontStateReached",
    "editorClosed",
    "findStateReached",
    "visualStateReached",
    "diagnosticCountsReached",
    "sessionIdentityMatched",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the complete two-phase palette and Find foreground suite."
    )
    parser.add_argument("--session", required=True)
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--foreground-report", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument(
        "--report-kind",
        choices=("session", "diagnostic"),
        default="session",
    )
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"foreground palette-find verification failed: {message}")


def load_object(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not readable JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def exact_integer(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def finite_number(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def assert_plan_semantics(phase: str, actions: list[dict[str, object]]) -> None:
    if [action.get("kind") for action in actions] != PHASE_KINDS[phase]:
        fail(f"{phase} planned action sequence changed")
    if phase == "block-find":
        if actions[2].get("xFraction") != 0.44 \
                or actions[2].get("yFraction") != 0.125 \
                or actions[4].get("text") != MARKER \
                or actions[5].get("key") != "command+k" \
                or pathlib.Path(str(actions[6].get("path", ""))).name \
                    != "active-edit-palette.png" \
                or actions[7].get("key") != "command+k" \
                or actions[8].get("key") != "command+minus" \
                or actions[9].get("key") != "command+f" \
                or [actions[index].get("control") for index in (11, 12, 16, 17)] \
                    != ["whole-word", "query-field", "disclosure", "replace-field"] \
                or actions[13].get("text") != "一级标题" \
                or actions[14].get("key") != "return" \
                or actions[15].get("key") != "shift+return" \
                or actions[18].get("text") != "E2E_REPLACE" \
                or pathlib.Path(str(actions[19].get("path", ""))).name \
                    != "find-populated.png":
            fail("block-find interaction semantics changed")
    else:
        if actions[0].get("kind") != "move-safe-point" \
                or actions[1].get("key") != "command+f" \
                or actions[2].get("kind") != "shift-tap" \
                or actions[3].get("kind") != "shift-tap" \
                or actions[4].get("text") != "字号" \
                or pathlib.Path(str(actions[5].get("path", ""))).name \
                    != "palette-filter-default.png" \
                or actions[6].get("xFraction") != 0.5 \
                or actions[6].get("yFraction") != 0.3526 \
                or pathlib.Path(str(actions[7].get("path", ""))).name \
                    != "palette-hover.png" \
                or [actions[index].get("key") for index in range(8, 14)] \
                    != [
                        "down", "up", "up", "return",
                        "command+shift+equals", "command+k",
                    ] \
                or actions[14].get("xFraction") != 0.9 \
                or actions[14].get("yFraction") != 0.85:
            fail("palette-keyboard interaction semantics changed")


def validate_phase_state(phase: str, state: object) -> None:
    if not isinstance(state, dict) \
            or state.get("schemaVersion") != 1 \
            or state.get("suite") != "palette-find" \
            or state.get("phase") != phase \
            or state.get("marker") != MARKER:
        fail(f"{phase} persisted state is missing")
    assertions = state.get("assertions")
    session = state.get("session")
    diagnostic = state.get("diagnostic")
    if not isinstance(assertions, dict) \
            or set(assertions) != PHASE_ASSERTIONS \
            or any(value is not True for value in assertions.values()):
        fail(f"{phase} persisted assertions are incomplete")
    if not isinstance(session, dict) \
            or session.get("schemaVersion") != 2 \
            or session.get("activeDocument") != "格式示例.md" \
            or session.get("tabCount") != 1 \
            or session.get("dirty") is not True \
            or session.get("fontIndex") != (0 if phase == "block-find" else 1) \
            or session.get("markerCount") != 1 \
            or session.get("structuredMarkerCount") != 1:
        fail(f"{phase} persisted session proof is wrong")
    if not isinstance(diagnostic, dict) \
            or diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("sessionPath") != session.get("expectedLivePath") \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1 \
            or diagnostic.get("find") != EXPECTED_FIND[phase]:
        fail(f"{phase} persisted diagnostic proof is wrong")
    visual = diagnostic.get("visual")
    expected_visible = phase == "block-find"
    if not isinstance(visual, dict) \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("paletteVisible") is not False \
            or visual.get("findPanelVisible") is not expected_visible \
            or visual.get("replaceRowVisible") is not expected_visible \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False:
        fail(f"{phase} persisted visual proof is wrong")


def validate_aggregate(report: dict[str, object]) -> list[dict[str, object]]:
    phases = report.get("phases")
    flat_actions = report.get("actions")
    pid = exact_integer(report.get("pid"))
    duration = finite_number(report.get("durationMs"))
    if report.get("schemaVersion") != 1 \
            or report.get("suite") != "palette-find" \
            or pid is None \
            or pid <= 0 \
            or report.get("pids") != [pid, pid] \
            or report.get("phaseCount") != 2 \
            or report.get("perPhaseBudgetMs") != 4_000 \
            or report.get("totalBudgetMs") != 8_000 \
            or report.get("budgetMs") != 8_000 \
            or report.get("targetActivationRequestCount") != 2 \
            or report.get("completed") is not True \
            or report.get("deadlineExceeded") is not False \
            or report.get("error") not in {None, ""} \
            or duration is None \
            or not 0 <= duration <= 8_000 \
            or not isinstance(phases, list) \
            or len(phases) != 2 \
            or not isinstance(flat_actions, list):
        fail("aggregate did not prove two bounded activations")
    interference = report.get("interference")
    if not isinstance(interference, dict) \
            or interference.get("detected") is not False \
            or interference.get("pointerInputDetected") is not False \
            or interference.get("pointerPositionInterferenceDetected") is not False \
            or interference.get("eventTapReliable") is not True:
        fail("aggregate interference proof is incomplete")
    for label, attempted in (
        ("focusRestore", True),
        ("pointerRestore", True),
        ("pasteboardRestore", False),
    ):
        restore = report.get(label)
        if not isinstance(restore, dict) \
                or restore.get("attempted") is not attempted \
                or restore.get("restored") is not True:
            fail(f"aggregate {label} proof is incomplete")

    expected_flat = []
    phase_duration = 0.0
    live_session_paths = []
    for phase_index, (phase, evidence) in enumerate(zip(PHASES, phases)):
        if not isinstance(evidence, dict) or evidence.get("name") != phase:
            fail("aggregate phase order is wrong")
        plan = evidence.get("plan")
        validation = evidence.get("planValidation")
        phase_report = evidence.get("report")
        window = evidence.get("windowAfter")
        if not isinstance(plan, dict) \
                or plan.get("schemaVersion") != 1 \
                or not isinstance(plan.get("actions"), list) \
                or any(not isinstance(action, dict) for action in plan["actions"]):
            fail(f"{phase} embedded plan is invalid")
        assert_plan_semantics(phase, plan["actions"])
        if not isinstance(validation, dict) \
                or validation.get("valid") is not True \
                or validation.get("budgetMs") != 4_000 \
                or validation.get("cleanupReserveMs") != 400 \
                or validation.get("estimatedForegroundMs") != PHASE_ESTIMATES[phase] \
                or not isinstance(validation.get("actions"), list) \
                or [action.get("index") for action in validation["actions"]] \
                    != list(range(len(PHASE_KINDS[phase]))) \
                or [action.get("kind") for action in validation["actions"]] \
                    != PHASE_KINDS[phase]:
            fail(f"{phase} embedded plan validation is wrong")
        if PHASE_ESTIMATES[phase] + 400 >= 3_600:
            fail(f"{phase} no longer has substantial cleanup headroom")
        if not isinstance(phase_report, dict):
            fail(f"{phase} embedded foreground report is missing")
        phase_actions = phase_report.get("actions")
        phase_interference = phase_report.get("interference")
        phase_duration_value = finite_number(phase_report.get("durationMs"))
        if phase_report.get("pid") != pid \
                or phase_report.get("budgetMs") != 4_000 \
                or phase_report.get("targetActivationRequestCount") != 1 \
                or phase_report.get("completed") is not True \
                or phase_report.get("deadlineExceeded") is not False \
                or phase_report.get("error") not in {None, ""} \
                or phase_duration_value is None \
                or not 0 <= phase_duration_value <= 4_000 \
                or not isinstance(phase_actions, list) \
                or len(phase_actions) != len(PHASE_KINDS[phase]):
            fail(f"{phase} was not one bounded complete activation")
        if not isinstance(phase_interference, dict) \
                or phase_interference.get("detected") is not False \
                or phase_interference.get("pointerInputDetected") is not False \
                or phase_interference.get(
                    "pointerPositionInterferenceDetected"
                ) is not False \
                or phase_interference.get("eventTapReliable") is not True:
            fail(f"{phase} detected interference")
        for label, attempted in (
            ("focusRestore", True),
            ("pointerRestore", True),
            ("pasteboardRestore", False),
        ):
            restore = phase_report.get(label)
            if not isinstance(restore, dict) \
                    or restore.get("attempted") is not attempted \
                    or restore.get("restored") is not True:
                fail(f"{phase} did not restore {label}")
        if phase_report["focusRestore"].get("priorPID") == pid:
            fail(f"{phase} focus restore points back to the target process")
        if not isinstance(window, dict) \
                or window.get("pid") != pid \
                or window.get("onScreen") is not False \
                or window.get("layer") != 0:
            fail(f"{phase} window was not restored offscreen")
        for action_index, action in enumerate(phase_actions):
            if not isinstance(action, dict) \
                    or action.get("index") != action_index \
                    or action.get("kind") != PHASE_KINDS[phase][action_index] \
                    or action.get("status") != "completed":
                fail(f"{phase} reported action sequence is incomplete")
            expected_flat.append({
                "action": action,
                "phase": phase,
                "phaseIndex": phase_index,
                "phaseActionIndex": action_index,
            })
        validate_phase_state(phase, evidence.get("phaseState"))
        live_session_paths.append(
            evidence["phaseState"]["session"].get("expectedLivePath")
        )
        phase_duration += phase_duration_value

    if len(set(live_session_paths)) != 1:
        fail("phases did not persist to the same isolated session")
    if not math.isclose(duration, phase_duration, abs_tol=0.001):
        fail("aggregate duration does not equal the two phase durations")
    if len(flat_actions) != len(expected_flat):
        fail("aggregate flattened action count is wrong")
    for index, (actual, expected) in enumerate(zip(flat_actions, expected_flat)):
        action = expected["action"]
        if not isinstance(actual, dict) \
                or actual.get("index") != index \
                or actual.get("phase") != expected["phase"] \
                or actual.get("phaseIndex") != expected["phaseIndex"] \
                or actual.get("phaseActionIndex") != expected["phaseActionIndex"] \
                or actual.get("kind") != action.get("kind") \
                or actual.get("status") != action.get("status"):
            fail("aggregate flattened action sequence is wrong")
    return phases


def markdown_round_trip(tab: dict[str, object]) -> str:
    markdown = tab.get("markdownDocument")
    if not isinstance(markdown, dict) or not isinstance(markdown.get("blocks"), list):
        fail("final fixture tab has no structured Markdown document")
    blocks = markdown["blocks"]
    if not blocks or any(not isinstance(block, dict) for block in blocks):
        fail("final fixture tab has invalid structured Markdown blocks")
    ids = [block.get("id") for block in blocks]
    if any(not isinstance(block_id, str) or not block_id for block_id in ids) \
            or len(ids) != len(set(ids)):
        fail("final fixture block IDs are not stable and unique")
    return "".join(
        str(block.get("leadingTrivia", "")) + str(block.get("source", ""))
        for block in blocks
    ) + str(markdown.get("trailingTrivia", ""))


def main() -> None:
    arguments = parse_args()
    session_path = pathlib.Path(arguments.session).expanduser().resolve()
    diagnostic_path = pathlib.Path(arguments.diagnostic).expanduser().resolve()
    report_path = pathlib.Path(arguments.foreground_report).expanduser().resolve()
    fixture_path = pathlib.Path(arguments.fixture).expanduser().resolve()
    output_root = pathlib.Path(arguments.output_root).expanduser().resolve()
    session = load_object(session_path, "session")
    diagnostic = load_object(diagnostic_path, "diagnostic")
    report = load_object(report_path, "foreground report")
    phases = validate_aggregate(report)

    fixture_bytes = fixture_path.read_bytes()
    fixture_hash = hashlib.sha256(fixture_bytes).hexdigest()
    if fixture_hash != arguments.fixture_sha \
            or MARKER.encode("utf-8") in fixture_bytes:
        fail("read-only fixture changed or contains the foreground marker")
    if any(
        phase["phaseState"].get("fixtureSHA256") != fixture_hash
        for phase in phases
    ):
        fail("embedded phase fixture hashes do not match the read-only fixture")
    tabs = session.get("tabs")
    if session.get("schemaVersion") != 2 \
            or not isinstance(tabs, list) \
            or len(tabs) != 1 \
            or any(not isinstance(tab, dict) for tab in tabs):
        fail("final session must contain exactly one schema-v2 fixture tab")
    active = next(
        (tab for tab in tabs if tab.get("id") == session.get("activeTabID")),
        None,
    )
    if active is None \
            or active.get("name") != "格式示例.md" \
            or active.get("isMarkdown") is not True \
            or active.get("isDirty") is not True \
            or not isinstance(active.get("text"), str) \
            or active["text"].count(MARKER) != 1 \
            or markdown_round_trip(active) != active["text"] \
            or session.get("fontIndex") != 1:
        fail("final session source, block model, dirty state, or font state is wrong")
    expected_live_session = phases[-1]["phaseState"]["session"][
        "expectedLivePath"
    ]
    if pathlib.Path(str(diagnostic.get("sessionPath", ""))).resolve() \
            != pathlib.Path(str(expected_live_session)).resolve() \
            or diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("activeTableCell") is not None \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1 \
            or diagnostic.get("find") != EXPECTED_FIND["palette-keyboard"]:
        fail("final diagnostic state is wrong")
    visual = diagnostic.get("visual")
    if not isinstance(visual, dict) \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("paletteVisible") is not False \
            or visual.get("findPanelVisible") is not False \
            or visual.get("replaceRowVisible") is not False \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False:
        fail("final visual diagnostic state is wrong")

    common_assertions = {
        "twoIndependentBoundedActivations": True,
        "eachPhaseRestoredFocusAndPointer": True,
        "eachPhaseRejectedInterference": True,
        "eachPhasePreservedCleanupHeadroom": True,
        "completeOriginalInteractionSequence": True,
        "sameProcessAndIsolatedSession": True,
    }
    if arguments.report_kind == "session":
        payload = {
            "label": "foreground-palette-find-session",
            "assertions": {
                **common_assertions,
                "activeEditInputCommittedExactlyOnce": True,
                "activeDocumentDirty": True,
                "blockModelContainsCommittedInputExactlyOnce": True,
                "paletteAndShortcutReachedExpectedFontIndex": True,
                "readOnlyFixtureUnchanged": True,
            },
            "fontIndex": session["fontIndex"],
            "marker": MARKER,
            "sessionPath": os.path.relpath(session_path, output_root),
            "fixtureSHA256": fixture_hash,
            "phaseCount": len(phases),
            "phaseEstimatesMs": PHASE_ESTIMATES,
        }
    else:
        payload = {
            "label": "foreground-palette-find-diagnostic",
            "assertions": {
                **common_assertions,
                "activeEditCommittedBeforePalette": True,
                "doubleShiftClearedFindQuery": True,
                "doubleShiftCollapsedReplace": True,
                "doubleShiftClosedFind": True,
                "wholeWordControlWasClicked": True,
                "sidebarRestored": True,
                "previewRestoredToEdit": True,
                "backdropClosedPalette": True,
                "sourceEditorClosed": True,
            },
            "snapshot": diagnostic,
            "phaseCount": len(phases),
            "phaseEstimatesMs": PHASE_ESTIMATES,
        }
    if arguments.check_only:
        return
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
