#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib


EXPECTED_REFERENCE_BLOCK = (
    "Markdown 是一种轻量级标记语言[^1]，本编辑器实现了其中最常用的子集[^scope]。"
)
EXPECTED_DEFINITION_BLOCK = "\n".join([
    "[^1]: 由 John Gruber 于 2004 年提出。",
    "[^scope]: 标题、列表、代码、表格、链接、脚注等。",
])
MIN_SCROLL_Y = 2_990
MAX_SCROLL_Y = 3_120
EXPECTED_FIND = {
    "query": "",
    "display": "",
    "matchCount": 0,
    "currentIndex": 0,
    "invalidRegex": False,
    "replaceExpanded": False,
    "caseSensitive": False,
    "wholeWord": False,
    "regex": False,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the bounded real-App preview footnote interaction."
    )
    parser.add_argument("--session", required=True)
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--workspace-fixture", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument(
        "--report-kind",
        choices=["session", "diagnostic"],
        default="session",
    )
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def load_json(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is not readable JSON: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must contain a JSON object")
    return value


def fail(message: str) -> None:
    raise SystemExit(f"foreground preview footnotes verification failed: {message}")


def scroll_is_expected(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and MIN_SCROLL_Y <= number <= MAX_SCROLL_Y


def main() -> None:
    arguments = parse_args()
    session_path = pathlib.Path(arguments.session)
    diagnostic_path = pathlib.Path(arguments.diagnostic)
    fixture_path = pathlib.Path(arguments.fixture)
    workspace_path = pathlib.Path(arguments.workspace_fixture)
    output_root = pathlib.Path(arguments.output_root)
    session = load_json(session_path, "session")
    diagnostic = load_json(diagnostic_path, "diagnostic")
    fixture = fixture_path.read_text(encoding="utf-8")
    if fixture.count(EXPECTED_REFERENCE_BLOCK) != 1 \
            or fixture.count(EXPECTED_DEFINITION_BLOCK) != 1:
        fail("the fixture footnote markers drifted")

    tabs = session.get("tabs")
    if not isinstance(tabs, list) or len(tabs) != 1 or not isinstance(tabs[0], dict):
        fail("session must contain exactly one structured fixture tab")
    tab = tabs[0]
    if session.get("activeTabID") != tab.get("id") \
            or tab.get("url") is not None \
            or tab.get("name") != "格式示例.md" \
            or tab.get("isMarkdown") is not True \
            or tab.get("isDirty") is not False \
            or tab.get("text") != fixture \
            or not scroll_is_expected(tab.get("scrollY")):
        fail("fixture tab metadata, source, cleanliness, or scroll position is wrong")

    markdown = tab.get("markdownDocument")
    if not isinstance(markdown, dict):
        fail("fixture tab has no structured Markdown document")
    blocks = markdown.get("blocks")
    if not isinstance(blocks, list) \
            or len(blocks) != 37 \
            or any(not isinstance(block, dict) for block in blocks):
        fail("fixture block count or structure changed")
    rebuilt = "".join(
        block.get("leadingTrivia", "") + block.get("source", "")
        for block in blocks
    ) + markdown.get("trailingTrivia", "")
    block_ids = [block.get("id") for block in blocks]
    if rebuilt != fixture \
            or any(not isinstance(block_id, str) or not block_id for block_id in block_ids) \
            or len(set(block_ids)) != len(block_ids) \
            or blocks[35].get("kind") != "paragraph" \
            or blocks[35].get("source") != EXPECTED_REFERENCE_BLOCK \
            or blocks[36].get("kind") != "footnotes" \
            or blocks[36].get("source") != EXPECTED_DEFINITION_BLOCK:
        fail("footnote navigation did not preserve the exact structured document")

    observed_find = diagnostic.get("find")
    outline = diagnostic.get("outline")
    visual = diagnostic.get("visual")
    if not isinstance(observed_find, dict) \
            or not isinstance(outline, dict) \
            or not isinstance(visual, dict):
        fail("diagnostic Find, outline, or visual state is not an object")
    if any(observed_find.get(key) != value for key, value in EXPECTED_FIND.items()):
        fail(f"Find diagnostic mismatch: {observed_find!r}")
    diagnostic_session_path = pathlib.Path(
        str(diagnostic.get("sessionPath", ""))
    ).resolve()
    if diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("activeTableCell") is not None \
            or diagnostic.get("dirty") is not False \
            or diagnostic.get("localMutationCount") != 0 \
            or diagnostic.get("parseCount") != 1 \
            or diagnostic_session_path != session_path.resolve() \
            or not scroll_is_expected(diagnostic.get("scrollY")) \
            or outline.get("headingCount") != 15 \
            or outline.get("activeIndex") != 13 \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("paletteVisible") is not False \
            or visual.get("findPanelVisible") is not False \
            or visual.get("replaceRowVisible") is not False \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False:
        fail("editor, outline, or visual diagnostic mismatch")

    fixture_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
    workspace_hash = hashlib.sha256(workspace_path.read_bytes()).hexdigest()
    if fixture_hash != arguments.fixture_sha or workspace_hash != arguments.fixture_sha:
        fail("bundle or workspace fixture bytes changed")
    if arguments.check_only:
        return

    if arguments.report_kind == "session":
        payload = {
            "label": "foreground-preview-footnotes-session",
            "assertions": {
                "sourceUnchanged": tab["text"] == fixture,
                "blockModelRoundTripsExactly": rebuilt == fixture,
                "documentRemainedClean": tab["isDirty"] is False,
                "bundleFixtureUnchanged": fixture_hash == arguments.fixture_sha,
                "workspaceFixtureUnchanged": workspace_hash == arguments.fixture_sha,
            },
            "activeDocument": tab["name"],
            "sessionPath": os.path.relpath(session_path, output_root),
            "fixtureSHA256": fixture_hash,
            "workspaceFixtureSHA256": workspace_hash,
        }
    else:
        payload = {
            "label": "foreground-preview-footnotes-diagnostic",
            "assertions": {
                "previewReturnedToEdit": (
                    diagnostic["mode"] == "edit"
                    and diagnostic["visual"]["previewActive"] is False
                ),
                "editingSurfacesClosed": (
                    diagnostic["blockID"] is None
                    and diagnostic["activeTableCell"] is None
                    and diagnostic["visual"]["sourceEditorVisible"] is False
                    and diagnostic["visual"]["tableGridVisible"] is False
                ),
                "navigationDidNotMutateSource": (
                    diagnostic["dirty"] is False
                    and diagnostic["localMutationCount"] == 0
                    and diagnostic["parseCount"] == 1
                ),
                "footnoteScrollAndOutlinePreserved": (
                    scroll_is_expected(diagnostic["scrollY"])
                    and diagnostic["outline"] == {
                        "headingCount": 15,
                        "activeIndex": 13,
                    }
                ),
            },
            "acceptedScrollRange": {
                "minimum": MIN_SCROLL_Y,
                "maximum": MAX_SCROLL_Y,
                "reason": (
                    "launch starts at 3000 and bottom-clamped animated footnote jumps "
                    "settle near the 1180x760 document maximum"
                ),
            },
            "snapshot": diagnostic,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
