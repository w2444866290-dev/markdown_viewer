#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import tempfile


PHASES = (
    "collapse-minimum",
    "maximum-toggle",
)
EXPECTED_ACTION_KINDS = {
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
EXPECTED_ESTIMATED_FOREGROUND_MS = {
    "collapse-minimum": 1_450,
    "maximum-toggle": 1_690,
}
EXPECTED_RESIZE_WIDTHS = {
    "collapse-minimum": (216.0, 176.0),
    "maximum-toggle": (176.0, 440.0),
}
MINIMUM_BOUNDARY_X_FRACTION = 175.5 / 1180
CLEANUP_RESERVE_MS = 400


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Strictly validate and flatten both bounded sidebar layout phases."
        )
    )
    parser.add_argument("--phase-root", required=True)
    parser.add_argument("--output-validation", required=True)
    parser.add_argument("--output-report", required=True)
    parser.add_argument("--budget-ms", type=int, default=4_000)
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"sidebar layout aggregate failed: {message}")


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


def validate_plan(
    phase: str,
    plan: dict[str, object],
    validation: dict[str, object],
    budget_ms: int,
) -> list[dict[str, object]]:
    actions = plan.get("actions")
    if plan.get("schemaVersion") != 1 \
            or not isinstance(actions, list) \
            or any(not isinstance(action, dict) for action in actions):
        fail(f"{phase} plan has an invalid schema")
    expected_kinds = EXPECTED_ACTION_KINDS[phase]
    if [action.get("kind") for action in actions] != expected_kinds:
        fail(f"{phase} plan action sequence changed")
    if phase == "collapse-minimum":
        drag = actions[5]
        if drag.get("identifier") != "sidebar-resize-handle" \
                or drag.get("deltaX") != -120:
            fail("collapse-minimum drag contract changed")
    else:
        drag = actions[1]
        if not math.isclose(
            float(drag.get("xFraction", math.nan)),
            MINIMUM_BOUNDARY_X_FRACTION,
            abs_tol=1e-15,
        ) or drag.get("yFraction") != 0.5 \
                or drag.get("deltaX") != 320:
            fail("maximum-toggle window drag contract changed")

    validation_actions = validation.get("actions")
    if validation.get("valid") is not True \
            or validation.get("budgetMs") != budget_ms \
            or validation.get("cleanupReserveMs") != CLEANUP_RESERVE_MS \
            or validation.get("estimatedForegroundMs") \
                != EXPECTED_ESTIMATED_FOREGROUND_MS[phase] \
            or not isinstance(validation_actions, list) \
            or len(validation_actions) != len(actions):
        fail(f"{phase} plan validation is inconsistent")
    for index, (action, validated_action) in enumerate(
        zip(actions, validation_actions)
    ):
        if not isinstance(validated_action, dict) \
                or validated_action.get("index") != index \
                or validated_action.get("kind") != action.get("kind"):
            fail(f"{phase} validated action order changed")
    if validation["estimatedForegroundMs"] + CLEANUP_RESERVE_MS >= 3_600:
        fail(f"{phase} no longer has substantial deadline headroom")
    return actions


