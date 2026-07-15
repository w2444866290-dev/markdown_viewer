#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib


TASK_BEFORE = "- [ ] 协同编辑"
TASK_AFTER = "- [x] 协同编辑"
EXPECTED_TASK_BLOCK = "\n".join([
    "- [x] 实时渲染",
    "- [x] 语法即时高亮",
    "- [x] 协同编辑",
    "- [ ] 导出 PDF",
])
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
        description="Verify the bounded real-App preview content interaction."
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
    raise SystemExit(f"foreground preview content verification failed: {message}")


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
    if fixture.count(TASK_BEFORE) != 1 or TASK_AFTER in fixture:
        fail("the fixture task marker drifted")
    expected_source = fixture.replace(TASK_BEFORE, TASK_AFTER, 1)

    tabs = session.get("tabs")
    if not isinstance(tabs, list) or len(tabs) != 1 or not isinstance(tabs[0], dict):
        fail("session must contain exactly one structured fixture tab")
    tab = tabs[0]
    if session.get("activeTabID") != tab.get("id") \
            or tab.get("url") is not None \
            or tab.get("name") != "格式示例.md" \
            or tab.get("isMarkdown") is not True \
            or tab.get("isDirty") is not True \
            or tab.get("text") != expected_source \
            or not math.isclose(float(tab.get("scrollY", -1)), 1_600, abs_tol=0.5):
        fail("fixture tab metadata, source, or scroll position is wrong")

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
    if rebuilt != expected_source \
            or any(not isinstance(block_id, str) or not block_id for block_id in block_ids) \
            or len(set(block_ids)) != len(block_ids) \
            or blocks[19].get("kind") != "list" \
            or blocks[19].get("source") != EXPECTED_TASK_BLOCK:
        fail("task mutation did not preserve the exact structured document")

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
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("localMutationCount") != 1 \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic_session_path != session_path.resolve() \
            or not math.isclose(float(diagnostic.get("scrollY", -1)), 1_600, abs_tol=0.5) \
            or outline.get("headingCount") != 15 \
            or outline.get("activeIndex") != 9 \
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
            "label": "foreground-preview-content-session",
            "assertions": {
                "sourceMutationExact": tab["text"] == expected_source,
                "blockModelRoundTripsExactly": rebuilt == expected_source,
                "onlyExpectedTaskMarkerChanged": (
                    fixture.replace(TASK_BEFORE, TASK_AFTER, 1) == expected_source
                ),
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
            "label": "foreground-preview-content-diagnostic",
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
                "expectedMutationCounts": (
                    diagnostic["localMutationCount"] == 1
                    and diagnostic["parseCount"] == 2
                ),
                "scrollAndOutlinePreserved": (
                    math.isclose(float(diagnostic["scrollY"]), 1_600, abs_tol=0.5)
                    and diagnostic["outline"] == {
                        "headingCount": 15,
                        "activeIndex": 9,
                    }
                ),
            },
            "snapshot": diagnostic,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
