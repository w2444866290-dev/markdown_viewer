#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/run-debug.sh [options]

Build and launch the real Debug app with an isolated visual-test profile.

Options:
  --reset                         Reset the selected visual-test profile first.
  --visual-test-root PATH         Set the isolated profile root.
  --visual-test-size WIDTHxHEIGHT Set the fixed window size (default: 1180x760).
  --visual-test-document NAME     Set the bundled Debug fixture to load.
  --visual-test-scroll Y          Set the initial nonnegative scroll offset.
  --visual-test-state STATE       Set the deterministic interface state.
                                  Values: default, palette, find, preview,
                                  sidebar-hidden, source-editor, table-editor.
  --visual-test-restore-session   Restore the selected profile instead of loading a fixture.
  --visual-test-hide-hud          Hide the diagnostic HUD for clean screenshots.
  --background                    Launch without taking focus or moving the pointer.
  --skip-build                    Reuse an already assembled Debug app.
  --show-hud                      Show the diagnostic HUD (the default).
  -h, --help                      Show this help.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBUG_APP_BINARY="$ROOT/dist/debug/MarkdownViewer.app/Contents/MacOS/MarkdownViewer"
SYSTEM_TMP="${TMPDIR:-/tmp}"
SYSTEM_TMP="${SYSTEM_TMP%/}"
PROFILE_ROOT="${MV_VISUAL_TEST_ROOT:-$SYSTEM_TMP/MarkdownViewerVisualTest}"
WINDOW_SIZE="1180x760"
DOCUMENT="格式示例.md"
SCROLL_Y="0"
VISUAL_TEST_STATE="default"
RESET=0
HIDE_HUD=0
BACKGROUND=0
SKIP_BUILD=0
RESTORE_SESSION=0

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "run-debug.sh: $option requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)
            RESET=1
            shift
            ;;
        --visual-test-root)
            require_value "$1" "${2:-}"
            PROFILE_ROOT="$2"
            shift 2
            ;;
        --visual-test-root=*)
            PROFILE_ROOT="${1#*=}"
            require_value "--visual-test-root" "$PROFILE_ROOT"
            shift
            ;;
        --visual-test-size)
            require_value "$1" "${2:-}"
            WINDOW_SIZE="$2"
            shift 2
            ;;
        --visual-test-size=*)
            WINDOW_SIZE="${1#*=}"
            require_value "--visual-test-size" "$WINDOW_SIZE"
            shift
            ;;
        --visual-test-document)
            require_value "$1" "${2:-}"
            DOCUMENT="$2"
            shift 2
            ;;
        --visual-test-document=*)
            DOCUMENT="${1#*=}"
            require_value "--visual-test-document" "$DOCUMENT"
            shift
            ;;
        --visual-test-scroll)
            require_value "$1" "${2:-}"
            SCROLL_Y="$2"
            shift 2
            ;;
        --visual-test-scroll=*)
            SCROLL_Y="${1#*=}"
            require_value "--visual-test-scroll" "$SCROLL_Y"
            shift
            ;;
        --visual-test-state)
            require_value "$1" "${2:-}"
            VISUAL_TEST_STATE="$2"
            shift 2
            ;;
        --visual-test-state=*)
            VISUAL_TEST_STATE="${1#*=}"
            require_value "--visual-test-state" "$VISUAL_TEST_STATE"
            shift
            ;;
        --visual-test-hide-hud|--hide-hud)
            HIDE_HUD=1
            shift
            ;;
        --visual-test-restore-session)
            RESTORE_SESSION=1
            shift
            ;;
        --background)
            BACKGROUND=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --show-hud)
            HIDE_HUD=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "run-debug.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$RESET" -eq 1 && "$RESTORE_SESSION" -eq 1 ]]; then
    echo "run-debug.sh: --reset cannot be combined with --visual-test-restore-session" >&2
    exit 2
fi

if [[ -z "$PROFILE_ROOT" || "$PROFILE_ROOT" == "/" ]]; then
    echo "run-debug.sh: refusing unsafe visual-test root: $PROFILE_ROOT" >&2
    exit 2
fi

