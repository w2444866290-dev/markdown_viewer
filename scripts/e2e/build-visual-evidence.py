#!/usr/bin/env python3
"""Bind settled Debug visual probes to an exact real-app screenshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import time
from typing import Any


ASSERTION_READERS = {
    "document-visible": lambda visual: visual.get("documentVisible") is True,
    "sidebar-visible": lambda visual: visual.get("sidebarVisible") is True,
    "sidebar-hidden": lambda visual: visual.get("sidebarVisible") is False,
    "palette-visible": lambda visual: visual.get("paletteVisible") is True,
    "palette-hidden": lambda visual: visual.get("paletteVisible") is False,
    "find-panel-visible": lambda visual: visual.get("findPanelVisible") is True,
    "find-panel-hidden": lambda visual: visual.get("findPanelVisible") is False,
    "replace-row-visible": lambda visual: visual.get("replaceRowVisible") is True,
    "preview-active": lambda visual: visual.get("previewActive") is True,
    "source-editor-visible": lambda visual: visual.get("sourceEditorVisible") is True,
    "source-editor-hidden": lambda visual: visual.get("sourceEditorVisible") is False,
    "table-grid-visible": lambda visual: visual.get("tableGridVisible") is True,
    "table-grid-hidden": lambda visual: visual.get("tableGridVisible") is False,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    wait_parser = subparsers.add_parser("wait")
    wait_parser.add_argument("--diagnostic", required=True, type=pathlib.Path)
    wait_parser.add_argument("--contract", required=True, type=pathlib.Path)
    wait_parser.add_argument("--app-label", required=True)
    wait_parser.add_argument("--output", required=True, type=pathlib.Path)
    wait_parser.add_argument("--timeout", type=float, default=2.0)
    wait_parser.add_argument("--stable-samples", type=int, default=3)

    bind_parser = subparsers.add_parser("bind")
    bind_parser.add_argument("--probe", required=True, type=pathlib.Path)
    bind_parser.add_argument("--metadata", required=True, type=pathlib.Path)
    bind_parser.add_argument("--evidence-root", required=True, type=pathlib.Path)
    bind_parser.add_argument("--output", required=True, type=pathlib.Path)
    return parser.parse_args()


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def state_contract(contract: dict[str, Any], app_label: str) -> tuple[str, dict[str, Any]]:
    matches = [
        (name, state)
        for name, state in contract.get("states", {}).items()
        if state.get("appLabel") == app_label
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"build-visual-evidence.py: app label {app_label!r} has {len(matches)} contract mappings"
        )
    return matches[0]


def finite_rect(raw: Any) -> dict[str, float] | None:
    if not isinstance(raw, dict):
        return None
    values: dict[str, float] = {}
    for component in ("x", "y", "width", "height"):
        value = raw.get(component)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        number = float(value)
        if not math.isfinite(number):
            return None
        values[component] = number
    if values["width"] <= 0 or values["height"] <= 0:
        return None
    return values


def evaluated_probe(
    snapshot: Any,
    app_label: str,
    state: dict[str, Any],
) -> tuple[dict[str, Any] | None, list[str]]:
    failures: list[str] = []
    if not isinstance(snapshot, dict):
        return None, ["diagnostic snapshot is not an object"]
    visual = snapshot.get("visual")
    if not isinstance(visual, dict):
        return None, ["diagnostic snapshot has no visual probe"]

    assertions = []
    for name in state.get("requiredStateAssertions", []):
        reader = ASSERTION_READERS.get(name)
        passed = reader(visual) if reader else False
        assertions.append({"name": name, "evaluated": reader is not None, "passed": passed})
        if reader is None:
            failures.append(f"unsupported state assertion {name!r}")
        elif not passed:
            failures.append(f"state assertion {name!r} did not pass")

    raw_anchors = visual.get("anchors")
    if not isinstance(raw_anchors, dict):
        raw_anchors = {}
    anchors = []
    for name in state.get("requiredGeometryAnchors", []):
        rect = finite_rect(raw_anchors.get(name))
        if rect is None:
            failures.append(f"geometry anchor {name!r} is missing or malformed")
            continue
        anchors.append(
            {
                "name": name,
                "evaluated": True,
                "source": "combined-machine-probes",
                "rect": rect,
            }
        )

    probe = {
        "appLabel": app_label,
        "diagnosticUpdatedAt": snapshot.get("updatedAt"),
        "stateEvaluation": {
            "evaluated": not failures,
            "status": "passed" if not failures else "failed",
            "expectedState": app_label,
            "observedState": app_label if not failures else None,
            "source": "debug-diagnostics",
            "assertions": assertions,
        },
        "geometryEvaluation": {
            "evaluated": not failures,
            "status": "passed" if not failures else "failed",
            "coordinateSpace": "viewportPixels",
            "anchors": anchors,
        },
    }
    return probe, failures


def wait_for_probe(options: argparse.Namespace) -> None:
    if options.timeout <= 0 or options.timeout > 10:
        raise SystemExit("build-visual-evidence.py: --timeout must be greater than 0 and at most 10")
    if options.stable_samples < 2 or options.stable_samples > 10:
        raise SystemExit("build-visual-evidence.py: --stable-samples must be from 2 through 10")
    contract = load_json(options.contract)
    if contract.get("schemaVersion") != 2:
        raise SystemExit("build-visual-evidence.py: acceptance contract is not schema version 2")
    reference_state, state = state_contract(contract, options.app_label)
    deadline = time.monotonic() + options.timeout
    prior_material = None
    stable_count = 0
    last_failures = ["diagnostic snapshot is not available"]
    settled_probe = None
    snapshot_hash = None

    while time.monotonic() < deadline:
        try:
            payload = options.diagnostic.read_bytes()
            snapshot = json.loads(payload)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            time.sleep(0.05)
            continue
        probe, failures = evaluated_probe(snapshot, options.app_label, state)
        last_failures = failures
        if failures or probe is None:
            stable_count = 0
            prior_material = None
            time.sleep(0.05)
            continue
        material = json.dumps(
            {
                "stateEvaluation": probe["stateEvaluation"],
                "geometryEvaluation": probe["geometryEvaluation"],
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        stable_count = stable_count + 1 if material == prior_material else 1
        prior_material = material
        settled_probe = probe
        snapshot_hash = hashlib.sha256(payload).hexdigest()
        if stable_count >= options.stable_samples:
            break
        time.sleep(0.05)

    if settled_probe is None or stable_count < options.stable_samples:
        detail = "; ".join(last_failures)
        raise SystemExit(
            f"build-visual-evidence.py: visual probe for {options.app_label} did not settle: {detail}"
        )

    settled_probe.update(
        {
            "schemaVersion": 1,
            "kind": "settled-debug-visual-probe",
            "referenceState": reference_state,
            "diagnosticPath": str(options.diagnostic),
            "diagnosticSHA256": snapshot_hash,
            "stableSampleCount": stable_count,
        }
    )
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(settled_probe, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def bind_probe(options: argparse.Namespace) -> None:
    probe = load_json(options.probe)
    metadata = load_json(options.metadata)
    if probe.get("kind") != "settled-debug-visual-probe":
        raise SystemExit("build-visual-evidence.py: visual probe kind is invalid")
    if metadata.get("label") != probe.get("appLabel"):
        raise SystemExit("build-visual-evidence.py: probe and screenshot labels differ")
    screenshot_hash = metadata.get("sha256")
    screenshot_path = metadata.get("path")
    if not isinstance(screenshot_hash, str) or len(screenshot_hash) != 64:
        raise SystemExit("build-visual-evidence.py: screenshot metadata hash is invalid")
    if not isinstance(screenshot_path, str) or not screenshot_path:
        raise SystemExit("build-visual-evidence.py: screenshot metadata path is invalid")
    evidence_root = options.evidence_root.resolve()
    screenshot_file = (evidence_root / screenshot_path).resolve()
    try:
        screenshot_file.relative_to(evidence_root)
    except ValueError:
        raise SystemExit("build-visual-evidence.py: screenshot path escapes the evidence root")
    if not screenshot_file.is_file():
        raise SystemExit("build-visual-evidence.py: screenshot file is missing")
    if sha256(screenshot_file) != screenshot_hash:
        raise SystemExit("build-visual-evidence.py: screenshot metadata hash is stale")

    metadata["visualProbe"] = {
        "kind": probe["kind"],
        "diagnosticSHA256": probe["diagnosticSHA256"],
        "diagnosticUpdatedAt": probe.get("diagnosticUpdatedAt"),
        "stableSampleCount": probe["stableSampleCount"],
    }
    metadata["visualEvidence"] = {
        "schemaVersion": 2,
        "kind": "machine-captured-visual-evidence",
        "screenshotSHA256": screenshot_hash,
        "stateEvaluation": probe["stateEvaluation"],
        "geometryEvaluation": probe["geometryEvaluation"],
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    options = arguments()
    if options.command == "wait":
        wait_for_probe(options)
    else:
        bind_probe(options)


if __name__ == "__main__":
    main()
