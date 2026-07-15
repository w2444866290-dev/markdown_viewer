#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/MarkdownViewer.app"
RELEASE_BINARY="$APP/Contents/MacOS/MarkdownViewer"
FIXTURE_NAME="格式示例.md"
OUTPUT="${MV_RELEASE_SMOKE_OUTPUT:-$ROOT/build/release-smoke-current}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$PWD/$OUTPUT"
fi
OUTPUT_PARENT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
OUTPUT_MARKER="$OUTPUT/.markdownviewer-release-smoke"
if [[ -d "$OUTPUT" ]]; then
    if [[ ! -f "$OUTPUT_MARKER" ]] \
        && [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "release-smoke.sh: refusing unmarked nonempty output directory: $OUTPUT" >&2
        exit 2
    fi
    rm -rf "$OUTPUT"
fi
mkdir -p "$OUTPUT"
touch "$OUTPUT_MARKER"

PROFILE="$(mktemp -d "$OUTPUT/profile.XXXXXX")"
PROFILE="$(cd "$PROFILE" && pwd -P)"
PID=""
SMOKE_PID=""
DRIVER=""
OBSERVER_PID=""
OBSERVER_READY="$OUTPUT/passive-frontmost-observer-ready.json"
OBSERVER_STOP="$OUTPUT/passive-frontmost-observer.stop"
OBSERVER_TARGET_PID="$OUTPUT/passive-frontmost-target.pid"
OBSERVER_REPORT="$OUTPUT/passive-frontmost-observer.json"
OBSERVER_ERROR="$OUTPUT/passive-frontmost-observer.err"
DESKTOP_BEFORE="$OUTPUT/passive-desktop-before.json"
DESKTOP_AFTER="$OUTPUT/passive-desktop-after.json"
LIFECYCLE_ASSERTION="$OUTPUT/passive-lifecycle-assertion.json"
TERMINATION_REPORT="$OUTPUT/normal-termination.json"

stop_observer_for_cleanup() {
    if [[ -n "$OBSERVER_PID" ]] && kill -0 "$OBSERVER_PID" 2>/dev/null; then
        local temporary_stop="$OBSERVER_STOP.cleanup.$$"
        : > "$temporary_stop"
        mv "$temporary_stop" "$OBSERVER_STOP"
        for _ in {1..20}; do
            kill -0 "$OBSERVER_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$OBSERVER_PID" 2>/dev/null; then
            kill "$OBSERVER_PID" 2>/dev/null || true
        fi
        wait "$OBSERVER_PID" 2>/dev/null || true
    fi
    OBSERVER_PID=""
}

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        if [[ -x "$DRIVER" && -x "${BINARY:-}" ]]; then
            "$DRIVER" terminate-release-smoke-app \
                --pid "$PID" \
                --timeout 2 \
                --executable "$BINARY" \
                >/dev/null 2>&1 || true
        fi
    fi
    stop_observer_for_cleanup
    if [[ "${MV_KEEP_RELEASE_SMOKE:-0}" != "1" ]]; then
        rm -rf "$PROFILE"
    else
        echo "release-smoke.sh: retained $PROFILE" >&2
    fi
}
trap cleanup EXIT INT TERM

source_tree_sha256() {
    python3 - "$ROOT" <<'PY'
import hashlib
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
raw_paths = subprocess.check_output([
    "git", "-C", str(root), "ls-files", "--cached", "--others",
    "--exclude-standard", "-z",
])
paths = sorted({path for path in raw_paths.split(b"\0") if path})
digest = hashlib.sha256()
for raw_path in paths:
    relative_path = os.fsdecode(raw_path)
    path = root / relative_path
    if path.is_symlink():
        kind = b"L"
        payload = os.fsencode(os.readlink(path))
    elif path.is_file():
        kind = b"F"
        payload = path.read_bytes()
    else:
        kind = b"M"
        payload = b""
    digest.update(len(raw_path).to_bytes(8, "big"))
    digest.update(raw_path)
    digest.update(kind)
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)
print(digest.hexdigest())
PY
}

