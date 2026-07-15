#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib


TABLE_HEADER = "| 快捷键 | 功能 | 平台 |"
TABLE_HEADER_MUTATED = "| E2E_TABLE | 功能 | 平台 |"
SOURCE_HEADING = "# Markdown 全格式示例"


def expected_source(fixture: str, state: str) -> str:
    source = fixture
    if state in {"table", "table-source"}:
        if source.count(TABLE_HEADER) != 1:
            raise ValueError("fixture must contain exactly one target table header")
        source = source.replace(TABLE_HEADER, TABLE_HEADER_MUTATED, 1)
    if state == "table-source":
        if not source.startswith(SOURCE_HEADING + "\n"):
            raise ValueError("fixture must start with the target source heading")
        source = source.replace(SOURCE_HEADING, SOURCE_HEADING + " E2E_SOURCE", 1)
    return source


def active_tab(session: dict) -> dict:
    active_id = session.get("activeTabID")
    for tab in session.get("tabs", []):
        if tab.get("id") == active_id:
            return tab
    raise ValueError("session has no active tab")


def reconstructed_source(tab: dict) -> str:
    document = tab.get("markdownDocument")
    if not isinstance(document, dict):
        raise ValueError("active tab has no structured Markdown document")
    blocks = document.get("blocks")
    if not isinstance(blocks, list):
        raise ValueError("structured Markdown document has no block list")
    return "".join(
        block["leadingTrivia"] + block["source"]
        for block in blocks
    ) + document["trailingTrivia"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--state", choices=("clean", "table", "table-source"), required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--evidence-root", required=True)
    args = parser.parse_args()

    session_path = pathlib.Path(args.session)
    fixture_path = pathlib.Path(args.fixture)
    fixture_bytes = fixture_path.read_bytes()
    fixture = fixture_bytes.decode("utf-8")
    expected = expected_source(fixture, args.state)
    session = json.loads(session_path.read_text(encoding="utf-8"))
    tab = active_tab(session)

    if tab.get("name") != "格式示例.md":
        raise ValueError("active document is not the authoritative Debug fixture")
    if tab.get("isMarkdown") is not True:
        raise ValueError("active fixture tab is not Markdown")
    if tab.get("isDirty") != (args.state != "clean"):
        raise ValueError("active fixture dirty state does not match the expected state")
    if tab.get("text") != expected:
        raise ValueError("active fixture source does not match the exact expected mutation")
    reconstructed = reconstructed_source(tab)
    if reconstructed != tab["text"]:
        raise ValueError("structured Markdown does not reconstruct the persisted source")

    source_bytes = tab["text"].encode("utf-8")
    document = tab["markdownDocument"]
    print(json.dumps({
        "label": args.label,
        "state": args.state,
        "activeDocument": tab["name"],
        "dirty": tab["isDirty"],
        "persisted": True,
        "blockCount": len(document["blocks"]),
        "sourceByteCount": len(source_bytes),
        "sourceSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "fixtureSHA256": hashlib.sha256(fixture_bytes).hexdigest(),
        "structuredSourceMatchesText": True,
        "sessionPath": os.path.relpath(session_path, args.evidence_root),
    }, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
