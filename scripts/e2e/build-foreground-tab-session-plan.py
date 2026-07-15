#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile
import uuid


FIXTURE_NAME = "格式示例.md"
FIRST_DRAFT_NAME = "未命名.md"
SECOND_DRAFT_NAME = "未命名 2.md"
FIRST_DRAFT_SOURCE = "E2E_SWITCH_COMMIT"
SECOND_DRAFT_SOURCE = "E2E_RIGHT_NEIGHBOR<br><br><br>" * 8
SOURCE_EDITOR = "document-block-0-source-editor"
FIRST_PARAGRAPH = "document-block-0-paragraph"
FIXTURE_HEADING = "document-block-0-heading"
FIXTURE_HEADING_SOURCE = "# Markdown 全格式示例"
FIXTURE_HEADING_SEEDED_VALUE = "Markdown 全格式示例 E2ERELAUNCHUNSAVED"
DOCS_FOLDER = "sidebar-folder-docs"
RESIZE_HANDLE = "sidebar-resize-handle"
SIDEBAR_SURFACE = "sidebar-surface"
FIXTURE_ROW = (
    "sidebar-file-docs%2F"
    "%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build one bounded real-App tab and session lifecycle plan."
    )
    parser.add_argument(
        "--phase",
        choices=[
            "switch-commit",
            "close-right-reopen",
            "close-left-seed",
            "seed-layout",
            "relaunch-scroll-check",
        ],
        required=True,
    )
    parser.add_argument("--session", required=True)
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


def load_session(raw_path: str) -> dict[str, object]:
    path = pathlib.Path(raw_path).expanduser().resolve()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"--session is not readable JSON: {error}") from error
    if not isinstance(payload, dict):
        raise SystemExit("--session must contain a JSON object")
    return payload


def session_tabs(session: dict[str, object]) -> list[dict[str, object]]:
    tabs = session.get("tabs")
    if not isinstance(tabs, list) or any(not isinstance(tab, dict) for tab in tabs):
        raise SystemExit("--session must contain a structured tabs array")
    return tabs


def require_tab(
    tabs: list[dict[str, object]],
    name: str,
    expected_source: str | None = None,
) -> dict[str, object]:
    matches = [tab for tab in tabs if tab.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"--session must contain exactly one {name!r} tab")
    tab = matches[0]
    raw_identifier = tab.get("id")
    if not isinstance(raw_identifier, str):
        raise SystemExit(f"tab {name!r} has no UUID identifier")
    try:
        uuid.UUID(raw_identifier)
    except ValueError as error:
        raise SystemExit(f"tab {name!r} has an invalid UUID identifier") from error
    if expected_source is not None and tab.get("text") != expected_source:
        raise SystemExit(f"tab {name!r} does not have the expected exact source")
    return tab


def identifier(prefix: str, tab: dict[str, object]) -> str:
    return f"{prefix}{tab['id']}"


def screenshot(raw_dir: pathlib.Path, name: str) -> dict[str, object]:
    return {
        "kind": "window-screenshot",
        "path": str(raw_dir / name),
        "waitMs": 40,
    }


def element(
    kind: str,
    accessibility_identifier: str,
    role: str,
    wait_ms: int = 80,
    expected_value: str | None = None,
    expected_selected: bool | None = None,
) -> dict[str, object]:
    action: dict[str, object] = {
        "kind": kind,
        "identifier": accessibility_identifier,
        "role": role,
        "waitMs": wait_ms,
    }
    if expected_value is not None:
        action["expectedValue"] = expected_value
    if expected_selected is not None:
        action["expectedSelected"] = expected_selected
    return action


def element_description_check(
    description: str,
    role: str,
    wait_ms: int = 40,
    expected_selected: bool | None = None,
) -> dict[str, object]:
    action: dict[str, object] = {
        "kind": "element-description-check",
        "description": description,
        "role": role,
        "waitMs": wait_ms,
    }
    if expected_selected is not None:
        action["expectedSelected"] = expected_selected
    return action


