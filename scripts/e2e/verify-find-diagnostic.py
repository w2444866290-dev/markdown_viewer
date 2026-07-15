#!/usr/bin/env python3

import argparse
import json
import pathlib


TOP_LEVEL_KEYS = {
    "schemaVersion", "document", "blockID", "blockType", "mode", "selection",
    "activeTableCell", "dirty", "find", "outline", "scrollY", "sessionPath",
    "parseCount", "localMutationCount", "renderedBlockUpdateCount",
    "activeBlockRenderUpdateCount", "renderedBlockUpdates", "visual", "updatedAt",
}

FIND_KEYS = {
    "query", "display", "matchCount", "currentIndex", "invalidRegex",
    "replaceExpanded", "caseSensitive", "wholeWord", "regex",
}


def boolean(value: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--profile-root", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--document", default="未命名.md")
    parser.add_argument("--query", required=True)
    parser.add_argument("--display", required=True)
    parser.add_argument("--match-count", type=int, required=True)
    parser.add_argument("--current-index", type=int, required=True)
    parser.add_argument("--replace-expanded", type=boolean, required=True)
    parser.add_argument("--case-sensitive", type=boolean, default=False)
    parser.add_argument("--whole-word", type=boolean, required=True)
    parser.add_argument("--regex", type=boolean, default=False)
    parser.add_argument("--invalid-regex", type=boolean, default=False)
    args = parser.parse_args()

    snapshot_path = pathlib.Path(args.snapshot)
    state = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if set(state) != TOP_LEVEL_KEYS:
        raise ValueError("diagnostic top-level schema does not match exactly")
    if state["schemaVersion"] != 1:
        raise ValueError("diagnostic schemaVersion is not 1")
    if state["document"] != args.document:
        raise ValueError("diagnostic document does not match")
    if state["mode"] != "edit":
        raise ValueError("find scenario is not in edit mode")
    if state["dirty"] is not True:
        raise ValueError("find scenario diagnostic is not dirty")
    if state["activeTableCell"] is not None:
        raise ValueError("find scenario unexpectedly has an active table cell")
    if state["outline"] != {"headingCount": 0, "activeIndex": 0}:
        raise ValueError("find scenario outline is not empty")
    expected_session = (
        pathlib.Path(args.profile_root)
        / "Application Support"
        / "MarkdownViewer"
        / "session.json"
    )
    if pathlib.Path(state["sessionPath"]) != expected_session:
        raise ValueError("diagnostic session path is not isolated to the profile")

    find = state["find"]
    if not isinstance(find, dict) or set(find) != FIND_KEYS:
        raise ValueError("diagnostic find schema does not match exactly")
    expected_find = {
        "query": args.query,
        "display": args.display,
        "matchCount": args.match_count,
        "currentIndex": args.current_index,
        "invalidRegex": args.invalid_regex,
        "replaceExpanded": args.replace_expanded,
        "caseSensitive": args.case_sensitive,
        "wholeWord": args.whole_word,
        "regex": args.regex,
    }
    if find != expected_find:
        raise ValueError("diagnostic find state does not match the exact expectation")

    render_updates = state["renderedBlockUpdates"]
    if not isinstance(render_updates, dict) or not render_updates:
        raise ValueError("diagnostic has no renderer update evidence")
    if any(not isinstance(value, int) or value <= 0 for value in render_updates.values()):
        raise ValueError("diagnostic renderer update map contains an invalid count")
    if state["renderedBlockUpdateCount"] != sum(render_updates.values()):
        raise ValueError("diagnostic renderer total does not match its update map")
    if not isinstance(state["activeBlockRenderUpdateCount"], int):
        raise ValueError("diagnostic active renderer count is not an integer")
    if not isinstance(state["parseCount"], int) or state["parseCount"] < 0:
        raise ValueError("diagnostic parse count is invalid")
    if not isinstance(state["localMutationCount"], int) or state["localMutationCount"] < 0:
        raise ValueError("diagnostic local mutation count is invalid")
    if not isinstance(state["scrollY"], (int, float)) or state["scrollY"] < 0:
        raise ValueError("diagnostic scroll offset is invalid")
    if not isinstance(state["updatedAt"], str) or not state["updatedAt"]:
        raise ValueError("diagnostic update timestamp is missing")

    print(json.dumps({
        "label": args.label,
        "snapshot": state,
    }, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
