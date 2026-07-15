#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import tempfile


PHASES = ("block-find", "palette-keyboard")
CLEANUP_RESERVE_MS = 400
EXPECTED_ESTIMATED_FOREGROUND_MS = {
    "block-find": 2_190,
    "palette-keyboard": 1_690,
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
EXPECTED_VISUAL = {
    "block-find": {
        "paletteVisible": False,
        "findPanelVisible": True,
        "replaceRowVisible": True,
    },
    "palette-keyboard": {
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
    },
}
EXPECTED_FONT_INDEX = {"block-find": 0, "palette-keyboard": 1}
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
        description="Strictly validate and flatten both palette and Find phases."
    )
    parser.add_argument("--phase-root", required=True)
    parser.add_argument("--output-validation", required=True)
    parser.add_argument("--output-report", required=True)
    parser.add_argument("--budget-ms", type=int, default=4_000)
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"palette-find aggregate failed: {message}")


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


def expected_actions(
    phase: str,
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    if phase == "block-find":
        return [
            {"kind": "move-safe-point", "waitMs": 40},
            {"kind": "wait", "durationMs": 80},
            {
                "kind": "window-click",
                "xFraction": 0.44,
                "yFraction": 0.125,
                "waitMs": 80,
            },
            {"kind": "wait", "durationMs": 40},
            {"kind": "text", "text": "E2E_PALETTE_COMMIT", "waitMs": 80},
            {"kind": "key", "key": "command+k", "waitMs": 80},
            {
                "kind": "window-screenshot",
                "path": str((raw_dir / "active-edit-palette.png").resolve()),
                "waitMs": 40,
            },
            {"kind": "key", "key": "command+k", "waitMs": 80},
            {"kind": "key", "key": "command+minus", "waitMs": 80},
            {"kind": "key", "key": "command+f", "waitMs": 80},
            {"kind": "wait", "durationMs": 40},
            {
                "kind": "find-control-click",
                "control": "whole-word",
                "waitMs": 40,
            },
            {
                "kind": "find-control-click",
                "control": "query-field",
                "waitMs": 40,
            },
            {"kind": "text", "text": "一级标题", "waitMs": 60},
            {"kind": "key", "key": "return", "waitMs": 40},
            {"kind": "key", "key": "shift+return", "waitMs": 40},
            {
                "kind": "find-control-click",
                "control": "disclosure",
                "waitMs": 40,
            },
            {
                "kind": "find-control-click",
                "control": "replace-field",
                "waitMs": 40,
            },
            {"kind": "text", "text": "E2E_REPLACE", "waitMs": 80},
            {
                "kind": "window-screenshot",
                "path": str((raw_dir / "find-populated.png").resolve()),
                "waitMs": 40,
            },
        ]
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {"kind": "key", "key": "command+f", "waitMs": 80},
        {"kind": "shift-tap", "waitMs": 80},
        {"kind": "shift-tap", "waitMs": 80},
        {"kind": "text", "text": "字号", "waitMs": 80},
        {
            "kind": "window-screenshot",
            "path": str((raw_dir / "palette-filter-default.png").resolve()),
            "waitMs": 40,
        },
        {
            "kind": "window-move",
            "xFraction": 0.5,
            "yFraction": 0.3526,
            "waitMs": 80,
        },
        {
            "kind": "window-screenshot",
            "path": str((raw_dir / "palette-hover.png").resolve()),
            "waitMs": 40,
        },
        {"kind": "key", "key": "down", "waitMs": 40},
        {"kind": "key", "key": "up", "waitMs": 40},
        {"kind": "key", "key": "up", "waitMs": 40},
        {"kind": "key", "key": "return", "waitMs": 80},
        {"kind": "key", "key": "command+shift+equals", "waitMs": 80},
        {"kind": "key", "key": "command+k", "waitMs": 80},
        {
            "kind": "window-click",
            "xFraction": 0.9,
            "yFraction": 0.85,
            "waitMs": 80,
        },
    ]


def validate_plan(
    phase: str,
    root: pathlib.Path,
    plan: dict[str, object],
    validation: dict[str, object],
    budget_ms: int,
) -> list[dict[str, object]]:
    actions = plan.get("actions")
    expected = expected_actions(phase, root / "raw")
    if set(plan) != {"schemaVersion", "actions"} \
            or plan.get("schemaVersion") != 1 \
            or actions != expected:
        fail(f"{phase} plan action contract changed")
    validated_actions = validation.get("actions")
    estimate = EXPECTED_ESTIMATED_FOREGROUND_MS[phase]
    if validation.get("valid") is not True \
            or validation.get("budgetMs") != budget_ms \
            or validation.get("cleanupReserveMs") != CLEANUP_RESERVE_MS \
            or validation.get("estimatedForegroundMs") != estimate \
            or not isinstance(validated_actions, list) \
            or len(validated_actions) != len(expected):
        fail(f"{phase} plan validation is inconsistent")
    for index, (action, validated) in enumerate(zip(expected, validated_actions)):
        if not isinstance(validated, dict) \
                or validated.get("index") != index \
                or validated.get("kind") != action["kind"]:
            fail(f"{phase} validated action order changed")
    if estimate + CLEANUP_RESERVE_MS >= 3_600:
        fail(f"{phase} no longer has substantial deadline headroom")
    return expected


