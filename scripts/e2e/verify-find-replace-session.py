#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib


EXPECTED_SOURCES = {
    "initial": "red red RED redwood red",
    "replace-current": "blue red RED redwood red",
    "replace-all": "blue blue blue redwood blue",
}


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
    parser.add_argument("--state", choices=tuple(EXPECTED_SOURCES), required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--evidence-root", required=True)
    args = parser.parse_args()

    session_path = pathlib.Path(args.session)
    session = json.loads(session_path.read_text(encoding="utf-8"))
    tab = active_tab(session)
    expected = EXPECTED_SOURCES[args.state]

    if tab.get("name") != "未命名.md":
        raise ValueError("active document is not the disposable find scenario")
    if tab.get("url") is not None:
        raise ValueError("find scenario unexpectedly targets a filesystem document")
    if tab.get("isMarkdown") is not True:
        raise ValueError("find scenario document is not Markdown")
    if tab.get("isDirty") is not True:
        raise ValueError("find scenario document is not dirty")
    if tab.get("text") != expected:
        raise ValueError("find scenario source does not match the exact expected state")
    reconstructed = reconstructed_source(tab)
    if reconstructed != expected:
        raise ValueError("structured Markdown does not reconstruct the expected source")

    source_bytes = expected.encode("utf-8")
    print(json.dumps({
        "label": args.label,
        "state": args.state,
        "activeDocument": tab["name"],
        "dirty": True,
        "persisted": True,
        "blockCount": len(tab["markdownDocument"]["blocks"]),
        "source": expected,
        "sourceByteCount": len(source_bytes),
        "sourceSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "structuredSourceMatchesText": True,
        "sessionPath": os.path.relpath(session_path, args.evidence_root),
    }, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
