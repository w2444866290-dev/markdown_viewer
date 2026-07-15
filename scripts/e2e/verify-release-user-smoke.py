#!/usr/bin/env python3
"""Validate and publish strict passive Release USER smoke evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re


EXPECTED_FIXTURE_SHA256 = (
    "cbcdfe19a3383f175f1e9beb78afce473f335fd0e8e814bc799f3a1deade0d9f"
)
EXPECTED_HTML_SHA256 = (
    "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
)
EXPECTED_BUNDLE_IDENTIFIER = "local.codex.markdownviewer.release-smoke"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=pathlib.Path)
    parser.add_argument("--session-copy", required=True, type=pathlib.Path)
    parser.add_argument("--fixture-name", required=True)
    parser.add_argument("--fixture-sha", required=True)
    parser.add_argument("--lifecycle", required=True, type=pathlib.Path)
    parser.add_argument("--termination", required=True, type=pathlib.Path)
    parser.add_argument("--preflight", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--target-pid", required=True, type=int)
    parser.add_argument("--git-commit", required=True)
    parser.add_argument("--source-tree-sha", required=True)
    parser.add_argument("--source-tree-dirty", required=True, choices=("0", "1"))
    parser.add_argument("--html-sha", required=True)
    parser.add_argument("--release-bundle", required=True, type=pathlib.Path)
    parser.add_argument("--release-binary", required=True, type=pathlib.Path)
    parser.add_argument("--profile-root", required=True, type=pathlib.Path)
    parser.add_argument("--forbidden-visual-profile", required=True, type=pathlib.Path)
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"verify-release-user-smoke.py: {message}")


def load_object(path: pathlib.Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"could not read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_descendant(path: pathlib.Path, parent: pathlib.Path, label: str) -> pathlib.Path:
    resolved_path = path.resolve()
    resolved_parent = parent.resolve()
    if resolved_path != resolved_parent and resolved_parent not in resolved_path.parents:
        fail(f"{label} is outside the expected root")
    return resolved_path


def validate_bundle(options: argparse.Namespace) -> dict:
    bundle = options.release_bundle.resolve()
    binary = require_descendant(options.release_binary, bundle, "release binary")
    if not bundle.is_dir():
        fail("release bundle is missing")
    if not binary.is_file():
        fail("release binary is missing")

    forbidden_file = None
    debug_fixture_directory = None
    for path in bundle.rglob("*"):
        if path.is_dir() and path.name == "DebugFixtures":
            debug_fixture_directory = path
            break
        if path.is_file() and (
            path.name == options.fixture_name
            or path.name == "support.js"
            or path.name.endswith(".dc.html")
        ):
            forbidden_file = path
            break
    if forbidden_file is not None:
        fail(f"release bundle contains forbidden resource: {forbidden_file.name}")
    if debug_fixture_directory is not None:
        fail("release bundle contains DebugFixtures")

    return {
        "debugFixtureAbsent": True,
        "prototypeHTMLAbsent": True,
        "supportJSAbsent": True,
        "debugFixturesDirectoryAbsent": True,
    }


def validate_session(options: argparse.Namespace) -> tuple[dict, bytes]:
    require_descendant(options.session, options.profile_root, "session")
    try:
        session_bytes = options.session.read_bytes()
        encoded = session_bytes.decode("utf-8")
        payload = json.loads(encoded)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"could not read isolated USER session: {error}")
    if options.fixture_name in encoded:
        fail("release smoke session contains the Debug fixture")
    if not isinstance(payload, dict):
        fail("release smoke session must be a JSON object")
    session = payload.get("session", payload)
    if not isinstance(session, dict):
        fail("release smoke session payload is malformed")
    tabs = session.get("tabs")
    if not isinstance(tabs, list) or len(tabs) != 1:
        fail("release smoke did not start with one tab")
    tab = tabs[0]
    if not isinstance(tab, dict):
        fail("release smoke tab payload is malformed")
    if tab.get("text") != "" or tab.get("url") is not None:
        fail("release smoke did not start with one blank untitled document")
    return (
        {
            "isolatedUserSession": True,
            "singleBlankUntitledDocument": True,
            "debugFixtureAbsent": True,
        },
        session_bytes,
    )


def validate_lifecycle(options: argparse.Namespace) -> dict:
    lifecycle = load_object(options.lifecycle, "passive lifecycle assertion")
    if lifecycle.get("targetPID") != options.target_pid:
        fail("lifecycle target PID mismatch")
    if lifecycle.get("targetNeverFrontmost") is not True:
        fail("release smoke target became frontmost")
    if lifecycle.get("pointerUnchanged") is not True:
        fail("release smoke changed the pointer")
    if lifecycle.get("targetExitedBeforeObserverStop") is not True:
        fail("release smoke target did not exit before observer stop")
    if lifecycle.get("targetMayRemainRunning") is not False:
        fail("release smoke lifecycle allowed the target to remain running")
    observer = lifecycle.get("lifecycleFrontmostObserver")
    if not isinstance(observer, dict):
        fail("release smoke lifecycle observer evidence is missing")
    if observer.get("targetPID") != options.target_pid:
        fail("release smoke lifecycle observer PID mismatch")
    if observer.get("sampleIntervalMs") != 25 or observer.get("sampleCount", 0) < 1:
        fail("release smoke lifecycle observer sampling is incomplete")
    if observer.get("notificationObserverRegistered") is not True:
        fail("release smoke lifecycle observer did not register notifications")
    if observer.get("stopFileObserved") is not True or observer.get("timedOut") is not False:
        fail("release smoke lifecycle observer did not stop cleanly")
    return lifecycle


def validate_termination(options: argparse.Namespace) -> dict:
    termination = load_object(options.termination, "normal termination report")
    expected_keys = {
        "schemaVersion", "pid", "bundleIdentifier", "requested", "exited",
        "forced", "durationMs",
    }
    if set(termination) != expected_keys:
        fail("normal termination report has an unexpected schema")
    if termination.get("schemaVersion") != 1:
        fail("normal termination schema version is invalid")
    if termination.get("pid") != options.target_pid:
        fail("normal termination PID mismatch")
    if termination.get("bundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER:
        fail("normal termination bundle identifier mismatch")
    if termination.get("requested") is not True or termination.get("exited") is not True:
        fail("normal exact-target termination did not complete")
    if termination.get("forced") is not False:
        fail("release smoke termination was forced")
    duration = termination.get("durationMs")
    if not isinstance(duration, int) or duration < 0 or duration > 10_000:
        fail("normal termination duration is invalid")
    return termination


def validate_preflight(options: argparse.Namespace) -> dict:
    preflight = load_object(options.preflight, "preflight")
    expected_keys = {
        "accessibilityTrusted", "listenEventAccess", "postEventAccess",
        "screenCaptureAccess", "sessionLocked",
    }
    if set(preflight) != expected_keys:
        fail("preflight has an unexpected schema")
    if any(not isinstance(preflight[key], bool) for key in expected_keys):
        fail("preflight values must be booleans")
    return preflight


def main() -> None:
    options = arguments()
    if options.target_pid <= 0:
        fail("target PID must be positive")
    if not options.fixture_name or "/" in options.fixture_name:
        fail("fixture name must be one basename")
    if options.fixture_sha != EXPECTED_FIXTURE_SHA256:
        fail("Debug fixture SHA-256 does not match the authoritative SEED")
    if options.html_sha != EXPECTED_HTML_SHA256:
        fail("authoritative HTML SHA-256 changed")
    if not GIT_SHA_PATTERN.fullmatch(options.git_commit):
        fail("git commit is malformed")
    if not SHA256_PATTERN.fullmatch(options.source_tree_sha):
        fail("source tree SHA-256 is malformed")
    require_descendant(
        options.forbidden_visual_profile,
        options.profile_root,
        "forbidden visual profile",
    )
    if options.forbidden_visual_profile.exists():
        fail("release build honored a visual-test profile")

    bundle_assertions = validate_bundle(options)
    session_assertions, session_bytes = validate_session(options)
    lifecycle = validate_lifecycle(options)
    termination = validate_termination(options)
    preflight = validate_preflight(options)
    binary_sha = hashlib.sha256(options.release_binary.read_bytes()).hexdigest()
    session_sha = hashlib.sha256(session_bytes).hexdigest()

    if options.session_copy.resolve() == options.output.resolve():
        fail("session copy and evidence output paths must be distinct")
    options.session_copy.parent.mkdir(parents=True, exist_ok=True)
    options.session_copy.write_bytes(session_bytes)

    evidence = {
        "schemaVersion": 1,
        "kind": "release-user-smoke-evidence",
        "status": "passed",
        "interactionTier": "passive-user-smoke",
        "launchMethod": "open-background-new-instance",
        "targetPID": options.target_pid,
        "targetNeverFrontmost": True,
        "pointerUnchanged": True,
        "exactTargetNormalTermination": True,
        "bundleAssertions": bundle_assertions,
        "launchArgumentAssertions": {
            "debugArgumentsIgnored": True,
            "visualTestProfileNotCreated": True,
        },
        "sessionAssertions": session_assertions,
        "isolatedUserSessionSHA256": session_sha,
        "preflight": preflight,
        "passiveLifecycleAssertion": lifecycle,
        "normalTermination": termination,
        "gitCommit": options.git_commit,
        "sourceTreeSHA256": options.source_tree_sha,
        "sourceTreeDirty": options.source_tree_dirty == "1",
        "sourceTreeSHA256Algorithm": (
            "SHA-256 over sorted git ls-files cached and untracked non-ignored paths, "
            "entry kind, and current worktree bytes"
        ),
        "authoritativeHTMLSHA256": options.html_sha,
        "debugFixtureSHA256": options.fixture_sha,
        "releaseBinarySHA256": binary_sha,
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