def switch_commit_actions(
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    tabs = session_tabs(session)
    if len(tabs) != 1:
        raise SystemExit("switch-commit requires exactly one initial fixture tab")
    fixture = require_tab(tabs, FIXTURE_NAME)
    if session.get("activeTabID") != fixture["id"]:
        raise SystemExit("switch-commit requires the fixture tab to be active")
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {"kind": "key", "key": "command+n", "waitMs": 80},
        element(
            "focused-element-check",
            SOURCE_EDITOR,
            "AXTextArea",
            expected_value="",
        ),
        {"kind": "text", "text": FIRST_DRAFT_SOURCE, "waitMs": 80},
        element("element-click", identifier("tab-", fixture), "AXButton"),
        screenshot(raw_dir, "tab-switch-fixture.png"),
        {"kind": "key", "key": "command+k", "waitMs": 80},
        {"kind": "text", "text": FIRST_DRAFT_NAME, "waitMs": 80},
        {"kind": "key", "key": "return", "waitMs": 80},
        element(
            "focused-element-check",
            SOURCE_EDITOR,
            "AXTextArea",
            expected_value=FIRST_DRAFT_SOURCE,
        ),
        screenshot(raw_dir, "tab-switch-draft-restored.png"),
    ]


def close_right_reopen_actions(
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    tabs = session_tabs(session)
    if len(tabs) != 2:
        raise SystemExit("close-right-reopen requires fixture and first draft tabs")
    require_tab(tabs, FIXTURE_NAME)
    first_draft = require_tab(tabs, FIRST_DRAFT_NAME, FIRST_DRAFT_SOURCE)
    if session.get("activeTabID") != first_draft["id"]:
        raise SystemExit("close-right-reopen requires the first draft to be active")
    tab_identifier = identifier("tab-", first_draft)
    close_identifier = identifier("tab-close-", first_draft)
    confirm_identifier = identifier("tab-confirm-close-", first_draft)
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {"kind": "key", "key": "command+n", "waitMs": 80},
        element(
            "focused-element-check",
            SOURCE_EDITOR,
            "AXTextArea",
            expected_value="",
        ),
        {"kind": "text", "text": SECOND_DRAFT_SOURCE, "waitMs": 80},
        {"kind": "key", "key": "escape", "waitMs": 80},
        {"kind": "scroll", "deltaY": -800, "waitMs": 40},
        {"kind": "wait", "durationMs": 160},
        element("element-click", tab_identifier, "AXButton"),
        element("element-click", close_identifier, "AXButton"),
        element("element-check", confirm_identifier, "AXButton", wait_ms=40),
        screenshot(raw_dir, "tab-close-right-confirm.png"),
        element("element-click", confirm_identifier, "AXButton"),
        element_description_check(
            SECOND_DRAFT_NAME,
            "AXButton",
            expected_selected=True,
        ),
        element("element-check", FIRST_PARAGRAPH, "AXButton", wait_ms=40),
        screenshot(raw_dir, "tab-close-right-neighbor.png"),
        {"kind": "key", "key": "command+shift+t", "waitMs": 80},
        element(
            "element-check",
            tab_identifier,
            "AXButton",
            expected_selected=True,
        ),
        screenshot(raw_dir, "tab-close-right-reopened.png"),
    ]


def close_left_seed_actions(
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    tabs = session_tabs(session)
    if len(tabs) != 3:
        raise SystemExit("close-left-seed requires fixture and two draft tabs")
    fixture = require_tab(tabs, FIXTURE_NAME)
    first_draft = require_tab(tabs, FIRST_DRAFT_NAME, FIRST_DRAFT_SOURCE)
    second_draft = require_tab(tabs, SECOND_DRAFT_NAME, SECOND_DRAFT_SOURCE)
    if session.get("activeTabID") != first_draft["id"]:
        raise SystemExit("close-left-seed requires the reopened first draft to be active")
    confirm_identifier = identifier("tab-confirm-close-", first_draft)
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        {"kind": "key", "key": "command+w", "waitMs": 80},
        element("element-check", confirm_identifier, "AXButton", wait_ms=40),
        screenshot(raw_dir, "tab-close-left-confirm.png"),
        {"kind": "key", "key": "command+w", "waitMs": 80},
        element(
            "element-check",
            identifier("tab-", second_draft),
            "AXButton",
            wait_ms=40,
            expected_selected=True,
        ),
        element("element-check", FIRST_PARAGRAPH, "AXButton", wait_ms=40),
        screenshot(raw_dir, "tab-close-left-neighbor.png"),
        element("element-click", identifier("tab-", fixture), "AXButton"),
        element("element-click", FIXTURE_HEADING, "AXButton"),
        element(
            "element-check",
            SOURCE_EDITOR,
            "AXTextArea",
            wait_ms=40,
            expected_value=FIXTURE_HEADING_SOURCE,
        ),
        element(
            "focused-element-check",
            SOURCE_EDITOR,
            "AXTextArea",
            expected_value=FIXTURE_HEADING_SOURCE,
        ),
        {"kind": "text", "text": " E2E_RELAUNCH_UNSAVED", "waitMs": 80},
        {"kind": "key", "key": "escape", "waitMs": 80},
    ]


