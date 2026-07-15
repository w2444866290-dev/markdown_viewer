#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/markdownviewer-release-smoke-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

fail() {
    echo "ReleaseUserSmokeHarnessTests: $*" >&2
    exit 1
}

bash -n "$ROOT/scripts/release-smoke.sh"
PYTHONPYCACHEPREFIX="$TEMP_ROOT/pycache" python3 -m py_compile \
    "$ROOT/scripts/e2e/verify-release-user-smoke.py"
rg -Fq 'observe-frontmost' "$ROOT/scripts/release-smoke.sh"
rg -Fq 'verify-passive-lifecycle.py' "$ROOT/scripts/release-smoke.sh"
rg -Fq 'terminate-release-smoke-app' "$ROOT/scripts/release-smoke.sh"
rg -Fq 'verify-release-user-smoke.py' "$ROOT/scripts/release-smoke.sh"
rg -Fq 'open -g -n' "$ROOT/scripts/release-smoke.sh"

xcrun swiftc \
    -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework ScreenCaptureKit \
    -framework Vision \
    "$ROOT/scripts/e2e/RealAppDriver.swift" \
    -o "$TEMP_ROOT/RealAppDriver"

if "$TEMP_ROOT/RealAppDriver" terminate-release-smoke-app \
    --pid 2147483647 \
    --executable relative/path \
    > "$TEMP_ROOT/relative.out" \
    2> "$TEMP_ROOT/relative.err"; then
    fail "release termination accepted a relative executable path"
fi
rg -Fq -- '--executable requires an absolute path' "$TEMP_ROOT/relative.err"

if "$TEMP_ROOT/RealAppDriver" terminate-release-smoke-app \
    --pid 2147483647 \
    --executable /tmp/missing-release-smoke \
    > "$TEMP_ROOT/missing.out" \
    2> "$TEMP_ROOT/missing.err"; then
    fail "release termination accepted a missing target"
fi
rg -Fq 'terminate-release-smoke-app target is not running: 2147483647' \
    "$TEMP_ROOT/missing.err"

NONRELEASE_PID="$(pgrep -x Finder 2>/dev/null | head -n 1 || true)"
if [[ ! "$NONRELEASE_PID" =~ ^[0-9]+$ ]]; then
    fail "could not locate Finder for the non-release safety check"
fi
if "$TEMP_ROOT/RealAppDriver" terminate-release-smoke-app \
    --pid "$NONRELEASE_PID" \
    --timeout 0.2 \
    --executable /tmp/not-the-release-smoke \
    > "$TEMP_ROOT/nonrelease.out" \
    2> "$TEMP_ROOT/nonrelease.err"; then
    fail "release termination accepted a non-release process"
fi
rg -Fq "terminate-release-smoke-app refuses process $NONRELEASE_PID with bundle identifier" \
    "$TEMP_ROOT/nonrelease.err"
kill -0 "$NONRELEASE_PID" 2>/dev/null \
    || fail "non-release safety check changed the Finder process"

PROFILE="$TEMP_ROOT/profile"
BUNDLE="$TEMP_ROOT/MarkdownViewer.app"
BINARY="$BUNDLE/Contents/MacOS/MarkdownViewer"
SESSION="$PROFILE/Application Support/MarkdownViewer/session.json"
mkdir -p "$(dirname "$BINARY")" "$(dirname "$SESSION")"
printf 'release-binary\n' > "$BINARY"
printf '%s\n' '{"session":{"tabs":[{"text":"","url":null}]}}' > "$SESSION"
cat > "$TEMP_ROOT/lifecycle.json" <<'JSON'
{
  "targetPID": 4242,
  "targetExitedBeforeObserverStop": true,
  "targetMayRemainRunning": false,
  "targetNeverFrontmost": true,
  "pointerUnchanged": true,
  "lifecycleFrontmostObserver": {
    "targetPID": 4242,
    "sampleIntervalMs": 25,
    "sampleCount": 4,
    "notificationObserverRegistered": true,
    "stopFileObserved": true,
    "timedOut": false
  }
}
JSON
cat > "$TEMP_ROOT/termination.json" <<'JSON'
{
  "schemaVersion": 1,
  "pid": 4242,
  "bundleIdentifier": "local.codex.markdownviewer.release-smoke",
  "requested": true,
  "exited": true,
  "forced": false,
  "durationMs": 17
}
JSON
cat > "$TEMP_ROOT/preflight.json" <<'JSON'
{
  "accessibilityTrusted": true,
  "listenEventAccess": true,
  "postEventAccess": true,
  "screenCaptureAccess": true,
  "sessionLocked": false
}
JSON