if [[ ! "$WINDOW_SIZE" =~ ^[0-9]+([.][0-9]+)?[xX][0-9]+([.][0-9]+)?$ ]]; then
    echo "run-debug.sh: invalid visual-test size: $WINDOW_SIZE" >&2
    exit 2
fi

WIDTH="${WINDOW_SIZE%%[xX]*}"
HEIGHT="${WINDOW_SIZE##*[xX]}"
if ! awk -v width="$WIDTH" -v height="$HEIGHT" 'BEGIN { exit !(width >= 860 && height >= 560) }'; then
    echo "run-debug.sh: visual-test size must be at least 860x560" >&2
    exit 2
fi

if [[ ! "$SCROLL_Y" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "run-debug.sh: invalid visual-test scroll offset: $SCROLL_Y" >&2
    exit 2
fi

case "$VISUAL_TEST_STATE" in
    default|palette|find|preview|sidebar-hidden|source-editor|table-editor)
        ;;
    *)
        echo "run-debug.sh: invalid visual-test state: $VISUAL_TEST_STATE" >&2
        exit 2
        ;;
esac

if [[ -z "$DOCUMENT" || "$DOCUMENT" == */* || "$DOCUMENT" == *\\* || "$DOCUMENT" == "." || "$DOCUMENT" == ".." ]]; then
    echo "run-debug.sh: invalid visual-test document name: $DOCUMENT" >&2
    exit 2
fi

if [[ "$PROFILE_ROOT" != /* ]]; then
    PROFILE_ROOT="$PWD/$PROFILE_ROOT"
fi
PROFILE_PARENT="$(dirname "$PROFILE_ROOT")"
mkdir -p "$PROFILE_PARENT"
PROFILE_PARENT="$(cd "$PROFILE_PARENT" && pwd -P)"
PROFILE_ROOT="$PROFILE_PARENT/$(basename "$PROFILE_ROOT")"
PROFILE_MARKER="$PROFILE_ROOT/.markdownviewer-visual-test-profile"
PID_FILE="$PROFILE_ROOT/app.pid"
LAUNCH_TOKEN_FILE="$PROFILE_ROOT/launch.token"

stop_profile_app() {
    [[ -f "$PID_FILE" ]] || return 0
    local pid
    pid="$(tr -dc '0-9' < "$PID_FILE")"
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        local command expected_token
        command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
        expected_token=""
        if [[ -f "$LAUNCH_TOKEN_FILE" ]]; then
            expected_token="$(tr -dc '[:alnum:]-' < "$LAUNCH_TOKEN_FILE")"
        fi
        if [[ -z "$expected_token" ]]; then
            if [[ "$command" == "$DEBUG_APP_BINARY "* \
                && "$command" == *"--visual-test-root $PROFILE_ROOT --visual-test-size "* ]]; then
                echo "run-debug.sh: refusing to stop a live profile without its launch token: $PROFILE_ROOT" >&2
                exit 1
            fi
            return 0
        fi
        if [[ "$command" == "$DEBUG_APP_BINARY "* \
            && "$command" == *"--visual-test-root $PROFILE_ROOT --visual-test-size "* \
            && "$command" == *" --visual-test-launch-token $expected_token" ]]; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..50}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo "run-debug.sh: existing Debug app did not terminate: $pid" >&2
                exit 1
            fi
        fi
    fi
}

if [[ -d "$PROFILE_ROOT" && ! -f "$PROFILE_MARKER" ]]; then
    if [[ -n "$(find "$PROFILE_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "run-debug.sh: refusing unmarked nonempty profile root: $PROFILE_ROOT" >&2
        exit 2
    fi
fi

if [[ "$RESET" -eq 1 ]]; then
    stop_profile_app
    if [[ -e "$PROFILE_ROOT" ]]; then
        rm -rf "$PROFILE_ROOT"
    fi
fi

mkdir -p "$PROFILE_ROOT"
touch "$PROFILE_MARKER"
stop_profile_app

if [[ "$SKIP_BUILD" -eq 1 ]]; then
    APP="$ROOT/dist/debug/MarkdownViewer.app"
else
    APP="$("$ROOT/scripts/build-debug.sh" --if-needed | tail -n 1)"
fi
APP_BINARY="$APP/Contents/MacOS/MarkdownViewer"
if [[ ! -x "$APP_BINARY" ]]; then
    echo "run-debug.sh: Debug app executable not found at $APP_BINARY" >&2
    exit 1
fi

LOG_DIR="$PROFILE_ROOT/Logs"
DIAGNOSTIC_STATE_FILE="$PROFILE_ROOT/Diagnostics/state.json"
EXPECTED_SESSION_FILE="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
mkdir -p "$LOG_DIR" "$PROFILE_ROOT/Temporary"
# A restored profile can contain the previous process's final diagnostic. Remove
# only this Debug-owned snapshot so launch readiness can never accept stale state.
rm -f "$DIAGNOSTIC_STATE_FILE"

APP_ARGUMENTS=(
    -ApplePersistenceIgnoreState YES
    --debug
    --visual-test
    --visual-test-root "$PROFILE_ROOT"
    --visual-test-size "$WINDOW_SIZE"
    --visual-test-document "$DOCUMENT"
    --visual-test-scroll "$SCROLL_Y"
    --visual-test-state "$VISUAL_TEST_STATE"
)
if [[ "$HIDE_HUD" -eq 1 ]]; then
    APP_ARGUMENTS+=(--visual-test-hide-hud)
fi
if [[ "$RESTORE_SESSION" -eq 1 ]]; then
    APP_ARGUMENTS+=(--visual-test-restore-session)
fi
if [[ "$BACKGROUND" -ne 1 ]]; then
    APP_ARGUMENTS+=(--visual-test-foreground)
fi

# Tag this exact launch so a concurrently running Debug instance can never be
# mistaken for the process created below. The app intentionally ignores this
# bookkeeping-only argument.
LAUNCH_TOKEN="$(uuidgen)"
APP_ARGUMENTS+=(--visual-test-launch-token "$LAUNCH_TOKEN")
BOOTSTRAP_URL="markdownviewer-debug-bootstrap://launch/$LAUNCH_TOKEN"

OPEN_ARGUMENTS=(-n)
if [[ "$BACKGROUND" -eq 1 ]]; then
    OPEN_ARGUMENTS+=(-g)
fi
open "${OPEN_ARGUMENTS[@]}" -a "$APP" "$BOOTSTRAP_URL" --args "${APP_ARGUMENTS[@]}"
APP_PID=""
for _ in {1..50}; do
    while IFS= read -r candidate; do
        [[ "$candidate" =~ ^[0-9]+$ ]] || continue
        command="$(ps -ww -p "$candidate" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$APP_BINARY "* && "$command" == *"$LAUNCH_TOKEN"* ]]; then
            APP_PID="$candidate"
            break
        fi
    done < <(pgrep -f "$LAUNCH_TOKEN" 2>/dev/null || true)
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
    echo "run-debug.sh: Debug app did not start" >&2
    exit 1
fi
printf '%s\n' "$LAUNCH_TOKEN" > "$LAUNCH_TOKEN_FILE"
echo "$APP_PID" > "$PID_FILE"

LAUNCH_READY=0
for _ in {1..100}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    if [[ -s "$DIAGNOSTIC_STATE_FILE" ]] \
        && python3 - "$DIAGNOSTIC_STATE_FILE" "$EXPECTED_SESSION_FILE" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
reported_session = state.get("sessionPath")
if state.get("schemaVersion") != 1 or not isinstance(reported_session, str):
    raise SystemExit(1)
if pathlib.Path(reported_session).resolve() != pathlib.Path(sys.argv[2]).resolve():
    raise SystemExit(1)
PY
    then
        LAUNCH_READY=1
        break
    fi
    sleep 0.05
done
if [[ "$LAUNCH_READY" -ne 1 ]]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    echo "run-debug.sh: Debug app did not publish fresh visual-test diagnostics" >&2
    exit 1
fi

echo "Debug app: $APP"
echo "Visual-test profile: $PROFILE_ROOT"
echo "PID: $APP_PID"
