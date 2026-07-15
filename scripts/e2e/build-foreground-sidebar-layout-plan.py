#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


DOCS_FOLDER = "sidebar-folder-docs"
CONFIG_ROW = "sidebar-file-docs%2Fconfig%2Eyaml"
RESIZE_HANDLE = "sidebar-resize-handle"
SIDEBAR_MINIMUM_BOUNDARY_X_FRACTION = 175.5 / 1180


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build the bounded real-App sidebar-layout-controls foreground plan."
        )
    )
    parser.add_argument("--raw-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--phase",
        choices=[
            "full",
            "collapse-minimum",
            "maximum-toggle",
        ],
        default="full",
        help=(
            "Build the complete compatibility plan or one bounded runner phase."
        ),
    )
    return parser.parse_args()


def require_directory(raw_path: str, label: str) -> pathlib.Path:
    path = pathlib.Path(raw_path).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"{label} must be an existing directory: {path}")
    if not os.access(path, os.W_OK):
        raise SystemExit(f"{label} must be writable: {path}")
    return path


def screenshot(raw_dir: pathlib.Path, name: str) -> dict[str, object]:
    return {
        "kind": "window-screenshot",
        "path": str(raw_dir / name),
        "waitMs": 40,
    }


def sidebar_layout_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        *sidebar_collapse_minimum_actions(raw_dir),
        *sidebar_maximum_toggle_actions(raw_dir)[1:],
    ]


def sidebar_collapse_minimum_actions(
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "element-click",
            "identifier": DOCS_FOLDER,
            "role": "AXButton",
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-folder-collapsed.png"),
        {
            "kind": "element-click",
            "identifier": DOCS_FOLDER,
            "role": "AXButton",
            "waitMs": 40,
        },
        {
            "kind": "element-check",
            "identifier": CONFIG_ROW,
            "role": "AXButton",
            "waitMs": 40,
        },
        {
            "kind": "element-drag",
            "identifier": RESIZE_HANDLE,
            "deltaX": -120,
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-width-minimum.png"),
    ]


def sidebar_maximum_toggle_actions(
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "window-drag",
            "xFraction": SIDEBAR_MINIMUM_BOUNDARY_X_FRACTION,
            "yFraction": 0.5,
            "deltaX": 320,
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-width-maximum.png"),
        {"kind": "key", "key": "command+backslash", "waitMs": 40},
        {"kind": "wait", "durationMs": 200},
        screenshot(raw_dir, "sidebar-hidden.png"),
        {"kind": "key", "key": "command+backslash", "waitMs": 40},
        {"kind": "wait", "durationMs": 200},
        screenshot(raw_dir, "sidebar-shown-maximum.png"),
    ]


def write_atomic_json(payload: dict[str, object], output: pathlib.Path) -> None:
    output = output.expanduser().resolve()
    parent = require_directory(str(output.parent), "--output parent")
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
    raw_dir = require_directory(arguments.raw_dir, "--raw-dir")
    actions_by_phase = {
        "full": sidebar_layout_actions,
        "collapse-minimum": sidebar_collapse_minimum_actions,
        "maximum-toggle": sidebar_maximum_toggle_actions,
    }
    write_atomic_json(
        {
            "schemaVersion": 1,
            "actions": actions_by_phase[arguments.phase](raw_dir),
        },
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