start_frontmost_observer() {
    "$DRIVER" desktop-state > "$DESKTOP_BEFORE"
    "$DRIVER" observe-frontmost \
        --target-pid-file "$OBSERVER_TARGET_PID" \
        --ready-file "$OBSERVER_READY" \
        --stop-file "$OBSERVER_STOP" \
        --timeout 60 \
        > "$OBSERVER_REPORT" \
        2> "$OBSERVER_ERROR" &
    OBSERVER_PID="$!"
    for _ in {1..100}; do
        [[ -s "$OBSERVER_READY" ]] && break
        if ! kill -0 "$OBSERVER_PID" 2>/dev/null; then
            wait "$OBSERVER_PID" 2>/dev/null || true
            echo "release-smoke.sh: passive observer exited before ready" >&2
            tail -n 20 "$OBSERVER_ERROR" >&2 || true
            exit 1
        fi
        sleep 0.05
    done
    if [[ ! -s "$OBSERVER_READY" ]]; then
        echo "release-smoke.sh: passive observer did not become ready" >&2
        exit 1
    fi
    python3 - "$OBSERVER_READY" "$OBSERVER_PID" <<'PY'
import json
import pathlib
import sys

ready = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schemaVersion", "observerPID", "notificationObserverRegistered",
    "sampleIntervalMs",
}
if set(ready) != expected:
    raise SystemExit("release smoke observer ready file has an unexpected schema")
if ready["schemaVersion"] != 1 or ready["observerPID"] != int(sys.argv[2]):
    raise SystemExit("release smoke observer ready identity is invalid")
if ready["notificationObserverRegistered"] is not True:
    raise SystemExit("release smoke observer notification registration is not ready")
if ready["sampleIntervalMs"] != 25:
    raise SystemExit("release smoke observer sampling interval is not 25 ms")
PY
}

publish_target_pid() {
    local temporary="$OBSERVER_TARGET_PID.tmp.$$"
    if [[ -z "$OBSERVER_PID" ]] || ! kill -0 "$OBSERVER_PID" 2>/dev/null; then
        echo "release-smoke.sh: passive observer exited before target publication" >&2
        exit 1
    fi
    printf '%s\n' "$SMOKE_PID" > "$temporary"
    mv "$temporary" "$OBSERVER_TARGET_PID"
}

finish_frontmost_observer() {
    "$DRIVER" desktop-state > "$DESKTOP_AFTER"
    local temporary_stop="$OBSERVER_STOP.tmp.$$"
    : > "$temporary_stop"
    mv "$temporary_stop" "$OBSERVER_STOP"
    local observer_pid="$OBSERVER_PID"
    for _ in {1..100}; do
        kill -0 "$observer_pid" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$observer_pid" 2>/dev/null; then
        echo "release-smoke.sh: passive observer did not stop promptly" >&2
        exit 1
    fi
    if ! wait "$observer_pid"; then
        echo "release-smoke.sh: passive observer failed" >&2
        tail -n 20 "$OBSERVER_ERROR" >&2 || true
        exit 1
    fi
    OBSERVER_PID=""
    python3 "$ROOT/scripts/e2e/verify-passive-lifecycle.py" \
        --before "$DESKTOP_BEFORE" \
        --after "$DESKTOP_AFTER" \
        --ready "$OBSERVER_READY" \
        --observer "$OBSERVER_REPORT" \
        --target-pid "$SMOKE_PID" \
        --output "$LIFECYCLE_ASSERTION"
}

SOURCE_TREE_SHA_START="$(source_tree_sha256)"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    SOURCE_TREE_DIRTY_START=1
else
    SOURCE_TREE_DIRTY_START=0
fi
GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
HTML_SHA="$(shasum -a 256 "$ROOT/ui/Markdown Viewer.dc.html" | awk '{print $1}')"
FIXTURE_SHA="$(shasum -a 256 "$ROOT/Fixtures/Debug/$FIXTURE_NAME" | awk '{print $1}')"

# Seed the existing bundle with a resource that is not part of a release build.
# A correct assembly replaces the whole app, so this file cannot survive.
STALE_RESOURCE="$APP/Contents/Resources/stale-release-assembly-resource.txt"
mkdir -p "$(dirname "$STALE_RESOURCE")"
touch "$STALE_RESOURCE"

"$ROOT/scripts/build.sh" >/dev/null

if [[ ! -x "$RELEASE_BINARY" ]]; then
    echo "release-smoke.sh: release executable is missing" >&2
    exit 1
fi
if [[ -e "$STALE_RESOURCE" ]]; then
    echo "release-smoke.sh: release assembly retained a stale resource" >&2
    exit 1
fi
if find "$APP" -type f \( -name "$FIXTURE_NAME" -o -name '*.dc.html' -o -name 'support.js' \) -print -quit | grep -q .; then
    echo "release-smoke.sh: USER bundle contains test or prototype resources" >&2
    exit 1
fi
if find "$APP" -type d -name 'DebugFixtures' -print -quit | grep -q .; then
    echo "release-smoke.sh: USER bundle contains DebugFixtures" >&2
    exit 1
fi