def validate_report(
    phase: str,
    report: dict[str, object],
    expected_actions_value: list[dict[str, object]],
    budget_ms: int,
) -> tuple[list[dict[str, object]], int, float]:
    actions = report.get("actions")
    interference = report.get("interference")
    focus = report.get("focusRestore")
    pointer = report.get("pointerRestore")
    pasteboard = report.get("pasteboardRestore")
    duration = finite_number(report.get("durationMs"))
    pid = exact_integer(report.get("pid"))
    if pid is None \
            or pid <= 0 \
            or report.get("budgetMs") != budget_ms \
            or report.get("targetActivationRequestCount") != 1 \
            or report.get("completed") is not True \
            or report.get("deadlineExceeded") is not False \
            or report.get("error") not in {None, ""} \
            or duration is None \
            or not 0 <= duration <= budget_ms \
            or not isinstance(actions, list) \
            or len(actions) != len(expected_actions_value):
        fail(f"{phase} report is not one bounded complete activation")
    if not isinstance(interference, dict) \
            or interference.get("detected") is not False \
            or interference.get("pointerInputDetected") is not False \
            or interference.get("pointerPositionInterferenceDetected") is not False \
            or interference.get("eventTapReliable") is not True:
        fail(f"{phase} report detected interference")
    if not isinstance(focus, dict) \
            or focus.get("attempted") is not True \
            or focus.get("restored") is not True \
            or focus.get("priorPID") == pid:
        fail(f"{phase} did not restore prior focus")
    if not isinstance(pointer, dict) \
            or pointer.get("attempted") is not True \
            or pointer.get("restored") is not True:
        fail(f"{phase} did not restore the pointer")
    if not isinstance(pasteboard, dict) \
            or pasteboard.get("attempted") is not False \
            or pasteboard.get("restored") is not True:
        fail(f"{phase} did not preserve the pasteboard contract")
    for index, (action, planned) in enumerate(zip(actions, expected_actions_value)):
        if not isinstance(action, dict) \
                or action.get("index") != index \
                or action.get("kind") != planned["kind"] \
                or action.get("status") != "completed":
            fail(f"{phase} foreground action sequence is incomplete")
    return actions, pid, duration


def validate_window_after(
    phase: str,
    window: dict[str, object],
    pid: int,
) -> None:
    if window.get("pid") != pid \
            or window.get("onScreen") is not False \
            or window.get("layer") != 0:
        fail(f"{phase} target window was not restored offscreen at normal level")


def validate_phase_state(
    phase: str,
    root: pathlib.Path,
    state: dict[str, object],
) -> str:
    assertions = state.get("assertions")
    session = state.get("session")
    diagnostic = state.get("diagnostic")
    expected_visual = EXPECTED_VISUAL[phase]
    if state.get("schemaVersion") != 1 \
            or state.get("suite") != "palette-find" \
            or state.get("phase") != phase \
            or not isinstance(assertions, dict) \
            or set(assertions) != PHASE_ASSERTIONS \
            or any(value is not True for value in assertions.values()) \
            or state.get("marker") != "E2E_PALETTE_COMMIT" \
            or not isinstance(state.get("fixtureSHA256"), str) \
            or len(state["fixtureSHA256"]) != 64:
        fail(f"{phase} persisted-state assertions are incomplete")
    if not isinstance(session, dict) \
            or pathlib.Path(str(session.get("path", ""))).resolve() \
                != (root / "session.json").resolve() \
            or session.get("schemaVersion") != 2 \
            or session.get("activeDocument") != "格式示例.md" \
            or session.get("tabCount") != 1 \
            or session.get("dirty") is not True \
            or session.get("fontIndex") != EXPECTED_FONT_INDEX[phase] \
            or session.get("markerCount") != 1 \
            or session.get("structuredMarkerCount") != 1 \
            or not isinstance(session.get("expectedLivePath"), str):
        fail(f"{phase} persisted session proof is wrong")
    if not isinstance(diagnostic, dict) \
            or pathlib.Path(str(diagnostic.get("path", ""))).resolve() \
                != (root / "diagnostic.json").resolve() \
            or diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("sessionPath") != session["expectedLivePath"] \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1 \
            or diagnostic.get("find") != EXPECTED_FIND[phase]:
        fail(f"{phase} persisted diagnostic proof is wrong")
    visual = diagnostic.get("visual")
    if not isinstance(visual, dict) \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False \
            or any(
                visual.get(key) is not value
                for key, value in expected_visual.items()
            ):
        fail(f"{phase} persisted visual proof is wrong")
    return str(session["expectedLivePath"])