verify() {
    python3 "$ROOT/scripts/e2e/verify-release-user-smoke.py" \
        --session "$SESSION" \
        --session-copy "$TEMP_ROOT/user-session.json" \
        --fixture-name '格式示例.md' \
        --fixture-sha cbcdfe19a3383f175f1e9beb78afce473f335fd0e8e814bc799f3a1deade0d9f \
        --lifecycle "$TEMP_ROOT/lifecycle.json" \
        --termination "$TEMP_ROOT/termination.json" \
        --preflight "$TEMP_ROOT/preflight.json" \
        --output "$TEMP_ROOT/evidence.json" \
        --target-pid 4242 \
        --git-commit 6445cee2e7f5be91c0485e2322545293342566bc \
        --source-tree-sha 9cf0a688ec8be5cb2452706d5f55cb6fcfd626abb20a348aa69111b0bc395ce0 \
        --source-tree-dirty 1 \
        --html-sha 269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d \
        --release-bundle "$BUNDLE" \
        --release-binary "$BINARY" \
        --profile-root "$PROFILE" \
        --forbidden-visual-profile "$PROFILE/forbidden-visual-profile"
}

verify
python3 - "$TEMP_ROOT/evidence.json" <<'PY'
import json
import pathlib
import sys

evidence = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert evidence["schemaVersion"] == 1
assert evidence["kind"] == "release-user-smoke-evidence"
assert evidence["status"] == "passed"
assert evidence["interactionTier"] == "passive-user-smoke"
assert evidence["targetNeverFrontmost"] is True
assert evidence["pointerUnchanged"] is True
assert evidence["exactTargetNormalTermination"] is True
assert evidence["sessionAssertions"]["singleBlankUntitledDocument"] is True
assert len(evidence["isolatedUserSessionSHA256"]) == 64
assert evidence["bundleAssertions"]["prototypeHTMLAbsent"] is True
assert evidence["sourceTreeDirty"] is True
PY

python3 - "$TEMP_ROOT/lifecycle.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["targetNeverFrontmost"] = False
path.write_text(json.dumps(value), encoding="utf-8")
PY
if verify > /dev/null 2> "$TEMP_ROOT/frontmost.err"; then
    fail "verifier accepted a foreground Release smoke"
fi
rg -Fq 'release smoke target became frontmost' "$TEMP_ROOT/frontmost.err"
python3 - "$TEMP_ROOT/lifecycle.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["targetNeverFrontmost"] = True
path.write_text(json.dumps(value), encoding="utf-8")
PY

mkdir -p "$PROFILE/forbidden-visual-profile"
if verify > /dev/null 2> "$TEMP_ROOT/visual-profile.err"; then
    fail "verifier accepted a release visual-test profile"
fi
rg -Fq 'release build honored a visual-test profile' "$TEMP_ROOT/visual-profile.err"
rmdir "$PROFILE/forbidden-visual-profile"

printf 'prototype\n' > "$BUNDLE/Contents/support.js"
if verify > /dev/null 2> "$TEMP_ROOT/resource.err"; then
    fail "verifier accepted support.js in the USER bundle"
fi
rg -Fq 'release bundle contains forbidden resource: support.js' "$TEMP_ROOT/resource.err"
rm "$BUNDLE/Contents/support.js"

printf '%s\n' '{"session":{"tabs":[{"text":"格式示例.md","url":null}]}}' > "$SESSION"
if verify > /dev/null 2> "$TEMP_ROOT/session.err"; then
    fail "verifier accepted Debug fixture text in the USER session"
fi
rg -Fq 'release smoke session contains the Debug fixture' "$TEMP_ROOT/session.err"

echo "Release USER smoke harness tests passed"