def seed_layout_actions(
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    tabs = session_tabs(session)
    if len(tabs) != 3:
        raise SystemExit("seed-layout requires the stage-two three-tab snapshot")
    fixture = require_tab(tabs, FIXTURE_NAME)
    first_draft = require_tab(tabs, FIRST_DRAFT_NAME, FIRST_DRAFT_SOURCE)
    second_draft = require_tab(tabs, SECOND_DRAFT_NAME, SECOND_DRAFT_SOURCE)
    if session.get("activeTabID") != first_draft["id"]:
        raise SystemExit("seed-layout requires the reopened first draft snapshot")
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        element(
            "element-check",
            identifier("tab-", fixture),
            "AXButton",
            wait_ms=40,
            expected_selected=True,
        ),
        element(
            "element-check",
            FIXTURE_HEADING,
            "AXButton",
            wait_ms=40,
            expected_value=FIXTURE_HEADING_SEEDED_VALUE,
        ),
        {"kind": "scroll", "deltaY": -1200, "waitMs": 40},
        {"kind": "scroll", "deltaY": -1200, "waitMs": 40},
        {"kind": "wait", "durationMs": 200},
        {"kind": "key", "key": "command+shift+equals", "waitMs": 40},
        element("element-click", DOCS_FOLDER, "AXButton", wait_ms=40),
        {
            "kind": "element-drag",
            "identifier": RESIZE_HANDLE,
            "deltaX": 96,
            "waitMs": 40,
        },
        {"kind": "key", "key": "command+backslash", "waitMs": 40},
        element(
            "element-click",
            identifier("tab-", second_draft),
            "AXButton",
            wait_ms=40,
        ),
        screenshot(raw_dir, "tab-session-relaunch-seed.png"),
    ]


def relaunch_scroll_check_actions(
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    tabs = session_tabs(session)
    if len(tabs) != 2:
        raise SystemExit("relaunch-scroll-check requires fixture and second draft tabs")
    fixture = require_tab(tabs, FIXTURE_NAME)
    second_draft = require_tab(tabs, SECOND_DRAFT_NAME, SECOND_DRAFT_SOURCE)
    if session.get("activeTabID") != second_draft["id"]:
        raise SystemExit("relaunch-scroll-check requires the second draft to be active")
    return [
        {"kind": "move-safe-point", "waitMs": 40},
        element(
            "element-check",
            identifier("tab-", second_draft),
            "AXButton",
            wait_ms=40,
            expected_selected=True,
        ),
        element(
            "element-check",
            identifier("tab-", fixture),
            "AXButton",
            wait_ms=40,
        ),
        element("element-check", FIRST_PARAGRAPH, "AXButton", wait_ms=40),
        {"kind": "key", "key": "command+backslash", "waitMs": 40},
        {"kind": "wait", "durationMs": 200},
        element("element-check", SIDEBAR_SURFACE, "AXGroup", wait_ms=40),
        element("element-click", DOCS_FOLDER, "AXButton", wait_ms=40),
        element("element-click", FIXTURE_ROW, "AXButton", wait_ms=80),
        {"kind": "wait", "durationMs": 280},
        element(
            "element-check",
            identifier("tab-", fixture),
            "AXButton",
            wait_ms=40,
            expected_selected=True,
        ),
        screenshot(raw_dir, "tab-session-restored-scroll.png"),
    ]


def actions_for_phase(
    phase: str,
    session: dict[str, object],
    raw_dir: pathlib.Path,
) -> list[dict[str, object]]:
    if phase == "switch-commit":
        return switch_commit_actions(session, raw_dir)
    if phase == "close-right-reopen":
        return close_right_reopen_actions(session, raw_dir)
    if phase == "close-left-seed":
        return close_left_seed_actions(session, raw_dir)
    if phase == "seed-layout":
        return seed_layout_actions(session, raw_dir)
    return relaunch_scroll_check_actions(session, raw_dir)


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
    session = load_session(arguments.session)
    raw_dir = require_directory(arguments.raw_dir, "--raw-dir")
    write_atomic_json(
        {
            "schemaVersion": 1,
            "actions": actions_for_phase(arguments.phase, session, raw_dir),
        },
        pathlib.Path(arguments.output),
    )


if __name__ == "__main__":
    main()