def validate_report(
    phase: str,
    report: dict[str, object],
    expected_actions: list[dict[str, object]],
    budget_ms: int,
) -> list[dict[str, object]]:
    actions = report.get("actions")
    interference = report.get("interference")
    focus_restore = report.get("focusRestore")
    pointer_restore = report.get("pointerRestore")
    pasteboard_restore = report.get("pasteboardRestore")
    duration_ms = finite_number(report.get("durationMs"))
    if exact_integer(report.get("pid")) is None \
            or report.get("budgetMs") != budget_ms \
            or report.get("targetActivationRequestCount") != 1 \
            or report.get("completed") is not True \
            or report.get("deadlineExceeded") is not False \
            or report.get("error") not in {None, ""} \
            or duration_ms is None \
            or duration_ms < 0 \
            or duration_ms > budget_ms \
            or not isinstance(actions, list) \
            or len(actions) != len(expected_actions):
        fail(f"{phase} foreground report is not a bounded complete run")
    if not isinstance(interference, dict) \
            or interference.get("detected") is not False \
            or interference.get("pointerInputDetected") is not False \
            or interference.get("pointerPositionInterferenceDetected") is not False \
            or interference.get("eventTapReliable") is not True:
        fail(f"{phase} foreground report detected interference")
    for label, restore in (
        ("focus", focus_restore),
        ("pointer", pointer_restore),
    ):
        if not isinstance(restore, dict) \
                or restore.get("attempted") is not True \
                or restore.get("restored") is not True:
            fail(f"{phase} did not restore {label}")
    if not isinstance(pasteboard_restore, dict) \
            or pasteboard_restore.get("attempted") is not False \
            or pasteboard_restore.get("restored") is not True:
        fail(f"{phase} did not preserve the pasteboard contract")

    expected_kinds = [action["kind"] for action in expected_actions]
    for index, action in enumerate(actions):
        if not isinstance(action, dict) \
                or action.get("index") != index \
                or action.get("kind") != expected_kinds[index] \
                or action.get("status") != "completed":
            fail(f"{phase} foreground action sequence is incomplete")
        if action.get("kind") in {"element-drag", "window-drag"}:
            start_readiness = action.get("pointerClickReadiness")
            endpoint_readiness = action.get("pointerDragEndpointReadiness")
            if not isinstance(start_readiness, dict) \
                    or start_readiness.get("ready") is not True \
                    or not isinstance(endpoint_readiness, dict) \
                    or endpoint_readiness.get("ready") is not True:
                fail(f"{phase} drag endpoints were not both routing-ready")
            for receipt_name in (
                "injectedPointerEvents",
                "targetInjectedPointerEvents",
            ):
                receipt = action.get(receipt_name)
                if not isinstance(receipt, dict) \
                        or receipt.get("completeDragSequenceObserved") is not True \
                        or exact_integer(receipt.get("leftMouseDraggedCount")) is None \
                        or receipt["leftMouseDraggedCount"] < 2:
                    fail(f"{phase} drag has no complete {receipt_name} receipt")
    return actions


def validate_window_after(
    phase: str,
    window: dict[str, object],
    pid: int,
) -> None:
    if window.get("pid") != pid \
            or window.get("onScreen") is not False \
            or window.get("layer") != 0:
        fail(f"{phase} target window was not restored offscreen at normal level")


def close(actual: object, expected: float) -> bool:
    number = finite_number(actual)
    return number is not None and math.isclose(number, expected, abs_tol=0.5)


def validate_resize_state(
    phase: str,
    state: dict[str, object],
) -> None:
    expected_begin, expected_end = EXPECTED_RESIZE_WIDTHS[phase]
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
        fail(f"{phase} resize-state assertions are incomplete")
    if not isinstance(session, dict) \
            or session.get("schemaVersion") != 2 \
            or session.get("sidebarOpen") is not True \
            or not close(session.get("sidebarWidth"), expected_end) \
            or not isinstance(session.get("path"), str) \
            or not isinstance(session.get("expectedLivePath"), str):
        fail(f"{phase} resize-state session proof is wrong")
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
        fail(f"{phase} resize-state diagnostic proof is wrong")
    segment = pointer_trace.get("latestResizeSegment") \
        if isinstance(pointer_trace, dict) else None
    if not isinstance(pointer_trace, dict) \
            or pointer_trace.get("schemaVersion") != 1 \
            or exact_integer(pointer_trace.get("entryCount")) is None \
            or pointer_trace["entryCount"] <= 0 \
            or not isinstance(segment, dict):
        fail(f"{phase} resize-state pointer trace proof is wrong")
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
        fail(f"{phase} resize-state latest segment proof is wrong")
    segment_sequences = [
        began.get("sequence"),
        *(entry.get("sequence") for entry in changed),
        ended.get("sequence"),
    ]
    if any(exact_integer(value) is None for value in segment_sequences) \
            or segment_sequences != sorted(set(segment_sequences)):
        fail(f"{phase} resize-state segment order is wrong")


