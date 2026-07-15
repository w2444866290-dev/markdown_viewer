#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build one bounded real-App palette and Find foreground phase."
    )
    parser.add_argument(
        "--phase",
        choices=("block-find", "palette-keyboard"),
        required=True,
    )
    parser.add_argument("--raw-dir", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def require_directory(raw_path: str, label: str) -> pathlib.Path:
    path = pathlib.Path(raw_path).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"{label} must be an existing directory: {path}")
    if not os.access(path, os.W_OK):
        raise SystemExit(f"{label} must be writable: {path}")
    return path


def block_find_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
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
            "path": str(raw_dir / "active-edit-palette.png"),
            "waitMs": 40,
        },
        {"kind": "key", "key": "command+k", "waitMs": 80},
        {"kind": "key", "key": "command+minus", "waitMs": 80},
        {"kind": "key", "key": "command+f", "waitMs": 80},
        {"kind": "wait", "durationMs": 40},
        {"kind": "find-control-click", "control": "whole-word", "waitMs": 40},
        {"kind": "find-control-click", "control": "query-field", "waitMs": 40},
        {"kind": "text", "text": "一级标题", "waitMs": 60},
        {"kind": "key", "key": "return", "waitMs": 40},
        {"kind": "key", "key": "shift+return", "waitMs": 40},
        {"kind": "find-control-click", "control": "disclosure", "waitMs": 40},
        {"kind": "find-control-click", "control": "replace-field", "waitMs": 40},
        {"kind": "text", "text": "E2E_REPLACE", "waitMs": 80},
        {
            "kind": "window-screenshot",
            "path": str(raw_dir / "find-populated.png"),
            "waitMs": 40,
        },
    ]


def palette_keyboard_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        # Command+F is deliberately repeated at this phase boundary. It opens,
        # focuses, and selects the existing query without toggling the panel, so
        # the double-Shift check does not depend on transient window visibility
        # left behind by the preceding independently restored foreground call.
        {"kind": "key", "key": "command+f", "waitMs": 80},
        {"kind": "shift-tap", "waitMs": 80},
        {"kind": "shift-tap", "waitMs": 80},
        {"kind": "text", "text": "字号", "waitMs": 80},
        {
            "kind": "window-screenshot",
            "path": str(raw_dir / "palette-filter-default.png"),
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
            "path": str(raw_dir / "palette-hover.png"),
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
    actions = (
        block_find_actions(raw_dir)
        if arguments.phase == "block-find"
        else palette_keyboard_actions(raw_dir)
    )
    write_atomic_json(
        {"schemaVersion": 1, "actions": actions},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
