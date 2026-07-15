#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the bounded real-App structured-editor foreground plan."
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


def editor_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "element-click",
            "identifier": "document-block-12-quote",
            "waitMs": 80,
        },
        {"kind": "key", "key": "return", "waitMs": 80},
        {"kind": "text", "text": "E2E_QUOTE", "waitMs": 80},
        screenshot(raw_dir, "quote-source-edited.png"),
        {"kind": "key", "key": "escape", "waitMs": 80},
        {
            "kind": "element-click",
            "identifier": "document-block-15-list",
            "waitMs": 80,
        },
        {"kind": "key", "key": "return", "waitMs": 80},
        {"kind": "text", "text": "E2E_LIST ", "waitMs": 80},
        {"kind": "key", "key": "tab", "waitMs": 80},
        {"kind": "key", "key": "shift+tab", "waitMs": 80},
        {"kind": "key", "key": "command+b", "waitMs": 80},
        {"kind": "text", "text": "BOLD", "waitMs": 80},
        screenshot(raw_dir, "list-source-edited.png"),
        {"kind": "key", "key": "escape", "waitMs": 80},
        {"kind": "key", "key": "command+z", "waitMs": 80},
        screenshot(raw_dir, "list-undone.png"),
        {"kind": "key", "key": "command+shift+z", "waitMs": 80},
        screenshot(raw_dir, "editor-structure-final.png"),
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
        {"schemaVersion": 1, "actions": editor_actions(raw_dir)},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
