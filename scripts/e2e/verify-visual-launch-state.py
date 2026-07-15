#!/usr/bin/env python3
"""Wait for one deterministic Debug visual-test launch state to settle."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import time
from typing import Any


STATE_LABELS = {
    "default": "baseline",
    "palette": "palette-open",
    "find": "find-open",
    "preview": "preview-on",
    "sidebar-hidden": "sidebar-hidden",
    "source-editor": "source-editing",
    "table-editor": "table-grid",
}

REFERENCE_TABLE_GRID_FRAMES = {
    "1180x760": {"x": 375.0, "y": 377.796875, "width": 640.0, "height": 177.0},
    "860x560": {"x": 282.0, "y": 277.796875, "width": 506.0, "height": 177.0},
    "1440x900": {"x": 505.0, "y": 447.796875, "width": 640.0, "height": 177.0},
}

REFERENCE_PREVIEW_TOAST_SIZE = {"width": 177.46875, "height": 29.0}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diagnostic", required=True, type=pathlib.Path)
    parser.add_argument("--window", required=True, type=pathlib.Path)
    parser.add_argument("--process-windows", required=True, type=pathlib.Path)
    parser.add_argument("--profile-root", required=True, type=pathlib.Path)
    parser.add_argument("--requested-state", required=True, choices=STATE_LABELS)
    parser.add_argument("--logical-size", required=True, choices=REFERENCE_TABLE_GRID_FRAMES)
    parser.add_argument("--expected-scroll-y", required=True, type=float)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--stable-samples", type=int, default=3)
    return parser.parse_args()


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def visual_flag(visual: dict[str, Any], name: str, expected: bool) -> str | None:
    if visual.get(name) is expected:
        return None
    return f"visual.{name} is not {str(expected).lower()}"


def process_window_failures(
    process_windows: Any,
    expected_pid: int,
    selected_window_number: Any,
) -> list[str]:
    if not isinstance(process_windows, list) or not process_windows:
        return ["process window list is empty or malformed"]

    failures: list[str] = []
    window_numbers: list[int] = []
    selected_matches = 0
    for index, process_window in enumerate(process_windows):
        if not isinstance(process_window, dict):
            failures.append(f"process window {index} is not an object")
            continue
        if process_window.get("pid") != expected_pid:
            failures.append(f"process window {index} PID does not match launch PID")
        window_number = process_window.get("windowNumber")
        if (
            isinstance(window_number, bool)
            or not isinstance(window_number, int)
            or window_number <= 0
        ):
            failures.append(f"process window {index} has an invalid windowNumber")
        else:
            window_numbers.append(window_number)
            if window_number == selected_window_number:
                selected_matches += 1
        if process_window.get("onScreen") is not False:
            failures.append(f"process window {index} is on screen")

    if len(window_numbers) != len(set(window_numbers)):
        failures.append("process windowNumber values are not unique")
    if selected_matches != 1:
        failures.append(
            "process window list does not contain exactly one selected main window"
        )
    return failures


def finite_rect(raw: Any) -> dict[str, float] | None:
    if not isinstance(raw, dict):
        return None
    rect: dict[str, float] = {}
    for component in ("x", "y", "width", "height"):
        value = raw.get(component)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        number = float(value)
        if not math.isfinite(number):
            return None
        rect[component] = number
    if rect["width"] <= 0 or rect["height"] <= 0:
        return None
    return rect


def rect_contains(outer: dict[str, float], inner: dict[str, float], tolerance: float) -> bool:
    return (
        inner["x"] >= outer["x"] - tolerance
        and inner["y"] >= outer["y"] - tolerance
        and inner["x"] + inner["width"]
        <= outer["x"] + outer["width"] + tolerance
        and inner["y"] + inner["height"]
        <= outer["y"] + outer["height"] + tolerance
    )


def evaluate(
    snapshot: Any,
    requested_state: str,
    profile_root: pathlib.Path,
    expected_scroll_y: float,
    logical_size: str,
) -> tuple[dict[str, Any] | None, list[str]]:
    if not isinstance(snapshot, dict):
        return None, ["diagnostic snapshot is not an object"]
    failures: list[str] = []
    visual = snapshot.get("visual")
    if not isinstance(visual, dict):
        return None, ["diagnostic snapshot has no visual object"]

    if visual.get("palettePresentation") != "inline-passive":
        failures.append("visual.palettePresentation is not inline-passive")

    if snapshot.get("schemaVersion") != 1:
        failures.append("diagnostic schemaVersion is not 1")
    if snapshot.get("document") != "格式示例.md":
        failures.append("diagnostic document is not the visual fixture")
    expected_session = (
        profile_root / "Application Support" / "MarkdownViewer" / "session.json"
    ).resolve()
    raw_session = snapshot.get("sessionPath")
    if not isinstance(raw_session, str) or pathlib.Path(raw_session).resolve() != expected_session:
        failures.append("diagnostic sessionPath is outside the requested profile")

    scroll_y = snapshot.get("scrollY")
    if isinstance(scroll_y, bool) or not isinstance(scroll_y, (int, float)):
        failures.append("diagnostic scrollY is not numeric")
    elif not math.isclose(float(scroll_y), expected_scroll_y, rel_tol=0, abs_tol=0.5):
        failures.append(
            f"diagnostic scrollY {float(scroll_y):.3f} did not reach {expected_scroll_y:.3f}"
        )

    common_flags = {
        "documentVisible": True,
    }
    state_flags: dict[str, bool]
    expected_mode = "edit"
    state_flags = {
        "sidebarVisible": True,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": False,
        "tableGridVisible": False,
    }
    if requested_state == "default":
        pass
    elif requested_state == "palette":
        state_flags["paletteVisible"] = True
    elif requested_state == "find":
        state_flags["findPanelVisible"] = True
    elif requested_state == "preview":
        expected_mode = "preview"
        state_flags["previewActive"] = True
        anchors = visual.get("anchors")
        anchors = anchors if isinstance(anchors, dict) else {}
        toast_frame = finite_rect(anchors.get("toast-frame"))
        logical_width = float(logical_size.split("x", 1)[0])
        expected_toast = {
            "x": (logical_width - REFERENCE_PREVIEW_TOAST_SIZE["width"]) / 2,
            "y": 56.0,
            **REFERENCE_PREVIEW_TOAST_SIZE,
        }
        tolerance = 1.0 if logical_size == "1180x760" else 2.0
        if toast_frame is None:
            failures.append("preview toast-frame is missing or malformed")
        else:
            for component, expected in expected_toast.items():
                actual = toast_frame[component]
                if not math.isclose(
                    actual,
                    expected,
                    rel_tol=0,
                    abs_tol=tolerance,
                ):
                    failures.append(
                        f"toast-frame.{component} {actual:.3f} did not reach "
                        f"{expected:.3f} within {tolerance:.1f}"
                    )
    elif requested_state == "sidebar-hidden":
        state_flags["sidebarVisible"] = False
    elif requested_state == "source-editor":
        state_flags["sourceEditorVisible"] = True
        if snapshot.get("blockType") != "heading":
            failures.append("source-editor did not select the first heading block")
        selection = snapshot.get("selection")
        if selection != {"location": 16, "length": 0}:
            failures.append("source-editor selection is not the authoritative source-end caret")
        if snapshot.get("activeTableCell") is not None:
            failures.append("source-editor unexpectedly has an active table cell")
        anchors = visual.get("anchors")
        anchors = anchors if isinstance(anchors, dict) else {}
        source_frame = finite_rect(anchors.get("source-editor-frame"))
        surface_frame = finite_rect(anchors.get("document-surface-frame"))
        tolerance = 1.0 if logical_size == "1180x760" else 2.0
        if source_frame is None or surface_frame is None:
            failures.append("source-editor visibility anchors are missing or malformed")
        elif not rect_contains(surface_frame, source_frame, tolerance):
            failures.append("source-editor-frame is not fully visible in document-surface-frame")
    else:
        state_flags["tableGridVisible"] = True
        if snapshot.get("blockType") != "table":
            failures.append("table-editor did not select a table block")
        if snapshot.get("activeTableCell") != {"row": -1, "column": 0}:
            failures.append("table-editor did not select its first header cell")
        if snapshot.get("selection") is not None:
            failures.append("table-editor unexpectedly has a source selection")
        anchors = visual.get("anchors")
        anchors = anchors if isinstance(anchors, dict) else {}
        raw_grid = anchors.get("table-grid-frame")
        expected_grid = REFERENCE_TABLE_GRID_FRAMES[logical_size]
        tolerance = 1.0 if logical_size == "1180x760" else 2.0
        grid_frame = finite_rect(raw_grid)
        if grid_frame is None:
            failures.append("table-editor has no table-grid-frame anchor")
        else:
            for component, expected in expected_grid.items():
                actual = grid_frame[component]
                if not math.isclose(
                    float(actual), expected, rel_tol=0, abs_tol=tolerance
                ):
                    failures.append(
                        f"table-grid-frame.{component} {float(actual):.3f} "
                        f"did not reach {expected:.3f} within {tolerance:.1f}"
                    )
            surface_frame = finite_rect(anchors.get("document-surface-frame"))
            if surface_frame is None or not rect_contains(
                surface_frame, grid_frame, tolerance
            ):
                failures.append(
                    "table-grid-frame is not fully visible in document-surface-frame"
                )
        page_frame = finite_rect(anchors.get("document-page-frame"))
        if page_frame is None or not isinstance(scroll_y, (int, float)):
            failures.append("table-editor document-page-frame is missing or malformed")
        elif not math.isclose(
            page_frame["y"] + float(scroll_y),
            44.0,
            rel_tol=0,
            abs_tol=tolerance,
        ):
            failures.append("table-editor page origin and scroll do not resolve to y=44")

    if snapshot.get("mode") != expected_mode:
        failures.append(f"diagnostic mode is not {expected_mode}")
    for name, expected in {**common_flags, **state_flags}.items():
        failure = visual_flag(visual, name, expected)
        if failure:
            failures.append(failure)

    material = {
        "mode": snapshot.get("mode"),
        "blockID": snapshot.get("blockID"),
        "blockType": snapshot.get("blockType"),
        "selection": snapshot.get("selection"),
        "activeTableCell": snapshot.get("activeTableCell"),
        "scrollY": scroll_y,
        "visual": visual,
    }
    return material, failures


def main() -> None:
    options = arguments()
    if options.pid <= 0:
        raise SystemExit("verify-visual-launch-state.py: --pid must be positive")
    if not math.isfinite(options.expected_scroll_y) or options.expected_scroll_y < 0:
        raise SystemExit(
            "verify-visual-launch-state.py: --expected-scroll-y must be nonnegative and finite"
        )
    if not 0 < options.timeout <= 10:
        raise SystemExit("verify-visual-launch-state.py: --timeout must be from 0 through 10")
    if not 2 <= options.stable_samples <= 10:
        raise SystemExit(
            "verify-visual-launch-state.py: --stable-samples must be from 2 through 10"
        )

    window = load_json(options.window)
    if not isinstance(window, dict):
        raise SystemExit("verify-visual-launch-state.py: selected window is not an object")
    if window.get("pid") != options.pid:
        raise SystemExit("verify-visual-launch-state.py: window PID does not match launch PID")
    if window.get("layer") != 0:
        raise SystemExit("verify-visual-launch-state.py: selected window is not the main layer")
    if window.get("onScreen") is not False:
        raise SystemExit("verify-visual-launch-state.py: selected main window is on screen")

    process_windows = load_json(options.process_windows)
    window_failures = process_window_failures(
        process_windows,
        options.pid,
        window.get("windowNumber"),
    )
    if window_failures:
        raise SystemExit(
            "verify-visual-launch-state.py: unsafe process window evidence: "
            + "; ".join(window_failures)
        )

    deadline = time.monotonic() + options.timeout
    prior_material: str | None = None
    stable_count = 0
    last_failures = ["diagnostic snapshot is unavailable"]
    resolved_material: dict[str, Any] | None = None
    diagnostic_payload: bytes | None = None
    while time.monotonic() < deadline:
        try:
            payload = options.diagnostic.read_bytes()
            snapshot = json.loads(payload)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            time.sleep(0.05)
            continue
        material, failures = evaluate(
            snapshot,
            options.requested_state,
            options.profile_root.resolve(),
            options.expected_scroll_y,
            options.logical_size,
        )
        last_failures = failures
        if failures or material is None:
            stable_count = 0
            prior_material = None
            time.sleep(0.05)
            continue
        serialized = json.dumps(material, sort_keys=True, separators=(",", ":"))
        stable_count = stable_count + 1 if serialized == prior_material else 1
        prior_material = serialized
        resolved_material = material
        diagnostic_payload = payload
        if stable_count >= options.stable_samples:
            break
        time.sleep(0.05)

    if resolved_material is None or diagnostic_payload is None or stable_count < options.stable_samples:
        raise SystemExit(
            "verify-visual-launch-state.py: requested state did not settle: "
            + "; ".join(last_failures)
        )

    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "kind": "deterministic-visual-test-launch",
                "pid": options.pid,
                "profileRoot": str(options.profile_root.resolve()),
                "requestedState": options.requested_state,
                "resolvedState": options.requested_state,
                "appLabel": STATE_LABELS[options.requested_state],
                "requestedScrollY": options.expected_scroll_y,
                "resolvedScrollY": float(resolved_material["scrollY"]),
                "logicalSize": options.logical_size,
                "referenceTableGridFrame": (
                    REFERENCE_TABLE_GRID_FRAMES[options.logical_size]
                    if options.requested_state == "table-editor"
                    else None
                ),
                "diagnosticSHA256": sha256_bytes(diagnostic_payload),
                "stableSampleCount": stable_count,
                "window": window,
                "processWindows": process_windows,
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
