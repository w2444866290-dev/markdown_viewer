#!/usr/bin/env python3
"""Evaluate state, geometry, and full-frame pixels for authoritative-to-app pairs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import sys
from typing import Any

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit(
        "evaluate-acceptance.py requires Pillow. Install it with: python3 -m pip install Pillow"
    ) from exc

from pixel_acceptance import ALGORITHM, ANALYSIS_PARAMETERS, analyze_images


EXPECTED_CONTRACT_KIND = "markdown-viewer-visual-acceptance-contract"
EXPECTED_EVIDENCE_KIND = "machine-captured-visual-evidence"
EXPECTED_METRICS_KIND = "unmasked-full-frame-visual-measurement"
OUTPUT_KIND = "authoritative-reference-to-real-app-visual-acceptance"
PAIR_KIND = "authoritative-reference-to-real-app-visual-comparison"
AUTHORITATIVE_HTML_SHA256 = "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
ACCEPTANCE_CONTRACT_SHA256 = "1b28f6d306b97f18afbffda694bb659955a69298a9557b5a24e3d2d0a8d010dc"

EXPECTED_PIXEL_LIMITS = {
    "maximumChangedPixelRatio": 0.015,
    "maximumStructuralPixelRatio": 0.0001,
    "maximumHighMagnitudePixelRatio": 0.0001,
    "maximumMeanAbsoluteChannelDifference": 1.0,
    "maximumRootMeanSquareChannelDifference": 6.0,
    "maximumChangedComponentPixels": 64,
    "maximumChangedComponentWidthPixels": 24,
    "maximumChangedComponentHeightPixels": 32,
    "maximumChangedHorizontalRunPixels": 24,
    "maximumChangedVerticalRunPixels": 32,
    "maximumChangedTilePixelRatio": 0.35,
    "maximumStructuralComponentPixels": 8,
    "maximumStructuralComponentWidthPixels": 8,
    "maximumStructuralComponentHeightPixels": 8,
    "maximumStructuralHorizontalRunPixels": 8,
    "maximumStructuralVerticalRunPixels": 8,
    "maximumStructuralTilePixelRatio": 0.03125,
}

EXPECTED_ANTIALIAS_POLICY = {
    "classification": (
        "changed pixels near luminance edges in both images and at or below "
        "the high-magnitude threshold"
    ),
    "pixelsRemainInChangedAggregate": True,
    "pixelsRemainInSpatialChecks": True,
    "masking": "none",
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate a complete visual comparison matrix with screenshot-bound state, "
            "geometry, and strict pixel evidence."
        )
    )
    parser.add_argument("--reference-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--app-evidence", required=True, type=pathlib.Path)
    parser.add_argument("--contract", required=True, type=pathlib.Path)
    parser.add_argument("--metrics-list", required=True, type=pathlib.Path)
    parser.add_argument("--sizes", required=True)
    parser.add_argument("--states", required=True)
    parser.add_argument("--mapping", required=True)
    parser.add_argument("--threshold", required=True, type=int)
    return parser.parse_args()


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_file(root: pathlib.Path, raw: Any) -> pathlib.Path | None:
    if not isinstance(raw, str) or not raw:
        return None
    candidate = (root / raw).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        return None
    return candidate if candidate.is_file() else None


def is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def is_positive_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def is_exact_string_coverage(value: Any, expected: set[str]) -> bool:
    return (
        isinstance(value, list)
        and all(isinstance(item, str) and item for item in value)
        and len(value) == len(set(value))
        and set(value) == expected
    )


def passive_process_windows_are_safe(
    value: Any,
    expected_pid: Any,
    selected_window_number: Any,
) -> bool:
    if (
        not isinstance(value, list)
        or not value
        or not is_positive_integer(expected_pid)
        or not is_positive_integer(selected_window_number)
    ):
        return False
    window_numbers: list[int] = []
    selected_matches = 0
    for window in value:
        if (
            not isinstance(window, dict)
            or window.get("pid") != expected_pid
            or window.get("onScreen") is not False
            or not is_positive_integer(window.get("windowNumber"))
        ):
            return False
        window_number = window["windowNumber"]
        window_numbers.append(window_number)
        if window_number == selected_window_number:
            selected_matches += 1
    return len(window_numbers) == len(set(window_numbers)) and selected_matches == 1


def validate_contract(contract: Any, states: list[str], mapping: dict[str, str]) -> None:
    if not isinstance(contract, dict):
        raise SystemExit("evaluate-acceptance.py: acceptance contract must be an object")
    if contract.get("schemaVersion") != 2 or contract.get("kind") != EXPECTED_CONTRACT_KIND:
        raise SystemExit("evaluate-acceptance.py: invalid schema-v2 acceptance contract")
    if contract.get("coordinateSpace") != "viewportPixels":
        raise SystemExit("evaluate-acceptance.py: contract coordinate space must be viewportPixels")
    if contract.get("authoritativeHTMLSHA256") != AUTHORITATIVE_HTML_SHA256:
        raise SystemExit("evaluate-acceptance.py: contract authoritative HTML hash changed")
    policy = contract.get("tolerancePolicy")
    if policy != {"1180x760": 1, "otherSizes": 2}:
        raise SystemExit("evaluate-acceptance.py: contract must preserve the fixed 1 px and 2 px tolerances")
    masking = contract.get("maskingPolicy")
    if masking != {
        "mode": "none",
        "ordinaryUIRegionsMasked": False,
        "antialiasMaskRadiusPixels": 0,
    }:
        raise SystemExit("evaluate-acceptance.py: contract masking policy must remain unmasked")
    pixel_policy = contract.get("pixelAcceptancePolicy")
    expected_analysis = {
        "algorithm": ALGORITHM,
        "changedPixelThreshold": 8,
        **ANALYSIS_PARAMETERS,
    }
    if not isinstance(pixel_policy, dict):
        raise SystemExit("evaluate-acceptance.py: contract pixel acceptance policy is missing")
    if pixel_policy.get("analysis") != expected_analysis:
        raise SystemExit("evaluate-acceptance.py: contract pixel analysis parameters changed")
    if pixel_policy.get("limits") != EXPECTED_PIXEL_LIMITS:
        raise SystemExit("evaluate-acceptance.py: contract pixel acceptance limits changed")
    if pixel_policy.get("antiAliasPolicy") != EXPECTED_ANTIALIAS_POLICY:
        raise SystemExit("evaluate-acceptance.py: contract antialias policy changed")
    state_contracts = contract.get("states")
    if not isinstance(state_contracts, dict):
        raise SystemExit("evaluate-acceptance.py: contract states must be an object")
    for state in states:
        state_contract = state_contracts.get(state)
        if not isinstance(state_contract, dict):
            raise SystemExit(f"evaluate-acceptance.py: contract has no state '{state}'")
        if state_contract.get("appLabel") != mapping.get(state):
            raise SystemExit(
                f"evaluate-acceptance.py: contract mapping differs for state '{state}'"
            )
        assertions = state_contract.get("requiredStateAssertions")
        anchors = state_contract.get("requiredGeometryAnchors")
        if (
            not isinstance(assertions, list)
            or not assertions
            or not all(isinstance(value, str) and value for value in assertions)
            or len(assertions) != len(set(assertions))
        ):
            raise SystemExit(
                f"evaluate-acceptance.py: state '{state}' has invalid required assertions"
            )
        if (
            not isinstance(anchors, list)
            or not anchors
            or not all(isinstance(value, str) and value for value in anchors)
            or len(anchors) != len(set(anchors))
        ):
            raise SystemExit(
                f"evaluate-acceptance.py: state '{state}' has invalid required anchors"
            )


def indexed_records(reference: Any, app: Any) -> tuple[dict[tuple[str, str], Any], dict[tuple[str, str], Any]]:
    reference_records: dict[tuple[str, str], Any] = {}
    for record in reference.get("snapshots", []) if isinstance(reference, dict) else []:
        if not isinstance(record, dict):
            continue
        key = (
            f"{record.get('viewportWidth')}x{record.get('viewportHeight')}",
            record.get("state"),
        )
        reference_records[key] = record

    app_records: dict[tuple[str, str], Any] = {}
    for size_record in app.get("sizes", []) if isinstance(app, dict) else []:
        if not isinstance(size_record, dict):
            continue
        size = size_record.get("size")
        for record in size_record.get("screenshots", []):
            if isinstance(record, dict):
                app_records[(size, record.get("label"))] = record
    return reference_records, app_records


def top_level_evidence_failures(reference: Any, app: Any, contract: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if not isinstance(reference, dict) or reference.get("schemaVersion") != 2:
        failures.append("reference manifest is not schema-v2 evidence")
    elif reference.get("kind") != "authoritative-dc-webkit-reference":
        failures.append("reference manifest kind is invalid")
    if isinstance(reference, dict):
        if reference.get("authoritativeHTMLSHA256") != contract["authoritativeHTMLSHA256"]:
            failures.append("reference manifest authoritative HTML hash is stale")
        if reference.get("acceptanceContractSHA256") != ACCEPTANCE_CONTRACT_SHA256:
            failures.append("reference manifest acceptance contract hash is stale")
        if reference.get("coverage", {}).get("complete") is not True:
            failures.append("reference manifest coverage is incomplete")

    if not isinstance(app, dict) or app.get("schemaVersion") != 2:
        failures.append("real-app evidence is not schema-v2 evidence")
    elif app.get("kind") != "real-macos-app-e2e":
        failures.append("real-app evidence kind is invalid")
    if isinstance(app, dict):
        if app.get("status") != "passed":
            failures.append("real-app evidence status is not passed")
        if app.get("authoritativeHTMLSHA256") != contract["authoritativeHTMLSHA256"]:
            failures.append("real-app evidence authoritative HTML hash is stale")
        if app.get("visualAcceptanceContractSHA256") != ACCEPTANCE_CONTRACT_SHA256:
            failures.append("real-app evidence acceptance contract hash is stale")
        tier = app.get("interactionTier")
        preflight = app.get("preflight")
        if tier == "passive":
            if app.get("runScope") != "strict-acceptance-matrix":
                failures.append("passive real-app run scope is not strict acceptance")
            if app.get("strictVisualAcceptanceEligible") is not True:
                failures.append("passive real-app evidence is not strict-acceptance eligible")
            coverage = app.get("coverage")
            if (
                not isinstance(coverage, dict)
                or coverage.get("strictMatrixComplete") is not True
            ):
                failures.append("passive real-app strict matrix coverage is incomplete")
            if app.get("mode") != "passive-window-observation":
                failures.append("passive real-app evidence mode is invalid")
            if app.get("staticOnly") is not True:
                failures.append("passive real-app evidence staticOnly flag is not true")
            if app.get("keyboardOnly") is not False:
                failures.append("passive real-app evidence keyboardOnly flag is not false")
            if app.get("extendedFullPointer") is not False:
                failures.append(
                    "passive real-app evidence extendedFullPointer flag is not false"
                )
            if app.get("interactionClaims") != {
                "takesFocus": False,
                "postsKeyboardInput": False,
                "movesPointer": False,
            }:
                failures.append("passive real-app interaction claims are invalid")
            if not isinstance(preflight, dict) or preflight.get("screenCaptureAccess") is not True:
                failures.append("passive real-app screen-capture preflight is incomplete")

            required_states = {
                name
                for name, state in contract.get("states", {}).items()
                if isinstance(state, dict) and state.get("appLabel") is not None
            }
            required_sizes = set(contract.get("requiredSizes", []))
            required_labels = {
                contract["states"][state]["appLabel"] for state in required_states
            }
            state_for_label = {
                contract["states"][state]["appLabel"]: state for state in required_states
            }
            if not is_exact_string_coverage(
                app.get("requestedVisualStates"), required_states
            ):
                failures.append("passive real-app requested visual states are incomplete")
            if not is_exact_string_coverage(app.get("requestedSizes"), required_sizes):
                failures.append("passive real-app requested sizes are incomplete")

            expected_pairs = {
                (size, state) for size in required_sizes for state in required_states
            }
            launches = app.get("resolvedVisualStateLaunches")
            launch_pairs: set[tuple[str, str]] = set()
            launch_pids: set[int] = set()
            launch_profiles: set[str] = set()
            launches_by_pair: dict[tuple[str, str], dict[str, Any]] = {}
            if not isinstance(launches, list):
                failures.append("passive real-app visual launch evidence is missing")
            else:
                for launch in launches:
                    if not isinstance(launch, dict):
                        failures.append("passive real-app has malformed visual launch evidence")
                        continue
                    logical_size = launch.get("logicalSize")
                    requested_state = launch.get("requestedState")
                    if not isinstance(logical_size, str) or not isinstance(
                        requested_state, str
                    ):
                        failures.append(
                            "passive real-app has malformed visual launch identity"
                        )
                        continue
                    pair = (logical_size, requested_state)
                    if pair in launch_pairs:
                        failures.append(
                            f"passive real-app has duplicate visual launch {pair[0]}/{pair[1]}"
                        )
                    launch_pairs.add(pair)
                    launches_by_pair[pair] = launch
                    if (
                        not isinstance(launch.get("schemaVersion"), int)
                        or isinstance(launch.get("schemaVersion"), bool)
                        or launch.get("schemaVersion") != 1
                        or launch.get("kind") != "deterministic-visual-test-launch"
                    ):
                        failures.append(
                            f"passive real-app visual launch schema is invalid for {pair[0]}/{pair[1]}"
                        )
                    stable_sample_count = launch.get("stableSampleCount")
                    if (
                        not isinstance(stable_sample_count, int)
                        or isinstance(stable_sample_count, bool)
                        or stable_sample_count < 2
                    ):
                        failures.append(
                            f"passive real-app visual launch did not settle for {pair[0]}/{pair[1]}"
                        )
                    profile_root = launch.get("profileRoot")
                    if not isinstance(profile_root, str) or not profile_root:
                        failures.append(
                            f"passive real-app visual launch profile is invalid for {pair[0]}/{pair[1]}"
                        )
                    elif profile_root in launch_profiles:
                        failures.append(
                            f"passive real-app visual launch profile is reused for {pair[0]}/{pair[1]}"
                        )
                    else:
                        launch_profiles.add(profile_root)
                    state_contract = contract.get("states", {}).get(pair[1], {})
                    if launch.get("resolvedState") != pair[1] or launch.get("appLabel") != state_contract.get("appLabel"):
                        failures.append(
                            f"passive real-app visual launch did not resolve {pair[0]}/{pair[1]}"
                        )
                    pid = launch.get("pid")
                    if is_positive_integer(pid):
                        launch_pids.add(pid)
                    else:
                        failures.append("passive real-app visual launch PID is invalid")
                    window = launch.get("window")
                    window_pid = window.get("pid") if isinstance(window, dict) else None
                    window_layer = (
                        window.get("layer") if isinstance(window, dict) else None
                    )
                    window_number = (
                        window.get("windowNumber") if isinstance(window, dict) else None
                    )
                    if (
                        not isinstance(window, dict)
                        or not is_positive_integer(pid)
                        or not is_positive_integer(window_pid)
                        or window_pid != pid
                        or not isinstance(window_layer, int)
                        or isinstance(window_layer, bool)
                        or window_layer != 0
                        or window.get("onScreen") is not False
                        or not is_positive_integer(window_number)
                    ):
                        failures.append(
                            f"passive real-app visual launch window is not offscreen layer zero for {pair[0]}/{pair[1]}"
                        )
                    elif not passive_process_windows_are_safe(
                        launch.get("processWindows"),
                        pid,
                        window_number,
                    ):
                        failures.append(
                            f"passive real-app visual launch process windows are unsafe for {pair[0]}/{pair[1]}"
                        )
                if launch_pairs != expected_pairs:
                    failures.append("passive real-app visual launch matrix is incomplete")
                if len(launch_pids) != len(expected_pairs):
                    failures.append("passive real-app visual launches do not use unique PIDs")
                if len(launch_profiles) != len(expected_pairs):
                    failures.append(
                        "passive real-app visual launches do not use unique profiles"
                    )

            lifecycles = app.get("passiveLifecycleAssertions")
            lifecycle_pids: set[int] = set()
            if not isinstance(lifecycles, list) or len(lifecycles) != len(expected_pairs):
                failures.append("passive real-app lifecycle evidence is incomplete")
            else:
                for lifecycle in lifecycles:
                    if not isinstance(lifecycle, dict):
                        failures.append("passive real-app lifecycle assertion did not pass")
                        continue
                    pid = lifecycle.get("targetPID")
                    if is_positive_integer(pid):
                        if pid in lifecycle_pids:
                            failures.append(
                                "passive real-app lifecycle target PID is duplicated"
                            )
                        lifecycle_pids.add(pid)
                    else:
                        failures.append("passive real-app lifecycle target PID is invalid")
                        continue
                    if any(
                        lifecycle.get(name) is not True
                        for name in (
                            "targetExitedBeforeObserverStop",
                            "targetNeverFrontmost",
                            "pointerUnchanged",
                        )
                    ):
                        failures.append("passive real-app lifecycle assertion did not pass")

                    observer = lifecycle.get("lifecycleFrontmostObserver")
                    if (
                        not isinstance(observer, dict)
                        or not is_positive_integer(observer.get("targetPID"))
                        or observer.get("targetPID") != pid
                        or observer.get("targetBecameFrontmost") is not False
                        or observer.get("stopFileObserved") is not True
                        or observer.get("timedOut") is not False
                    ):
                        failures.append(
                            "passive real-app lifecycle observer evidence is invalid"
                        )

                    endpoints = lifecycle.get("endpointObservations")
                    before = endpoints.get("before") if isinstance(endpoints, dict) else None
                    after = endpoints.get("after") if isinstance(endpoints, dict) else None
                    if (
                        not isinstance(before, dict)
                        or not isinstance(after, dict)
                        or "frontmostPID" not in before
                        or "frontmostPID" not in after
                        or before.get("frontmostPID") == pid
                        or after.get("frontmostPID") == pid
                    ):
                        failures.append(
                            "passive real-app lifecycle endpoint focus evidence is invalid"
                        )
                    before_pointer = (
                        before.get("pointer") if isinstance(before, dict) else None
                    )
                    after_pointer = (
                        after.get("pointer") if isinstance(after, dict) else None
                    )
                    pointer_unchanged = (
                        isinstance(before_pointer, dict)
                        and isinstance(after_pointer, dict)
                        and all(
                            is_number(before_pointer.get(axis))
                            and is_number(after_pointer.get(axis))
                            and math.isclose(
                                float(before_pointer[axis]),
                                float(after_pointer[axis]),
                                abs_tol=0.01,
                            )
                            for axis in ("x", "y")
                        )
                    )
                    if (
                        not pointer_unchanged
                        or not isinstance(endpoints, dict)
                        or endpoints.get("pointerChangedBetweenEndpoints") is not False
                    ):
                        failures.append(
                            "passive real-app lifecycle endpoint pointer evidence is invalid"
                        )
                if lifecycle_pids != launch_pids:
                    failures.append(
                        "passive real-app lifecycle PIDs do not match visual launches"
                    )

            size_records = app.get("sizes")
            screenshots_by_pair: dict[tuple[str, str], dict[str, Any]] = {}
            observed_sizes: set[str] = set()
            if not isinstance(size_records, list):
                failures.append("passive real-app size evidence is missing")
            else:
                for size_record in size_records:
                    if not isinstance(size_record, dict):
                        failures.append("passive real-app has malformed size evidence")
                        continue
                    size = size_record.get("size")
                    if not isinstance(size, str) or not size:
                        failures.append("passive real-app has malformed size identity")
                        continue
                    if size in observed_sizes:
                        failures.append(
                            f"passive real-app has duplicate size evidence for {size}"
                        )
                    observed_sizes.add(size)
                    screenshots = size_record.get("screenshots")
                    observed_labels: set[str] = set()
                    if not isinstance(screenshots, list):
                        failures.append(
                            f"passive real-app screenshots are missing for {size}"
                        )
                        continue
                    for screenshot in screenshots:
                        if not isinstance(screenshot, dict):
                            failures.append(
                                f"passive real-app has malformed screenshot evidence for {size}"
                            )
                            continue
                        label = screenshot.get("label")
                        if not isinstance(label, str) or not label:
                            failures.append(
                                f"passive real-app has malformed screenshot label for {size}"
                            )
                            continue
                        if label in observed_labels:
                            failures.append(
                                f"passive real-app has duplicate screenshot {size}/{label}"
                            )
                        observed_labels.add(label)
                        state = state_for_label.get(label)
                        if state is not None:
                            screenshots_by_pair[(size, state)] = screenshot
                    if observed_labels != required_labels:
                        failures.append(
                            f"passive real-app screenshot matrix is incomplete for {size}"
                        )
                if observed_sizes != required_sizes:
                    failures.append("passive real-app size matrix is incomplete")

            for pair in expected_pairs:
                launch = launches_by_pair.get(pair)
                screenshot = screenshots_by_pair.get(pair)
                if launch is None or screenshot is None:
                    continue
                launch_window = launch.get("window")
                capture_window = screenshot.get("windowIdentityAtCapture")
                if not isinstance(launch_window, dict) or not isinstance(
                    capture_window, dict
                ):
                    failures.append(
                        f"passive real-app screenshot window identity is missing for {pair[0]}/{pair[1]}"
                    )
                    continue
                if (
                    not is_positive_integer(capture_window.get("pid"))
                    or capture_window.get("pid") != launch.get("pid")
                    or not is_positive_integer(capture_window.get("windowNumber"))
                    or capture_window.get("windowNumber")
                    != launch_window.get("windowNumber")
                    or not isinstance(capture_window.get("layer"), int)
                    or isinstance(capture_window.get("layer"), bool)
                    or capture_window.get("layer") != 0
                    or capture_window.get("layer") != launch_window.get("layer")
                    or capture_window.get("onScreen") is not False
                    or capture_window.get("onScreen")
                    != launch_window.get("onScreen")
                ):
                    failures.append(
                        f"passive real-app screenshot window identity does not match launch for {pair[0]}/{pair[1]}"
                    )
                elif not passive_process_windows_are_safe(
                    screenshot.get("processWindowsAtCapture"),
                    launch.get("pid"),
                    capture_window.get("windowNumber"),
                ):
                    failures.append(
                        f"passive real-app screenshot process windows are unsafe for {pair[0]}/{pair[1]}"
                    )
        elif tier == "extended-full-pointer":
            if app.get("mode") != "legacy-extended-full-pointer":
                failures.append(
                    "real-app evidence mode is not legacy-extended-full-pointer"
                )
            if app.get("extendedFullPointer") is not True:
                failures.append("real-app evidence extendedFullPointer flag is not true")
            if app.get("staticOnly") is not False:
                failures.append("real-app evidence staticOnly flag is not false")
            if app.get("keyboardOnly") is not False:
                failures.append("real-app evidence keyboardOnly flag is not false")
            if not isinstance(preflight, dict) or any(
                preflight.get(name) is not True
                for name in (
                    "accessibilityTrusted",
                    "postEventAccess",
                    "screenCaptureAccess",
                )
            ):
                failures.append("real-app evidence preflight is incomplete")
        else:
            failures.append(
                "real-app evidence interactionTier is not eligible for visual acceptance"
            )
        size_records = app.get("sizes")
        if isinstance(size_records, list):
            for record in size_records:
                if isinstance(record, dict) and record.get("status") != "passed":
                    failures.append(
                        f"real-app size evidence {record.get('size')} status is not passed"
                    )
        else:
            failures.append("real-app size evidence is missing")
    return failures


def state_evaluation(
    visual: Any,
    expected_state: str,
    required_assertions: list[str],
    allowed_sources: set[str],
    side: str,
    expected_screenshot_hash: str | None,
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    result: dict[str, Any] = {
        "evaluated": False,
        "status": "failed",
        "expectedState": expected_state,
    }
    if not isinstance(visual, dict):
        return result, [f"{side} visualEvidence is missing"]
    if visual.get("schemaVersion") != 2 or visual.get("kind") != EXPECTED_EVIDENCE_KIND:
        failures.append(f"{side} visualEvidence is not schema-v2 machine evidence")
    if not expected_screenshot_hash:
        failures.append(f"{side} screenshot hash is missing")
    elif visual.get("screenshotSHA256") != expected_screenshot_hash:
        failures.append(f"{side} visualEvidence is not bound to the screenshot hash")

    raw = visual.get("stateEvaluation")
    if not isinstance(raw, dict):
        failures.append(f"{side} state evaluation is missing")
        return result, failures

    result.update(
        {
            "evaluated": raw.get("evaluated") is True,
            "status": raw.get("status") if isinstance(raw.get("status"), str) else "failed",
            "observedState": raw.get("observedState"),
            "source": raw.get("source"),
            "assertions": raw.get("assertions") if isinstance(raw.get("assertions"), list) else [],
        }
    )
    if raw.get("evaluated") is not True:
        failures.append(f"{side} state evaluation was not evaluated")
    if raw.get("status") != "passed":
        failures.append(f"{side} state evaluation did not pass")
    if raw.get("expectedState") != expected_state:
        failures.append(f"{side} state evaluation expectedState does not match {expected_state}")
    if raw.get("observedState") != expected_state:
        failures.append(f"{side} state evaluation did not observe {expected_state}")
    if raw.get("source") not in allowed_sources:
        failures.append(f"{side} state evaluation source is not an allowed machine probe")

    assertions = raw.get("assertions")
    assertion_records: dict[str, dict[str, Any]] = {}
    if not isinstance(assertions, list):
        failures.append(f"{side} state assertions are missing")
    else:
        for assertion in assertions:
            if not isinstance(assertion, dict) or not isinstance(assertion.get("name"), str):
                failures.append(f"{side} has a malformed state assertion")
                continue
            name = assertion["name"]
            if name in assertion_records:
                failures.append(f"{side} has duplicate state assertion '{name}'")
            assertion_records[name] = assertion
        for name in required_assertions:
            assertion = assertion_records.get(name)
            if assertion is None:
                failures.append(f"{side} is missing required state assertion '{name}'")
            elif assertion.get("evaluated") is not True or assertion.get("passed") is not True:
                failures.append(f"{side} required state assertion '{name}' did not pass")
    result["status"] = "passed" if not failures else "failed"
    result["evaluated"] = not failures
    return result, failures


def geometry_records(
    visual: Any,
    required_anchors: list[str],
    allowed_sources: set[str],
    side: str,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any], list[str]]:
    failures: list[str] = []
    summary: dict[str, Any] = {
        "evaluated": False,
        "status": "failed",
        "coordinateSpace": None,
    }
    if not isinstance(visual, dict):
        return {}, summary, [f"{side} geometry evidence is missing"]
    raw = visual.get("geometryEvaluation")
    if not isinstance(raw, dict):
        return {}, summary, [f"{side} geometry evaluation is missing"]
    summary["coordinateSpace"] = raw.get("coordinateSpace")
    if raw.get("evaluated") is not True:
        failures.append(f"{side} geometry evaluation was not evaluated")
    if raw.get("status") != "passed":
        failures.append(f"{side} geometry evaluation did not pass")
    if raw.get("coordinateSpace") != "viewportPixels":
        failures.append(f"{side} geometry coordinate space is not viewportPixels")

    anchors = raw.get("anchors")
    records: dict[str, dict[str, Any]] = {}
    if not isinstance(anchors, list):
        failures.append(f"{side} geometry anchors are missing")
    else:
        for anchor in anchors:
            if not isinstance(anchor, dict) or not isinstance(anchor.get("name"), str):
                failures.append(f"{side} has a malformed geometry anchor")
                continue
            name = anchor["name"]
            if name in records:
                failures.append(f"{side} has duplicate geometry anchor '{name}'")
            records[name] = anchor

    for name in required_anchors:
        anchor = records.get(name)
        if anchor is None:
            failures.append(f"{side} is missing required geometry anchor '{name}'")
            continue
        if anchor.get("evaluated") is not True:
            failures.append(f"{side} geometry anchor '{name}' was not evaluated")
        if anchor.get("source") not in allowed_sources:
            failures.append(f"{side} geometry anchor '{name}' source is not an allowed machine probe")
        rect = anchor.get("rect")
        if not isinstance(rect, dict):
            failures.append(f"{side} geometry anchor '{name}' has no rectangle")
            continue
        for component in ("x", "y", "width", "height"):
            if not is_number(rect.get(component)):
                failures.append(
                    f"{side} geometry anchor '{name}' has invalid {component}"
                )
        if is_number(rect.get("width")) and float(rect["width"]) <= 0:
            failures.append(f"{side} geometry anchor '{name}' has nonpositive width")
        if is_number(rect.get("height")) and float(rect["height"]) <= 0:
            failures.append(f"{side} geometry anchor '{name}' has nonpositive height")

    summary["status"] = "passed" if not failures else "failed"
    summary["evaluated"] = not failures
    return records, summary, failures


def compare_anchors(
    names: list[str],
    reference: dict[str, dict[str, Any]],
    app: dict[str, dict[str, Any]],
    tolerance: float,
) -> tuple[list[dict[str, Any]], list[str]]:
    results: list[dict[str, Any]] = []
    failures: list[str] = []
    for name in names:
        reference_rect = reference.get(name, {}).get("rect")
        app_rect = app.get(name, {}).get("rect")
        if not isinstance(reference_rect, dict) or not isinstance(app_rect, dict):
            results.append(
                {
                    "name": name,
                    "evaluated": False,
                    "status": "failed",
                    "withinTolerance": False,
                }
            )
            continue
        if not all(
            is_number(reference_rect.get(component)) and is_number(app_rect.get(component))
            for component in ("x", "y", "width", "height")
        ):
            results.append(
                {
                    "name": name,
                    "evaluated": False,
                    "status": "failed",
                    "withinTolerance": False,
                }
            )
            continue
        deltas = {
            component: float(app_rect[component]) - float(reference_rect[component])
            for component in ("x", "y", "width", "height")
        }
        maximum = max(abs(value) for value in deltas.values())
        within_tolerance = maximum <= tolerance
        if not within_tolerance:
            failures.append(
                f"geometry anchor '{name}' error {maximum:g} px exceeds {tolerance:g} px"
            )
        results.append(
            {
                "name": name,
                "evaluated": True,
                "status": "passed" if within_tolerance else "failed",
                "referenceRect": reference_rect,
                "appRect": app_rect,
                "deltas": deltas,
                "maximumAbsoluteErrorPixels": maximum,
                "tolerancePixels": tolerance,
                "withinTolerance": within_tolerance,
            }
        )
    return results, failures


def validate_screenshot(
    root: pathlib.Path,
    record: Any,
    path_key: str,
    hash_key: str,
    side: str,
) -> tuple[str | None, list[str]]:
    failures: list[str] = []
    if not isinstance(record, dict):
        return None, [f"{side} screenshot record is missing"]
    path = checked_file(root, record.get(path_key))
    if path is None:
        return None, [f"{side} screenshot path is missing, unsafe, or unreadable"]
    actual = sha256(path)
    recorded = record.get(hash_key)
    if not isinstance(recorded, str) or not recorded:
        failures.append(f"{side} screenshot manifest hash is missing")
    elif recorded != actual:
        failures.append(f"{side} screenshot manifest hash does not match the file")
    return actual, failures


def _component_dimension(component: dict[str, Any], name: str) -> int:
    bounds = component.get("bounds")
    if bounds is None:
        return 0
    value = bounds.get(name) if isinstance(bounds, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) else -1


def pixel_evaluation(
    metric: Any,
    reference_path: pathlib.Path,
    app_path: pathlib.Path,
    reference_hash: str | None,
    app_hash: str | None,
    threshold: int,
    policy: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    if not isinstance(metric, dict):
        return {
            "evaluated": False,
            "status": "failed",
            "algorithm": ALGORITHM,
            "checks": [],
            "failures": ["pixel measurement is not an object"],
        }, ["pixel measurement is not an object"]

    if metric.get("schemaVersion") != 2 or metric.get("kind") != EXPECTED_METRICS_KIND:
        failures.append("pixel measurement is not the expected schema-v2 output")
    if metric.get("measurementOnly") is not True:
        failures.append("pixel measurement is not marked measurement-only")
    measurement_acceptance = metric.get("acceptance")
    if (
        not isinstance(measurement_acceptance, dict)
        or measurement_acceptance.get("evaluated") is not False
        or measurement_acceptance.get("status") != "notEvaluated"
    ):
        failures.append("pixel measurement improperly claims standalone acceptance")
    if metric.get("masking") != "none":
        failures.append("pixel measurement masked UI pixels")
    if metric.get("reference", {}).get("sha256") != reference_hash:
        failures.append("pixel measurement reference hash is stale")
    if metric.get("app", {}).get("sha256") != app_hash:
        failures.append("pixel measurement app hash is stale")

    configured_threshold = policy["analysis"]["changedPixelThreshold"]
    if threshold != configured_threshold:
        failures.append(
            f"pixel threshold {threshold} differs from pinned contract threshold {configured_threshold}"
        )
    if metric.get("threshold") != configured_threshold:
        failures.append("pixel measurement threshold differs from the pinned contract")

    try:
        with Image.open(reference_path) as opened_reference:
            reference_image = opened_reference.copy()
        with Image.open(app_path) as opened_app:
            app_image = opened_app.copy()
        recomputed = analyze_images(
            reference_image,
            app_image,
            configured_threshold,
        )
    except (OSError, ValueError) as error:
        failures.append(f"pixel measurement could not be recomputed: {error}")
        result = {
            "evaluated": False,
            "status": "failed",
            "algorithm": ALGORITHM,
            "checks": [],
            "failures": failures,
        }
        return result, failures

    if metric.get("pixelAnalysis") != recomputed:
        failures.append("pixel measurement does not match recomputation from bound screenshots")

    legacy_values = {
        "pixelSize": recomputed["pixelSize"],
        "totalPixels": recomputed["totalPixels"],
        "exactChangedPixels": recomputed["exactChangedPixels"],
        "exactChangedPixelRatio": recomputed["exactChangedPixelRatio"],
        "changedPixels": recomputed["changed"]["pixels"],
        "changedPixelRatio": recomputed["changed"]["pixelRatio"],
        "meanAbsoluteChannelDifference": recomputed[
            "meanAbsoluteChannelDifference"
        ],
        "rootMeanSquareChannelDifference": recomputed[
            "rootMeanSquareChannelDifference"
        ],
        "maximumChannelDifference": recomputed["maximumChannelDifference"],
    }
    rms = recomputed["rootMeanSquareChannelDifference"]
    legacy_values["peakSignalToNoiseRatioDB"] = (
        None if rms == 0 else 20 * math.log10(255 / rms)
    )
    if any(metric.get(name) != value for name, value in legacy_values.items()):
        failures.append("pixel measurement summary differs from recomputed analysis")

    changed = recomputed["changed"]
    structural = recomputed["structural"]
    high_magnitude = recomputed["highMagnitude"]
    changed_component = changed["largestConnectedComponent"]
    structural_component = structural["largestConnectedComponent"]
    limits = policy["limits"]
    raw_checks = [
        (
            "changedPixelRatio",
            "changed pixel ratio",
            changed["pixelRatio"],
            limits["maximumChangedPixelRatio"],
        ),
        (
            "structuralPixelRatio",
            "structural pixel ratio",
            structural["pixelRatio"],
            limits["maximumStructuralPixelRatio"],
        ),
        (
            "highMagnitudePixelRatio",
            "high-magnitude pixel ratio",
            high_magnitude["pixelRatio"],
            limits["maximumHighMagnitudePixelRatio"],
        ),
        (
            "meanAbsoluteChannelDifference",
            "mean absolute channel difference",
            recomputed["meanAbsoluteChannelDifference"],
            limits["maximumMeanAbsoluteChannelDifference"],
        ),
        (
            "rootMeanSquareChannelDifference",
            "root mean square channel difference",
            recomputed["rootMeanSquareChannelDifference"],
            limits["maximumRootMeanSquareChannelDifference"],
        ),
        (
            "changedComponentPixels",
            "largest changed component pixels",
            changed_component["pixels"],
            limits["maximumChangedComponentPixels"],
        ),
        (
            "changedComponentWidthPixels",
            "largest changed component width",
            _component_dimension(changed_component, "width"),
            limits["maximumChangedComponentWidthPixels"],
        ),
        (
            "changedComponentHeightPixels",
            "largest changed component height",
            _component_dimension(changed_component, "height"),
            limits["maximumChangedComponentHeightPixels"],
        ),
        (
            "changedHorizontalRunPixels",
            "longest changed horizontal run",
            changed["longestHorizontalRunPixels"],
            limits["maximumChangedHorizontalRunPixels"],
        ),
        (
            "changedVerticalRunPixels",
            "longest changed vertical run",
            changed["longestVerticalRunPixels"],
            limits["maximumChangedVerticalRunPixels"],
        ),
        (
            "changedTilePixelRatio",
            "densest changed tile ratio",
            changed["maximumTilePixelRatio"],
            limits["maximumChangedTilePixelRatio"],
        ),
        (
            "structuralComponentPixels",
            "largest structural component pixels",
            structural_component["pixels"],
            limits["maximumStructuralComponentPixels"],
        ),
        (
            "structuralComponentWidthPixels",
            "largest structural component width",
            _component_dimension(structural_component, "width"),
            limits["maximumStructuralComponentWidthPixels"],
        ),
        (
            "structuralComponentHeightPixels",
            "largest structural component height",
            _component_dimension(structural_component, "height"),
            limits["maximumStructuralComponentHeightPixels"],
        ),
        (
            "structuralHorizontalRunPixels",
            "longest structural horizontal run",
            structural["longestHorizontalRunPixels"],
            limits["maximumStructuralHorizontalRunPixels"],
        ),
        (
            "structuralVerticalRunPixels",
            "longest structural vertical run",
            structural["longestVerticalRunPixels"],
            limits["maximumStructuralVerticalRunPixels"],
        ),
        (
            "structuralTilePixelRatio",
            "densest structural tile ratio",
            structural["maximumTilePixelRatio"],
            limits["maximumStructuralTilePixelRatio"],
        ),
    ]
    checks: list[dict[str, Any]] = []
    for name, description, actual, maximum in raw_checks:
        passed = actual <= maximum
        checks.append(
            {
                "name": name,
                "actual": actual,
                "maximumInclusive": maximum,
                "passed": passed,
            }
        )
        if not passed:
            failures.append(
                f"pixel {description} {actual:.9g} exceeds contract limit {maximum:.9g}"
            )

    result = {
        "evaluated": True,
        "status": "failed" if failures else "passed",
        "algorithm": ALGORITHM,
        "changedPixelThreshold": configured_threshold,
        "masking": "none",
        "antialiasCandidatesRemainInChangedAggregateAndSpatialChecks": True,
        "analysis": recomputed,
        "checks": checks,
        "failures": failures,
    }
    return result, failures


def main() -> int:
    arguments = parse_arguments()
    sizes = arguments.sizes.split(",")
    states = arguments.states.split(",")
    mapping = dict(item.split("=", 1) for item in arguments.mapping.split(","))
    reference = load_json(arguments.reference_manifest)
    app = load_json(arguments.app_evidence)
    if sha256(arguments.contract) != ACCEPTANCE_CONTRACT_SHA256:
        raise SystemExit("evaluate-acceptance.py: acceptance contract bytes changed")
    contract = load_json(arguments.contract)
    validate_contract(contract, states, mapping)

    metric_paths = [
        pathlib.Path(line)
        for line in arguments.metrics_list.read_text(encoding="utf-8").splitlines()
        if line
    ]
    expected_count = len(sizes) * len(states)
    if len(metric_paths) != expected_count:
        raise SystemExit(
            f"evaluate-acceptance.py: found {len(metric_paths)} metrics files, expected {expected_count}"
        )
    metrics = [load_json(path) for path in metric_paths]
    reference_records, app_records = indexed_records(reference, app)
    state_contracts = contract["states"]
    sources = contract.get("allowedEvidenceSources", {})

    root_failures = top_level_evidence_failures(reference, app, contract)

    comparisons: list[dict[str, Any]] = []
    metric_index = 0
    for size in sizes:
        tolerance = 1.0 if size == "1180x760" else 2.0
        for state in states:
            app_label = mapping[state]
            state_contract = state_contracts[state]
            required_assertions = state_contract["requiredStateAssertions"]
            required_anchors = state_contract["requiredGeometryAnchors"]
            reference_record = reference_records.get((size, state))
            app_record = app_records.get((size, app_label))
            pair_failures: list[str] = []
            state_failures: list[str] = []
            geometry_failures: list[str] = []

            reference_hash, screenshot_failures = validate_screenshot(
                arguments.reference_manifest.parent.resolve(),
                reference_record,
                "relativePath",
                "pngSHA256",
                "reference",
            )
            pair_failures.extend(screenshot_failures)
            app_hash, screenshot_failures = validate_screenshot(
                arguments.app_evidence.parent.resolve(),
                app_record,
                "path",
                "sha256",
                "app",
            )
            pair_failures.extend(screenshot_failures)

            reference_visual = (
                reference_record.get("visualEvidence")
                if isinstance(reference_record, dict)
                else None
            )
            app_visual = app_record.get("visualEvidence") if isinstance(app_record, dict) else None
            reference_state, failures = state_evaluation(
                reference_visual,
                state,
                required_assertions,
                set(sources.get("referenceState", [])),
                "reference",
                reference_hash,
            )
            state_failures.extend(failures)
            pair_failures.extend(failures)
            app_state, failures = state_evaluation(
                app_visual,
                app_label,
                required_assertions,
                set(sources.get("appState", [])),
                "app",
                app_hash,
            )
            state_failures.extend(failures)
            pair_failures.extend(failures)

            reference_anchors, reference_geometry, failures = geometry_records(
                reference_visual,
                required_anchors,
                set(sources.get("referenceGeometry", [])),
                "reference",
            )
            geometry_failures.extend(failures)
            pair_failures.extend(failures)
            app_anchors, app_geometry, failures = geometry_records(
                app_visual,
                required_anchors,
                set(sources.get("appGeometry", [])),
                "app",
            )
            geometry_failures.extend(failures)
            pair_failures.extend(failures)
            anchor_results, failures = compare_anchors(
                required_anchors, reference_anchors, app_anchors, tolerance
            )
            geometry_failures.extend(failures)
            pair_failures.extend(failures)

            metric = metrics[metric_index]
            metric_index += 1
            reference_path = checked_file(
                arguments.reference_manifest.parent.resolve(),
                reference_record.get("relativePath")
                if isinstance(reference_record, dict)
                else None,
            )
            app_path = checked_file(
                arguments.app_evidence.parent.resolve(),
                app_record.get("path") if isinstance(app_record, dict) else None,
            )
            if reference_path is None or app_path is None:
                pixel_failures = [
                    "pixel acceptance could not read both bound screenshots"
                ]
                pixel_result = {
                    "evaluated": False,
                    "status": "failed",
                    "algorithm": ALGORITHM,
                    "checks": [],
                    "failures": pixel_failures,
                }
            else:
                pixel_result, pixel_failures = pixel_evaluation(
                    metric,
                    reference_path,
                    app_path,
                    reference_hash,
                    app_hash,
                    arguments.threshold,
                    contract["pixelAcceptancePolicy"],
                )
            pair_failures.extend(pixel_failures)

            comparison = {
                "schemaVersion": 2,
                "kind": PAIR_KIND,
                "size": size,
                "statePair": {
                    "referenceState": state,
                    "appLabel": app_label,
                },
                "evidence": {
                    "referenceScreenshotSHA256": reference_hash,
                    "appScreenshotSHA256": app_hash,
                },
                "stateEvaluation": {
                    "evaluated": reference_state["evaluated"] and app_state["evaluated"],
                    "status": "failed" if state_failures else "passed",
                    "reference": reference_state,
                    "app": app_state,
                    "failures": state_failures,
                },
                "geometryEvaluation": {
                    "evaluated": (
                        reference_geometry["evaluated"]
                        and app_geometry["evaluated"]
                        and all(item["evaluated"] for item in anchor_results)
                    ),
                    "status": "failed" if geometry_failures else "passed",
                    "coordinateSpace": "viewportPixels",
                    "tolerancePixels": tolerance,
                    "referenceEvidence": reference_geometry,
                    "appEvidence": app_geometry,
                    "requiredAnchors": required_anchors,
                    "anchors": anchor_results,
                    "failures": geometry_failures,
                },
                "pixelMeasurement": metric,
                "pixelEvaluation": pixel_result,
                "masking": contract["maskingPolicy"],
                "acceptance": {
                    "evaluated": True,
                    "status": "failed" if pair_failures else "passed",
                    "failures": pair_failures,
                },
            }
            comparisons.append(comparison)
            for failure in pair_failures:
                root_failures.append(f"{size}/{state}: {failure}")

    status = "failed" if root_failures else "passed"
    manifest = {
        "schemaVersion": 2,
        "kind": OUTPUT_KIND,
        "measurementOnly": False,
        "referenceManifest": str(arguments.reference_manifest),
        "appEvidence": str(arguments.app_evidence),
        "acceptanceContract": str(arguments.contract),
        "requestedMatrix": {
            "sizes": sizes,
            "states": states,
            "expectedPairCount": expected_count,
        },
        "coverage": {
            "generatedPairCount": len(comparisons),
            "complete": len(comparisons) == expected_count,
        },
        "measurement": {
            "pixelChangeThreshold": arguments.threshold,
            "thresholdMeaning": (
                "A pixel is counted as changed when any RGB channel exceeds this difference."
            ),
            "acceptanceUsesAggregatePixelScore": True,
            "acceptanceUsesSpatialPixelChecks": True,
            "acceptanceUsesOnlyAggregatePixelScore": False,
        },
        "pixelAcceptancePolicy": contract["pixelAcceptancePolicy"],
        "geometryTolerancePolicy": contract["tolerancePolicy"],
        "masking": contract["maskingPolicy"],
        "acceptance": {
            "evaluated": True,
            "status": status,
            "passedPairCount": sum(
                item["acceptance"]["status"] == "passed" for item in comparisons
            ),
            "failedPairCount": sum(
                item["acceptance"]["status"] == "failed" for item in comparisons
            ),
            "failures": root_failures,
        },
        "comparisons": comparisons,
    }
    print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
