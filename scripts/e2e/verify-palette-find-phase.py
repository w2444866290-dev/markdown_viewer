#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import tempfile


MARKER = "E2E_PALETTE_COMMIT"
PHASES = {
    "block-find": {
        "fontIndex": 0,
        "find": {
            "query": "一级标题",
            "display": "1/1",
            "matchCount": 1,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": True,
            "caseSensitive": False,
            "wholeWord": True,
            "regex": False,
        },
        "visual": {
            "paletteVisible": False,
            "findPanelVisible": True,
            "replaceRowVisible": True,
        },
    },
    "palette-keyboard": {
        "fontIndex": 1,
        "find": {
            "query": "",
            "display": "",
            "matchCount": 0,
            "currentIndex": 0,
            "invalidRegex": False,
            "replaceExpanded": False,
            "caseSensitive": False,
            "wholeWord": True,
            "regex": False,
        },
        "visual": {
            "paletteVisible": False,
            "findPanelVisible": False,
            "replaceRowVisible": False,
        },
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify one persisted palette and Find foreground phase."
    )
    parser.add_argument("--phase", choices=tuple(PHASES), required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--expected-session-path")
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--output")
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"palette-find phase verification failed: {message}")


def load_object(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not readable JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def structured_source(tab: dict[str, object]) -> str:
    markdown = tab.get("markdownDocument")
    if not isinstance(markdown, dict):
        fail("active fixture tab has no structured Markdown document")
    blocks = markdown.get("blocks")
    if not isinstance(blocks, list) \
            or not blocks \
            or any(not isinstance(block, dict) for block in blocks):
        fail("active fixture tab has invalid structured Markdown blocks")
    block_ids = [block.get("id") for block in blocks]
    if any(not isinstance(block_id, str) or not block_id for block_id in block_ids) \
            or len(block_ids) != len(set(block_ids)):
        fail("active fixture tab block IDs are not stable and unique")
    return "".join(
        str(block.get("leadingTrivia", "")) + str(block.get("source", ""))
        for block in blocks
    ) + str(markdown.get("trailingTrivia", ""))


def write_atomic_json(payload: dict[str, object], output: pathlib.Path) -> None:
    output = output.expanduser().resolve()
    if not output.parent.is_dir() or not os.access(output.parent, os.W_OK):
        fail(f"output parent must be a writable directory: {output.parent}")
    descriptor, temporary_name = tempfile.mkstemp(
        dir=output.parent,
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
    expected = PHASES[arguments.phase]
    session_path = pathlib.Path(arguments.session).expanduser().resolve()
    expected_session_path = pathlib.Path(
        arguments.expected_session_path or arguments.session
    ).expanduser().resolve()
    diagnostic_path = pathlib.Path(arguments.diagnostic).expanduser().resolve()
    fixture_path = pathlib.Path(arguments.fixture).expanduser().resolve()
    session = load_object(session_path, "session")
    diagnostic = load_object(diagnostic_path, "diagnostic")

    try:
        fixture_bytes = fixture_path.read_bytes()
    except OSError as error:
        fail(f"fixture is not readable: {error}")
    fixture_hash = hashlib.sha256(fixture_bytes).hexdigest()
    if fixture_hash != arguments.fixture_sha:
        fail("read-only fixture hash changed")
    if MARKER.encode("utf-8") in fixture_bytes:
        fail("read-only fixture contains the foreground marker")

    tabs = session.get("tabs")
    if session.get("schemaVersion") != 2 \
            or not isinstance(tabs, list) \
            or len(tabs) != 1 \
            or any(not isinstance(tab, dict) for tab in tabs):
        fail("session must contain exactly one schema-v2 fixture tab")
    active = next(
        (tab for tab in tabs if tab.get("id") == session.get("activeTabID")),
        None,
    )
    if active is None \
            or active.get("name") != "格式示例.md" \
            or active.get("isMarkdown") is not True \
            or active.get("isDirty") is not True:
        fail("active fixture tab identity or dirty state is wrong")
    source = active.get("text")
    if not isinstance(source, str) or source.count(MARKER) != 1:
        fail("active fixture source does not contain exactly one marker")
    rebuilt = structured_source(active)
    if rebuilt != source or rebuilt.count(MARKER) != 1:
        fail("structured Markdown source does not round trip the marker exactly")
    if session.get("fontIndex") != expected["fontIndex"]:
        fail(f"{arguments.phase} font state is wrong")

    if diagnostic.get("schemaVersion") != 1 \
            or diagnostic.get("document") != "格式示例.md" \
            or diagnostic.get("mode") != "edit" \
            or diagnostic.get("dirty") is not True \
            or diagnostic.get("blockID") is not None \
            or diagnostic.get("blockType") is not None \
            or diagnostic.get("selection") is not None \
            or diagnostic.get("activeTableCell") is not None:
        fail("editor diagnostic did not reach the committed fixture state")
    if pathlib.Path(str(diagnostic.get("sessionPath", ""))).resolve() \
            != expected_session_path:
        fail("diagnostic session path does not match the live isolated session")
    if diagnostic.get("parseCount") != 2 \
            or diagnostic.get("localMutationCount") != 1:
        fail("diagnostic mutation counts do not prove one local block commit")
    if diagnostic.get("find") != expected["find"]:
        fail(f"{arguments.phase} Find diagnostic is wrong")
    visual = diagnostic.get("visual")
    if not isinstance(visual, dict) \
            or visual.get("documentVisible") is not True \
            or visual.get("sidebarVisible") is not True \
            or visual.get("previewActive") is not False \
            or visual.get("sourceEditorVisible") is not False \
            or visual.get("tableGridVisible") is not False \
            or any(
                visual.get(key) is not value
                for key, value in expected["visual"].items()
            ):
        fail(f"{arguments.phase} visual diagnostic is wrong")

    assertions = {
        "activeEditCommittedExactlyOnce": True,
        "structuredSourceRoundTrips": True,
        "readOnlyFixtureUnchanged": True,
        "fontStateReached": True,
        "editorClosed": True,
        "findStateReached": True,
        "visualStateReached": True,
        "diagnosticCountsReached": True,
        "sessionIdentityMatched": True,
    }
    payload = {
        "schemaVersion": 1,
        "suite": "palette-find",
        "phase": arguments.phase,
        "assertions": assertions,
        "session": {
            "path": str(session_path),
            "expectedLivePath": str(expected_session_path),
            "schemaVersion": session["schemaVersion"],
            "activeTabID": session["activeTabID"],
            "activeDocument": active["name"],
            "tabCount": len(tabs),
            "dirty": active["isDirty"],
            "fontIndex": session["fontIndex"],
            "markerCount": source.count(MARKER),
            "structuredMarkerCount": rebuilt.count(MARKER),
        },
        "diagnostic": {
            "path": str(diagnostic_path),
            "schemaVersion": diagnostic["schemaVersion"],
            "sessionPath": diagnostic["sessionPath"],
            "document": diagnostic["document"],
            "dirty": diagnostic["dirty"],
            "parseCount": diagnostic["parseCount"],
            "localMutationCount": diagnostic["localMutationCount"],
            "find": diagnostic["find"],
            "visual": {
                key: visual[key]
                for key in (
                    "documentVisible",
                    "sidebarVisible",
                    "paletteVisible",
                    "findPanelVisible",
                    "replaceRowVisible",
                    "previewActive",
                    "sourceEditorVisible",
                    "tableGridVisible",
                )
            },
        },
        "fixtureSHA256": fixture_hash,
        "marker": MARKER,
    }
    if arguments.check_only:
        return
    if not arguments.output:
        fail("--output is required unless --check-only is used")
    write_atomic_json(payload, pathlib.Path(arguments.output))


if __name__ == "__main__":
    main()