def write_atomic_json(payload: dict[str, object], output: pathlib.Path) -> None:
    output = output.expanduser().resolve()
    if not output.parent.is_dir() or not os.access(output.parent, os.W_OK):
        fail(f"output parent must be a writable directory: {output.parent}")
    descriptor, temporary_name = tempfile.mkstemp(
        dir=output.parent,
        prefix=f".{output.name}.",
        suffix=".tmp",
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    arguments = parse_args()
    if arguments.budget_ms != 4_000:
        fail("each palette-find phase must keep the fixed 4000 ms budget")
    phase_root = pathlib.Path(arguments.phase_root).expanduser().resolve()
    if not phase_root.is_dir():
        fail(f"phase root must be an existing directory: {phase_root}")

    phases = []
    flat_plan_actions = []
    flat_report_actions = []
    pids = []
    live_session_paths = []
    fixture_hashes = []
    total_duration_ms = 0.0
    for phase_index, phase in enumerate(PHASES):
        root = phase_root / phase
        plan = load_object(root / "foreground-plan.json", f"{phase} plan")
        validation = load_object(
            root / "foreground-plan-validation.json",
            f"{phase} plan validation",
        )
        report = load_object(
            root / "foreground-report.json",
            f"{phase} foreground report",
        )
        window_after = load_object(
            root / "foreground-window-after.json",
            f"{phase} restored window",
        )
        state = load_object(root / "phase-state.json", f"{phase} persisted state")
        planned = validate_plan(
            phase,
            root,
            plan,
            validation,
            arguments.budget_ms,
        )
        reported, pid, duration = validate_report(
            phase,
            report,
            planned,
            arguments.budget_ms,
        )
        validate_window_after(phase, window_after, pid)
        live_session_paths.append(validate_phase_state(phase, root, state))
        fixture_hashes.append(state["fixtureSHA256"])
        pids.append(pid)
        total_duration_ms += duration
        evidence = {
            "name": phase,
            "plan": plan,
            "planValidation": validation,
            "report": report,
            "windowAfter": window_after,
            "phaseState": state,
        }
        phases.append(evidence)
        for action_index, action in enumerate(validation["actions"]):
            flat_plan_actions.append({
                **action,
                "index": len(flat_plan_actions),
                "phase": phase,
                "phaseIndex": phase_index,
                "phaseActionIndex": action_index,
            })
        for action_index, action in enumerate(reported):
            flat_report_actions.append({
                **action,
                "index": len(flat_report_actions),
                "phase": phase,
                "phaseIndex": phase_index,
                "phaseActionIndex": action_index,
            })

    if len(set(pids)) != 1:
        fail(f"palette-find phases used different app processes: {pids!r}")
    if len(set(live_session_paths)) != 1:
        fail("palette-find phases did not persist to the same isolated session")
    if len(set(fixture_hashes)) != 1:
        fail("palette-find phase fixture hashes changed")

    per_phase_budget_ms = arguments.budget_ms
    total_budget_ms = per_phase_budget_ms * len(PHASES)
    estimated_ms = sum(EXPECTED_ESTIMATED_FOREGROUND_MS.values())
    aggregate_validation = {
        "schemaVersion": 1,
        "suite": "palette-find",
        "valid": True,
        "phaseCount": len(PHASES),
        "perPhaseBudgetMs": per_phase_budget_ms,
        "totalBudgetMs": total_budget_ms,
        "budgetMs": total_budget_ms,
        "estimatedForegroundMs": estimated_ms,
        "cleanupReserveMs": CLEANUP_RESERVE_MS * len(PHASES),
        "actions": flat_plan_actions,
        "phases": phases,
    }
    aggregate_report = {
        "schemaVersion": 1,
        "suite": "palette-find",
        "pid": pids[0],
        "pids": pids,
        "phaseCount": len(PHASES),
        "perPhaseBudgetMs": per_phase_budget_ms,
        "totalBudgetMs": total_budget_ms,
        "budgetMs": total_budget_ms,
        "durationMs": total_duration_ms,
        "targetActivationRequestCount": len(PHASES),
        "completed": True,
        "deadlineExceeded": False,
        "error": None,
        "actions": flat_report_actions,
        "interference": {
            "detected": False,
            "pointerInputDetected": False,
            "pointerPositionInterferenceDetected": False,
            "eventTapReliable": True,
        },
        "focusRestore": {"attempted": True, "restored": True},
        "pointerRestore": {"attempted": True, "restored": True},
        "pasteboardRestore": {"attempted": False, "restored": True},
        "phases": phases,
    }
    write_atomic_json(
        aggregate_validation,
        pathlib.Path(arguments.output_validation),
    )
    write_atomic_json(
        aggregate_report,
        pathlib.Path(arguments.output_report),
    )


if __name__ == "__main__":
    main()
