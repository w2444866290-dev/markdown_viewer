#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the bounded real-App regex Find replacement plan."
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


def element_click(
    identifier: str,
    role: str,
    *,
    wait_ms: int = 40,
) -> dict[str, object]:
    return {
        "kind": "element-click",
        "identifier": identifier,
        "role": role,
        "waitMs": wait_ms,
    }


def screenshot(raw_dir: pathlib.Path, name: str) -> dict[str, object]:
    return {
        "kind": "window-screenshot",
        "path": str(raw_dir / name),
        "waitMs": 40,
    }


def regex_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {"kind": "key", "key": "command+n", "waitMs": 80},
        {"kind": "wait", "durationMs": 80},
        {
            "kind": "focused-element-check",
            "identifier": "document-block-0-source-editor",
            "waitMs": 40,
        },
        {"kind": "text", "text": "Name:Ada Name:Bob Name:Cy", "waitMs": 80},
        {"kind": "key", "key": "command+f", "waitMs": 80},
        {"kind": "wait", "durationMs": 40},
        {
            "kind": "focused-element-check",
            "identifier": "find-query",
            "role": "AXTextField",
            "waitMs": 40,
        },
        {"kind": "text", "text": r"Name:(\w+)", "waitMs": 60},
        element_click("find-regex", "AXButton"),
        element_click("find-toggle-replace", "AXButton", wait_ms=80),
        element_click("find-replacement", "AXTextField"),
        {
            "kind": "focused-element-check",
            "identifier": "find-replacement",
            "role": "AXTextField",
            "waitMs": 40,
        },
        {"kind": "text", "text": "Current:$1", "waitMs": 60},
        element_click("find-replace-current", "AXButton", wait_ms=80),
        screenshot(raw_dir, "find-regex-current.png"),
        element_click("find-replacement", "AXTextField"),
        {
            "kind": "focused-element-check",
            "identifier": "find-replacement",
            "role": "AXTextField",
            "waitMs": 40,
        },
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "text", "text": "All:$1", "waitMs": 60},
        element_click("find-replace-all", "AXButton", wait_ms=80),
        screenshot(raw_dir, "find-regex-final.png"),
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
        {"schemaVersion": 1, "actions": regex_actions(raw_dir)},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
