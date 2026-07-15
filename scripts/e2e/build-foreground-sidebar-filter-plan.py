#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


FILTER_FIELD = "sidebar-filter"
FIXTURE_ROW = (
    "sidebar-file-docs%2F"
    "%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd"
)
CONFIG_ROW = "sidebar-file-docs%2Fconfig%2Eyaml"
EMPTY_RESULT = "sidebar-filter-empty"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build the bounded real-App sidebar-filter-navigation foreground plan."
        )
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


def screenshot(raw_dir: pathlib.Path, name: str) -> dict[str, object]:
    return {
        "kind": "window-screenshot",
        "path": str(raw_dir / name),
        "waitMs": 40,
    }


def sidebar_filter_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "element-click",
            "identifier": FILTER_FIELD,
            "role": "AXTextField",
            "waitMs": 40,
        },
        {
            "kind": "focused-element-check",
            "identifier": FILTER_FIELD,
            "role": "AXTextField",
            "expectedValue": "",
            "waitMs": 40,
        },
        {"kind": "text", "text": "格式", "waitMs": 80},
        {
            "kind": "element-check",
            "identifier": FIXTURE_ROW,
            "role": "AXButton",
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-filter-name.png"),
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "text", "text": "docs/config", "waitMs": 80},
        {
            "kind": "element-check",
            "identifier": CONFIG_ROW,
            "role": "AXButton",
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-filter-path.png"),
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "text", "text": "NO_MATCH_7F2", "waitMs": 80},
        {
            "kind": "element-check",
            "identifier": EMPTY_RESULT,
            "role": "AXStaticText",
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-filter-empty.png"),
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "text", "text": ".md", "waitMs": 80},
        {"kind": "key", "key": "down", "waitMs": 40},
        {"kind": "key", "key": "return", "waitMs": 80},
        screenshot(raw_dir, "sidebar-filter-readme.png"),
        {"kind": "key", "key": "up", "waitMs": 40},
        {"kind": "key", "key": "return", "waitMs": 80},
        screenshot(raw_dir, "sidebar-filter-fixture.png"),
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "key", "key": "delete", "waitMs": 80},
        {
            "kind": "focused-element-check",
            "identifier": FILTER_FIELD,
            "role": "AXTextField",
            "expectedValue": "",
            "waitMs": 40,
        },
        screenshot(raw_dir, "sidebar-filter-cleared.png"),
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
    write_atomic_json(
        {"schemaVersion": 1, "actions": sidebar_filter_actions(raw_dir)},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
