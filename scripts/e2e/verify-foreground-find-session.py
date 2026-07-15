#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib


SCENARIOS = {
    "find-options": {
        "source": "Red red redwood RED",
        "selection": None,
        "local": 1,
        "parse": 2,
        "find": {
            "query": "red",
            "display": "1/1",
            "matchCount": 1,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": False,
            "caseSensitive": True,
            "wholeWord": True,
            "regex": False,
        },
    },
    "find-regex-replace": {
        "source": "Current:Ada All:Bob All:Cy",
        "selection": None,
        "local": 3,
        "parse": 4,
        "find": {
            "query": r"Name:(\w+)",
            "display": "无结果",
            "matchCount": 0,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": True,
            "caseSensitive": False,
            "wholeWord": False,
            "regex": True,
        },
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify bounded foreground Find session and diagnostics."
    )
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), required=True)
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
    raise SystemExit(f"foreground Find verification failed: {message}")


def main() -> None:
    arguments = parse_args()
    expected = SCENARIOS[arguments.scenario]
    session_path = pathlib.Path(arguments.session)
    diagnostic_path = pathlib.Path(arguments.diagnostic)
    fixture_path = pathlib.Path(arguments.fixture)
    workspace_path = pathlib.Path(arguments.workspace_fixture)
    output_root = pathlib.Path(arguments.output_root)
    session = load_json(session_path, "session")
    diagnostic = load_json(diagnostic_path, "diagnostic")
    fixture = fixture_path.read_text(encoding="utf-8")

    tabs = session.get("tabs")
    if not isinstance(tabs, list) or len(tabs) != 2:
        fail("session must contain exactly the fixture tab and one untitled tab")
    active = next(
        (tab for tab in tabs if tab.get("id") == session.get("activeTabID")),
        None,
    )
    fixture_tab = next((tab for tab in tabs if tab.get("name") == "格式示例.md"), None)
    if active is None or active.get("name") != "未命名.md":
        fail("the untitled Markdown tab is not active")
    if fixture_tab is None \
            or fixture_tab.get("url") is not None \
            or fixture_tab.get("isMarkdown") is not True \
            or fixture_tab.get("isDirty") is not False \
            or fixture_tab.get("text") != fixture:
        fail("the fixture tab changed")
    if active.get("url") is not None \
            or active.get("isMarkdown") is not True \
            or active.get("isDirty") is not True \
            or active.get("text") != expected["source"] \
            or not math.isclose(float(active.get("scrollY", -1)), 0, abs_tol=0.5):
        fail("the untitled tab metadata or source is wrong")

    fixture_markdown = fixture_tab.get("markdownDocument")
    if not isinstance(fixture_markdown, dict):
        fail("the fixture tab has no structured Markdown document")
    fixture_blocks = fixture_markdown.get("blocks")
    if not isinstance(fixture_blocks, list) \
            or any(not isinstance(block, dict) for block in fixture_blocks):
        fail("the fixture tab has no structured Markdown blocks")
    fixture_rebuilt = "".join(
        block.get("leadingTrivia", "") + block.get("source", "")
        for block in fixture_blocks
    ) + fixture_markdown.get("trailingTrivia", "")
    if fixture_rebuilt != fixture:
        fail("the fixture block model does not round trip exactly")

    markdown = active.get("markdownDocument", {})
    if not isinstance(markdown, dict):
        fail("the untitled tab has no structured Markdown document")
    blocks = markdown.get("blocks", [])
    if not isinstance(blocks, list) \
            or any(not isinstance(block, dict) for block in blocks):
        fail("the untitled tab has no structured Markdown blocks")
    rebuilt = "".join(
        block.get("leadingTrivia", "") + block.get("source", "")
        for block in blocks
    ) + markdown.get("trailingTrivia", "")
    if len(blocks) != 1 \
            or blocks[0].get("kind") != "paragraph" \
            or blocks[0].get("source") != expected["source"] \
            or rebuilt != expected["source"]:
        fail("the untitled block model does not round trip exactly")

    visual = diagnostic.get("visual", {})
    observed_find = diagnostic.get("find", {})
    if not isinstance(visual, dict) or not isinstance(observed_find, dict):
        fail("diagnostic Find or visual state is not an object")
    if any(observed_find.get(key) != value for key, value in expected["find"].items()):
        fail(f"Find diagnostic mismatch: {observed_find!r}")
    diagnostic_session_path = pathlib.Path(
        str(diagnostic.get("sessionPath", ""))
    ).resolve()
    if diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != "未命名.md" \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") != expected["selection"] \
            or diagnostic.get("activeTableCell") is not None \
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("localMutationCount") != expected["local"] \
            or diagnostic.get("parseCount") != expected["parse"] \
            or diagnostic_session_path != session_path.resolve() \
            or not math.isclose(float(diagnostic.get("scrollY", -1)), 0, abs_tol=0.5) \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("paletteVisible") is not False \
            or visual.get("findPanelVisible") is not True \
            or visual.get("replaceRowVisible") is not expected["find"]["replaceExpanded"] \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False:
        fail("editor or visual diagnostic mismatch")

    fixture_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
    workspace_hash = hashlib.sha256(workspace_path.read_bytes()).hexdigest()
    if fixture_hash != arguments.fixture_sha or workspace_hash != arguments.fixture_sha:
        fail("bundle or workspace fixture bytes changed")
    if arguments.check_only:
        return

    common_assertions = {
        "untitledSourceExact": active["text"] == expected["source"],
        "blockModelRoundTripsExactly": rebuilt == expected["source"],
        "fixtureTabUnchanged": (
            fixture_tab["text"] == fixture and fixture_rebuilt == fixture
        ),
        "bundleFixtureUnchanged": fixture_hash == arguments.fixture_sha,
        "workspaceFixtureUnchanged": workspace_hash == arguments.fixture_sha,
    }
    if arguments.report_kind == "session":
        payload = {
            "label": f"foreground-{arguments.scenario}-session",
            "assertions": common_assertions,
            "activeDocument": active["name"],
            "sessionPath": os.path.relpath(session_path, output_root),
            "fixtureSHA256": fixture_hash,
            "workspaceFixtureSHA256": workspace_hash,
        }
    else:
        payload = {
            "label": f"foreground-{arguments.scenario}-diagnostic",
            "assertions": {
                "findStateExact": all(
                    observed_find.get(key) == value
                    for key, value in expected["find"].items()
                ),
                "sourceEditorCommittedBeforeFind": (
                    diagnostic["blockID"] is None
                    and diagnostic["blockType"] is None
                    and diagnostic["selection"] is None
                    and diagnostic["visual"]["sourceEditorVisible"] is False
                ),
                "expectedMutationCounts": (
                    diagnostic["localMutationCount"] == expected["local"]
                    and diagnostic["parseCount"] == expected["parse"]
                ),
                "findOverlayExact": (
                    diagnostic["visual"]["findPanelVisible"] is True
                    and diagnostic["visual"]["replaceRowVisible"]
                        is expected["find"]["replaceExpanded"]
                ),
            },
            "snapshot": diagnostic,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
