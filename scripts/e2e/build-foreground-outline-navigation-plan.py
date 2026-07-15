#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


TARGET_HEADING = "outline-heading-12"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the bounded real-App outline-navigation foreground plan."
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


def screenshot(
    raw_dir: pathlib.Path,
    name: str,
    wait_ms: int = 40,
) -> dict[str, object]:
    return {
        "kind": "window-screenshot",
        "path": str(raw_dir / name),
        "waitMs": wait_ms,
    }


def outline_navigation_actions(raw_dir: pathlib.Path) -> list[dict[str, object]]:
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {
            "kind": "element-move",
            "identifier": TARGET_HEADING,
            "role": "AXButton",
            "waitMs": 80,
        },
        # Heading 12 settles after its 144 ms stagger and 240 ms row animation.
        {"kind": "wait", "durationMs": 320},
        screenshot(raw_dir, "outline-expanded.png"),
        {
            "kind": "element-click",
            "identifier": TARGET_HEADING,
            "role": "AXButton",
            "waitMs": 40,
        },
        # Capture before the 300 ms ease-out jump can settle.
        screenshot(raw_dir, "outline-jump-in-flight.png"),
        {"kind": "wait", "durationMs": 260},
        # The wash starts only after the 300 ms jump completes.
        screenshot(raw_dir, "outline-wash-peak.png"),
        {"kind": "wait", "durationMs": 400},
        screenshot(raw_dir, "outline-wash-fading.png", wait_ms=80),
        # Let the 900 ms wash finish before persisted state is verified.
        {"kind": "wait", "durationMs": 400},
        screenshot(raw_dir, "outline-wash-cleared.png"),
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
        {"schemaVersion": 1, "actions": outline_navigation_actions(raw_dir)},
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
