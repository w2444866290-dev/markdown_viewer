#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib


MARKDOWN_FILE = "README.md"
PLAIN_FILE = "config.yaml"
MARKDOWN_ORIGINAL = "markdown original"
MARKDOWN_LATEST = "markdown latest"
TABLE_ORIGINAL = "table original"
TABLE_LATEST = "table latest"
CONFLICT_DRAFT = "conflict draft"
CURRENT_CONFLICT_DRAFT = "current conflict draft"
SESSION_DRAFT = "session conflict draft"
PLAIN_ORIGINAL_VALUE = "0.2"
PLAIN_LATEST_VALUE = "0.7"

PARAGRAPH = "document-block-1-paragraph"
PARAGRAPH_EDITOR = "document-block-1-source-editor"
TABLE_CELL = "document-block-1-table-row-1-column-1"
TABLE_CELL_EDITOR = "table-cell-1-1"
NON_MARKDOWN_BANNER = "non-markdown-banner"
TOAST = "toast"

PHASES = (
    "markdown-save",
    "close-clean",
    "table-save",
    "conflict-open",
    "conflict-save",
    "save-as-new",
    "conflict-save-as-current",
    "conflict-save-as-symlink",
    "discard-dirty-close",
    "session-draft",
    "restored-conflict-save",
    "plain-open-diagnostic",
    "plain-save",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build one bounded real-App Goal 2 save lifecycle plan."
    )
    parser.add_argument("--phase", choices=PHASES, required=True)
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


def action(kind: str, **values: object) -> dict[str, object]:
    return {"kind": kind, "waitMs": 80, **values}


def key(value: str) -> dict[str, object]:
    return action("key", key=value)


def text(value: str) -> dict[str, object]:
    return action("text", text=value)


def wait(duration_ms: int = 240) -> dict[str, object]:
    return {"kind": "wait", "durationMs": duration_ms}


def element(
    kind: str,
    identifier: str,
    role: str | None = None,
    expected_value: str | None = None,
) -> dict[str, object]:
    values: dict[str, object] = {"identifier": identifier}
    if role is not None:
        values["role"] = role
    if expected_value is not None:
        values["expectedValue"] = expected_value
    return action(kind, **values)


def screenshot(raw_dir: pathlib.Path, phase: str) -> dict[str, object]:
    return action("window-screenshot", path=str(raw_dir / f"{phase}.png"))


def open_from_palette(name: str) -> list[dict[str, object]]:
    return [
        action("move-safe-point"),
        key("command+k"),
        text(name),
        key("return"),
        wait(160),
    ]


def edit_paragraph(source: str) -> list[dict[str, object]]:
    return [
        element("element-click", PARAGRAPH, "AXButton"),
        element("focused-element-check", PARAGRAPH_EDITOR, "AXTextArea"),
        key("command+a"),
        text(source),
    ]


def conflict_feedback() -> list[dict[str, object]]:
    return [
        element("element-check", TOAST),
        element(
            "focused-element-check",
            PARAGRAPH_EDITOR,
            "AXTextArea",
        ),
    ]


