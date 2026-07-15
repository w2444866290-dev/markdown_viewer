#!/usr/bin/env python3
"""Validate no-focus and no-pointer-movement evidence for one passive app PID."""

from __future__ import annotations

import argparse
import errno
import json
import math
import os
import pathlib


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True, type=pathlib.Path)
    parser.add_argument("--after", required=True, type=pathlib.Path)
    parser.add_argument("--ready", required=True, type=pathlib.Path)
    parser.add_argument("--observer", required=True, type=pathlib.Path)
    parser.add_argument("--target-pid", required=True, type=int)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--target-may-remain-running", action="store_true")
    return parser.parse_args()


def load(path: pathlib.Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"verify-passive-lifecycle.py: {path} is not a JSON object")
    return value


def main() -> None:
    options = arguments()
    if options.target_pid <= 0:
        raise SystemExit("verify-passive-lifecycle.py: --target-pid must be positive")
    before = load(options.before)
    after = load(options.after)
    ready = load(options.ready)
    observer = load(options.observer)
    target_pid = options.target_pid

    required = {
        "schemaVersion", "observerPID", "durationMs", "sampleIntervalMs",
        "notificationObserverRegistered", "readyFileCreated", "stopFileObserved",
        "timedOut", "targetPID", "targetPIDLoadedAtMs", "targetBecameFrontmost",
        "initialFrontmostPID", "finalFrontmostPID", "notificationCount",
        "sampleCount", "transitions",
    }
    missing = required.difference(observer)
    if missing:
        raise SystemExit(
            f"verify-passive-lifecycle.py: observer report is missing fields: {sorted(missing)}"
        )
    if observer["schemaVersion"] != 1:
        raise SystemExit("verify-passive-lifecycle.py: observer schema version is invalid")
    if observer["observerPID"] != ready.get("observerPID"):
        raise SystemExit(
            "verify-passive-lifecycle.py: observer PID does not match ready handshake"
        )
    if observer["notificationObserverRegistered"] is not True:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not register activation notifications"
        )
    if observer["readyFileCreated"] is not True:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not confirm its ready handshake"
        )
    if observer["stopFileObserved"] is not True or observer["timedOut"] is not False:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not cover the requested lifecycle"
        )
    if observer["targetPID"] != target_pid:
        raise SystemExit("verify-passive-lifecycle.py: observer loaded the wrong target PID")
    if not isinstance(observer["targetPIDLoadedAtMs"], int):
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not record target PID load time"
        )
    if observer["durationMs"] < observer["targetPIDLoadedAtMs"]:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer ended before loading the target PID"
        )
    if observer["sampleIntervalMs"] != 25 or observer["sampleCount"] < 1:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not maintain 25 ms sampling"
        )
    if observer["targetBecameFrontmost"] is not False:
        raise SystemExit("verify-passive-lifecycle.py: passive target became frontmost")
    if observer.get("firstTargetFrontmostObservation") is not None:
        raise SystemExit(
            "verify-passive-lifecycle.py: observer contains a target frontmost observation"
        )
    if any(item.get("frontmostPID") == target_pid for item in observer["transitions"]):
        raise SystemExit(
            "verify-passive-lifecycle.py: transitions include the target PID"
        )
    if not observer["transitions"]:
        raise SystemExit("verify-passive-lifecycle.py: observer has no initial observation")
    if observer["transitions"][0].get("source") != "initial":
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not begin with an initial snapshot"
        )
    if observer["transitions"][-1].get("source") != "stop":
        raise SystemExit(
            "verify-passive-lifecycle.py: observer did not end with a stop snapshot"
        )
    if before.get("frontmostPID") == target_pid or after.get("frontmostPID") == target_pid:
        raise SystemExit(
            "verify-passive-lifecycle.py: passive target appears in a desktop endpoint"
        )

    target_running = True
    try:
        os.kill(target_pid, 0)
    except ProcessLookupError:
        target_running = False
    except PermissionError:
        target_running = True
    except OSError as error:
        if error.errno == errno.ESRCH:
            target_running = False
        else:
            raise
    if target_running and not options.target_may_remain_running:
        raise SystemExit(
            "verify-passive-lifecycle.py: target still runs before observer stop"
        )

    try:
        pointer_changed = any(
            not math.isclose(
                float(before["pointer"][axis]),
                float(after["pointer"][axis]),
                abs_tol=0.01,
            )
            for axis in ("x", "y")
        )
    except (KeyError, TypeError, ValueError):
        raise SystemExit(
            "verify-passive-lifecycle.py: desktop endpoint pointer is malformed"
        )
    if pointer_changed:
        raise SystemExit(
            "verify-passive-lifecycle.py: passive tier changed the pointer position "
            "between lifecycle endpoints"
        )

    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(
            {
                "targetPID": target_pid,
                "targetExitedBeforeObserverStop": not target_running,
                "targetMayRemainRunning": options.target_may_remain_running,
                "targetNeverFrontmost": True,
                "pointerUnchanged": True,
                "lifecycleFrontmostObserver": observer,
                "endpointObservations": {
                    "scope": "lifecycle-bracketing-endpoints",
                    "frontmostPIDChangedBetweenEndpoints": (
                        before.get("frontmostPID") != after.get("frontmostPID")
                    ),
                    "pointerChangedBetweenEndpoints": False,
                    "before": before,
                    "after": after,
                },
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
