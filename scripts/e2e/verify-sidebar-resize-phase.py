#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import tempfile


PHASE_WIDTHS = {
    "collapse-minimum": (216.0, 176.0),
    "maximum-toggle": (176.0, 440.0),
}
RESIZE_PHASES = {
    "sidebar-resize-began",
    "sidebar-resize-changed",
    "sidebar-resize-ended",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify persisted, diagnostic, and pointer-trace state after one "
            "bounded sidebar resize phase."
        )
    )
    parser.add_argument("--phase", choices=sorted(PHASE_WIDTHS), required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--expected-session-path")
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--pointer-trace", required=True)
    parser.add_argument("--output")
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"sidebar resize phase verification failed: {message}")


def load_object(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not readable JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def finite_number(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def close(actual: object, expected: float) -> bool:
    number = finite_number(actual)
    return number is not None and math.isclose(number, expected, abs_tol=0.5)


def latest_resize_segment(
    pointer_trace: dict[str, object],
) -> dict[str, object]:
    entries = pointer_trace.get("entries")
    if pointer_trace.get("schemaVersion") != 1 \
            or not isinstance(entries, list) \
            or any(not isinstance(entry, dict) for entry in entries):
        fail("pointer trace schema is wrong")
    sequences = [entry.get("sequence") for entry in entries]
    if any(
        not isinstance(sequence, int) or isinstance(sequence, bool)
        for sequence in sequences
    ) or sequences != list(range(len(entries))):
        fail("pointer trace sequence order is wrong")

    segments: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    resize_entries = []
    for entry in entries:
        phase = entry.get("phase")
        if phase not in RESIZE_PHASES:
            continue
        resize_entries.append(entry)
        width = finite_number(entry.get("sidebarWidth"))
        if width is None:
            fail("resize trace entry has no finite sidebar width")
        compact = {
            "sequence": entry["sequence"],
            "sidebarWidth": width,
        }
        if phase == "sidebar-resize-began":
            if current is not None:
                fail("resize trace began a new segment before ending the previous one")
            current = {"began": compact, "changed": []}
        elif phase == "sidebar-resize-changed":
            if current is None:
                fail("resize trace contains an orphan changed event")
            current["changed"].append(compact)
        elif current is None:
            fail("resize trace contains an orphan ended event")
        else:
            current["ended"] = compact
            segments.append(current)
            current = None
    if current is not None:
        fail("latest resize trace segment has no end event")
    if not segments or not resize_entries:
        fail("pointer trace contains no completed resize segment")
    latest = segments[-1]
    if latest["ended"]["sequence"] != resize_entries[-1]["sequence"]:
        fail("latest resize trace event is not the completed segment end")
    if not latest["changed"]:
        fail("latest resize trace segment contains no changed event")
    return {
        "entryCount": len(entries),
        "segment": latest,
    }


def validate_state(
    phase: str,
    session_path: pathlib.Path,
    expected_session_path: pathlib.Path,
    diagnostic_path: pathlib.Path,
    pointer_trace_path: pathlib.Path,
) -> dict[str, object]:
    expected_begin, expected_end = PHASE_WIDTHS[phase]
    session = load_object(session_path, "session")
    diagnostic = load_object(diagnostic_path, "diagnostic")
    pointer_trace = load_object(pointer_trace_path, "pointer trace")

    if session.get("schemaVersion") != 2 \
            or session.get("sidebarOpen") is not True \
            or not close(session.get("sidebarWidth"), expected_end):
        fail(
            f"{phase} persisted sidebar state is not open at {expected_end:g} pt"
        )
    visual = diagnostic.get("visual")
    anchors = visual.get("anchors") if isinstance(visual, dict) else None
    sidebar_anchor = anchors.get("sidebar-frame") \
        if isinstance(anchors, dict) else None
    if diagnostic.get("schemaVersion") != 1 \
            or pathlib.Path(str(diagnostic.get("sessionPath", ""))).resolve() \
                != expected_session_path.resolve() \
            or not isinstance(visual, dict) \
            or visual.get("sidebarVisible") is not True \
            or not isinstance(sidebar_anchor, dict) \
            or not close(sidebar_anchor.get("width"), expected_end) \
            or not close(sidebar_anchor.get("height"), 760.0) \
            or not close(sidebar_anchor.get("x"), 0.0) \
            or not close(sidebar_anchor.get("y"), 0.0):
        fail(
            f"{phase} diagnostic sidebar anchor is not visible at "
            f"{expected_end:g}x760 pt"
        )

    trace_state = latest_resize_segment(pointer_trace)
    segment = trace_state["segment"]
    changed_widths = [entry["sidebarWidth"] for entry in segment["changed"]]
    if not close(segment["began"].get("sidebarWidth"), expected_begin) \
            or not any(close(width, expected_end) for width in changed_widths) \
            or not close(segment["ended"].get("sidebarWidth"), expected_end):
        fail(
            f"{phase} latest resize segment does not prove "
            f"{expected_begin:g}->{expected_end:g} pt"
        )

    return {
        "schemaVersion": 1,
        "suite": "sidebar-layout-controls",
        "phase": phase,
        "expectedBeginWidth": expected_begin,
        "expectedEndWidth": expected_end,
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
            "path": str(session_path.resolve()),
            "expectedLivePath": str(expected_session_path.resolve()),
            "schemaVersion": session["schemaVersion"],
            "sidebarOpen": session["sidebarOpen"],
            "sidebarWidth": finite_number(session["sidebarWidth"]),
        },
        "diagnostic": {
            "path": str(diagnostic_path.resolve()),
            "schemaVersion": diagnostic["schemaVersion"],
            "sessionPath": str(
                pathlib.Path(str(diagnostic["sessionPath"])).resolve()
            ),
            "sidebarVisible": visual["sidebarVisible"],
            "sidebarAnchor": {
                key: finite_number(sidebar_anchor[key])
                for key in ("x", "y", "width", "height")
            },
        },
        "pointerTrace": {
            "path": str(pointer_trace_path.resolve()),
            "schemaVersion": pointer_trace["schemaVersion"],
            "entryCount": trace_state["entryCount"],
            "latestResizeSegment": segment,
        },
    }


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
    state = validate_state(
        arguments.phase,
        pathlib.Path(arguments.session),
        pathlib.Path(arguments.expected_session_path or arguments.session),
        pathlib.Path(arguments.diagnostic),
        pathlib.Path(arguments.pointer_trace),
    )
    if arguments.check_only:
        return
    if not arguments.output:
        fail("--output is required unless --check-only is used")
    write_atomic_json(state, pathlib.Path(arguments.output))


if __name__ == "__main__":
    main()