def plan_actions(phase: str, raw_dir: pathlib.Path) -> list[dict[str, object]]:
    if phase == "markdown-save":
        return [
            *open_from_palette(MARKDOWN_FILE),
            element("element-click", PARAGRAPH, "AXButton"),
            element(
                "focused-element-check",
                PARAGRAPH_EDITOR,
                "AXTextArea",
                MARKDOWN_ORIGINAL,
            ),
            key("command+a"),
            text(MARKDOWN_LATEST),
            key("command+s"),
            element(
                "focused-element-check",
                PARAGRAPH_EDITOR,
                "AXTextArea",
                MARKDOWN_LATEST,
            ),
            screenshot(raw_dir, phase),
        ]
    if phase == "close-clean":
        return [action("move-safe-point"), key("command+w"), wait(160)]
    if phase == "table-save":
        return [
            *open_from_palette(MARKDOWN_FILE),
            element("element-click", TABLE_CELL, "AXButton"),
            element(
                "focused-element-check",
                TABLE_CELL_EDITOR,
                "AXTextField",
                TABLE_ORIGINAL,
            ),
            key("command+a"),
            text(TABLE_LATEST),
            key("command+s"),
            element(
                "focused-element-check",
                TABLE_CELL_EDITOR,
                "AXTextField",
                TABLE_LATEST,
            ),
            screenshot(raw_dir, phase),
        ]
    if phase == "conflict-open":
        return [
            *open_from_palette(MARKDOWN_FILE),
            element("element-check", PARAGRAPH, "AXButton"),
            screenshot(raw_dir, phase),
        ]
    if phase == "conflict-save":
        return [
            action("move-safe-point"),
            *edit_paragraph(CONFLICT_DRAFT),
            key("command+s"),
            *conflict_feedback(),
            screenshot(raw_dir, phase),
        ]
    if phase == "save-as-new":
        return [
            action("move-safe-point"),
            key("command+shift+s"),
            wait(),
            key("command+a"),
            text("saved-as.md"),
            key("return"),
            wait(),
            element(
                "focused-element-check",
                PARAGRAPH_EDITOR,
                "AXTextArea",
                CONFLICT_DRAFT,
            ),
            screenshot(raw_dir, phase),
        ]
    if phase == "conflict-save-as-current":
        return [
            action("move-safe-point"),
            *edit_paragraph(CURRENT_CONFLICT_DRAFT),
            key("command+shift+s"),
            wait(),
            key("return"),
            wait(160),
            key("return"),
            wait(),
            *conflict_feedback(),
            screenshot(raw_dir, phase),
        ]
    if phase == "conflict-save-as-symlink":
        return [
            action("move-safe-point"),
            key("command+shift+s"),
            wait(),
            key("command+a"),
            text("README-link.md"),
            key("return"),
            wait(160),
            key("return"),
            wait(),
            *conflict_feedback(),
            screenshot(raw_dir, phase),
        ]
    if phase == "discard-dirty-close":
        return [
            action("move-safe-point"),
            key("command+w"),
            wait(160),
            key("command+w"),
            wait(160),
        ]
    if phase == "session-draft":
        return [
            *open_from_palette(MARKDOWN_FILE),
            *edit_paragraph(SESSION_DRAFT),
            element(
                "focused-element-check",
                PARAGRAPH_EDITOR,
                "AXTextArea",
                SESSION_DRAFT,
            ),
            wait(400),
            screenshot(raw_dir, phase),
        ]
    if phase == "restored-conflict-save":
        return [
            action("move-safe-point"),
            element("element-click", PARAGRAPH, "AXButton"),
            element(
                "focused-element-check",
                PARAGRAPH_EDITOR,
                "AXTextArea",
                SESSION_DRAFT,
            ),
            key("command+s"),
            *conflict_feedback(),
            screenshot(raw_dir, phase),
        ]
    if phase == "plain-open-diagnostic":
        return [
            *open_from_palette(PLAIN_FILE),
            element("element-check", NON_MARKDOWN_BANNER),
            wait(400),
            element("element-check", NON_MARKDOWN_BANNER),
            screenshot(raw_dir, phase),
        ]
    if phase == "plain-save":
        return [
            action("move-safe-point"),
            action("window-click", xFraction=0.62, yFraction=0.45),
            key("command+f"),
            text(PLAIN_ORIGINAL_VALUE),
            wait(160),
            key("escape"),
            text(PLAIN_LATEST_VALUE),
            key("command+s"),
            element("element-check", NON_MARKDOWN_BANNER),
            screenshot(raw_dir, phase),
        ]
    raise AssertionError(f"unhandled phase: {phase}")


def main() -> None:
    args = parse_args()
    raw_dir = require_directory(args.raw_dir, "--raw-dir")
    output = pathlib.Path(args.output).expanduser().resolve()
    if not output.parent.is_dir():
        raise SystemExit(f"--output parent must exist: {output.parent}")
    payload = {
        "schemaVersion": 1,
        "actions": plan_actions(args.phase, raw_dir),
    }
    output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
