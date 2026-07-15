#!/usr/bin/env python3
"""Verify capture runtime pins against the constants shipped by support.js."""

from __future__ import annotations

import argparse
import pathlib
import re


PIN_NAMES = (
    "REACT_URL",
    "REACT_SRI",
    "REACT_DOM_URL",
    "REACT_DOM_SRI",
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--support-js", required=True, type=pathlib.Path)
    for name in PIN_NAMES:
        parser.add_argument(f"--{name.lower().replace('_', '-')}", required=True)
    return parser.parse_args()


def constants(source: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for name in PIN_NAMES:
        matches = re.findall(
            rf"\bvar\s+{re.escape(name)}\s*=\s*([\"'])(.*?)\1\s*;",
            source,
        )
        if len(matches) != 1:
            raise SystemExit(
                f"verify-support-runtime.py: expected exactly one {name} constant, "
                f"found {len(matches)}"
            )
        values[name] = matches[0][1]
    return values


def main() -> None:
    arguments = parse_arguments()
    source = arguments.support_js.read_text(encoding="utf-8")
    actual = constants(source)
    expected = {
        "REACT_URL": arguments.react_url,
        "REACT_SRI": arguments.react_sri,
        "REACT_DOM_URL": arguments.react_dom_url,
        "REACT_DOM_SRI": arguments.react_dom_sri,
    }
    mismatches = [
        f"{name}: capture={expected[name]!r}, support.js={actual[name]!r}"
        for name in PIN_NAMES
        if actual[name] != expected[name]
    ]
    if mismatches:
        raise SystemExit(
            "verify-support-runtime.py: capture runtime pins do not match support.js\n"
            + "\n".join(mismatches)
        )


if __name__ == "__main__":
    main()
