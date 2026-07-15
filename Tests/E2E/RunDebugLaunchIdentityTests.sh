#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/MarkdownViewerLaunchIdentity.XXXXXX")"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
FIRST_PROFILE="$TEMP_ROOT/profile-old"
SECOND_PROFILE="$TEMP_ROOT/profile"
FIRST_PID=""
SECOND_PID=""

verify_ready_profile() {
    local profile="$1"
    local expected_document="$2"
    python3 - "$profile/Diagnostics/state.json" \
        "$profile/Application Support/MarkdownViewer/session.json" \
        "$expected_document" <<'PY'
import json
import pathlib
import sys

diagnostic = pathlib.Path(sys.argv[1])
if not diagnostic.is_file():
    raise SystemExit("RunDebugLaunchIdentityTests: diagnostic snapshot is missing")
state = json.loads(diagnostic.read_text(encoding="utf-8"))
if state.get("schemaVersion") != 1:
    raise SystemExit("RunDebugLaunchIdentityTests: diagnostic schema is stale")
reported_session = state.get("sessionPath")
if not isinstance(reported_session, str):
    raise SystemExit("RunDebugLaunchIdentityTests: diagnostic session path is missing")
if pathlib.Path(reported_session).resolve() != pathlib.Path(sys.argv[2]).resolve():
    raise SystemExit("RunDebugLaunchIdentityTests: diagnostic session path escaped its profile")
if state.get("document") != sys.argv[3]:
    raise SystemExit("RunDebugLaunchIdentityTests: bootstrap URL changed the active document")
PY
    [[ -f "$profile/Temporary/Workspace/docs/格式示例.md" ]] || {
        echo "RunDebugLaunchIdentityTests: fixture workspace is missing" >&2
        exit 1
    }
}

cleanup() {
    for profile in "$FIRST_PROFILE" "$SECOND_PROFILE"; do
        [[ -f "$profile/app.pid" && -f "$profile/launch.token" ]] || continue
        pid="$(tr -dc '0-9' < "$profile/app.pid")"
        launch_token="$(tr -dc '[:alnum:]-' < "$profile/launch.token")"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
            if [[ "$command" == "$ROOT/dist/debug/MarkdownViewer.app/Contents/MacOS/MarkdownViewer "* \
                && "$command" == *"--visual-test-root $profile --visual-test-size "* \
                && "$command" == *" --visual-test-launch-token $launch_token" ]]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        fi
    done
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

"$ROOT/scripts/run-debug.sh" \
    --reset \
    --background \
    --visual-test-root "$FIRST_PROFILE" \
    --visual-test-state preview \
    --visual-test-hide-hud \
    > "$TEMP_ROOT/first.log"
FIRST_PID="$(tr -dc '0-9' < "$FIRST_PROFILE/app.pid")"
verify_ready_profile "$FIRST_PROFILE" "格式示例.md"

FIRST_TOKEN="$(tr -dc '[:alnum:]-' < "$FIRST_PROFILE/launch.token")"
rm "$FIRST_PROFILE/launch.token"
if "$ROOT/scripts/run-debug.sh" \
    --reset \
    --background \
    --visual-test-root "$FIRST_PROFILE" \
    --visual-test-hide-hud \
    > "$TEMP_ROOT/missing-token.out" \
    2> "$TEMP_ROOT/missing-token.err"; then
    echo "RunDebugLaunchIdentityTests: live tokenless profile was reset" >&2
    exit 1
fi
if ! rg -q "without its launch token" "$TEMP_ROOT/missing-token.err"; then
    echo "RunDebugLaunchIdentityTests: missing-token refusal was not precise" >&2
    exit 1
fi
printf '%s\n' "$FIRST_TOKEN" > "$FIRST_PROFILE/launch.token"
if ! kill -0 "$FIRST_PID" 2>/dev/null; then
    echo "RunDebugLaunchIdentityTests: missing-token refusal terminated the live app" >&2
    exit 1
fi

# Simulate an old or reused PID file that points at another live Debug instance.
# Resetting the second profile must not terminate the first instance.
mkdir -p "$SECOND_PROFILE"
touch "$SECOND_PROFILE/.markdownviewer-visual-test-profile"
printf '%s\n' "$FIRST_PID" > "$SECOND_PROFILE/app.pid"

"$ROOT/scripts/run-debug.sh" \
    --reset \
    --background \
    --visual-test-root "$SECOND_PROFILE" \
    --visual-test-hide-hud \
    > "$TEMP_ROOT/second.log"
SECOND_PID="$(tr -dc '0-9' < "$SECOND_PROFILE/app.pid")"
verify_ready_profile "$SECOND_PROFILE" "格式示例.md"

if [[ ! "$FIRST_PID" =~ ^[0-9]+$ || ! "$SECOND_PID" =~ ^[0-9]+$ ]]; then
    echo "RunDebugLaunchIdentityTests: launcher returned an invalid PID" >&2
    exit 1
fi
if [[ "$FIRST_PID" == "$SECOND_PID" ]]; then
    echo "RunDebugLaunchIdentityTests: second launch reused the first PID" >&2
    exit 1
fi
if ! kill -0 "$FIRST_PID" 2>/dev/null || ! kill -0 "$SECOND_PID" 2>/dev/null; then
    echo "RunDebugLaunchIdentityTests: one of the isolated instances is not running" >&2
    exit 1
fi

FIRST_COMMAND="$(ps -ww -p "$FIRST_PID" -o command=)"
SECOND_COMMAND="$(ps -ww -p "$SECOND_PID" -o command=)"
if [[ "$FIRST_COMMAND" != *"--visual-test-root $FIRST_PROFILE"* ]]; then
    echo "RunDebugLaunchIdentityTests: first PID does not belong to its profile" >&2
    exit 1
fi
if [[ "$FIRST_COMMAND" != *"--visual-test-state preview"* ]]; then
    echo "RunDebugLaunchIdentityTests: visual-test state was not forwarded" >&2
    exit 1
fi
if [[ "$SECOND_COMMAND" != *"--visual-test-root $SECOND_PROFILE"* ]]; then
    echo "RunDebugLaunchIdentityTests: second PID does not belong to its profile" >&2
    exit 1
fi
if [[ "$FIRST_COMMAND" != *"--visual-test-launch-token "* \
    || "$SECOND_COMMAND" != *"--visual-test-launch-token "* ]]; then
    echo "RunDebugLaunchIdentityTests: launch token is missing" >&2
    exit 1
fi

FRONT_PID="$(
    lsappinfo info -only pid "$(lsappinfo front)" \
        | sed -E 's/[^0-9]//g'
)"
if [[ "$FRONT_PID" == "$FIRST_PID" || "$FRONT_PID" == "$SECOND_PID" ]]; then
    echo "RunDebugLaunchIdentityTests: a background launch became frontmost" >&2
    exit 1
fi

echo "RunDebugLaunchIdentityTests: PASS"
