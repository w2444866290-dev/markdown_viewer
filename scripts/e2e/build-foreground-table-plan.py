#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the bounded real-App table-controls foreground plan."
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


def element_action(
    kind: str,
    identifier: str,
    *,
    wait_ms: int,
    role: str = "AXButton",
) -> dict[str, object]:
    return {
        "kind": kind,
        "identifier": identifier,
        "role": role,
        "waitMs": wait_ms,
    }


def table_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    passive_cell = "document-block-28-table-row-0-column-0"
    actions: list[dict[str, object]] = [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "window-screenshot",
            "path": str(raw_dir / "table-reading-rest.png"),
            "waitMs": 40,
        },
        element_action("element-move", passive_cell, wait_ms=80),
        {
            "kind": "window-screenshot",
            "path": str(raw_dir / "table-reading-hover.png"),
            "waitMs": 40,
        },
        element_action("element-click", passive_cell, wait_ms=80),
        {"kind": "key", "key": "command+a", "waitMs": 40},
        {"kind": "text", "text": "E2E_TABLE", "waitMs": 80},
        {"kind": "key", "key": "tab", "waitMs": 80},
    ]
    actions.extend(
        element_action(
            "element-click",
            "table-cycle-alignment",
            wait_ms=60,
        )
        for _ in range(3)
    )
    actions.extend(
        [
            element_action("element-click", "table-add-row", wait_ms=60),
            element_action("element-click", "table-delete-row", wait_ms=60),
            element_action("element-click", "table-add-column", wait_ms=60),
            element_action("element-click", "table-delete-column", wait_ms=80),
            {
                "kind": "window-screenshot",
                "path": str(raw_dir / "table-controls-final.png"),
                "waitMs": 40,
            },
            {"kind": "key", "key": "escape", "waitMs": 80},
            {
                "kind": "window-screenshot",
                "path": str(raw_dir / "table-committed.png"),
                "waitMs": 40,
            },
        ]
    )
    return actions


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
        {"schemaVersion": 1, "actions": table_actions(raw_dir)},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