def write_atomic_json(payload: dict[str, object], output: pathlib.Path) -> None:
    output = output.expanduser().resolve()
    parent = output.parent
    if not parent.is_dir() or not os.access(parent, os.W_OK):
        fail(f"output parent must be a writable directory: {parent}")
    descriptor, temporary_name = tempfile.mkstemp(
        dir=parent,
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
        fail("each sidebar layout phase must keep the fixed 4000 ms budget")
    phase_root = pathlib.Path(arguments.phase_root).expanduser().resolve()
    if not phase_root.is_dir():
        fail(f"phase root must be an existing directory: {phase_root}")

    phase_evidence = []
    flat_plan_actions = []
    flat_report_actions = []
    total_duration_ms = 0.0
    pids = []
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
        resize_state = load_object(
            root / "resize-state.json",
            f"{phase} resize state",
        )
        plan_actions = validate_plan(
            phase,
            plan,
            validation,
            arguments.budget_ms,
        )
        report_actions = validate_report(
            phase,
            report,
            plan_actions,
            arguments.budget_ms,
        )
        pid = exact_integer(report["pid"])
        if pid is None or pid <= 0:
            fail(f"{phase} foreground report has an invalid pid")
        validate_window_after(phase, window_after, pid)
        validate_resize_state(phase, resize_state)
        if pathlib.Path(str(resize_state["session"]["path"])).resolve() \
                != (root / "session.json").resolve() \
                or pathlib.Path(str(resize_state["diagnostic"]["path"])).resolve() \
                != (root / "diagnostic.json").resolve() \
                or pathlib.Path(
                    str(resize_state["pointerTrace"]["path"])
                ).resolve() != (root / "pointer-trace.json").resolve():
            fail(f"{phase} resize-state snapshot paths are wrong")
        pids.append(pid)
        total_duration_ms += float(report["durationMs"])
        phase_evidence.append({
            "name": phase,
            "plan": plan,
            "planValidation": validation,
            "report": report,
            "windowAfter": window_after,
            "resizeState": resize_state,
        })
        for phase_action_index, action in enumerate(validation["actions"]):
            flat_plan_actions.append({
                **action,
                "index": len(flat_plan_actions),
                "phase": phase,
                "phaseIndex": phase_index,
                "phaseActionIndex": phase_action_index,
            })
        for phase_action_index, action in enumerate(report_actions):
            flat_report_actions.append({
                **action,
                "index": len(flat_report_actions),
                "phase": phase,
                "phaseIndex": phase_index,
                "phaseActionIndex": phase_action_index,
            })

    if len(set(pids)) != 1:
        fail(f"sidebar layout phases used different app processes: {pids!r}")
    per_phase_budget_ms = arguments.budget_ms
    total_budget_ms = per_phase_budget_ms * len(PHASES)
    aggregate_validation = {
        "schemaVersion": 1,
        "suite": "sidebar-layout-controls",
        "valid": True,
        "phaseCount": len(PHASES),
        "perPhaseBudgetMs": per_phase_budget_ms,
        "totalBudgetMs": total_budget_ms,
        "budgetMs": total_budget_ms,
        "estimatedForegroundMs": sum(EXPECTED_ESTIMATED_FOREGROUND_MS.values()),
        "cleanupReserveMs": CLEANUP_RESERVE_MS * len(PHASES),
        "actions": flat_plan_actions,
        "phases": phase_evidence,
    }
    aggregate_report = {
        "schemaVersion": 1,
        "suite": "sidebar-layout-controls",
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
        "phases": phase_evidence,
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