"$ROOT/scripts/e2e/run-real-app-e2e.sh" --prepare-driver-only \
    > "$OUTPUT/driver-cache.json"
DRIVER_CACHE_BINARY="$(python3 - "$OUTPUT/driver-cache.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
path = payload.get("cachedBinary")
if not isinstance(path, str) or not path.startswith("/"):
    raise SystemExit("release smoke driver cache returned an invalid binary path")
print(path)
PY
)"
DRIVER="$PROFILE/RealAppDriver"
cp "$DRIVER_CACHE_BINARY" "$DRIVER"
chmod +x "$DRIVER"
"$DRIVER" preflight > "$OUTPUT/preflight.json"

# A USER instance may already be open. Launch an identical copy under a temporary
# bundle identity so the smoke never attaches to, focuses, or terminates that app.
SMOKE_APP="$PROFILE/MarkdownViewerReleaseSmoke.app"
cp -R "$APP" "$SMOKE_APP"
SMOKE_PLIST="$SMOKE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.codex.markdownviewer.release-smoke" "$SMOKE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName MarkdownViewerReleaseSmoke" "$SMOKE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable MarkdownViewerReleaseSmoke" "$SMOKE_PLIST"
mv "$SMOKE_APP/Contents/MacOS/MarkdownViewer" "$SMOKE_APP/Contents/MacOS/MarkdownViewerReleaseSmoke"
codesign --force --deep --sign - "$SMOKE_APP" >/dev/null
BINARY="$SMOKE_APP/Contents/MacOS/MarkdownViewerReleaseSmoke"

start_frontmost_observer

open -g -n "$SMOKE_APP" --args \
    --debug \
    --visual-test \
    --release-smoke-root "$PROFILE" \
    --visual-test-root "$PROFILE/forbidden-visual-profile" \
    --visual-test-document "$FIXTURE_NAME" \
    >"$PROFILE/open.stdout.log" 2>"$PROFILE/open.stderr.log"

for _ in {1..30}; do
    PID="$(pgrep -n -f "$BINARY" 2>/dev/null || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
if [[ -z "$PID" ]]; then
    echo "release-smoke.sh: USER smoke process did not launch" >&2
    sed -n '1,80p' "$PROFILE/open.stderr.log" >&2
    pgrep -alf 'MarkdownViewerReleaseSmoke|markdownviewer.release-smoke' >&2 || true
    exit 1
fi
SMOKE_PID="$PID"
publish_target_pid

SESSION="$PROFILE/Application Support/MarkdownViewer/session.json"
for _ in {1..30}; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "release-smoke.sh: USER app exited during launch" >&2
        exit 1
    fi
    [[ -s "$SESSION" ]] && break
    sleep 0.1
done
if [[ -e "$PROFILE/forbidden-visual-profile" ]]; then
    echo "release-smoke.sh: release build honored a visual-test profile" >&2
    exit 1
fi

"$DRIVER" terminate-release-smoke-app \
    --pid "$PID" \
    --timeout 4 \
    --executable "$BINARY" \
    > "$TERMINATION_REPORT"
PID=""
finish_frontmost_observer

if [[ ! -f "$SESSION" ]]; then
    echo "release-smoke.sh: USER app did not persist its isolated blank session" >&2
    exit 1
fi
SOURCE_TREE_SHA_FINISH="$(source_tree_sha256)"
if [[ "$SOURCE_TREE_SHA_FINISH" != "$SOURCE_TREE_SHA_START" ]]; then
    echo "release-smoke.sh: source tree changed during smoke" >&2
    exit 1
fi

python3 "$ROOT/scripts/e2e/verify-release-user-smoke.py" \
    --session "$SESSION" \
    --session-copy "$OUTPUT/user-session.json" \
    --fixture-name "$FIXTURE_NAME" \
    --fixture-sha "$FIXTURE_SHA" \
    --lifecycle "$LIFECYCLE_ASSERTION" \
    --termination "$TERMINATION_REPORT" \
    --preflight "$OUTPUT/preflight.json" \
    --output "$OUTPUT/evidence.json" \
    --target-pid "$SMOKE_PID" \
    --git-commit "$GIT_SHA" \
    --source-tree-sha "$SOURCE_TREE_SHA_START" \
    --source-tree-dirty "$SOURCE_TREE_DIRTY_START" \
    --html-sha "$HTML_SHA" \
    --release-bundle "$APP" \
    --release-binary "$RELEASE_BINARY" \
    --profile-root "$PROFILE" \
    --forbidden-visual-profile "$PROFILE/forbidden-visual-profile"

echo "Release USER smoke passed: $OUTPUT/evidence.json"
