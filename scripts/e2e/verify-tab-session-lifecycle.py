#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import pathlib


FIXTURE_NAME = "格式示例.md"
FIRST_DRAFT_NAME = "未命名.md"
SECOND_DRAFT_NAME = "未命名 2.md"
FIRST_DRAFT_SOURCE = "E2E_SWITCH_COMMIT"
SECOND_DRAFT_SOURCE = "E2E_RIGHT_NEIGHBOR<br><br><br>" * 8
HEADING_BEFORE = "# Markdown 全格式示例"
HEADING_AFTER = "# Markdown 全格式示例 E2E_RELAUNCH_UNSAVED"
DEFAULT_FIND = {
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
        description="Verify one stage of the real-App tab and session lifecycle."
    )
    parser.add_argument(
        "--stage",
        choices=[
            "switch-commit",
            "close-right-reopen",
            "close-left-seed",
            "relaunch",
            "relaunch-scroll-check",
        ],
        required=True,
    )
    parser.add_argument("--session", required=True)
    parser.add_argument("--expected-session-path")
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--workspace-fixture", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--previous-session")
    parser.add_argument("--previous-diagnostic")
    parser.add_argument("--output-root", required=True)
    parser.add_argument(
        "--report-kind",
        choices=["session", "diagnostic"],
        default="session",
    )
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def load_json(raw_path: str, label: str) -> dict[str, object]:
    path = pathlib.Path(raw_path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is not readable JSON: {error}") from error
    if not isinstance(payload, dict):
        raise SystemExit(f"{label} must contain a JSON object")
    return payload


def fail(message: str) -> None:
    raise SystemExit(f"tab session lifecycle verification failed: {message}")


def require_previous(
    raw_path: str | None,
    label: str,
) -> dict[str, object]:
    if not raw_path:
        fail(f"{label} is required for this stage")
    return load_json(raw_path, label)


def require_tabs(session: dict[str, object]) -> list[dict[str, object]]:
    tabs = session.get("tabs")
    if not isinstance(tabs, list) or any(not isinstance(tab, dict) for tab in tabs):
        fail("session tabs are not a structured array")
    return tabs


def require_named_tab(
    tabs: list[dict[str, object]],
    name: str,
) -> dict[str, object]:
    matches = [tab for tab in tabs if tab.get("name") == name]
    if len(matches) != 1:
        fail(f"expected exactly one {name!r} tab")
    return matches[0]


def require_active_tab(
    session: dict[str, object],
    tabs: list[dict[str, object]],
) -> dict[str, object]:
    active = next(
        (tab for tab in tabs if tab.get("id") == session.get("activeTabID")),
        None,
    )
    if active is None:
        fail("session activeTabID does not identify one current tab")
    return active


def structured_blocks(tab: dict[str, object]) -> list[dict[str, object]]:
    markdown = tab.get("markdownDocument")
    if not isinstance(markdown, dict):
        fail(f"tab {tab.get('name')!r} has no structured Markdown document")
    blocks = markdown.get("blocks")
    if not isinstance(blocks, list) or any(not isinstance(block, dict) for block in blocks):
        fail(f"tab {tab.get('name')!r} has no structured Markdown blocks")
    rebuilt = "".join(
        block.get("leadingTrivia", "") + block.get("source", "")
        for block in blocks
    ) + markdown.get("trailingTrivia", "")
    if rebuilt != tab.get("text"):
        fail(f"tab {tab.get('name')!r} does not round trip exactly")
    identifiers = [block.get("id") for block in blocks]
    if any(not isinstance(identifier, str) or not identifier for identifier in identifiers) \
            or len(set(identifiers)) != len(identifiers):
        fail(f"tab {tab.get('name')!r} has invalid or duplicate block IDs")
    return blocks


def assert_fixture_unchanged(tab: dict[str, object], fixture: str) -> None:
    if tab.get("url") is not None \
            or tab.get("isMarkdown") is not True \
            or tab.get("isDirty") is not False \
            or tab.get("text") != fixture:
        fail("the fixture tab changed before the relaunch seed stage")
    blocks = structured_blocks(tab)
    if len(blocks) != 37:
        fail("the fixture block count changed")


def assert_draft(
    tab: dict[str, object],
    source: str,
    selection_location: int,
    minimum_scroll: float = 0,
) -> list[dict[str, object]]:
    if tab.get("url") is not None \
            or tab.get("isMarkdown") is not True \
            or tab.get("isDirty") is not True \
            or tab.get("text") != source \
            or tab.get("selectionLocation") != selection_location \
            or tab.get("selectionLength") != 0:
        fail(f"draft tab {tab.get('name')!r} metadata or source is wrong")
    scroll = finite_number(tab.get("scrollY"))
    if (minimum_scroll > 0 and scroll <= minimum_scroll) \
            or (minimum_scroll <= 0 and not close_number(scroll, 0)):
        fail(f"draft tab {tab.get('name')!r} scroll position is wrong")
    blocks = structured_blocks(tab)
    if len(blocks) != 1 \
            or blocks[0].get("kind") != "paragraph" \
            or blocks[0].get("source") != source:
        fail(f"draft tab {tab.get('name')!r} block model is wrong")
    return blocks


def close_number(value: object, expected: float, tolerance: float = 0.5) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and math.isclose(number, expected, abs_tol=tolerance)


def finite_number(value: object) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        fail(f"expected a finite number, found {value!r}")
        raise AssertionError from error
    if not math.isfinite(number):
        fail(f"expected a finite number, found {value!r}")
    return number


def require_visual_anchor(
    diagnostic: dict[str, object],
    name: str,
) -> dict[str, object]:
    visual = diagnostic.get("visual")
    anchors = visual.get("anchors") if isinstance(visual, dict) else None
    anchor = anchors.get(name) if isinstance(anchors, dict) else None
    if not isinstance(anchor, dict):
        fail(f"diagnostic is missing visual anchor {name!r}")
    for field in ("x", "y", "width", "height"):
        value = finite_number(anchor.get(field))
        if field in {"width", "height"} and value <= 0:
            fail(f"diagnostic visual anchor {name!r} is not positive")
    return anchor


def assert_default_visual(
    diagnostic: dict[str, object],
    source_editor_visible: bool,
    sidebar_visible: bool = True,
) -> None:
    visual = diagnostic.get("visual")
    if not isinstance(visual, dict):
        fail("diagnostic visual state is not an object")
    expected = {
        "documentVisible": True,
        "sidebarVisible": sidebar_visible,
        "paletteVisible": False,
        "findPanelVisible": False,
        "replaceRowVisible": False,
        "previewActive": False,
        "sourceEditorVisible": source_editor_visible,
        "tableGridVisible": False,
    }
    if any(visual.get(key) != value for key, value in expected.items()):
        fail(f"diagnostic visual state mismatch: {visual!r}")


def assert_diagnostic_base(
    diagnostic: dict[str, object],
    session_path: pathlib.Path,
    document: str,
    dirty: bool,
    source_editor_visible: bool,
    sidebar_visible: bool = True,
) -> None:
    if diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != document \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("dirty") is not dirty \
            or diagnostic.get("activeTableCell") is not None:
        fail("diagnostic document, mode, dirty, or table state is wrong")
    observed_session_path = pathlib.Path(
        str(diagnostic.get("sessionPath", ""))
    ).resolve()
    if observed_session_path != session_path.resolve():
        fail("diagnostic session path does not match the isolated profile")
    observed_find = diagnostic.get("find")
    if not isinstance(observed_find, dict) \
            or any(observed_find.get(key) != value for key, value in DEFAULT_FIND.items()):
        fail(f"diagnostic Find state mismatch: {observed_find!r}")
    assert_default_visual(diagnostic, source_editor_visible, sidebar_visible)


def assert_fixture_mutation(
    fixture_tab: dict[str, object],
    previous_fixture_tab: dict[str, object],
    fixture: str,
) -> None:
    expected_source = fixture.replace(HEADING_BEFORE, HEADING_AFTER, 1)
    if fixture.count(HEADING_BEFORE) != 1:
        fail("fixture heading marker drifted")
    if fixture_tab.get("id") != previous_fixture_tab.get("id") \
            or fixture_tab.get("url") is not None \
            or fixture_tab.get("isMarkdown") is not True \
            or fixture_tab.get("isDirty") is not True \
            or fixture_tab.get("text") != expected_source:
        fail("fixture relaunch seed source or identity is wrong")
    before_blocks = structured_blocks(previous_fixture_tab)
    after_blocks = structured_blocks(fixture_tab)
    if len(before_blocks) != 37 or len(after_blocks) != 37:
        fail("fixture block count changed while seeding relaunch")
    if after_blocks[0].get("source") != HEADING_AFTER \
            or before_blocks[0].get("source") != HEADING_BEFORE:
        fail("fixture heading block source is wrong")
    normalized_first = copy.deepcopy(after_blocks[0])
    normalized_first["source"] = HEADING_BEFORE
    if normalized_first != before_blocks[0] or after_blocks[1:] != before_blocks[1:]:
        fail("editing the heading changed an untouched block or stable block ID")
    before_markdown = previous_fixture_tab["markdownDocument"]
    after_markdown = fixture_tab["markdownDocument"]
    if set(after_markdown) != set(before_markdown) \
            or after_markdown.get("trailingTrivia") != before_markdown.get("trailingTrivia"):
        fail("fixture Markdown serialization changed outside the edited heading")


def assert_seeded_fixture(tab: dict[str, object], fixture: str) -> None:
    expected_source = fixture.replace(HEADING_BEFORE, HEADING_AFTER, 1)
    if fixture.count(HEADING_BEFORE) != 1 \
            or tab.get("url") is not None \
            or tab.get("isMarkdown") is not True \
            or tab.get("isDirty") is not True \
            or tab.get("text") != expected_source:
        fail("relaunch did not preserve the seeded fixture source")
    blocks = structured_blocks(tab)
    if len(blocks) != 37 or blocks[0].get("source") != HEADING_AFTER:
        fail("relaunch did not preserve the seeded fixture block model")


def verify_switch_commit(
    session: dict[str, object],
    diagnostic: dict[str, object],
    fixture: str,
    session_path: pathlib.Path,
) -> dict[str, object]:
    tabs = require_tabs(session)
    if [tab.get("name") for tab in tabs] != [FIXTURE_NAME, FIRST_DRAFT_NAME]:
        fail("switch-commit tab order is wrong")
    fixture_tab = require_named_tab(tabs, FIXTURE_NAME)
    draft = require_named_tab(tabs, FIRST_DRAFT_NAME)
    if require_active_tab(session, tabs).get("id") != draft.get("id"):
        fail("first draft is not active after switch-commit")
    assert_fixture_unchanged(fixture_tab, fixture)
    blocks = assert_draft(draft, FIRST_DRAFT_SOURCE, len(FIRST_DRAFT_SOURCE))
    assert_diagnostic_base(
        diagnostic,
        session_path,
        FIRST_DRAFT_NAME,
        True,
        True,
    )
    selection = diagnostic.get("selection")
    if diagnostic.get("blockID") != blocks[0].get("id") \
            or diagnostic.get("blockType") != "paragraph" \
            or selection != {"location": len(FIRST_DRAFT_SOURCE), "length": 0} \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1 \
            or not close_number(diagnostic.get("scrollY"), 0) \
            or diagnostic.get("outline") != {"headingCount": 0, "activeIndex": 0}:
        fail("switch-commit diagnostic state is wrong")
    return {"activeTab": draft, "fixtureTab": fixture_tab}


def verify_close_right_reopen(
    session: dict[str, object],
    diagnostic: dict[str, object],
    previous_session: dict[str, object],
    fixture: str,
    session_path: pathlib.Path,
) -> dict[str, object]:
    previous_tabs = require_tabs(previous_session)
    previous_fixture = require_named_tab(previous_tabs, FIXTURE_NAME)
    previous_first = require_named_tab(previous_tabs, FIRST_DRAFT_NAME)
    tabs = require_tabs(session)
    if [tab.get("name") for tab in tabs] != [
        FIXTURE_NAME,
        SECOND_DRAFT_NAME,
        FIRST_DRAFT_NAME,
    ]:
        fail("close-right-reopen tab order is wrong")
    fixture_tab = require_named_tab(tabs, FIXTURE_NAME)
    second = require_named_tab(tabs, SECOND_DRAFT_NAME)
    first = require_named_tab(tabs, FIRST_DRAFT_NAME)
    if fixture_tab.get("id") != previous_fixture.get("id") \
            or first.get("id") != previous_first.get("id"):
        fail("closing and reopening changed an existing tab ID")
    if require_active_tab(session, tabs).get("id") != first.get("id"):
        fail("reopened first draft is not active")
    assert_fixture_unchanged(fixture_tab, fixture)
    assert_draft(first, FIRST_DRAFT_SOURCE, len(FIRST_DRAFT_SOURCE))
    assert_draft(
        second,
        SECOND_DRAFT_SOURCE,
        0,
        minimum_scroll=100,
    )
    assert_diagnostic_base(
        diagnostic,
        session_path,
        FIRST_DRAFT_NAME,
        True,
        False,
    )
    if diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("parseCount") != 1 \
            or diagnostic.get("localMutationCount") != 0 \
            or diagnostic.get("outline") != {"headingCount": 0, "activeIndex": 0}:
        fail("close-right-reopen diagnostic state is wrong")
    return {"activeTab": first, "fixtureTab": fixture_tab, "secondDraft": second}


def verify_close_left_seed(
    session: dict[str, object],
    diagnostic: dict[str, object],
    previous_session: dict[str, object],
    fixture: str,
    session_path: pathlib.Path,
) -> dict[str, object]:
    previous_tabs = require_tabs(previous_session)
    previous_fixture = require_named_tab(previous_tabs, FIXTURE_NAME)
    previous_second = require_named_tab(previous_tabs, SECOND_DRAFT_NAME)
    tabs = require_tabs(session)
    if [tab.get("name") for tab in tabs] != [FIXTURE_NAME, SECOND_DRAFT_NAME]:
        fail("close-left-seed tab order is wrong")
    fixture_tab = require_named_tab(tabs, FIXTURE_NAME)
    second = require_named_tab(tabs, SECOND_DRAFT_NAME)
    if second.get("id") != previous_second.get("id"):
        fail("left-neighbor draft ID changed")
    if require_active_tab(session, tabs).get("id") != second.get("id"):
        fail("the non-first draft tab is not active after relaunch seeding")
    assert_fixture_mutation(fixture_tab, previous_fixture, fixture)
    assert_draft(
        second,
        SECOND_DRAFT_SOURCE,
        0,
        minimum_scroll=100,
    )
    session_scroll = finite_number(fixture_tab.get("scrollY"))
    second_scroll = finite_number(second.get("scrollY"))
    if session_scroll <= 1_500:
        fail("fixture did not persist a deep scroll position")
    if session.get("fontIndex") != 2 \
            or session.get("sidebarOpen") is not False \
            or not close_number(session.get("sidebarWidth"), 312) \
            or session.get("expandedFolderPaths") != []:
        fail("non-default font, sidebar, or folder state was not seeded")
    assert_diagnostic_base(
        diagnostic,
        session_path,
        SECOND_DRAFT_NAME,
        True,
        False,
        False,
    )
    outline = diagnostic.get("outline")
    diagnostic_scroll = finite_number(diagnostic.get("scrollY"))
    if diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1 \
            or not close_number(diagnostic_scroll, second_scroll) \
            or outline != {"headingCount": 0, "activeIndex": 0}:
        fail("close-left-seed draft diagnostic state is wrong")
    return {"activeTab": second, "fixtureTab": fixture_tab, "secondDraft": second}


def verify_relaunch(
    session: dict[str, object],
    diagnostic: dict[str, object],
    previous_session: dict[str, object],
    previous_diagnostic: dict[str, object],
    fixture: str,
    session_path: pathlib.Path,
) -> dict[str, object]:
    if session != previous_session:
        fail("normal terminate and relaunch did not preserve the exact session snapshot")
    tabs = require_tabs(session)
    fixture_tab = require_named_tab(tabs, FIXTURE_NAME)
    second = require_named_tab(tabs, SECOND_DRAFT_NAME)
    if require_active_tab(session, tabs).get("id") != second.get("id"):
        fail("relaunch did not restore the non-first active tab")
    assert_seeded_fixture(fixture_tab, fixture)
    assert_draft(
        second,
        SECOND_DRAFT_SOURCE,
        0,
        minimum_scroll=100,
    )
    assert_diagnostic_base(
        diagnostic,
        session_path,
        SECOND_DRAFT_NAME,
        True,
        False,
        False,
    )
    current_outline = diagnostic.get("outline")
    previous_outline = previous_diagnostic.get("outline")
    current_paragraph = require_visual_anchor(
        diagnostic,
        "document-content-0-paragraph",
    )
    previous_paragraph = require_visual_anchor(
        previous_diagnostic,
        "document-content-0-paragraph",
    )
    if diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("parseCount") != 1 \
            or diagnostic.get("localMutationCount") != 0 \
            or not close_number(
                diagnostic.get("scrollY"),
                finite_number(second.get("scrollY")),
            ) \
            or not close_number(
                diagnostic.get("scrollY"),
                finite_number(previous_diagnostic.get("scrollY")),
            ) \
            or current_outline != previous_outline \
            or current_outline != {"headingCount": 0, "activeIndex": 0} \
            or any(
                not close_number(current_paragraph.get(field), finite_number(
                    previous_paragraph.get(field)
                ), tolerance=1)
                for field in ("x", "y", "width", "height")
            ):
        fail("relaunch diagnostic counters, scroll, or outline state is wrong")
    return {"activeTab": second, "fixtureTab": fixture_tab, "secondDraft": second}


def verify_relaunch_scroll_check(
    session: dict[str, object],
    diagnostic: dict[str, object],
    previous_session: dict[str, object],
    fixture: str,
    session_path: pathlib.Path,
) -> dict[str, object]:
    previous_tabs = require_tabs(previous_session)
    previous_fixture = require_named_tab(previous_tabs, FIXTURE_NAME)
    previous_second = require_named_tab(previous_tabs, SECOND_DRAFT_NAME)
    tabs = require_tabs(session)
    if [tab.get("name") for tab in tabs] != [FIXTURE_NAME, SECOND_DRAFT_NAME]:
        fail("post-relaunch tab order changed")
    fixture_tab = require_named_tab(tabs, FIXTURE_NAME)
    second = require_named_tab(tabs, SECOND_DRAFT_NAME)
    if fixture_tab.get("id") != previous_fixture.get("id") \
            or second.get("id") != previous_second.get("id") \
            or require_active_tab(session, tabs).get("id") != fixture_tab.get("id"):
        fail("post-relaunch workspace activation changed a tab ID or active identity")
    assert_seeded_fixture(fixture_tab, fixture)
    assert_draft(
        second,
        SECOND_DRAFT_SOURCE,
        0,
        minimum_scroll=100,
    )
    expected_session = copy.deepcopy(previous_session)
    expected_session["activeTabID"] = fixture_tab["id"]
    expected_session["sidebarOpen"] = True
    directory_path = expected_session.get("directoryPath")
    if not isinstance(directory_path, str) or not directory_path:
        fail("post-relaunch session has no workspace directory")
    expected_session["expandedFolderPaths"] = [
        str(pathlib.Path(directory_path) / "docs")
    ]
    if session != expected_session:
        fail("post-relaunch workspace activation changed unrelated session state")
    session_scroll = finite_number(fixture_tab.get("scrollY"))
    if session_scroll <= 1_500:
        fail("post-relaunch fixture did not retain its inactive-tab scroll")
    assert_diagnostic_base(
        diagnostic,
        session_path,
        FIXTURE_NAME,
        True,
        False,
        True,
    )
    outline = diagnostic.get("outline")
    sidebar_anchor = require_visual_anchor(diagnostic, "sidebar-frame")
    if diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("parseCount") != 1 \
            or diagnostic.get("localMutationCount") != 0 \
            or not close_number(diagnostic.get("scrollY"), session_scroll) \
            or not isinstance(outline, dict) \
            or outline.get("headingCount") != 15 \
            or not isinstance(outline.get("activeIndex"), int) \
            or not 0 <= outline["activeIndex"] < 15 \
            or not close_number(sidebar_anchor.get("width"), 312, tolerance=1):
        fail("post-relaunch fixture scroll or outline state is wrong")
    return {"activeTab": fixture_tab, "fixtureTab": fixture_tab, "secondDraft": second}


def main() -> None:
    arguments = parse_args()
    session_artifact_path = pathlib.Path(arguments.session)
    session_path = pathlib.Path(
        arguments.expected_session_path or arguments.session
    )
    diagnostic_path = pathlib.Path(arguments.diagnostic)
    fixture_path = pathlib.Path(arguments.fixture)
    workspace_path = pathlib.Path(arguments.workspace_fixture)
    output_root = pathlib.Path(arguments.output_root)
    session = load_json(arguments.session, "session")
    diagnostic = load_json(arguments.diagnostic, "diagnostic")
    fixture = fixture_path.read_text(encoding="utf-8")

    if arguments.stage == "switch-commit":
        observed = verify_switch_commit(
            session,
            diagnostic,
            fixture,
            session_path,
        )
    elif arguments.stage == "close-right-reopen":
        observed = verify_close_right_reopen(
            session,
            diagnostic,
            require_previous(arguments.previous_session, "previous session"),
            fixture,
            session_path,
        )
    elif arguments.stage == "close-left-seed":
        observed = verify_close_left_seed(
            session,
            diagnostic,
            require_previous(arguments.previous_session, "previous session"),
            fixture,
            session_path,
        )
    elif arguments.stage == "relaunch":
        observed = verify_relaunch(
            session,
            diagnostic,
            require_previous(arguments.previous_session, "previous session"),
            require_previous(arguments.previous_diagnostic, "previous diagnostic"),
            fixture,
            session_path,
        )
    else:
        observed = verify_relaunch_scroll_check(
            session,
            diagnostic,
            require_previous(arguments.previous_session, "previous session"),
            fixture,
            session_path,
        )

    fixture_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
    workspace_hash = hashlib.sha256(workspace_path.read_bytes()).hexdigest()
    if fixture_hash != arguments.fixture_sha or workspace_hash != arguments.fixture_sha:
        fail("bundle or workspace fixture bytes changed")
    if arguments.check_only:
        return

    if arguments.report_kind == "session":
        payload = {
            "label": f"tab-session-{arguments.stage}-session",
            "assertions": {
                "tabOrderAndIdentityExact": True,
                "structuredSourceRoundTripsExactly": True,
                "fixtureWorkspaceUnchanged": True,
                "dirtyAndSelectionStateExact": True,
            },
            "activeDocument": observed["activeTab"]["name"],
            "sessionArtifact": os.path.relpath(session_artifact_path, output_root),
            "sessionPath": os.path.relpath(session_path, output_root),
            "fixtureSHA256": fixture_hash,
            "workspaceFixtureSHA256": workspace_hash,
        }
    else:
        payload = {
            "label": f"tab-session-{arguments.stage}-diagnostic",
            "assertions": {
                "isolatedSessionPathExact": True,
                "overlayAndEditorStateExact": True,
                "mutationCountersExact": True,
                "scrollAndOutlineStateExact": True,
            },
            "snapshot": diagnostic,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
