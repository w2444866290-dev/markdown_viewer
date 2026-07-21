#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/e2e/run-real-app-e2e.sh [options]

Launch the isolated Debug app in the background and capture tiered evidence.

Options:
  --output PATH                 Evidence directory (default: build/e2e/real-app-latest).
  --passive                     Capture the 3x7 visual matrix without input, focus, or pointer movement (default).
  --probe-sizes CSV             Passive development probe for selected canonical sizes.
  --probe-states CSV            Passive development probe for selected visual state names.
  --foreground-smoke            Run the bounded palette/find foreground batch at 1180x760.
  --foreground-batch NAME       Run a named bounded batch, the five-phase tab-session-lifecycle suite, or save-lifecycle.
  --foreground-budget SECONDS   Foreground batch budget, fixed at 4 seconds.
  --keyboard-only               Run the legacy focus-taking keyboard matrix.
  --extended-full-pointer       Run the legacy extended keyboard and pointer matrix.
  --static-only                 Deprecated alias for --passive.
  --keep-last-app               Leave the final app for an explicit interaction tier.
  --prepare-driver-only         Warm the driver cache without touching output or launching the app.
  -h, --help                    Show this help.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="$ROOT/build/e2e/real-app-latest"
OUTPUT_WAS_EXPLICIT=0
INTERACTION_TIER="passive"
TIER_WAS_EXPLICIT=0
LEGACY_STATIC_ALIAS=0
FOREGROUND_BUDGET="4"
FOREGROUND_BUDGET_WAS_EXPLICIT=0
FOREGROUND_BATCH_NAME=""
KEEP_LAST_APP=0
PREPARE_DRIVER_ONLY=0
PROBE_SIZES=""
PROBE_STATES=""
PROBE_SIZES_WAS_EXPLICIT=0
PROBE_STATES_WAS_EXPLICIT=0
MARKER_NAME=".markdownviewer-real-app-e2e"
REQUIRED_SIZES=("1180x760" "860x560" "1440x900")
SIZES=("${REQUIRED_SIZES[@]}")
SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
DEBUG_APP_BINARY="$ROOT/dist/debug/MarkdownViewer.app/Contents/MacOS/MarkdownViewer"
VISUAL_EVIDENCE_BUILDER="$ROOT/scripts/e2e/build-visual-evidence.py"
VISUAL_LAUNCH_VERIFIER="$ROOT/scripts/e2e/verify-visual-launch-state.py"
PASSIVE_LIFECYCLE_VERIFIER="$ROOT/scripts/e2e/verify-passive-lifecycle.py"
PASSIVE_VISUAL_STATES=(
    "default:baseline"
    "palette:palette-open"
    "find:find-open"
    "preview:preview-on"
    "sidebar-hidden:sidebar-hidden"
    "source-editor:source-editing"
    "table-editor:table-grid"
)
REQUIRED_VISUAL_STATE_NAMES=(
    "default"
    "palette"
    "find"
    "preview"
    "sidebar-hidden"
    "source-editor"
    "table-editor"
)

RUNNER_CLEANUP_STARTED=0

runner_cleanup() {
    if [[ "$RUNNER_CLEANUP_STARTED" -eq 1 ]]; then
        return 0
    fi
    RUNNER_CLEANUP_STARTED=1
    if declare -F cleanup_runtime_resources >/dev/null 2>&1; then
        cleanup_runtime_resources || true
    fi
    if declare -F cleanup_driver_cache_build >/dev/null 2>&1; then
        cleanup_driver_cache_build || true
    fi
}

runner_exit_trap() {
    local status="$1"
    trap - EXIT INT TERM
    runner_cleanup
    exit "$status"
}

runner_signal_trap() {
    local status="$1"
    trap - INT TERM
    exit "$status"
}

trap 'runner_exit_trap "$?"' EXIT
trap 'runner_signal_trap 130' INT
trap 'runner_signal_trap 143' TERM

debug_process_matches_identity() {
    local pid="$1"
    local binary="$2"
    local profile_root="$3"
    local launch_token="$4"
    local command
    [[ "$pid" =~ ^[0-9]+$ && -n "$profile_root" && -n "$launch_token" ]] || return 1
    command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == "$binary "* \
        && "$command" == *"--visual-test-root $profile_root --visual-test-size "* \
        && "$command" == *" --visual-test-launch-token $launch_token" ]]
}

debug_app_binary_sha256() {
    if [[ ! -x "$DEBUG_APP_BINARY" ]]; then
        return 1
    fi
    shasum -a 256 "$DEBUG_APP_BINARY" | awk '{print $1}'
}

assert_debug_app_binary_unchanged() {
    local current_sha
    if ! current_sha="$(debug_app_binary_sha256)"; then
        echo "run-real-app-e2e.sh: Debug app binary became unavailable while evidence was being recorded" >&2
        exit 5
    fi
    if [[ "$current_sha" != "$APP_SHA_START" ]]; then
        echo "run-real-app-e2e.sh: Debug app binary changed while evidence was being recorded" >&2
        exit 5
    fi
}

stop_recorded_output_apps() {
    local profiles_root="$OUTPUT/profiles"
    [[ -d "$profiles_root" ]] || return 0
    local pid_file profile_root token_file pid launch_token
    while IFS= read -r -d '' pid_file; do
        profile_root="$(dirname "$pid_file")"
        token_file="$profile_root/launch.token"
        pid="$(tr -dc '0-9' < "$pid_file")"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        launch_token=""
        if [[ -f "$token_file" ]]; then
            launch_token="$(tr -dc '[:alnum:]-' < "$token_file")"
        fi
        if [[ -z "$launch_token" ]]; then
            echo "run-real-app-e2e.sh: refusing to erase live profile identity without a launch token: $profile_root" >&2
            return 1
        fi
        if ! debug_process_matches_identity \
            "$pid" "$DEBUG_APP_BINARY" "$profile_root" "$launch_token"; then
            continue
        fi
        kill "$pid" 2>/dev/null || true
        for _ in {1..40}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "run-real-app-e2e.sh: recorded Debug app did not terminate: $pid" >&2
            return 1
        fi
    done < <(find "$profiles_root" -type f -name app.pid -print0)
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "run-real-app-e2e.sh: $option requires a value" >&2
        exit 2
    fi
}

validate_probe_csv() {
    local option="$1"
    local value="$2"
    local allowed_csv="$3"
    if ! python3 - "$option" "$value" "$allowed_csv" <<'PY'
import sys

option, raw, allowed_csv = sys.argv[1:]
allowed = allowed_csv.split(",")
values = raw.split(",")
if not raw or any(not value for value in values):
    print(f"run-real-app-e2e.sh: {option} must be a nonempty comma-separated list", file=sys.stderr)
    raise SystemExit(1)
unknown = [value for value in values if value not in allowed]
if unknown:
    print(
        f"run-real-app-e2e.sh: {option} contains unsupported value: {unknown[0]}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if len(values) != len(set(values)):
    print(f"run-real-app-e2e.sh: {option} contains duplicate values", file=sys.stderr)
    raise SystemExit(1)
PY
    then
        exit 2
    fi
}

visual_state_spec() {
    case "$1" in
        default) printf 'default:baseline\n' ;;
        palette) printf 'palette:palette-open\n' ;;
        find) printf 'find:find-open\n' ;;
        preview) printf 'preview:preview-on\n' ;;
        sidebar-hidden) printf 'sidebar-hidden:sidebar-hidden\n' ;;
        source-editor) printf 'source-editor:source-editing\n' ;;
        table-editor) printf 'table-editor:table-grid\n' ;;
        *)
            echo "run-real-app-e2e.sh: internal visual state error: $1" >&2
            exit 2
            ;;
    esac
}

select_tier() {
    local requested="$1"
    local option="$2"
    if [[ "$TIER_WAS_EXPLICIT" -eq 1 ]]; then
        echo "run-real-app-e2e.sh: interaction tier options are mutually exclusive" >&2
        echo "run-real-app-e2e.sh: cannot combine $option with the previously selected tier" >&2
        exit 2
    fi
    INTERACTION_TIER="$requested"
    TIER_WAS_EXPLICIT=1
}

select_foreground_batch() {
    local name="$1"
    local option="$2"
    case "$name" in
        palette-find|block-activation|find-options|find-regex-replace|preview-content|preview-footnotes|outline-navigation|sidebar-filter-navigation|sidebar-layout-controls|tab-session-lifecycle|table-controls|save-lifecycle|table-navigation|editor-structure|editor-boundaries) ;;
        *)
            echo "run-real-app-e2e.sh: unsupported foreground batch: $name" >&2
            echo "run-real-app-e2e.sh: expected palette-find, block-activation, find-options, find-regex-replace, preview-content, preview-footnotes, outline-navigation, sidebar-filter-navigation, sidebar-layout-controls, tab-session-lifecycle, save-lifecycle, table-controls, table-navigation, editor-structure, or editor-boundaries" >&2
            exit 2
            ;;
    esac
    select_tier "foreground-smoke" "$option"
    FOREGROUND_BATCH_NAME="$name"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            require_value "$1" "${2:-}"
            OUTPUT="$2"
            OUTPUT_WAS_EXPLICIT=1
            shift 2
            ;;
        --output=*)
            OUTPUT="${1#*=}"
            require_value "--output" "$OUTPUT"
            OUTPUT_WAS_EXPLICIT=1
            shift
            ;;
        --passive)
            select_tier "passive" "$1"
            shift
            ;;
        --probe-sizes)
            require_value "$1" "${2:-}"
            if [[ "$PROBE_SIZES_WAS_EXPLICIT" -eq 1 ]]; then
                echo "run-real-app-e2e.sh: --probe-sizes may be specified only once" >&2
                exit 2
            fi
            PROBE_SIZES="$2"
            PROBE_SIZES_WAS_EXPLICIT=1
            shift 2
            ;;
        --probe-sizes=*)
            if [[ "$PROBE_SIZES_WAS_EXPLICIT" -eq 1 ]]; then
                echo "run-real-app-e2e.sh: --probe-sizes may be specified only once" >&2
                exit 2
            fi
            PROBE_SIZES="${1#*=}"
            require_value "--probe-sizes" "$PROBE_SIZES"
            PROBE_SIZES_WAS_EXPLICIT=1
            shift
            ;;
        --probe-states)
            require_value "$1" "${2:-}"
            if [[ "$PROBE_STATES_WAS_EXPLICIT" -eq 1 ]]; then
                echo "run-real-app-e2e.sh: --probe-states may be specified only once" >&2
                exit 2
            fi
            PROBE_STATES="$2"
            PROBE_STATES_WAS_EXPLICIT=1
            shift 2
            ;;
        --probe-states=*)
            if [[ "$PROBE_STATES_WAS_EXPLICIT" -eq 1 ]]; then
                echo "run-real-app-e2e.sh: --probe-states may be specified only once" >&2
                exit 2
            fi
            PROBE_STATES="${1#*=}"
            require_value "--probe-states" "$PROBE_STATES"
            PROBE_STATES_WAS_EXPLICIT=1
            shift
            ;;
        --foreground-smoke)
            select_foreground_batch "palette-find" "$1"
            shift
            ;;
        --foreground-batch)
            require_value "$1" "${2:-}"
            select_foreground_batch "$2" "$1"
            shift 2
            ;;
        --foreground-batch=*)
            foreground_batch_value="${1#*=}"
            require_value "--foreground-batch" "$foreground_batch_value"
            select_foreground_batch "$foreground_batch_value" "--foreground-batch"
            shift
            ;;
        --foreground-budget)
            require_value "$1" "${2:-}"
            FOREGROUND_BUDGET="$2"
            FOREGROUND_BUDGET_WAS_EXPLICIT=1
            shift 2
            ;;
        --foreground-budget=*)
            FOREGROUND_BUDGET="${1#*=}"
            require_value "--foreground-budget" "$FOREGROUND_BUDGET"
            FOREGROUND_BUDGET_WAS_EXPLICIT=1
            shift
            ;;
        --static-only)
            select_tier "passive" "$1"
            LEGACY_STATIC_ALIAS=1
            shift
            ;;
        --keyboard-only)
            select_tier "keyboard-only" "$1"
            shift
            ;;
        --extended-full-pointer)
            select_tier "extended-full-pointer" "$1"
            shift
            ;;
        --keep-last-app)
            KEEP_LAST_APP=1
            shift
            ;;
        --prepare-driver-only)
            PREPARE_DRIVER_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "run-real-app-e2e.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

PROBE_MODE=0
if [[ "$PROBE_SIZES_WAS_EXPLICIT" -eq 1 || "$PROBE_STATES_WAS_EXPLICIT" -eq 1 ]]; then
    PROBE_MODE=1
fi
if [[ "$PROBE_MODE" -eq 1 && "$OUTPUT_WAS_EXPLICIT" -eq 0 ]]; then
    OUTPUT="$ROOT/build/e2e/real-app-probe-latest"
fi
if [[ "$PROBE_MODE" -eq 1 && "$INTERACTION_TIER" != "passive" ]]; then
    echo "run-real-app-e2e.sh: probe filters are available only for the passive tier" >&2
    exit 2
fi
if [[ "$PROBE_MODE" -eq 1 && "$PREPARE_DRIVER_ONLY" -eq 1 ]]; then
    echo "run-real-app-e2e.sh: probe filters cannot be combined with --prepare-driver-only" >&2
    exit 2
fi

if [[ "$PROBE_SIZES_WAS_EXPLICIT" -eq 1 ]]; then
    validate_probe_csv \
        "--probe-sizes" "$PROBE_SIZES" \
        "$(IFS=,; printf '%s' "${REQUIRED_SIZES[*]}")"
    IFS=',' read -r -a SIZES <<< "$PROBE_SIZES"
fi
if [[ "$PROBE_STATES_WAS_EXPLICIT" -eq 1 ]]; then
    validate_probe_csv \
        "--probe-states" "$PROBE_STATES" \
        "$(IFS=,; printf '%s' "${REQUIRED_VISUAL_STATE_NAMES[*]}")"
    IFS=',' read -r -a requested_visual_states <<< "$PROBE_STATES"
    PASSIVE_VISUAL_STATES=()
    for requested_visual_state in "${requested_visual_states[@]}"; do
        PASSIVE_VISUAL_STATES+=("$(visual_state_spec "$requested_visual_state")")
    done
fi

case "$INTERACTION_TIER:$PROBE_MODE" in
    passive:0)
        RUN_SCOPE="strict-acceptance-matrix"
        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=1
        ;;
    passive:1)
        RUN_SCOPE="development-probe"
        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=0
        ;;
    foreground-smoke:0)
        RUN_SCOPE="bounded-foreground-smoke"
        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=0
        ;;
    keyboard-only:0)
        RUN_SCOPE="legacy-keyboard-interaction"
        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=0
        ;;
    extended-full-pointer:0)
        RUN_SCOPE="legacy-extended-interaction"
        STRICT_VISUAL_ACCEPTANCE_ELIGIBLE=1
        ;;
    *)
        echo "run-real-app-e2e.sh: internal run scope error: $INTERACTION_TIER/$PROBE_MODE" >&2
        exit 2
        ;;
esac
VISUAL_STATE_NAMES=()
for visual_state_spec_value in "${PASSIVE_VISUAL_STATES[@]}"; do
    VISUAL_STATE_NAMES+=("${visual_state_spec_value%%:*}")
done
VISUAL_STATE_NAMES_CSV="$(IFS=,; printf '%s' "${VISUAL_STATE_NAMES[*]}")"

if [[ "$FOREGROUND_BUDGET_WAS_EXPLICIT" -eq 1 && "$INTERACTION_TIER" != "foreground-smoke" ]]; then
    echo "run-real-app-e2e.sh: --foreground-budget requires a foreground batch" >&2
    exit 2
fi
if [[ "$KEEP_LAST_APP" -eq 1 && "$INTERACTION_TIER" == "passive" ]]; then
    echo "run-real-app-e2e.sh: --keep-last-app cannot be used with passive lifecycle evidence" >&2
    exit 2
fi
if [[ "$PREPARE_DRIVER_ONLY" -eq 1 ]] \
    && [[ "$TIER_WAS_EXPLICIT" -eq 1 \
        || "$FOREGROUND_BUDGET_WAS_EXPLICIT" -eq 1 \
        || "$KEEP_LAST_APP" -eq 1 ]]; then
    echo "run-real-app-e2e.sh: --prepare-driver-only cannot be combined with interaction options" >&2
    exit 2
fi
if ! python3 - "$FOREGROUND_BUDGET" <<'PY'
import decimal
import sys

try:
    value = decimal.Decimal(sys.argv[1])
except decimal.InvalidOperation:
    raise SystemExit(1)
if not value.is_finite() or value != 4:
    raise SystemExit(1)
PY
then
    echo "run-real-app-e2e.sh: --foreground-budget must be exactly 4 seconds" >&2
    exit 2
fi
STATIC_ONLY=0
KEYBOARD_ONLY=0
EXTENDED_FULL_POINTER=0
FOREGROUND_SMOKE=0
case "$INTERACTION_TIER" in
    passive)
        STATIC_ONLY=1
        EVIDENCE_MODE="passive-window-observation"
        ;;
    foreground-smoke)
        FOREGROUND_SMOKE=1
        SIZES=("1180x760")
        EVIDENCE_MODE="bounded-foreground-smoke"
        ;;
    keyboard-only)
        KEYBOARD_ONLY=1
        EVIDENCE_MODE="legacy-focus-taking-keyboard"
        ;;
    extended-full-pointer)
        EXTENDED_FULL_POINTER=1
        EVIDENCE_MODE="legacy-extended-full-pointer"
        ;;
    *)
        echo "run-real-app-e2e.sh: internal interaction tier error: $INTERACTION_TIER" >&2
        exit 2
        ;;
esac
LAST_SIZE="${SIZES[${#SIZES[@]}-1]}"
SIZE_NAMES_CSV="$(IFS=,; printf '%s' "${SIZES[*]}")"

DRIVER_SOURCE="$ROOT/scripts/e2e/RealAppDriver.swift"
DRIVER_SOURCE_SHA="$(shasum -a 256 "$DRIVER_SOURCE" | awk '{print $1}')"
DRIVER_CACHE_ROOT="${MARKDOWNVIEWER_E2E_DRIVER_CACHE_ROOT:-$ROOT/build/e2e/real-app-driver-cache}"
if [[ -z "$DRIVER_CACHE_ROOT" || "$DRIVER_CACHE_ROOT" != /* || "$DRIVER_CACHE_ROOT" == "/" ]]; then
    echo "run-real-app-e2e.sh: invalid RealAppDriver cache root: $DRIVER_CACHE_ROOT" >&2
    exit 2
fi
DRIVER_COMPILE_ARGUMENTS=(
    -O
    -framework AppKit
    -framework ApplicationServices
    -framework CoreGraphics
    -framework ImageIO
    -framework ScreenCaptureKit
    -framework Vision
)
DRIVER_SWIFTC_PATH="$(xcrun --sdk macosx --find swiftc)"
DRIVER_SWIFTC_VERSION="$(xcrun --sdk macosx swiftc --version 2>&1)"
DRIVER_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
DRIVER_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
DRIVER_HOST_ARCH="$(uname -m)"
DRIVER_CACHE_KEY="$(python3 - \
    "$DRIVER_SOURCE_SHA" \
    "$DRIVER_SWIFTC_PATH" "$DRIVER_SWIFTC_VERSION" \
    "$DRIVER_SDK_PATH" "$DRIVER_SDK_VERSION" "$DRIVER_HOST_ARCH" \
    "${MACOSX_DEPLOYMENT_TARGET:-}" "${SDKROOT:-}" \
    "${DEVELOPER_DIR:-}" "${TOOLCHAINS:-}" \
    "${DRIVER_COMPILE_ARGUMENTS[@]}" <<'PY'
import hashlib
import json
import sys

(
    source_sha,
    swiftc_path,
    swiftc_version,
    sdk_path,
    sdk_version,
    host_arch,
    deployment_target,
    sdkroot,
    developer_dir,
    toolchains,
    *compile_arguments,
) = sys.argv[1:]
material = {
    "schemaVersion": 1,
    "driverSourceSHA256": source_sha,
    "swiftcPath": swiftc_path,
    "swiftcVersion": swiftc_version,
    "sdkPath": sdk_path,
    "sdkVersion": sdk_version,
    "hostArchitecture": host_arch,
    "environment": {
        "MACOSX_DEPLOYMENT_TARGET": deployment_target,
        "SDKROOT": sdkroot,
        "DEVELOPER_DIR": developer_dir,
        "TOOLCHAINS": toolchains,
    },
    "compileArguments": compile_arguments,
}
payload = json.dumps(
    material,
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
print(hashlib.sha256(payload).hexdigest())
PY
)"
DRIVER_CACHE_BINARY="$DRIVER_CACHE_ROOT/$DRIVER_CACHE_KEY-RealAppDriver"
DRIVER_CACHE_CHECKSUM="$DRIVER_CACHE_ROOT/$DRIVER_CACHE_KEY.sha256"
DRIVER_CACHE_METADATA="$DRIVER_CACHE_ROOT/$DRIVER_CACHE_KEY.json"
DRIVER_CACHE_LOCK="$DRIVER_CACHE_ROOT/$DRIVER_CACHE_KEY.lock"
DRIVER_CACHE_RESULT=""
DRIVER_CACHE_LOCK_OWNED=0
DRIVER_CACHE_TEMP_BINARY=""
DRIVER_CACHE_TEMP_CHECKSUM=""
DRIVER_CACHE_TEMP_METADATA=""
release_driver_cache_lock() {
    [[ "$DRIVER_CACHE_LOCK_OWNED" -eq 1 ]] || return 0
    if [[ ! -f "$DRIVER_CACHE_LOCK" \
        || "$(tr -d '[:space:]' < "$DRIVER_CACHE_LOCK")" != "$$" ]]; then
        echo "run-real-app-e2e.sh: refusing to release a RealAppDriver cache lock whose owner changed" >&2
        DRIVER_CACHE_LOCK_OWNED=0
        return 1
    fi
    rm -f "$DRIVER_CACHE_LOCK"
    DRIVER_CACHE_LOCK_OWNED=0
}

cleanup_driver_cache_build() {
    [[ -z "$DRIVER_CACHE_TEMP_BINARY" ]] || rm -f "$DRIVER_CACHE_TEMP_BINARY"
    [[ -z "$DRIVER_CACHE_TEMP_CHECKSUM" ]] || rm -f "$DRIVER_CACHE_TEMP_CHECKSUM"
    [[ -z "$DRIVER_CACHE_TEMP_METADATA" ]] || rm -f "$DRIVER_CACHE_TEMP_METADATA"
    DRIVER_CACHE_TEMP_BINARY=""
    DRIVER_CACHE_TEMP_CHECKSUM=""
    DRIVER_CACHE_TEMP_METADATA=""
    release_driver_cache_lock || true
}

driver_cache_is_valid() {
    [[ -f "$DRIVER_CACHE_BINARY" && -x "$DRIVER_CACHE_BINARY" ]] || return 1
    [[ -f "$DRIVER_CACHE_CHECKSUM" && -f "$DRIVER_CACHE_METADATA" ]] || return 1
    local expected_sha actual_sha
    expected_sha="$(tr -d '[:space:]' < "$DRIVER_CACHE_CHECKSUM")"
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_sha="$(shasum -a 256 "$DRIVER_CACHE_BINARY" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] || return 1
    python3 - \
        "$DRIVER_CACHE_METADATA" "$DRIVER_CACHE_KEY" "$expected_sha" \
        "$DRIVER_SOURCE_SHA" "$DRIVER_SWIFTC_PATH" "$DRIVER_SWIFTC_VERSION" \
        "$DRIVER_SDK_PATH" "$DRIVER_SDK_VERSION" "$DRIVER_HOST_ARCH" \
        "${MACOSX_DEPLOYMENT_TARGET:-}" "${SDKROOT:-}" \
        "${DEVELOPER_DIR:-}" "${TOOLCHAINS:-}" \
        "${DRIVER_COMPILE_ARGUMENTS[@]}" <<'PY'
import json
import pathlib
import sys

try:
    metadata = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
(
    _,
    cache_key,
    binary_sha,
    source_sha,
    swiftc_path,
    swiftc_version,
    sdk_path,
    sdk_version,
    host_arch,
    deployment_target,
    sdkroot,
    developer_dir,
    toolchains,
    *compile_arguments,
) = sys.argv[1:]
expected = {
    "schemaVersion": 1,
    "cacheKey": cache_key,
    "binarySHA256": binary_sha,
    "driverSourceSHA256": source_sha,
    "swiftcPath": swiftc_path,
    "swiftcVersion": swiftc_version,
    "sdkPath": sdk_path,
    "sdkVersion": sdk_version,
    "hostArchitecture": host_arch,
    "environment": {
        "MACOSX_DEPLOYMENT_TARGET": deployment_target,
        "SDKROOT": sdkroot,
        "DEVELOPER_DIR": developer_dir,
        "TOOLCHAINS": toolchains,
    },
    "compileArguments": compile_arguments,
}
if metadata != expected:
    raise SystemExit(1)
PY
}

acquire_driver_cache_lock() {
    for _ in {1..100}; do
        if /usr/bin/shlock -f "$DRIVER_CACHE_LOCK" -p "$$"; then
            DRIVER_CACHE_LOCK_OWNED=1
            return 0
        fi
        if driver_cache_is_valid; then
            return 1
        fi
        sleep 0.1
    done
    echo "run-real-app-e2e.sh: timed out waiting 10 seconds for the RealAppDriver cache lock" >&2
    exit 4
}

prepare_driver_cache() {
    mkdir -p "$DRIVER_CACHE_ROOT"
    if driver_cache_is_valid; then
        DRIVER_CACHE_RESULT="hit"
        return 0
    fi
    if ! acquire_driver_cache_lock; then
        DRIVER_CACHE_RESULT="hit"
        return 0
    fi
    if driver_cache_is_valid; then
        DRIVER_CACHE_RESULT="hit"
        cleanup_driver_cache_build
        return 0
    fi

    rm -rf "$DRIVER_CACHE_BINARY" "$DRIVER_CACHE_CHECKSUM" "$DRIVER_CACHE_METADATA"
    local binary_temp checksum_temp metadata_temp binary_sha
    binary_temp="$(mktemp "$DRIVER_CACHE_ROOT/.RealAppDriver.$DRIVER_CACHE_KEY.XXXXXX")"
    checksum_temp="$(mktemp "$DRIVER_CACHE_ROOT/.RealAppDriver-sha.$DRIVER_CACHE_KEY.XXXXXX")"
    metadata_temp="$(mktemp "$DRIVER_CACHE_ROOT/.RealAppDriver-meta.$DRIVER_CACHE_KEY.XXXXXX")"
    DRIVER_CACHE_TEMP_BINARY="$binary_temp"
    DRIVER_CACHE_TEMP_CHECKSUM="$checksum_temp"
    DRIVER_CACHE_TEMP_METADATA="$metadata_temp"
    if ! xcrun --sdk macosx swiftc \
        "${DRIVER_COMPILE_ARGUMENTS[@]}" \
        "$DRIVER_SOURCE" \
        -o "$binary_temp"; then
        echo "run-real-app-e2e.sh: RealAppDriver compilation failed" >&2
        exit 4
    fi
    chmod +x "$binary_temp"
    binary_sha="$(shasum -a 256 "$binary_temp" | awk '{print $1}')"
    printf '%s\n' "$binary_sha" > "$checksum_temp"
    python3 - \
        "$metadata_temp" "$DRIVER_CACHE_KEY" "$binary_sha" \
        "$DRIVER_SOURCE_SHA" "$DRIVER_SWIFTC_PATH" "$DRIVER_SWIFTC_VERSION" \
        "$DRIVER_SDK_PATH" "$DRIVER_SDK_VERSION" "$DRIVER_HOST_ARCH" \
        "${MACOSX_DEPLOYMENT_TARGET:-}" "${SDKROOT:-}" \
        "${DEVELOPER_DIR:-}" "${TOOLCHAINS:-}" \
        "${DRIVER_COMPILE_ARGUMENTS[@]}" <<'PY'
import json
import pathlib
import sys

(
    output,
    cache_key,
    binary_sha,
    source_sha,
    swiftc_path,
    swiftc_version,
    sdk_path,
    sdk_version,
    host_arch,
    deployment_target,
    sdkroot,
    developer_dir,
    toolchains,
    *compile_arguments,
) = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "schemaVersion": 1,
    "cacheKey": cache_key,
    "binarySHA256": binary_sha,
    "driverSourceSHA256": source_sha,
    "swiftcPath": swiftc_path,
    "swiftcVersion": swiftc_version,
    "sdkPath": sdk_path,
    "sdkVersion": sdk_version,
    "hostArchitecture": host_arch,
    "environment": {
        "MACOSX_DEPLOYMENT_TARGET": deployment_target,
        "SDKROOT": sdkroot,
        "DEVELOPER_DIR": developer_dir,
        "TOOLCHAINS": toolchains,
    },
    "compileArguments": compile_arguments,
}, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    mv -f "$metadata_temp" "$DRIVER_CACHE_METADATA"
    mv -f "$checksum_temp" "$DRIVER_CACHE_CHECKSUM"
    mv -f "$binary_temp" "$DRIVER_CACHE_BINARY"
    DRIVER_CACHE_TEMP_BINARY=""
    DRIVER_CACHE_TEMP_CHECKSUM=""
    DRIVER_CACHE_TEMP_METADATA=""
    if ! driver_cache_is_valid; then
        echo "run-real-app-e2e.sh: compiled RealAppDriver cache entry failed validation" >&2
        exit 4
    fi
    DRIVER_CACHE_RESULT="built"
    cleanup_driver_cache_build
}

if [[ "$PREPARE_DRIVER_ONLY" -eq 1 ]]; then
    prepare_driver_cache
    python3 - \
        "$DRIVER_CACHE_KEY" "$DRIVER_CACHE_RESULT" \
        "$DRIVER_CACHE_BINARY" "$DRIVER_CACHE_METADATA" <<'PY'
import json
import sys

print(json.dumps({
    "schemaVersion": 1,
    "cacheKey": sys.argv[1],
    "cacheStatus": sys.argv[2],
    "cachedBinary": sys.argv[3],
    "metadata": sys.argv[4],
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    exit 0
fi

if [[ -z "$OUTPUT" || "$OUTPUT" == "/" ]]; then
    echo "run-real-app-e2e.sh: refusing unsafe output directory: $OUTPUT" >&2
    exit 2
fi
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$PWD/$OUTPUT"
fi
OUTPUT_PARENT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
OUTPUT_MARKER="$OUTPUT/$MARKER_NAME"

case "$DRIVER_CACHE_ROOT/" in
    "$OUTPUT/"*)
        echo "run-real-app-e2e.sh: output directory cannot contain the shared driver cache: $OUTPUT" >&2
        exit 2
        ;;
esac

if [[ -d "$OUTPUT" ]]; then
    if [[ ! -f "$OUTPUT_MARKER" ]] && [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "run-real-app-e2e.sh: refusing unmarked nonempty output directory: $OUTPUT" >&2
        exit 2
    fi
    if ! stop_recorded_output_apps; then
        echo "run-real-app-e2e.sh: refusing to erase output while a recorded app identity is unresolved" >&2
        exit 2
    fi
    rm -rf "$OUTPUT"
fi
mkdir -p "$OUTPUT/tools" "$OUTPUT/sizes" "$OUTPUT/profiles"
touch "$OUTPUT_MARKER"

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

source_tree_dirty() {
    if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
FIXTURE_SHA="$(shasum -a 256 "$ROOT/ui/格式示例.md" | awk '{print $1}')"
HTML_SHA="$(shasum -a 256 "$ROOT/ui/Markdown Viewer.dc.html" | awk '{print $1}')"
VISUAL_CONTRACT_SHA="$(shasum -a 256 "$ROOT/scripts/visual/acceptance-contract.json" | awk '{print $1}')"
E2E_SCRIPT_SHA="$(shasum -a 256 "$ROOT/scripts/e2e/run-real-app-e2e.sh" | awk '{print $1}')"
SOURCE_TREE_SHA_START="$(source_tree_sha256)"
SOURCE_TREE_DIRTY_START="$(source_tree_dirty)"
OS_VERSION="$(sw_vers -productVersion)"

DRIVER="$OUTPUT/tools/RealAppDriver"
prepare_driver_cache
DRIVER_TEMP="$OUTPUT/tools/.RealAppDriver.$$"
cp "$DRIVER_CACHE_BINARY" "$DRIVER_TEMP"
chmod +x "$DRIVER_TEMP"
if [[ "$(shasum -a 256 "$DRIVER_TEMP" | awk '{print $1}')" \
    != "$(tr -d '[:space:]' < "$DRIVER_CACHE_CHECKSUM")" ]]; then
    rm -f "$DRIVER_TEMP"
    echo "run-real-app-e2e.sh: copied RealAppDriver failed cache validation" >&2
    exit 4
fi
mv -f "$DRIVER_TEMP" "$DRIVER"
DRIVER_BINARY_SHA="$(shasum -a 256 "$DRIVER" | awk '{print $1}')"

"$DRIVER" preflight > "$OUTPUT/preflight.json"
POST_EVENT_ACCESS="$(python3 - "$OUTPUT/preflight.json" <<'PY'
import json
import sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["postEventAccess"] else "0")
PY
)"
LISTEN_EVENT_ACCESS="$(python3 - "$OUTPUT/preflight.json" <<'PY'
import json
import sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["listenEventAccess"] else "0")
PY
)"
ACCESSIBILITY_TRUSTED="$(python3 - "$OUTPUT/preflight.json" <<'PY'
import json
import sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["accessibilityTrusted"] else "0")
PY
)"
SCREEN_CAPTURE_ACCESS="$(python3 - "$OUTPUT/preflight.json" <<'PY'
import json
import sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["screenCaptureAccess"] else "0")
PY
)"
SESSION_LOCKED="$(python3 - "$OUTPUT/preflight.json" <<'PY'
import json
import sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["sessionLocked"] else "0")
PY
)"

if [[ "$SCREEN_CAPTURE_ACCESS" != "1" ]]; then
    echo "run-real-app-e2e.sh: macOS Screen Recording permission is required for window screenshots" >&2
    echo "run-real-app-e2e.sh: preflight evidence is at $OUTPUT/preflight.json" >&2
    exit 3
fi
if [[ ! -f "$SRGB_PROFILE" ]]; then
    echo "run-real-app-e2e.sh: system sRGB color profile is unavailable" >&2
    exit 3
fi
if [[ "$STATIC_ONLY" -ne 1 && "$POST_EVENT_ACCESS" != "1" ]]; then
    echo "run-real-app-e2e.sh: macOS Input Monitoring or Accessibility permission is required for CGEvent input" >&2
    echo "run-real-app-e2e.sh: rerun without an interaction option for passive evidence" >&2
    echo "run-real-app-e2e.sh: preflight evidence is at $OUTPUT/preflight.json" >&2
    exit 3
fi
if [[ "$FOREGROUND_SMOKE" -eq 1 && "$LISTEN_EVENT_ACCESS" != "1" ]]; then
    echo "run-real-app-e2e.sh: foreground smoke requires Input Monitoring permission to detect user interference" >&2
    echo "run-real-app-e2e.sh: rerun without an interaction option for passive evidence" >&2
    echo "run-real-app-e2e.sh: preflight evidence is at $OUTPUT/preflight.json" >&2
    exit 3
fi
if [[ "$STATIC_ONLY" -ne 1 && "$KEYBOARD_ONLY" -ne 1 ]] \
    && [[ "$SESSION_LOCKED" == "1" || "$ACCESSIBILITY_TRUSTED" != "1" ]]; then
    if [[ "$SESSION_LOCKED" == "1" ]]; then
        BLOCKER_CODE="console-session-locked"
        BLOCKER_DETAIL="loginwindow prevents real pointer events from reaching the Debug window"
        AX_FALLBACK_REASON="under loginwindow the app AX window and focused element do not expose semantic find, block, or table controls"
    else
        BLOCKER_CODE="accessibility-permission-required"
        BLOCKER_DETAIL="real pointer actions cannot focus the target app without macOS Accessibility permission"
        AX_FALLBACK_REASON="the target app accessibility hierarchy is unavailable without Accessibility permission"
    fi
    python3 - \
        "$OUTPUT/preflight.json" "$GIT_SHA" "$FIXTURE_SHA" "$HTML_SHA" "$VISUAL_CONTRACT_SHA" \
        "$E2E_SCRIPT_SHA" "$DRIVER_SOURCE_SHA" "$DRIVER_BINARY_SHA" \
        "$SOURCE_TREE_SHA_START" "$SOURCE_TREE_DIRTY_START" "$OS_VERSION" \
        "$BLOCKER_CODE" "$BLOCKER_DETAIL" "$AX_FALLBACK_REASON" \
        "$INTERACTION_TIER" "$FOREGROUND_BATCH_NAME" \
        "$EVIDENCE_MODE" "$FOREGROUND_BUDGET" "$SIZE_NAMES_CSV" \
        "$RUN_SCOPE" "$STRICT_VISUAL_ACCEPTANCE_ELIGIBLE" \
        "$STATIC_ONLY" "$KEYBOARD_ONLY" "$EXTENDED_FULL_POINTER" "$LEGACY_STATIC_ALIAS" \
        > "$OUTPUT/evidence.json" <<'PY'
import datetime
import json
import pathlib
import sys

preflight = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
(
    git_sha,
    fixture_sha,
    html_sha,
    visual_contract_sha,
    script_sha,
    driver_source_sha,
    driver_binary_sha,
    source_tree_sha,
    source_tree_dirty,
    os_version,
    blocker_code,
    blocker_detail,
    ax_fallback_reason,
    interaction_tier,
    foreground_batch_name,
    mode,
    foreground_budget,
    size_names_csv,
    run_scope,
    strict_visual_acceptance_eligible,
    static_only,
    keyboard_only,
    extended_full_pointer,
    legacy_static_alias,
) = sys.argv[2:26]
required_sizes = ["1180x760", "860x560", "1440x900"]
required_visual_states = [
    "default", "palette", "find", "preview", "sidebar-hidden",
    "source-editor", "table-editor",
]
requested_sizes = size_names_csv.split(",")
requested_visual_states = (
    required_visual_states if interaction_tier == "passive" else []
)
print(json.dumps({
    "schemaVersion": 2,
    "kind": "real-macos-app-e2e",
    "status": "blocked",
    "interactionTier": interaction_tier,
    "foregroundBatchName": foreground_batch_name or None,
    "mode": mode,
    "runScope": run_scope,
    "strictVisualAcceptanceEligible": strict_visual_acceptance_eligible == "1",
    "staticOnly": static_only == "1",
    "keyboardOnly": keyboard_only == "1",
    "extendedFullPointer": extended_full_pointer == "1",
    "legacyStaticOnlyAlias": legacy_static_alias == "1",
    "requestedSizes": requested_sizes,
    "requestedVisualStates": requested_visual_states,
    "coverage": {
        "visualCoverageApplicable": interaction_tier == "passive",
        "requiredSizes": required_sizes,
        "requestedSizes": requested_sizes,
        "requiredVisualStates": required_visual_states,
        "requestedVisualStates": requested_visual_states,
        "requiredPairCount": len(required_sizes) * len(required_visual_states),
        "requestedPairCount": len(requested_sizes) * len(requested_visual_states),
        "resolvedPairCount": 0,
        "requestedPairsComplete": False,
        "strictMatrixComplete": False,
    },
    "interactionCoverage": {
        "applicable": interaction_tier == "foreground-smoke",
        "status": (
            "passed" if interaction_tier == "foreground-smoke" else "not-applicable"
        ),
        "requestedBatchName": (
            foreground_batch_name if interaction_tier == "foreground-smoke" else None
        ),
        "plannedActionCount": 0,
        "completedActionCount": 0,
        "allPlannedActionsCompleted": False,
        "targetActivationRequestCount": 0,
        "interferenceDetected": False,
        "deadlineExceeded": False,
        "focusRestored": False,
        "pointerRestored": False,
        "pasteboardRestored": False,
        "status": "blocked-before-launch",
    },
    "foregroundBudgetSeconds": (
        float(foreground_budget) if interaction_tier == "foreground-smoke" else None
    ),
    "foregroundReport": None,
    "passiveLifecycleAssertions": [],
    "resolvedVisualStateLaunches": [],
    "interactionClaims": {
        "takesFocus": interaction_tier != "passive",
        "postsKeyboardInput": interaction_tier != "passive",
        "movesPointer": interaction_tier in {
            "foreground-smoke", "extended-full-pointer",
        },
    },
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "gitCommit": git_sha,
    "fixtureSHA256": fixture_sha,
    "authoritativeHTMLSHA256": html_sha,
    "visualAcceptanceContractSHA256": visual_contract_sha,
    "e2eScriptSHA256": script_sha,
    "driverSourceSHA256": driver_source_sha,
    "driverBinarySHA256": driver_binary_sha,
    "sourceTreeSHA256": source_tree_sha,
    "sourceTreeDirty": source_tree_dirty == "1",
    "sourceTreeSHA256Algorithm": (
        "SHA-256 over sorted git ls-files cached and untracked non-ignored paths, "
        "entry kind, and current worktree bytes"
    ),
    "macOSVersion": os_version,
    "preflight": preflight,
    "sizes": [],
    "blocker": {
        "code": blocker_code,
        "detail": blocker_detail,
        "fallbacks": ["default passive tier", "--keyboard-only"],
        "axFallback": {
            "available": False,
            "reason": ax_fallback_reason,
        },
    },
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    echo "run-real-app-e2e.sh: $BLOCKER_CODE" >&2
    echo "run-real-app-e2e.sh: $BLOCKER_DETAIL" >&2
    echo "run-real-app-e2e.sh: use the default passive tier or --keyboard-only for narrower evidence" >&2
    echo "run-real-app-e2e.sh: preflight evidence is at $OUTPUT/preflight.json" >&2
    exit 3
fi

if ! "$ROOT/scripts/build-debug.sh" --if-needed > "$OUTPUT/build-debug.log" 2>&1; then
    echo "run-real-app-e2e.sh: Debug app build failed" >&2
    tail -n 30 "$OUTPUT/build-debug.log" >&2
    exit 4
fi
PREBUILT_DEBUG_APP="$(tail -n 1 "$OUTPUT/build-debug.log")"
if [[ "$PREBUILT_DEBUG_APP" != "$ROOT/dist/debug/MarkdownViewer.app" \
    || ! -x "$DEBUG_APP_BINARY" ]]; then
    echo "run-real-app-e2e.sh: prebuilt Debug app is invalid" >&2
    exit 4
fi
APP_SHA_START="$(debug_app_binary_sha256)"

CURRENT_PID=""
CURRENT_BINARY=""
CURRENT_PROFILE_ROOT=""
CURRENT_LAUNCH_TOKEN=""
CAFFEINATE_PID=""
PASSIVE_OBSERVER_PID=""
PASSIVE_OBSERVER_READY_FILE=""
PASSIVE_OBSERVER_STOP_FILE=""
PASSIVE_OBSERVER_TARGET_PID_FILE=""
PASSIVE_OBSERVER_REPORT=""
PASSIVE_OBSERVER_ERROR=""

stop_current_app() {
    [[ -n "$CURRENT_PID" ]] || return 0
    if kill -0 "$CURRENT_PID" 2>/dev/null; then
        if ! debug_process_matches_identity \
            "$CURRENT_PID" "$CURRENT_BINARY" \
            "$CURRENT_PROFILE_ROOT" "$CURRENT_LAUNCH_TOKEN"; then
            echo "run-real-app-e2e.sh: refusing to stop a PID whose launch identity no longer matches: $CURRENT_PID" >&2
            return 1
        fi
        kill "$CURRENT_PID" 2>/dev/null || true
        for _ in {1..40}; do
            kill -0 "$CURRENT_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$CURRENT_PID" 2>/dev/null; then
            kill -KILL "$CURRENT_PID" 2>/dev/null || true
            echo "run-real-app-e2e.sh: isolated Debug app required forced termination: $CURRENT_PID" >&2
            return 1
        fi
    fi
    CURRENT_PID=""
    CURRENT_BINARY=""
    CURRENT_PROFILE_ROOT=""
    CURRENT_LAUNCH_TOKEN=""
}

normal_terminate_current_app() {
    local report="$1"
    [[ -n "$CURRENT_PID" ]] || {
        echo "run-real-app-e2e.sh: no current Debug app to terminate normally" >&2
        return 1
    }
    if ! debug_process_matches_identity \
        "$CURRENT_PID" "$CURRENT_BINARY" \
        "$CURRENT_PROFILE_ROOT" "$CURRENT_LAUNCH_TOKEN"; then
        echo "run-real-app-e2e.sh: refusing normal termination for a mismatched PID: $CURRENT_PID" >&2
        return 1
    fi
    local terminated_pid="$CURRENT_PID"
    "$DRIVER" terminate-app \
        --pid "$terminated_pid" \
        --timeout 4 \
        > "$report"
    python3 - "$report" "$terminated_pid" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_pid = int(sys.argv[2])
if set(report) != {
    "schemaVersion", "pid", "bundleIdentifier", "requested", "exited",
    "forced", "durationMs",
}:
    raise SystemExit("normal termination report has an unexpected schema")
if report["schemaVersion"] != 1 \
        or report["pid"] != expected_pid \
        or report["bundleIdentifier"] != "local.codex.markdownviewer.debug" \
        or report["requested"] is not True \
        or report["exited"] is not True \
        or report["forced"] is not False \
        or not isinstance(report["durationMs"], int) \
        or report["durationMs"] < 0 \
        or report["durationMs"] > 4_000:
    raise SystemExit("normal termination report did not prove a clean Debug exit")
PY
    if kill -0 "$terminated_pid" 2>/dev/null; then
        echo "run-real-app-e2e.sh: normally terminated Debug app is still running: $terminated_pid" >&2
        return 1
    fi
    CURRENT_PID=""
    CURRENT_BINARY=""
    CURRENT_PROFILE_ROOT=""
    CURRENT_LAUNCH_TOKEN=""
}

launch_restored_visual_session() {
    local launch_log="$1"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    if [[ ! -s "$session" ]]; then
        echo "run-real-app-e2e.sh: restored visual launch requires an existing session" >&2
        return 1
    fi
    : > "$launch_log"
    local launch_succeeded=0
    local attempt
    for attempt in 1 2 3; do
        printf 'Restore launch attempt %s\n' "$attempt" >> "$launch_log"
        assert_debug_app_binary_unchanged
        local restore_hud_options=(--visual-test-hide-hud)
        if [[ "$FOREGROUND_BATCH_NAME" == "save-lifecycle" ]]; then
            restore_hud_options=(--show-hud)
        fi
        if "$ROOT/scripts/run-debug.sh" \
            --background \
            --skip-build \
            --visual-test-root "$PROFILE_ROOT" \
            --visual-test-size "$SIZE" \
            --visual-test-restore-session \
            "${restore_hud_options[@]}" \
            >> "$launch_log" 2>&1; then
            launch_succeeded=1
            break
        fi
        sleep 0.5
    done
    if [[ "$launch_succeeded" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: restored Debug app launch failed" >&2
        tail -n 20 "$launch_log" >&2
        return 1
    fi
    CURRENT_PID="$(tr -dc '0-9' < "$PROFILE_ROOT/app.pid")"
    CURRENT_BINARY="$DEBUG_APP_BINARY"
    CURRENT_PROFILE_ROOT="$PROFILE_ROOT"
    if [[ ! -f "$PROFILE_ROOT/launch.token" ]]; then
        echo "run-real-app-e2e.sh: restored Debug app launch token is missing" >&2
        return 1
    fi
    CURRENT_LAUNCH_TOKEN="$(tr -dc '[:alnum:]-' < "$PROFILE_ROOT/launch.token")"
    if [[ -z "$CURRENT_PID" ]] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then
        echo "run-real-app-e2e.sh: restored Debug app did not remain running" >&2
        return 1
    fi
    if [[ -z "$CURRENT_LAUNCH_TOKEN" ]] || ! debug_process_matches_identity \
        "$CURRENT_PID" "$CURRENT_BINARY" \
        "$CURRENT_PROFILE_ROOT" "$CURRENT_LAUNCH_TOKEN"; then
        echo "run-real-app-e2e.sh: restored Debug app identity does not match its profile" >&2
        return 1
    fi
}

prove_normal_termination_session_flush() {
    local expected_session="$1"
    local artifact_dir="$2"
    local label="$3"
    local live_session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local removed_session="$artifact_dir/session-removed-before-termination.json"
    local rebuilt_session="$artifact_dir/session-rebuilt-on-termination.json"
    local termination_report="$artifact_dir/termination-report.json"
    local assertion="$artifact_dir/session-flush-assertion.json"
    mkdir -p "$artifact_dir"
    python3 - "$expected_session" "$live_session" <<'PY'
import json
import pathlib
import sys

expected = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
observed = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if observed != expected:
    raise SystemExit("live session drifted before the normal termination proof")
PY
    mv "$live_session" "$removed_session"
    normal_terminate_current_app "$termination_report"
    if [[ ! -s "$live_session" ]]; then
        echo "run-real-app-e2e.sh: normal termination did not recreate session.json" >&2
        return 1
    fi
    cp "$live_session" "$rebuilt_session"
    python3 - \
        "$expected_session" "$removed_session" "$rebuilt_session" \
        "$termination_report" "$label" \
        > "$assertion" <<'PY'
import hashlib
import json
import pathlib
import sys

expected_path, removed_path, rebuilt_path, termination_path, label = sys.argv[1:]
expected = json.loads(pathlib.Path(expected_path).read_text(encoding="utf-8"))
removed = json.loads(pathlib.Path(removed_path).read_text(encoding="utf-8"))
rebuilt = json.loads(pathlib.Path(rebuilt_path).read_text(encoding="utf-8"))
termination = json.loads(pathlib.Path(termination_path).read_text(encoding="utf-8"))
if removed != expected or rebuilt != expected:
    raise SystemExit("normal termination did not rebuild the exact expected session")
print(json.dumps({
    "label": label,
    "assertions": {
        "liveSessionRemovedBeforeTermination": True,
        "willTerminateRecreatedSession": True,
        "rebuiltSessionExactlyMatchesExpected": True,
        "normalCocoaTerminationUsed": (
            termination["requested"] is True
            and termination["exited"] is True
            and termination["forced"] is False
        ),
    },
    "sessionSHA256": hashlib.sha256(
        pathlib.Path(rebuilt_path).read_bytes()
    ).hexdigest(),
    "termination": termination,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

stop_passive_observer_for_cleanup() {
    [[ -n "$PASSIVE_OBSERVER_PID" ]] || return 0
    if kill -0 "$PASSIVE_OBSERVER_PID" 2>/dev/null; then
        if [[ -n "$PASSIVE_OBSERVER_STOP_FILE" ]]; then
            : > "$PASSIVE_OBSERVER_STOP_FILE"
        fi
        for _ in {1..40}; do
            kill -0 "$PASSIVE_OBSERVER_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$PASSIVE_OBSERVER_PID" 2>/dev/null; then
            kill "$PASSIVE_OBSERVER_PID" 2>/dev/null || true
        fi
    fi
    wait "$PASSIVE_OBSERVER_PID" 2>/dev/null || true
    PASSIVE_OBSERVER_PID=""
}

cleanup_runtime_resources() {
    stop_current_app || true
    stop_passive_observer_for_cleanup
    if [[ -n "$CAFFEINATE_PID" ]]; then
        kill "$CAFFEINATE_PID" 2>/dev/null || true
    fi
}

# Passive evidence and the bounded foreground smoke must not synthesize user
# activity outside the monitored batch. Only the deliberate legacy matrices may
# wake an idle display before their longer focus-taking work begins.
if [[ "$KEYBOARD_ONLY" -eq 1 || "$EXTENDED_FULL_POINTER" -eq 1 ]]; then
    caffeinate -u -t 8 &
fi
if [[ "$STATIC_ONLY" -eq 1 ]]; then
    caffeinate -i -m -w $$ &
else
    caffeinate -d -i -m -w $$ &
fi
CAFFEINATE_PID="$!"
if [[ "$STATIC_ONLY" -ne 1 ]]; then
    sleep 2
fi

is_visual_acceptance_label() {
    case "$1" in
        baseline|palette-open|find-open|preview-on|sidebar-hidden|source-editing|table-grid)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

capture_window() {
    local label="$1"
    local png="$SIZE_DIR/$label.png"
    local metadata="$SIZE_DIR/$label.json"
    local capture_error="$SIZE_DIR/.$label-capture.err"
    local visual_probe=""
    local window_identity=""
    local process_windows_at_capture=""
    if [[ "$STATIC_ONLY" -eq 1 || "$EXTENDED_FULL_POINTER" -eq 1 ]] \
        && is_visual_acceptance_label "$label"; then
        visual_probe="$SIZE_DIR/visual-probe-$label.json"
        python3 "$VISUAL_EVIDENCE_BUILDER" wait \
            --diagnostic "$PROFILE_ROOT/Diagnostics/state.json" \
            --contract "$ROOT/scripts/visual/acceptance-contract.json" \
            --app-label "$label" \
            --output "$visual_probe" \
            --timeout 2
    fi
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        window_identity="$SIZE_DIR/window-$label-at-capture.json"
        "$DRIVER" window \
            --pid "$CURRENT_PID" \
            --window-number "$WINDOW_NUMBER" \
            --timeout 2 \
            --include-offscreen \
            --require-offscreen \
            > "$window_identity"
        validate_passive_main_window "$window_identity"
        python3 - "$window_identity" "$WINDOW_NUMBER" <<'PY'
import json
import sys

window = json.load(open(sys.argv[1], encoding="utf-8"))
if window["windowNumber"] != int(sys.argv[2]):
    raise SystemExit("passive capture window identity changed before capture")
PY
        process_windows_at_capture="$SIZE_DIR/process-windows-$label-at-capture.json"
        "$DRIVER" windows \
            --pid "$CURRENT_PID" \
            --include-offscreen \
            > "$process_windows_at_capture"
        validate_passive_process_windows \
            "$process_windows_at_capture" "$window_identity"
    fi
    rm -f "$png"
    for _ in {1..3}; do
        if "$DRIVER" capture-window \
            --pid "$CURRENT_PID" \
            --window-number "$WINDOW_NUMBER" \
            --output "$png" \
            --logical-width "$SIZE_WIDTH" \
            --logical-height "$SIZE_HEIGHT" \
            --timeout 2 \
            > /dev/null 2> "$capture_error" \
            && [[ -s "$png" ]]; then
            break
        fi
        rm -f "$png"
        sleep 0.25
    done
    if [[ ! -s "$png" ]]; then
        echo "run-real-app-e2e.sh: screenshot failed for window $WINDOW_NUMBER ($SIZE)" >&2
        if [[ -s "$capture_error" ]]; then
            sed 's/^/run-real-app-e2e.sh: /' "$capture_error" >&2
        fi
        exit 4
    fi
    rm -f "$capture_error"

    local normalized_png="$SIZE_DIR/.$label-srgb.png"
    rm -f "$normalized_png"
    sips -m "$SRGB_PROFILE" "$png" --out "$normalized_png" >/dev/null
    mv "$normalized_png" "$png"

    local pixel_width pixel_height sha relative_path
    pixel_width="$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    pixel_height="$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    sha="$(shasum -a 256 "$png" | awk '{print $1}')"
    relative_path="${png#"$OUTPUT/"}"
    python3 - \
        "$label" "$relative_path" "$sha" \
        "$SIZE_WIDTH" "$SIZE_HEIGHT" "$pixel_width" "$pixel_height" \
        "$window_identity" "$process_windows_at_capture" \
        > "$metadata" <<'PY'
import json
import math
import pathlib
import sys

label, path, sha = sys.argv[1:4]
logical_width, logical_height, pixel_width, pixel_height = map(float, sys.argv[4:8])
window_identity_path = sys.argv[8]
process_windows_at_capture_path = sys.argv[9]
scale_x = pixel_width / logical_width
scale_y = pixel_height / logical_height
if not math.isclose(scale_x, scale_y, rel_tol=0, abs_tol=0.01):
    raise SystemExit(f"inconsistent screenshot scale: {scale_x} x {scale_y}")
if scale_x < 1:
    raise SystemExit(f"invalid screenshot scale: {scale_x}")
record = {
    "label": label,
    "path": path,
    "sha256": sha,
    "logicalSize": {"width": logical_width, "height": logical_height},
    "pixelSize": {"width": int(pixel_width), "height": int(pixel_height)},
    "backingScale": scale_x,
}
if window_identity_path:
    record["windowIdentityAtCapture"] = json.loads(
        pathlib.Path(window_identity_path).read_text(encoding="utf-8")
    )
if process_windows_at_capture_path:
    record["processWindowsAtCapture"] = json.loads(
        pathlib.Path(process_windows_at_capture_path).read_text(encoding="utf-8")
    )
print(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True))
PY
    if [[ -n "$visual_probe" ]]; then
        local bound_metadata="$SIZE_DIR/.$label-bound.json"
        python3 "$VISUAL_EVIDENCE_BUILDER" bind \
            --probe "$visual_probe" \
            --metadata "$metadata" \
            --evidence-root "$OUTPUT" \
            --output "$bound_metadata"
        mv "$bound_metadata" "$metadata"
    fi
    printf '%s\n' "$metadata" >> "$SCREENSHOT_LIST"
}

register_foreground_checkpoint() {
    local label="$1"
    local raw_png="$2"
    local normalized_png="$SIZE_DIR/$label.png"
    local metadata="$SIZE_DIR/$label.json"
    local checkpoint="$SIZE_DIR/foreground-checkpoint-$label.json"
    if [[ ! -s "$raw_png" ]]; then
        echo "run-real-app-e2e.sh: foreground checkpoint is missing: $raw_png" >&2
        exit 5
    fi

    rm -f "$normalized_png"
    sips -m "$SRGB_PROFILE" "$raw_png" --out "$normalized_png" >/dev/null

    local pixel_width pixel_height sha relative_path raw_sha raw_relative_path
    pixel_width="$(sips -g pixelWidth "$normalized_png" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    pixel_height="$(sips -g pixelHeight "$normalized_png" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    sha="$(shasum -a 256 "$normalized_png" | awk '{print $1}')"
    raw_sha="$(shasum -a 256 "$raw_png" | awk '{print $1}')"
    relative_path="${normalized_png#"$OUTPUT/"}"
    raw_relative_path="${raw_png#"$OUTPUT/"}"
    python3 - \
        "$label" "$relative_path" "$sha" \
        "$SIZE_WIDTH" "$SIZE_HEIGHT" "$pixel_width" "$pixel_height" \
        > "$metadata" <<'PY'
import json
import math
import sys

label, path, sha = sys.argv[1:4]
logical_width, logical_height, pixel_width, pixel_height = map(float, sys.argv[4:8])
scale_x = pixel_width / logical_width
scale_y = pixel_height / logical_height
if not math.isclose(scale_x, scale_y, rel_tol=0, abs_tol=0.01):
    raise SystemExit(f"inconsistent foreground screenshot scale: {scale_x} x {scale_y}")
if scale_x < 1:
    raise SystemExit(f"invalid foreground screenshot scale: {scale_x}")
print(json.dumps({
    "label": label,
    "path": path,
    "sha256": sha,
    "logicalSize": {"width": logical_width, "height": logical_height},
    "pixelSize": {"width": int(pixel_width), "height": int(pixel_height)},
    "backingScale": scale_x,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    python3 - \
        "$label" "$raw_relative_path" "$raw_sha" "$metadata" \
        > "$checkpoint" <<'PY'
import json
import pathlib
import sys

label, raw_path, raw_sha, normalized_path = sys.argv[1:5]
print(json.dumps({
    "label": label,
    "capturedInsideForegroundBatch": True,
    "rawPath": raw_path,
    "rawSHA256": raw_sha,
    "normalized": json.loads(pathlib.Path(normalized_path).read_text(encoding="utf-8")),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$metadata" >> "$SCREENSHOT_LIST"
    printf '%s\n' "$checkpoint" >> "$FOREGROUND_CHECKPOINT_LIST"
}

record_action_with_delay() {
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        echo "run-real-app-e2e.sh: passive tier refuses input actions" >&2
        exit 5
    fi
    local label="$1"
    local delay="$2"
    shift 2
    local raw="$SIZE_DIR/action-$label-driver.json"
    local wrapped="$SIZE_DIR/action-$label.json"
    "$DRIVER" send --pid "$CURRENT_PID" --delay "$delay" -- "$@" > "$raw"
    python3 - "$label" "$raw" > "$wrapped" <<'PY'
import datetime
import json
import sys

label, raw_path = sys.argv[1:3]
with open(raw_path, encoding="utf-8") as handle:
    driver = json.load(handle)
print(json.dumps({
    "label": label,
    "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "driver": driver,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$wrapped" >> "$ACTION_LIST"
}

record_action() {
    local label="$1"
    shift
    record_action_with_delay "$label" "0.22" "$@"
}

record_text_click_action() {
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        echo "run-real-app-e2e.sh: passive tier refuses pointer actions" >&2
        exit 5
    fi
    local label="$1"
    local screenshot_label="$2"
    local requested_text="$3"
    local click_count="${4:-1}"
    local raw="$SIZE_DIR/action-$label-driver.json"
    local wrapped="$SIZE_DIR/action-$label.json"
    "$DRIVER" click-text \
        --pid "$CURRENT_PID" \
        --screenshot "$SIZE_DIR/$screenshot_label.png" \
        --text "$requested_text" \
        --count "$click_count" \
        > "$raw"
    python3 - "$label" "$raw" > "$wrapped" <<'PY'
import datetime
import json
import sys

label, raw_path = sys.argv[1:3]
with open(raw_path, encoding="utf-8") as handle:
    driver = json.load(handle)
print(json.dumps({
    "label": label,
    "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "driver": driver,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$wrapped" >> "$ACTION_LIST"
}

record_comparison() {
    local label="$1"
    local before_label="$2"
    local after_label="$3"
    local minimum_ratio="$4"
    local comparison="$SIZE_DIR/comparison-$label.json"
    "$DRIVER" compare \
        --before "$SIZE_DIR/$before_label.png" \
        --after "$SIZE_DIR/$after_label.png" \
        > "$comparison"
    python3 - "$comparison" "$minimum_ratio" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    comparison = json.load(handle)
minimum = float(sys.argv[2])
actual = comparison["changedPixelRatio"]
if actual < minimum:
    raise SystemExit(f"visual change ratio {actual:.6f} is below required {minimum:.6f}")
PY
    printf '%s\n' "$comparison" >> "$COMPARISON_LIST"
}

record_visual_text_assertion() {
    local label="$1"
    local screenshot_label="$2"
    shift 2
    local assertion="$SIZE_DIR/visual-$label.json"
    "$DRIVER" screenshot-text \
        --screenshot "$SIZE_DIR/$screenshot_label.png" \
        "$@" \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$VISUAL_ASSERTION_LIST"
}

assert_session_marker() {
    local label="$1"
    local marker="$2"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local assertion="$SIZE_DIR/session-$label.json"
    local found=0
    for _ in {1..30}; do
        if [[ -f "$session" ]] && python3 - "$session" "$marker" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    session = json.load(handle)
raise SystemExit(0 if any(sys.argv[2] in tab.get("text", "") for tab in session.get("tabs", [])) else 1)
PY
        then
            found=1
            break
        fi
        sleep 0.1
    done
    if [[ "$found" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: session marker was not persisted: $marker" >&2
        exit 5
    fi
    python3 - "$label" "$marker" "$session" "$OUTPUT" > "$assertion" <<'PY'
import json
import os
import sys

label, marker, session, output = sys.argv[1:5]
print(json.dumps({
    "label": label,
    "marker": marker,
    "persisted": True,
    "sessionPath": os.path.relpath(session, output),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

assert_fixture_source_state() {
    local label="$1"
    local expected_state="$2"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local fixture="$ROOT/ui/格式示例.md"
    local assertion="$SIZE_DIR/session-fixture-$label.json"
    local verifier="$ROOT/scripts/e2e/verify-fixture-session.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" ]] && python3 "$verifier" \
            --session "$session" \
            --fixture "$fixture" \
            --state "$expected_state" \
            --label "$label" \
            --evidence-root "$OUTPUT" \
            >/dev/null 2>&1
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: fixture source did not reach exact $expected_state state" >&2
        exit 5
    fi
    python3 "$verifier" \
        --session "$session" \
        --fixture "$fixture" \
        --state "$expected_state" \
        --label "$label" \
        --evidence-root "$OUTPUT" \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

assert_find_replace_session() {
    local label="$1"
    local expected_state="$2"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local assertion="$SIZE_DIR/session-find-$label.json"
    local verifier="$ROOT/scripts/e2e/verify-find-replace-session.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" ]] && python3 "$verifier" \
            --session "$session" \
            --state "$expected_state" \
            --label "$label" \
            --evidence-root "$OUTPUT" \
            >/dev/null 2>&1
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: find scenario did not reach exact $expected_state state" >&2
        exit 5
    fi
    python3 "$verifier" \
        --session "$session" \
        --state "$expected_state" \
        --label "$label" \
        --evidence-root "$OUTPUT" \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

record_diagnostic_snapshot() {
    local label="$1"
    local expected_mode="${2:-}"
    local expected_query="${3:-}"
    local expected_document="${4-格式示例.md}"
    local expected_block_type="${5:-}"
    local expected_table_cell="${6:-}"
    local expected_selection="${7:-}"
    local source="$PROFILE_ROOT/Diagnostics/state.json"
    local wrapped="$SIZE_DIR/diagnostic-$label.json"
    local ready=0
    for _ in {1..40}; do
        if [[ -s "$source" ]] && python3 - \
            "$source" "$PROFILE_ROOT" "$expected_mode" "$expected_query" "$expected_document" \
            "$expected_block_type" "$expected_table_cell" "$expected_selection" \
            >/dev/null <<'PY'
import json
import pathlib
import sys

(
    source,
    profile_root,
    expected_mode,
    expected_query,
    expected_document,
    expected_block_type,
    expected_table_cell,
    expected_selection,
) = sys.argv[1:9]
state = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
required = {
    "schemaVersion", "document", "blockID", "blockType", "mode", "selection",
    "activeTableCell", "dirty", "find", "outline", "scrollY", "sessionPath",
    "parseCount", "localMutationCount", "renderedBlockUpdateCount",
    "activeBlockRenderUpdateCount", "renderedBlockUpdates", "visual", "updatedAt",
}
if set(state) != required:
    raise SystemExit(1)
if state["document"] != expected_document:
    raise SystemExit(1)
expected_session = pathlib.Path(profile_root) / "Application Support/MarkdownViewer/session.json"
if pathlib.Path(state["sessionPath"]) != expected_session:
    raise SystemExit(1)
if state["renderedBlockUpdateCount"] <= 0 or not state["renderedBlockUpdates"]:
    raise SystemExit(1)
if expected_mode and state["mode"] != expected_mode:
    raise SystemExit(1)
if expected_query and state["find"]["query"] != expected_query:
    raise SystemExit(1)
if expected_block_type == "null" and state["blockType"] is not None:
    raise SystemExit(1)
if expected_block_type not in ("", "null") and state["blockType"] != expected_block_type:
    raise SystemExit(1)
if expected_table_cell == "present" and state["activeTableCell"] is None:
    raise SystemExit(1)
if expected_table_cell == "absent" and state["activeTableCell"] is not None:
    raise SystemExit(1)
if expected_selection == "present" and state["selection"] is None:
    raise SystemExit(1)
if expected_selection == "absent" and state["selection"] is not None:
    raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: diagnostic snapshot did not reach $label state for $SIZE" >&2
        exit 5
    fi
    python3 - "$label" "$source" > "$wrapped" <<'PY'
import json
import pathlib
import sys

label, source = sys.argv[1:3]
print(json.dumps({
    "label": label,
    "snapshot": json.loads(pathlib.Path(source).read_text(encoding="utf-8")),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$wrapped" >> "$DIAGNOSTIC_LIST"
}

record_find_diagnostic_snapshot() {
    local label="$1"
    local expected_query="$2"
    local expected_display="$3"
    local expected_count="$4"
    local expected_index="$5"
    local expected_replace_expanded="$6"
    local expected_whole_word="$7"
    local source="$PROFILE_ROOT/Diagnostics/state.json"
    local wrapped="$SIZE_DIR/diagnostic-$label.json"
    local verifier="$ROOT/scripts/e2e/verify-find-diagnostic.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$source" ]] && python3 "$verifier" \
            --snapshot "$source" \
            --profile-root "$PROFILE_ROOT" \
            --label "$label" \
            --query "$expected_query" \
            --display "$expected_display" \
            --match-count "$expected_count" \
            --current-index "$expected_index" \
            --replace-expanded "$expected_replace_expanded" \
            --whole-word "$expected_whole_word" \
            >/dev/null 2>&1
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: find diagnostic did not reach $label state for $SIZE" >&2
        exit 5
    fi
    python3 "$verifier" \
        --snapshot "$source" \
        --profile-root "$PROFILE_ROOT" \
        --label "$label" \
        --query "$expected_query" \
        --display "$expected_display" \
        --match-count "$expected_count" \
        --current-index "$expected_index" \
        --replace-expanded "$expected_replace_expanded" \
        --whole-word "$expected_whole_word" \
        > "$wrapped"
    printf '%s\n' "$wrapped" >> "$DIAGNOSTIC_LIST"
}

assert_active_session_document() {
    local label="$1"
    local expected_name="$2"
    local expected_markdown="$3"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local assertion="$SIZE_DIR/session-active-$label.json"
    local ready=0
    for _ in {1..40}; do
        if [[ -s "$session" ]] && python3 - \
            "$session" "$expected_name" "$expected_markdown" \
            >/dev/null <<'PY'
import json
import pathlib
import sys

session_path, expected_name, expected_markdown = sys.argv[1:4]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
active_id = session.get("activeTabID")
active = next((tab for tab in session.get("tabs", []) if tab.get("id") == active_id), None)
if not active or active.get("name") != expected_name:
    raise SystemExit(1)
if bool(active.get("isMarkdown")) != (expected_markdown == "true"):
    raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: active session document mismatch for $label" >&2
        exit 5
    fi
    python3 - "$label" "$expected_name" "$expected_markdown" "$session" "$OUTPUT" \
        > "$assertion" <<'PY'
import json
import os
import sys

label, name, markdown, session, output = sys.argv[1:6]
print(json.dumps({
    "label": label,
    "activeDocument": name,
    "isMarkdown": markdown == "true",
    "persisted": True,
    "sessionPath": os.path.relpath(session, output),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

assert_empty_session() {
    local label="$1"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local assertion="$SIZE_DIR/session-empty-$label.json"
    local ready=0
    for _ in {1..40}; do
        if [[ -s "$session" ]] && python3 - "$session" >/dev/null <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if state.get("tabs") != [] or state.get("activeTabID") is not None:
    raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: session did not reach the empty state" >&2
        exit 5
    fi
    python3 - "$label" "$session" "$OUTPUT" > "$assertion" <<'PY'
import json
import os
import sys

label, session, output = sys.argv[1:4]
print(json.dumps({
    "label": label,
    "activeDocument": None,
    "persisted": True,
    "tabCount": 0,
    "sessionPath": os.path.relpath(session, output),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

assert_foreground_palette_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local fixture="$ROOT/ui/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-palette.json"
    local marker="E2E_PALETTE_COMMIT"
    local ready=0
    for _ in {1..50}; do
        if [[ -s "$session" ]] && python3 - \
            "$session" "$fixture" "$FIXTURE_SHA" "$marker" \
            >/dev/null <<'PY'
import hashlib
import json
import pathlib
import sys

session_path, fixture_path, fixture_sha, marker = sys.argv[1:5]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
active_id = session.get("activeTabID")
active = next(
    (tab for tab in session.get("tabs", []) if tab.get("id") == active_id),
    None,
)
if active is None or active.get("name") != "格式示例.md":
    raise SystemExit(1)
if active.get("isDirty") is not True or active.get("text", "").count(marker) != 1:
    raise SystemExit(1)
blocks = active.get("markdownDocument", {}).get("blocks", [])
if sum(block.get("source", "").count(marker) for block in blocks) != 1:
    raise SystemExit(1)
if session.get("fontIndex") != 1:
    raise SystemExit(1)
fixture_bytes = pathlib.Path(fixture_path).read_bytes()
if marker.encode() in fixture_bytes:
    raise SystemExit(1)
if hashlib.sha256(fixture_bytes).hexdigest() != fixture_sha:
    raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground palette commit or font shortcut state was not persisted" >&2
        exit 5
    fi
    python3 - \
        "$session" "$fixture" "$FIXTURE_SHA" "$marker" "$OUTPUT" \
        > "$assertion" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

session_path, fixture_path, fixture_sha, marker, output = sys.argv[1:6]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
active = next(
    tab for tab in session["tabs"] if tab.get("id") == session["activeTabID"]
)
fixture_actual_sha = hashlib.sha256(pathlib.Path(fixture_path).read_bytes()).hexdigest()
print(json.dumps({
    "label": "foreground-palette-session",
    "assertions": {
        "activeEditInputCommittedExactlyOnce": active["text"].count(marker) == 1,
        "activeDocumentDirty": active["isDirty"] is True,
        "blockModelContainsCommittedInputExactlyOnce": sum(
            block.get("source", "").count(marker)
            for block in active["markdownDocument"]["blocks"]
        ) == 1,
        "paletteEnterThenCommandPlusReachedExpectedFontIndex": session["fontIndex"] == 1,
        "readOnlyFixtureUnchanged": fixture_actual_sha == fixture_sha,
    },
    "fontIndex": session["fontIndex"],
    "marker": marker,
    "sessionPath": os.path.relpath(session_path, output),
    "fixtureSHA256": fixture_actual_sha,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
}

record_foreground_palette_diagnostic() {
    local source="$PROFILE_ROOT/Diagnostics/state.json"
    local wrapped="$SIZE_DIR/diagnostic-foreground-palette-completion.json"
    local ready=0
    for _ in {1..40}; do
        if [[ -s "$source" ]] && python3 - "$source" "$PROFILE_ROOT" >/dev/null <<'PY'
import json
import pathlib
import sys

source, profile_root = sys.argv[1:3]
state = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
expected_session = pathlib.Path(profile_root) / "Application Support/MarkdownViewer/session.json"
find = state.get("find", {})
visual = state.get("visual", {})
if state.get("document") != "格式示例.md" or state.get("mode") != "edit":
    raise SystemExit(1)
if pathlib.Path(state.get("sessionPath", "")) != expected_session:
    raise SystemExit(1)
if state.get("dirty") is not True \
        or state.get("blockID") is not None \
        or state.get("blockType") is not None \
        or state.get("selection") is not None \
        or state.get("activeTableCell") is not None:
    raise SystemExit(1)
if find.get("query") != "" \
        or find.get("display") != "" \
        or find.get("matchCount") != 0 \
        or find.get("currentIndex") != 0 \
        or find.get("invalidRegex") is not False \
        or find.get("replaceExpanded") is not False \
        or find.get("wholeWord") is not True:
    raise SystemExit(1)
if visual.get("sidebarVisible") is not True \
        or visual.get("previewActive") is not False \
        or visual.get("paletteVisible") is not False \
        or visual.get("findPanelVisible") is not False \
        or visual.get("replaceRowVisible") is not False \
        or visual.get("sourceEditorVisible") is not False \
        or visual.get("tableGridVisible") is not False:
    raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground palette completion state was not observed" >&2
        exit 5
    fi
    python3 - "$source" > "$wrapped" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({
    "label": "foreground-palette-completion",
    "assertions": {
        "activeEditCommittedBeforePalette": (
            state["dirty"] is True
            and state["blockID"] is None
            and state["selection"] is None
        ),
        "doubleShiftClearedFindQuery": state["find"]["query"] == "",
        "doubleShiftCollapsedReplace": state["find"]["replaceExpanded"] is False,
        "doubleShiftClosedFind": state["visual"]["findPanelVisible"] is False,
        "wholeWordControlWasClicked": state["find"]["wholeWord"] is True,
        "sidebarRestored": state["visual"]["sidebarVisible"] is True,
        "previewRestoredToEdit": state["visual"]["previewActive"] is False,
        "backdropClosedPalette": state["visual"]["paletteVisible"] is False,
        "sourceEditorClosed": state["visual"]["sourceEditorVisible"] is False,
    },
    "snapshot": state,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$wrapped" >> "$DIAGNOSTIC_LIST"
}

run_foreground_palette_find_phase() {
    local phase="$1"
    local phase_dir="$SIZE_DIR/palette-find/$phase"
    local raw_dir="$phase_dir/raw"
    local plan="$phase_dir/foreground-plan.json"
    local plan_validation="$phase_dir/foreground-plan-validation.json"
    local report="$phase_dir/foreground-report.json"
    mkdir -p "$raw_dir"
    python3 "$ROOT/scripts/e2e/build-foreground-smoke-plan.py" \
        --phase "$phase" \
        --raw-dir "$raw_dir" \
        --output "$plan"
    run_foreground_plan_file "$plan" "$plan_validation" "$report"
}

capture_foreground_palette_find_phase_state() {
    local phase="$1"
    local phase_dir="$SIZE_DIR/palette-find/$phase"
    local live_session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local live_diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local session_snapshot="$phase_dir/session.json"
    local diagnostic_snapshot="$phase_dir/diagnostic.json"
    local output="$phase_dir/phase-state.json"
    local error="$phase_dir/phase-state.err"
    local verifier="$ROOT/scripts/e2e/verify-palette-find-phase.py"
    local fixture="$ROOT/ui/格式示例.md"
    local live_args=(
        --phase "$phase"
        --session "$live_session"
        --expected-session-path "$live_session"
        --diagnostic "$live_diagnostic"
        --fixture "$fixture"
        --fixture-sha "$FIXTURE_SHA"
    )
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$live_session" && -s "$live_diagnostic" ]] \
            && python3 "$verifier" "${live_args[@]}" --check-only \
                >/dev/null 2>&1; then
            cp "$live_session" "$session_snapshot"
            cp "$live_diagnostic" "$diagnostic_snapshot"
            if python3 "$verifier" \
                --phase "$phase" \
                --session "$session_snapshot" \
                --expected-session-path "$live_session" \
                --diagnostic "$diagnostic_snapshot" \
                --fixture "$fixture" \
                --fixture-sha "$FIXTURE_SHA" \
                --check-only >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        python3 "$verifier" "${live_args[@]}" --check-only \
            >/dev/null 2> "$error" || true
        echo "run-real-app-e2e.sh: palette-find phase did not persist: $phase" >&2
        if [[ -s "$error" ]]; then
            sed 's/^/  /' "$error" >&2
        fi
        exit 5
    fi
    python3 "$verifier" \
        --phase "$phase" \
        --session "$session_snapshot" \
        --expected-session-path "$live_session" \
        --diagnostic "$diagnostic_snapshot" \
        --fixture "$fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output "$output"
}

write_foreground_palette_find_aggregate() {
    python3 "$ROOT/scripts/e2e/aggregate-foreground-palette-find.py" \
        --phase-root "$SIZE_DIR/palette-find" \
        --output-validation "$SIZE_DIR/foreground-plan-validation.json" \
        --output-report "$SIZE_DIR/foreground-report.json" \
        --budget-ms 4000
}

assert_foreground_palette_find_completion() {
    local phase_dir="$SIZE_DIR/palette-find/palette-keyboard"
    local session="$phase_dir/session.json"
    local diagnostic="$phase_dir/diagnostic.json"
    local report="$SIZE_DIR/foreground-report.json"
    local fixture="$ROOT/ui/格式示例.md"
    local verifier="$ROOT/scripts/e2e/verify-foreground-palette-find.py"
    local session_assertion="$SIZE_DIR/session-foreground-palette.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-palette-completion.json"
    local verifier_args=(
        --session "$session"
        --diagnostic "$diagnostic"
        --foreground-report "$report"
        --fixture "$fixture"
        --fixture-sha "$FIXTURE_SHA"
        --output-root "$OUTPUT"
    )
    python3 "$verifier" "${verifier_args[@]}" --check-only
    python3 "$verifier" \
        "${verifier_args[@]}" \
        --report-kind session \
        > "$session_assertion"
    python3 "$verifier" \
        "${verifier_args[@]}" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$session_assertion" >> "$SESSION_ASSERTION_LIST"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_plan_file() {
    local plan="$1"
    local plan_validation="$2"
    local report="$3"
    local window_after="$(dirname "$report")/foreground-window-after.json"
    "$DRIVER" foreground-batch-plan \
        --plan "$plan" \
        --budget "$FOREGROUND_BUDGET" \
        > "$plan_validation"
    "$DRIVER" foreground-batch \
        --pid "$CURRENT_PID" \
        --launch-token "$CURRENT_LAUNCH_TOKEN" \
        --plan "$plan" \
        --budget "$FOREGROUND_BUDGET" \
        --width "$SIZE_WIDTH" \
        --height "$SIZE_HEIGHT" \
        > "$report"
    "$DRIVER" window \
        --pid "$CURRENT_PID" \
        --timeout 3 \
        --width "$SIZE_WIDTH" \
        --height "$SIZE_HEIGHT" \
        --allow-uniform-presentation-scale \
        --include-offscreen \
        --require-offscreen \
        --main-window-only \
        > "$window_after"
    python3 - "$report" "$plan" "$FOREGROUND_BUDGET" "$window_after" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
plan = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
budget_ms = float(sys.argv[3]) * 1000
window_after = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
required = {
    "pid", "durationMs", "budgetMs", "targetActivationRequestCount", "completed",
    "actions", "interference", "deadlineExceeded", "focusRestore",
    "pointerRestore", "pasteboardRestore",
}
if not required.issubset(report):
    raise SystemExit("foreground report is missing required fields")
if report["completed"] is not True:
    raise SystemExit(report.get("error") or "foreground batch did not complete")
if report["deadlineExceeded"] is not False:
    raise SystemExit("foreground batch exceeded its deadline")
if report.get("error") not in {None, ""}:
    raise SystemExit(f"foreground batch reported an unexpected error: {report['error']}")
if report["targetActivationRequestCount"] != 1:
    raise SystemExit("foreground batch did not use exactly one activation")
if report["durationMs"] > budget_ms or report["budgetMs"] > budget_ms:
    raise SystemExit("foreground report exceeds the requested budget")
if report["interference"].get("detected") is not False:
    raise SystemExit("foreground batch detected user interference")
if report["interference"].get("pointerInputDetected") is not False:
    raise SystemExit("foreground batch detected pointer interference")
if report["interference"].get("pointerPositionInterferenceDetected") is not False:
    raise SystemExit("foreground batch detected pointer position interference")
if report["interference"].get("eventTapReliable") is not True:
    raise SystemExit("foreground batch interference monitor became unreliable")
if report["focusRestore"].get("restored") is not True \
        or report["focusRestore"].get("attempted") is not True \
        or report["focusRestore"].get("priorPID") == report["pid"]:
    raise SystemExit("foreground batch did not restore focus")
if report["pointerRestore"].get("restored") is not True \
        or report["pointerRestore"].get("attempted") is not True:
    raise SystemExit("foreground batch did not restore the pointer")
if window_after.get("pid") != report["pid"] \
        or window_after.get("onScreen") is not False \
        or window_after.get("layer") != 0:
    raise SystemExit("foreground target window did not return offscreen at normal level")
uses_pasteboard = any(
    action.get("kind") == "pasteboard-string-check"
    for action in plan["actions"]
)
if report["pasteboardRestore"].get("restored") is not True \
        or report["pasteboardRestore"].get("attempted") is not uses_pasteboard:
    raise SystemExit("foreground batch did not preserve the pasteboard")
planned_kinds = [action["kind"] for action in plan["actions"]]
reported_kinds = [action.get("kind") for action in report["actions"]]
reported_indexes = [action.get("index") for action in report["actions"]]
if reported_kinds != planned_kinds \
        or reported_indexes != list(range(len(planned_kinds))) \
        or any(action.get("status") != "completed" for action in report["actions"]):
    raise SystemExit("foreground batch did not complete every planned action")
PY
}

run_bounded_foreground_plan() {
    local builder="$1"
    local plan="$SIZE_DIR/foreground-plan.json"
    local plan_validation="$SIZE_DIR/foreground-plan-validation.json"
    local report="$SIZE_DIR/foreground-report.json"
    local raw_dir="$SIZE_DIR/foreground-raw"
    mkdir -p "$raw_dir"
    python3 "$builder" \
        --raw-dir "$raw_dir" \
        --output "$plan"
    run_foreground_plan_file "$plan" "$plan_validation" "$report"
}

run_foreground_block_activation() {
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-block-activation-plan.py"
    assert_foreground_element_reports
}

verify_tab_session_stage() {
    local stage="$1"
    local previous_session="${2:-}"
    local previous_diagnostic="${3:-}"
    local verifier="$ROOT/scripts/e2e/verify-tab-session-lifecycle.py"
    local live_session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local live_diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local stage_dir="$SIZE_DIR/tab-session/$stage"
    local session_snapshot="$stage_dir/session.json"
    local diagnostic_snapshot="$stage_dir/diagnostic.json"
    local session_assertion="$stage_dir/session-assertion.json"
    local diagnostic_assertion="$stage_dir/diagnostic-assertion.json"
    local verification_error="$stage_dir/verification.err"
    mkdir -p "$stage_dir"
    local verifier_options=(
        --stage "$stage"
        --session "$session_snapshot"
        --expected-session-path "$live_session"
        --diagnostic "$diagnostic_snapshot"
        --fixture "$fixture"
        --workspace-fixture "$workspace_fixture"
        --fixture-sha "$FIXTURE_SHA"
        --output-root "$OUTPUT"
    )
    if [[ -n "$previous_session" ]]; then
        verifier_options+=(--previous-session "$previous_session")
    fi
    if [[ -n "$previous_diagnostic" ]]; then
        verifier_options+=(--previous-diagnostic "$previous_diagnostic")
    fi
    local ready=0
    local attempt
    for attempt in {1..80}; do
        if [[ -s "$live_session" && -s "$live_diagnostic" ]]; then
            cp "$live_session" "$session_snapshot"
            cp "$live_diagnostic" "$diagnostic_snapshot"
            if python3 "$verifier" \
                "${verifier_options[@]}" \
                --check-only \
                >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        python3 "$verifier" \
            "${verifier_options[@]}" \
            --check-only \
            2> "$verification_error" || true
        echo "run-real-app-e2e.sh: tab/session stage did not stabilize: $stage" >&2
        tail -n 20 "$verification_error" >&2 || true
        exit 5
    fi
    python3 "$verifier" \
        "${verifier_options[@]}" \
        --report-kind session \
        > "$session_assertion"
    python3 "$verifier" \
        "${verifier_options[@]}" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$session_assertion" >> "$SESSION_ASSERTION_LIST"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
    TAB_SESSION_STAGE_SESSION="$session_snapshot"
    TAB_SESSION_STAGE_DIAGNOSTIC="$diagnostic_snapshot"
}

run_foreground_palette_find() {
    local block_find_raw_dir="$SIZE_DIR/palette-find/block-find/raw"
    local palette_raw_dir="$SIZE_DIR/palette-find/palette-keyboard/raw"
    run_foreground_palette_find_phase "block-find"
    capture_foreground_palette_find_phase_state "block-find"
    run_foreground_palette_find_phase "palette-keyboard"
    capture_foreground_palette_find_phase_state "palette-keyboard"
    write_foreground_palette_find_aggregate

    register_foreground_checkpoint \
        "active-edit-palette" "$block_find_raw_dir/active-edit-palette.png"
    register_foreground_checkpoint \
        "find-populated" "$block_find_raw_dir/find-populated.png"
    register_foreground_checkpoint \
        "palette-filter-default" "$palette_raw_dir/palette-filter-default.png"
    register_foreground_checkpoint \
        "palette-hover" "$palette_raw_dir/palette-hover.png"
    # From this point onward the driver has restored the user's focus and pointer.
    # The remaining checks inspect files or screenshots without posting input.
    record_comparison "foreground-active-edit-palette" \
        "baseline" "active-edit-palette" "0.10"
    record_comparison "foreground-find-populated" \
        "baseline" "find-populated" "0.005"
    record_comparison "foreground-double-shift-palette" \
        "find-populated" "palette-filter-default" "0.10"
    record_comparison "foreground-palette-hover-selection" \
        "palette-filter-default" "palette-hover" "0.01"
    record_visual_text_assertion \
        "foreground-active-edit-palette" "active-edit-palette" \
        --contains "搜索文档或命令"
    record_visual_text_assertion \
        "foreground-find-populated" "find-populated" \
        --contains "一级标题" \
        --contains "E2E_REPLACE" \
        --contains "替换"
    record_visual_text_assertion \
        "foreground-palette-filter-default" "palette-filter-default" \
        --contains "放大字号" \
        --contains "缩小字号" \
        --contains "重置字号"
    record_visual_text_assertion \
        "foreground-palette-hover" "palette-hover" \
        --contains "放大字号" \
        --contains "缩小字号" \
        --contains "重置字号"
    assert_foreground_palette_find_completion
}

assert_foreground_find_session() {
    local scenario="$1"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-$scenario.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-$scenario.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-find-session.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && "$verifier" \
            --scenario "$scenario" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        local detail="$SIZE_DIR/foreground-$scenario-verification.err"
        "$verifier" \
            --scenario "$scenario" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>"$detail" || true
        echo "run-real-app-e2e.sh: foreground $scenario state was not persisted or diagnosed" >&2
        if [[ -s "$detail" ]]; then
            sed 's/^/  /' "$detail" >&2
        fi
        exit 5
    fi
    "$verifier" \
        --scenario "$scenario" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind session \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    "$verifier" \
        --scenario "$scenario" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_find_options() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-find-options-plan.py"

    register_foreground_checkpoint \
        "find-options-composed" "$raw_dir/find-options-composed.png"
    record_comparison "foreground-find-options" \
        "baseline" "find-options-composed" "0.005"
    record_visual_text_assertion \
        "foreground-find-options-composed" "find-options-composed" \
        --contains "redwood"
    assert_foreground_element_reports
    assert_foreground_find_session "find-options"
}

run_foreground_find_regex_replace() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-find-regex-plan.py"

    register_foreground_checkpoint \
        "find-regex-current" "$raw_dir/find-regex-current.png"
    register_foreground_checkpoint \
        "find-regex-final" "$raw_dir/find-regex-final.png"
    record_comparison "foreground-find-regex-all" \
        "find-regex-current" "find-regex-final" "0.00001"
    record_visual_text_assertion \
        "foreground-find-regex-current" "find-regex-current" \
        --contains "Current:Ada" \
        --contains "Name:Bob"
    record_visual_text_assertion \
        "foreground-find-regex-final" "find-regex-final" \
        --contains "Current:Ada" \
        --contains "All:Bob" \
        --contains "All:Cy"
    assert_foreground_element_reports
    assert_foreground_find_session "find-regex-replace"
}

assert_foreground_preview_content_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-preview-content.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-preview-content.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-preview-content.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        local detail="$SIZE_DIR/foreground-preview-content-verification.err"
        "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>"$detail" || true
        echo "run-real-app-e2e.sh: foreground preview-content state was not persisted or diagnosed" >&2
        if [[ -s "$detail" ]]; then
            sed 's/^/  /' "$detail" >&2
        fi
        exit 5
    fi
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind session \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_preview_content() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-preview-content-plan.py"

    register_foreground_checkpoint \
        "preview-content-on" "$raw_dir/preview-content-on.png"
    register_foreground_checkpoint \
        "preview-task-toggled" "$raw_dir/preview-task-toggled.png"
    register_foreground_checkpoint \
        "preview-code-copied" "$raw_dir/preview-code-copied.png"
    register_foreground_checkpoint \
        "preview-content-returned" "$raw_dir/preview-content-returned.png"
    record_comparison "foreground-preview-enabled" \
        "baseline" "preview-content-on" "0.005"
    record_comparison "foreground-preview-task" \
        "preview-content-on" "preview-task-toggled" "0.00001"
    record_comparison "foreground-preview-code-copy" \
        "preview-task-toggled" "preview-code-copied" "0.00001"
    record_comparison "foreground-preview-returned" \
        "preview-code-copied" "preview-content-returned" "0.005"
    record_visual_text_assertion \
        "foreground-preview-enabled" "preview-content-on" \
        --contains "编辑"
    record_visual_text_assertion \
        "foreground-preview-task" "preview-task-toggled" \
        --contains "协同编辑"
    record_visual_text_assertion \
        "foreground-preview-code-copy" "preview-code-copied" \
        --contains "BASH" \
        --contains "复制" \
        --contains "已复制代码"
    record_visual_text_assertion \
        "foreground-preview-returned" "preview-content-returned" \
        --contains "预览"
    assert_foreground_element_reports
    assert_foreground_preview_content_session
}

assert_foreground_preview_footnotes_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-preview-footnotes.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-preview-footnotes.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-preview-footnotes.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        local detail="$SIZE_DIR/foreground-preview-footnotes-verification.err"
        "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>"$detail" || true
        echo "run-real-app-e2e.sh: foreground preview-footnotes state was not persisted or diagnosed" >&2
        if [[ -s "$detail" ]]; then
            sed 's/^/  /' "$detail" >&2
        fi
        exit 5
    fi
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind session \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_preview_footnotes() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-preview-footnotes-plan.py"

    register_foreground_checkpoint \
        "preview-footnotes-on" "$raw_dir/preview-footnotes-on.png"
    register_foreground_checkpoint \
        "preview-footnote-hover" "$raw_dir/preview-footnote-hover.png"
    register_foreground_checkpoint \
        "preview-footnote-definition" "$raw_dir/preview-footnote-definition.png"
    register_foreground_checkpoint \
        "preview-footnote-return" "$raw_dir/preview-footnote-return.png"
    register_foreground_checkpoint \
        "preview-footnotes-returned" "$raw_dir/preview-footnotes-returned.png"
    record_comparison "foreground-preview-footnotes-enabled" \
        "baseline" "preview-footnotes-on" "0.005"
    record_comparison "foreground-preview-footnote-hover" \
        "preview-footnotes-on" "preview-footnote-hover" "0.00001"
    record_comparison "foreground-preview-footnote-definition" \
        "preview-footnote-hover" "preview-footnote-definition" "0.00001"
    record_comparison "foreground-preview-footnote-return" \
        "preview-footnote-definition" "preview-footnote-return" "0.00001"
    record_comparison "foreground-preview-footnotes-returned" \
        "preview-footnote-return" "preview-footnotes-returned" "0.005"
    record_visual_text_assertion \
        "foreground-preview-footnotes-enabled" "preview-footnotes-on" \
        --contains "编辑"
    record_visual_text_assertion \
        "foreground-preview-footnote-hover" "preview-footnote-hover" \
        --contains "由 John Gruber 于 2004 年提出"
    record_visual_text_assertion \
        "foreground-preview-footnote-definition" "preview-footnote-definition" \
        --contains "脚注" \
        --contains "由 John Gruber 于 2004 年提出"
    record_visual_text_assertion \
        "foreground-preview-footnote-return" "preview-footnote-return" \
        --contains "Markdown 是一种轻量级标记语言"
    record_visual_text_assertion \
        "foreground-preview-footnotes-returned" "preview-footnotes-returned" \
        --contains "预览"
    assert_foreground_element_reports
    assert_foreground_preview_footnotes_session
}

assert_foreground_outline_navigation_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-outline-navigation.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-outline-navigation.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-outline-navigation.py"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        local detail="$SIZE_DIR/foreground-outline-navigation-verification.err"
        "$verifier" \
            --session "$session" \
            --diagnostic "$diagnostic" \
            --fixture "$fixture" \
            --workspace-fixture "$workspace_fixture" \
            --fixture-sha "$FIXTURE_SHA" \
            --output-root "$OUTPUT" \
            --check-only \
            >/dev/null 2>"$detail" || true
        echo "run-real-app-e2e.sh: foreground outline-navigation state was not persisted or diagnosed" >&2
        if [[ -s "$detail" ]]; then
            sed 's/^/  /' "$detail" >&2
        fi
        exit 5
    fi
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind session \
        > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    "$verifier" \
        --session "$session" \
        --diagnostic "$diagnostic" \
        --fixture "$fixture" \
        --workspace-fixture "$workspace_fixture" \
        --fixture-sha "$FIXTURE_SHA" \
        --output-root "$OUTPUT" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_outline_navigation() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-outline-navigation-plan.py"

    register_foreground_checkpoint \
        "outline-navigation-expanded" "$raw_dir/outline-expanded.png"
    register_foreground_checkpoint \
        "outline-navigation-in-flight" "$raw_dir/outline-jump-in-flight.png"
    register_foreground_checkpoint \
        "outline-navigation-wash-peak" "$raw_dir/outline-wash-peak.png"
    register_foreground_checkpoint \
        "outline-navigation-wash-fading" "$raw_dir/outline-wash-fading.png"
    register_foreground_checkpoint \
        "outline-navigation-wash-cleared" "$raw_dir/outline-wash-cleared.png"
    record_comparison "foreground-outline-expanded" \
        "baseline" "outline-navigation-expanded" "0.001"
    record_comparison "foreground-outline-jump-in-flight" \
        "outline-navigation-expanded" "outline-navigation-in-flight" "0.005"
    record_comparison "foreground-outline-wash-peak" \
        "outline-navigation-in-flight" "outline-navigation-wash-peak" "0.005"
    record_comparison "foreground-outline-wash-fading" \
        "outline-navigation-wash-peak" "outline-navigation-wash-fading" "0.00001"
    record_comparison "foreground-outline-wash-cleared" \
        "outline-navigation-wash-fading" "outline-navigation-wash-cleared" "0.00001"
    record_visual_text_assertion \
        "foreground-outline-expanded" "outline-navigation-expanded" \
        --contains "Markdown 全格式示例" \
        --contains "表格" \
        --contains "脚注"
    record_visual_text_assertion \
        "foreground-outline-wash-peak" "outline-navigation-wash-peak" \
        --contains "表格" \
        --contains "快捷键"
    record_visual_text_assertion \
        "foreground-outline-wash-fading" "outline-navigation-wash-fading" \
        --contains "表格" \
        --contains "快捷键"
    record_visual_text_assertion \
        "foreground-outline-wash-cleared" "outline-navigation-wash-cleared" \
        --contains "表格" \
        --contains "快捷键"
    assert_foreground_element_reports
    assert_foreground_outline_navigation_session
}

assert_foreground_sidebar_state() {
    local scenario="$1"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_root="$PROFILE_ROOT/Temporary/Workspace"
    local foreground_report="$SIZE_DIR/foreground-report.json"
    local assertion="$SIZE_DIR/session-foreground-$scenario.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-$scenario.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-sidebar.py"
    local verifier_args=(
        --scenario "$scenario"
        --session "$session"
        --diagnostic "$diagnostic"
        --foreground-report "$foreground_report"
        --fixture "$fixture"
        --workspace-root "$workspace_root"
        --fixture-sha "$FIXTURE_SHA"
        --output-root "$OUTPUT"
    )
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" && -s "$foreground_report" ]] \
            && "$verifier" "${verifier_args[@]}" --check-only \
                >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        local detail="$SIZE_DIR/foreground-$scenario-verification.err"
        "$verifier" "${verifier_args[@]}" --check-only \
            >/dev/null 2>"$detail" || true
        echo "run-real-app-e2e.sh: foreground $scenario state was not persisted or diagnosed" >&2
        if [[ -s "$detail" ]]; then
            sed 's/^/  /' "$detail" >&2
        fi
        exit 5
    fi
    "$verifier" "${verifier_args[@]}" --report-kind session > "$assertion"
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    "$verifier" "${verifier_args[@]}" --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_sidebar_filter_navigation() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-sidebar-filter-plan.py"

    register_foreground_checkpoint \
        "sidebar-filter-name" "$raw_dir/sidebar-filter-name.png"
    register_foreground_checkpoint \
        "sidebar-filter-path" "$raw_dir/sidebar-filter-path.png"
    register_foreground_checkpoint \
        "sidebar-filter-empty" "$raw_dir/sidebar-filter-empty.png"
    register_foreground_checkpoint \
        "sidebar-filter-readme" "$raw_dir/sidebar-filter-readme.png"
    register_foreground_checkpoint \
        "sidebar-filter-fixture" "$raw_dir/sidebar-filter-fixture.png"
    register_foreground_checkpoint \
        "sidebar-filter-cleared" "$raw_dir/sidebar-filter-cleared.png"
    record_comparison "foreground-sidebar-filter-name" \
        "baseline" "sidebar-filter-name" "0.00001"
    record_comparison "foreground-sidebar-filter-path" \
        "sidebar-filter-name" "sidebar-filter-path" "0.00001"
    record_comparison "foreground-sidebar-filter-empty" \
        "sidebar-filter-path" "sidebar-filter-empty" "0.00001"
    record_comparison "foreground-sidebar-filter-readme" \
        "sidebar-filter-empty" "sidebar-filter-readme" "0.005"
    record_comparison "foreground-sidebar-filter-fixture" \
        "sidebar-filter-readme" "sidebar-filter-fixture" "0.005"
    record_comparison "foreground-sidebar-filter-cleared" \
        "sidebar-filter-fixture" "sidebar-filter-cleared" "0.00001"
    record_visual_text_assertion \
        "foreground-sidebar-filter-name" "sidebar-filter-name" \
        --contains "格式示例.md"
    record_visual_text_assertion \
        "foreground-sidebar-filter-path" "sidebar-filter-path" \
        --contains "config.yaml" \
        --contains "docs"
    record_visual_text_assertion \
        "foreground-sidebar-filter-empty" "sidebar-filter-empty" \
        --contains "没有匹配的文档"
    record_visual_text_assertion \
        "foreground-sidebar-filter-readme" "sidebar-filter-readme" \
        --contains "Markdown Editor"
    record_visual_text_assertion \
        "foreground-sidebar-filter-fixture" "sidebar-filter-fixture" \
        --contains "Markdown 全格式示例"
    record_visual_text_assertion \
        "foreground-sidebar-filter-cleared" "sidebar-filter-cleared" \
        --contains "config.yaml" \
        --contains "README.md" \
        --contains "更新日志.md"
    assert_foreground_element_reports
    assert_foreground_sidebar_state "sidebar-filter-navigation"
}

run_foreground_sidebar_layout_phase() {
    local phase="$1"
    local phase_dir="$SIZE_DIR/sidebar-layout/$phase"
    local raw_dir="$phase_dir/raw"
    local plan="$phase_dir/foreground-plan.json"
    local plan_validation="$phase_dir/foreground-plan-validation.json"
    local report="$phase_dir/foreground-report.json"
    mkdir -p "$raw_dir"
    python3 "$ROOT/scripts/e2e/build-foreground-sidebar-layout-plan.py" \
        --phase "$phase" \
        --raw-dir "$raw_dir" \
        --output "$plan"
    run_foreground_plan_file "$plan" "$plan_validation" "$report"
}

verify_foreground_sidebar_resize_phase() {
    local phase="$1"
    local phase_dir="$SIZE_DIR/sidebar-layout/$phase"
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local pointer_trace="$PROFILE_ROOT/Diagnostics/pointer-trace.json"
    local output="$phase_dir/resize-state.json"
    local error="$phase_dir/resize-state.err"
    local session_snapshot="$phase_dir/session.json"
    local diagnostic_snapshot="$phase_dir/diagnostic.json"
    local pointer_trace_snapshot="$phase_dir/pointer-trace.json"
    local verifier="$ROOT/scripts/e2e/verify-sidebar-resize-phase.py"
    local verifier_args=(
        --phase "$phase"
        --session "$session"
        --diagnostic "$diagnostic"
        --pointer-trace "$pointer_trace"
    )
    local ready=0
    for _ in {1..80}; do
        if [[ -s "$session" && -s "$diagnostic" && -s "$pointer_trace" ]] \
            && python3 "$verifier" "${verifier_args[@]}" --check-only \
                >/dev/null 2>&1; then
            cp "$session" "$session_snapshot"
            cp "$diagnostic" "$diagnostic_snapshot"
            cp "$pointer_trace" "$pointer_trace_snapshot"
            if python3 "$verifier" \
                --phase "$phase" \
                --session "$session_snapshot" \
                --expected-session-path "$session" \
                --diagnostic "$diagnostic_snapshot" \
                --pointer-trace "$pointer_trace_snapshot" \
                --check-only >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        python3 "$verifier" "${verifier_args[@]}" --check-only \
            >/dev/null 2> "$error" || true
        echo "run-real-app-e2e.sh: sidebar resize phase did not persist: $phase" >&2
        if [[ -s "$error" ]]; then
            sed 's/^/  /' "$error" >&2
        fi
        exit 5
    fi
    python3 "$verifier" \
        --phase "$phase" \
        --session "$session_snapshot" \
        --expected-session-path "$session" \
        --diagnostic "$diagnostic_snapshot" \
        --pointer-trace "$pointer_trace_snapshot" \
        --output "$output"
}

write_foreground_sidebar_layout_aggregate() {
    python3 "$ROOT/scripts/e2e/aggregate-foreground-sidebar-layout.py" \
        --phase-root "$SIZE_DIR/sidebar-layout" \
        --output-validation "$SIZE_DIR/foreground-plan-validation.json" \
        --output-report "$SIZE_DIR/foreground-report.json" \
        --budget-ms 4000
}

run_foreground_sidebar_layout_controls() {
    local collapse_raw_dir="$SIZE_DIR/sidebar-layout/collapse-minimum/raw"
    local maximum_raw_dir="$SIZE_DIR/sidebar-layout/maximum-toggle/raw"
    run_foreground_sidebar_layout_phase "collapse-minimum"
    assert_foreground_element_reports \
        "$SIZE_DIR/sidebar-layout/collapse-minimum/foreground-report.json" \
        "$SIZE_DIR/sidebar-layout/collapse-minimum/foreground-plan.json" \
        "$SIZE_DIR/sidebar-layout/collapse-minimum/foreground-window-after.json"
    verify_foreground_sidebar_resize_phase "collapse-minimum"
    run_foreground_sidebar_layout_phase "maximum-toggle"
    assert_foreground_element_reports \
        "$SIZE_DIR/sidebar-layout/maximum-toggle/foreground-report.json" \
        "$SIZE_DIR/sidebar-layout/maximum-toggle/foreground-plan.json" \
        "$SIZE_DIR/sidebar-layout/maximum-toggle/foreground-window-after.json"
    verify_foreground_sidebar_resize_phase "maximum-toggle"
    write_foreground_sidebar_layout_aggregate

    register_foreground_checkpoint \
        "sidebar-folder-collapsed" \
        "$collapse_raw_dir/sidebar-folder-collapsed.png"
    register_foreground_checkpoint \
        "sidebar-width-minimum" \
        "$collapse_raw_dir/sidebar-width-minimum.png"
    register_foreground_checkpoint \
        "sidebar-width-maximum" \
        "$maximum_raw_dir/sidebar-width-maximum.png"
    register_foreground_checkpoint \
        "sidebar-layout-hidden" "$maximum_raw_dir/sidebar-hidden.png"
    register_foreground_checkpoint \
        "sidebar-shown-maximum" \
        "$maximum_raw_dir/sidebar-shown-maximum.png"
    record_comparison "foreground-sidebar-folder-collapse" \
        "baseline" "sidebar-folder-collapsed" "0.00001"
    record_comparison "foreground-sidebar-resize-minimum" \
        "sidebar-folder-collapsed" "sidebar-width-minimum" "0.01"
    record_comparison "foreground-sidebar-resize-maximum" \
        "sidebar-width-minimum" "sidebar-width-maximum" "0.01"
    record_comparison "foreground-sidebar-hide" \
        "sidebar-width-maximum" "sidebar-layout-hidden" "0.02"
    record_comparison "foreground-sidebar-show" \
        "sidebar-layout-hidden" "sidebar-shown-maximum" "0.02"
    record_visual_text_assertion \
        "foreground-sidebar-folder-collapsed" "sidebar-folder-collapsed" \
        --contains "docs" \
        --not-contains "config.yaml"
    record_visual_text_assertion \
        "foreground-sidebar-width-minimum" "sidebar-width-minimum" \
        --contains "config.yaml"
    record_visual_text_assertion \
        "foreground-sidebar-width-maximum" "sidebar-width-maximum" \
        --contains "config.yaml" \
        --contains "README.md"
    record_visual_text_assertion \
        "foreground-sidebar-hidden" "sidebar-layout-hidden" \
        --not-contains "筛选文档" \
        --not-contains "全部命令"
    record_visual_text_assertion \
        "foreground-sidebar-shown" "sidebar-shown-maximum" \
        --contains "筛选文档" \
        --contains "config.yaml" \
        --contains "全部命令"
    assert_foreground_sidebar_state "sidebar-layout-controls"
}

assert_foreground_table_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-table.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-table-completion.json"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && python3 - \
            "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" \
            >/dev/null <<'PY'
import hashlib
import json
import math
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
expected = fixture.replace(
    "| ⌘B | 加粗 | 全部 |",
    "| E2E_TABLE | 加粗 | 全部 |",
    1,
)
active = next(
    (tab for tab in session.get("tabs", []) if tab.get("id") == session.get("activeTabID")),
    None,
)
if active is None or active.get("name") != "格式示例.md":
    raise SystemExit(1)
blocks = active.get("markdownDocument", {}).get("blocks", [])
trailing = active.get("markdownDocument", {}).get("trailingTrivia", "")
rebuilt = "".join(
    block.get("leadingTrivia", "") + block.get("source", "")
    for block in blocks
) + trailing
if active.get("isMarkdown") is not True \
        or active.get("isDirty") is not True \
        or active.get("text") != expected \
        or rebuilt != expected \
        or len(blocks) != 37 \
        or blocks[28].get("kind") != "table" \
        or blocks[28].get("source", "").count("E2E_TABLE") != 1 \
        or "| --- | --- | :---: |" not in blocks[28].get("source", "") \
        or not math.isclose(float(active.get("scrollY", -1)), 2326, abs_tol=0.5):
    raise SystemExit(1)
visual = diagnostic.get("visual", {})
find = diagnostic.get("find", {})
if diagnostic.get("schemaVersion") != 1 \
        or diagnostic.get("document") != "格式示例.md" \
        or diagnostic.get("mode") != "edit" \
        or diagnostic.get("blockID") is not None \
        or diagnostic.get("blockType") is not None \
        or diagnostic.get("selection") is not None \
        or diagnostic.get("activeTableCell") is not None \
        or diagnostic.get("dirty") is not True \
        or diagnostic.get("localMutationCount") != 8 \
        or diagnostic.get("parseCount") != 9 \
        or not math.isclose(float(diagnostic.get("scrollY", -1)), 2326, abs_tol=0.5) \
        or find.get("query") != "" \
        or find.get("display") != "" \
        or find.get("matchCount") != 0 \
        or find.get("currentIndex") != 0 \
        or find.get("invalidRegex") is not False \
        or find.get("replaceExpanded") is not False \
        or find.get("caseSensitive") is not False \
        or find.get("wholeWord") is not False \
        or find.get("regex") is not False \
        or visual.get("documentVisible") is not True \
        or visual.get("sidebarVisible") is not True \
        or visual.get("paletteVisible") is not False \
        or visual.get("palettePresentation") != "inline-main" \
        or visual.get("findPanelVisible") is not False \
        or visual.get("replaceRowVisible") is not False \
        or visual.get("previewActive") is not False \
        or visual.get("sourceEditorVisible") is not False \
        or visual.get("tableGridVisible") is not False:
    raise SystemExit(1)
for path in (fixture_path, workspace_path):
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != fixture_sha:
        raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground table state was not persisted or diagnosed" >&2
        exit 5
    fi
    python3 - \
        "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" "$OUTPUT" \
        > "$assertion" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha, output = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
expected = fixture.replace(
    "| ⌘B | 加粗 | 全部 |",
    "| E2E_TABLE | 加粗 | 全部 |",
    1,
)
active = next(tab for tab in session["tabs"] if tab.get("id") == session["activeTabID"])
blocks = active["markdownDocument"]["blocks"]
rebuilt = "".join(
    block.get("leadingTrivia", "") + block["source"]
    for block in blocks
) + active["markdownDocument"].get("trailingTrivia", "")
fixture_hash = hashlib.sha256(pathlib.Path(fixture_path).read_bytes()).hexdigest()
workspace_hash = hashlib.sha256(pathlib.Path(workspace_path).read_bytes()).hexdigest()
print(json.dumps({
    "label": "foreground-table-session",
    "assertions": {
        "activeDocumentIsFixtureCopy": active["name"] == "格式示例.md" and active["isMarkdown"],
        "activeDocumentDirty": active["isDirty"] is True,
        "onlyExpectedCellChanged": active["text"] == expected,
        "blockModelRoundTripsExactly": rebuilt == expected,
        "blockCountPreserved": len(blocks) == 37,
        "firstTablePreservedAtStableIndex": blocks[28]["kind"] == "table",
        "tableControlsNetShapeAndAlignmentPreserved": (
            blocks[28]["source"].count("\n") == 5
            and "| --- | --- | :---: |" in blocks[28]["source"]
        ),
        "escapeClosedGrid": (
            diagnostic["activeTableCell"] is None
            and diagnostic["visual"]["tableGridVisible"] is False
        ),
        "eightLocalTableMutationsRecorded": (
            diagnostic["localMutationCount"] == 8
            and diagnostic["parseCount"] == 9
        ),
        "scrollPositionPreserved": (
            math.isclose(active["scrollY"], 2326, abs_tol=0.5)
            and math.isclose(diagnostic["scrollY"], 2326, abs_tol=0.5)
        ),
        "bundleFixtureUnchanged": fixture_hash == fixture_sha,
        "workspaceFixtureUnchanged": workspace_hash == fixture_sha,
    },
    "sessionPath": os.path.relpath(session_path, output),
    "fixtureSHA256": fixture_hash,
    "workspaceFixtureSHA256": workspace_hash,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    python3 - "$diagnostic" > "$diagnostic_assertion" <<'PY'
import json
import pathlib
import sys

snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({
    "label": "foreground-table-completion",
    "assertions": {
        "escapeClosedGrid": (
            snapshot["blockID"] is None
            and snapshot["blockType"] is None
            and snapshot["activeTableCell"] is None
            and snapshot["visual"]["tableGridVisible"] is False
        ),
        "documentDirty": snapshot["dirty"] is True,
        "expectedMutationCounts": (
            snapshot["localMutationCount"] == 8
            and snapshot["parseCount"] == 9
        ),
        "findAndOverlaysClosed": (
            snapshot["find"]["query"] == ""
            and snapshot["visual"]["findPanelVisible"] is False
            and snapshot["visual"]["paletteVisible"] is False
        ),
        "sidebarRemainedVisible": snapshot["visual"]["sidebarVisible"] is True,
    },
    "snapshot": snapshot,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

assert_foreground_element_reports() {
    local report_path="${1:-$SIZE_DIR/foreground-report.json}"
    local plan_path="${2:-$SIZE_DIR/foreground-plan.json}"
    local window_path="${3:-$SIZE_DIR/foreground-window-after.json}"
    python3 - \
        "$report_path" \
        "$plan_path" \
        "$window_path" <<'PY'
import json
import math
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
plan = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
window = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))["bounds"]
semantic_kinds = {
    "element-move",
    "element-click",
    "element-check",
    "element-description-check",
    "element-drag",
    "focused-element-check",
}
expected = [
    (
        index,
        action.get("identifier"),
        action.get("description"),
        action.get("role"),
    )
    for index, action in enumerate(plan["actions"])
    if action["kind"] in semantic_kinds
]
observed = []
for action in report["actions"]:
    element = action.get("element")
    if action["kind"] in {"element-drag", "window-drag"}:
        start_readiness = action.get("pointerClickReadiness")
        end_readiness = action.get("pointerDragEndpointReadiness")
        if not isinstance(start_readiness, dict) \
                or start_readiness.get("ready") is not True \
                or not isinstance(end_readiness, dict) \
                or end_readiness.get("ready") is not True:
            raise SystemExit("foreground drag endpoints were not both routing-ready")
        for receipt_name in (
            "injectedPointerEvents",
            "targetInjectedPointerEvents",
        ):
            receipt = action.get(receipt_name)
            if not isinstance(receipt, dict) \
                    or receipt.get("completeDragSequenceObserved") is not True \
                    or not isinstance(receipt.get("leftMouseDraggedCount"), int) \
                    or isinstance(receipt.get("leftMouseDraggedCount"), bool) \
                    or receipt["leftMouseDraggedCount"] < 2:
                raise SystemExit(
                    f"foreground drag has no complete {receipt_name} receipt"
                )
    if action["kind"] not in semantic_kinds:
        if element is not None:
            raise SystemExit("non-element foreground action unexpectedly resolved an element")
        continue
    if not isinstance(element, dict):
        raise SystemExit("foreground element action has no semantic resolution report")
    frame = element.get("frame", {})
    values = [frame.get(key) for key in ("x", "y", "width", "height")]
    if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
        raise SystemExit("foreground element frame is not finite")
    if frame["width"] <= 0 or frame["height"] <= 0:
        raise SystemExit("foreground element frame is not positive")
    center_x = frame["x"] + frame["width"] / 2
    center_y = frame["y"] + frame["height"] / 2
    if not (
        window["x"] <= center_x <= window["x"] + window["width"]
        and window["y"] <= center_y <= window["y"] + window["height"]
    ):
        raise SystemExit("foreground element center is outside the target window")
    observed.append((
        action["index"],
        element["identifier"],
        element.get("description"),
        element["role"],
    ))
if len(observed) != len(expected):
    raise SystemExit(f"foreground element resolution count mismatch: {observed!r}")
for actual, requested in zip(observed, expected):
    if actual[0] != requested[0] \
            or requested[1] is not None and actual[1] != requested[1] \
            or requested[2] is not None and actual[2] != requested[2] \
            or requested[3] is not None and actual[3] != requested[3]:
        raise SystemExit(
            f"foreground element resolution mismatch: {observed!r} != {expected!r}"
        )
PY
}

run_foreground_table_controls() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-table-plan.py"

    register_foreground_checkpoint \
        "table-reading-rest" "$raw_dir/table-reading-rest.png"
    register_foreground_checkpoint \
        "table-reading-hover" "$raw_dir/table-reading-hover.png"
    register_foreground_checkpoint \
        "table-controls-final" "$raw_dir/table-controls-final.png"
    register_foreground_checkpoint \
        "table-committed" "$raw_dir/table-committed.png"
    # The foreground driver has restored focus and pointer before these checks.
    record_comparison "foreground-table-reading-hover" \
        "table-reading-rest" "table-reading-hover" "0.00001"
    record_comparison "foreground-table-cell-edit" \
        "table-reading-hover" "table-controls-final" "0.005"
    record_comparison "foreground-table-escape" \
        "table-controls-final" "table-committed" "0.005"
    record_visual_text_assertion \
        "foreground-table-controls-visible" "table-controls-final" \
        --contains "删行" \
        --contains "删列"
    record_visual_text_assertion \
        "foreground-table-controls-final" "table-controls-final" \
        --contains "E2E_TABLE"
    record_visual_text_assertion \
        "foreground-table-committed" "table-committed" \
        --contains "E2E_TABLE"
    assert_foreground_element_reports
    assert_foreground_table_session
}

assert_foreground_table_navigation_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local report="$SIZE_DIR/foreground-report.json"
    local assertion="$SIZE_DIR/session-foreground-table-navigation.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-table-navigation.json"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && python3 - \
            "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" "$report" \
            >/dev/null <<'PY'
import hashlib
import json
import math
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha, report_path = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
report = json.loads(pathlib.Path(report_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
original_table = "\n".join([
    "| 快捷键 | 功能 | 平台 |",
    "| --- | --- | :---: |",
    "| ⌘B | 加粗 | 全部 |",
    "| ⌘I | 斜体 | 全部 |",
    "| ⌘K | 命令面板 | 全部 |",
    "| ⌘F | 查找替换 | 全部 |",
])
if fixture.count(original_table) != 1:
    raise SystemExit(1)
expected_table = original_table + "\n|  |  |  |"
expected = fixture.replace(original_table, expected_table, 1)
active = next(
    (tab for tab in session.get("tabs", []) if tab.get("id") == session.get("activeTabID")),
    None,
)
if active is None or active.get("name") != "格式示例.md":
    raise SystemExit(1)
blocks = active.get("markdownDocument", {}).get("blocks", [])
rebuilt = "".join(
    block.get("leadingTrivia", "") + block.get("source", "")
    for block in blocks
) + active.get("markdownDocument", {}).get("trailingTrivia", "")
focus_sequence = [
    action.get("element", {}).get("identifier")
    for action in report.get("actions", [])
    if action.get("kind") == "focused-element-check"
]
expected_focus = [
    "table-cell-0-0",
    "table-cell-0-1",
    "table-cell-0-0",
    "table-cell-1-0",
    "table-cell-3-2",
    "table-cell-4-0",
]
visual = diagnostic.get("visual", {})
if active.get("isMarkdown") is not True \
        or active.get("isDirty") is not True \
        or active.get("text") != expected \
        or rebuilt != expected \
        or len(blocks) != 37 \
        or blocks[28].get("kind") != "table" \
        or blocks[28].get("source") != expected_table \
        or focus_sequence != expected_focus \
        or not math.isclose(float(active.get("scrollY", -1)), 2326, abs_tol=0.5) \
        or diagnostic.get("schemaVersion") != 1 \
        or diagnostic.get("document") != "格式示例.md" \
        or diagnostic.get("blockID") is not None \
        or diagnostic.get("blockType") is not None \
        or diagnostic.get("activeTableCell") is not None \
        or diagnostic.get("dirty") is not True \
        or diagnostic.get("localMutationCount") != 1 \
        or diagnostic.get("parseCount") != 2 \
        or not math.isclose(float(diagnostic.get("scrollY", -1)), 2326, abs_tol=0.5) \
        or visual.get("tableGridVisible") is not False \
        or visual.get("sourceEditorVisible") is not False:
    raise SystemExit(1)
for path in (fixture_path, workspace_path):
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != fixture_sha:
        raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground table-navigation state was not persisted or diagnosed" >&2
        exit 5
    fi
    python3 - \
        "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" "$report" "$OUTPUT" \
        > "$assertion" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha, report_path, output = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
report = json.loads(pathlib.Path(report_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
original_table = "\n".join([
    "| 快捷键 | 功能 | 平台 |",
    "| --- | --- | :---: |",
    "| ⌘B | 加粗 | 全部 |",
    "| ⌘I | 斜体 | 全部 |",
    "| ⌘K | 命令面板 | 全部 |",
    "| ⌘F | 查找替换 | 全部 |",
])
expected_table = original_table + "\n|  |  |  |"
expected = fixture.replace(original_table, expected_table, 1)
active = next(tab for tab in session["tabs"] if tab.get("id") == session["activeTabID"])
blocks = active["markdownDocument"]["blocks"]
rebuilt = "".join(
    block.get("leadingTrivia", "") + block["source"]
    for block in blocks
) + active["markdownDocument"].get("trailingTrivia", "")
focus_sequence = [
    action["element"]["identifier"]
    for action in report["actions"]
    if action["kind"] == "focused-element-check"
]
expected_focus = [
    "table-cell-0-0",
    "table-cell-0-1",
    "table-cell-0-0",
    "table-cell-1-0",
    "table-cell-3-2",
    "table-cell-4-0",
]
fixture_hash = hashlib.sha256(pathlib.Path(fixture_path).read_bytes()).hexdigest()
workspace_hash = hashlib.sha256(pathlib.Path(workspace_path).read_bytes()).hexdigest()
print(json.dumps({
    "label": "foreground-table-navigation-session",
    "assertions": {
        "onlyAutomaticRowWasAdded": active["text"] == expected,
        "blockModelRoundTripsExactly": rebuilt == expected,
        "tableBlockAndAlignmentPreserved": (
            len(blocks) == 37
            and blocks[28]["kind"] == "table"
            and blocks[28]["source"] == expected_table
            and "| --- | --- | :---: |" in blocks[28]["source"]
        ),
        "exactFocusedCellSequenceObserved": focus_sequence == expected_focus,
        "oneAutomaticRowMutationRecorded": (
            diagnostic["localMutationCount"] == 1
            and diagnostic["parseCount"] == 2
        ),
        "escapeClosedTableGrid": (
            diagnostic["activeTableCell"] is None
            and diagnostic["visual"]["tableGridVisible"] is False
        ),
        "scrollPositionPreserved": (
            math.isclose(active["scrollY"], 2326, abs_tol=0.5)
            and math.isclose(diagnostic["scrollY"], 2326, abs_tol=0.5)
        ),
        "bundleFixtureUnchanged": fixture_hash == fixture_sha,
        "workspaceFixtureUnchanged": workspace_hash == fixture_sha,
    },
    "focusedCellSequence": focus_sequence,
    "sessionPath": os.path.relpath(session_path, output),
    "fixtureSHA256": fixture_hash,
    "workspaceFixtureSHA256": workspace_hash,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    python3 - "$diagnostic" > "$diagnostic_assertion" <<'PY'
import json
import pathlib
import sys

snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({
    "label": "foreground-table-navigation-completion",
    "assertions": {
        "tableGridClosed": (
            snapshot["blockID"] is None
            and snapshot["blockType"] is None
            and snapshot["activeTableCell"] is None
            and snapshot["visual"]["tableGridVisible"] is False
        ),
        "documentDirty": snapshot["dirty"] is True,
        "expectedNavigationMutationCounts": (
            snapshot["localMutationCount"] == 1
            and snapshot["parseCount"] == 2
        ),
    },
    "snapshot": snapshot,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_table_navigation() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-table-navigation-plan.py"

    register_foreground_checkpoint \
        "table-navigation-last" "$raw_dir/table-navigation-last.png"
    register_foreground_checkpoint \
        "table-navigation-auto-row" "$raw_dir/table-navigation-auto-row.png"
    register_foreground_checkpoint \
        "table-navigation-committed" "$raw_dir/table-navigation-committed.png"
    record_comparison "foreground-table-navigation-open" \
        "baseline" "table-navigation-last" "0.005"
    record_comparison "foreground-table-navigation-auto-row" \
        "table-navigation-last" "table-navigation-auto-row" "0.00001"
    record_comparison "foreground-table-navigation-escape" \
        "table-navigation-auto-row" "table-navigation-committed" "0.005"
    record_visual_text_assertion \
        "foreground-table-navigation-auto-row" "table-navigation-auto-row" \
        --contains "删行" \
        --contains "删列"
    assert_foreground_element_reports
    assert_foreground_table_navigation_session
}

assert_foreground_editor_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-editor.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-editor-completion.json"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && python3 - \
            "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" \
            >/dev/null <<'PY'
import hashlib
import json
import math
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
expected = fixture.replace(
    "> \u2014\u2014 设计原则：读起来像一页纸，而不是一个应用。",
    "> \u2014\u2014 设计原则：读起来像一页纸，而不是一个应用。\n> E2E_QUOTE",
    1,
).replace(
    "- 另一个第一层项目",
    "- 另一个第一层项目\n- E2E_LIST **BOLD**",
    1,
)
active = next(
    (tab for tab in session.get("tabs", []) if tab.get("id") == session.get("activeTabID")),
    None,
)
if active is None or active.get("name") != "格式示例.md":
    raise SystemExit(1)
blocks = active.get("markdownDocument", {}).get("blocks", [])
rebuilt = "".join(
    block.get("leadingTrivia", "") + block.get("source", "")
    for block in blocks
) + active.get("markdownDocument", {}).get("trailingTrivia", "")
if active.get("isMarkdown") is not True \
        or active.get("isDirty") is not True \
        or active.get("text") != expected \
        or rebuilt != expected \
        or len(blocks) != 37 \
        or blocks[12].get("kind") != "quote" \
        or blocks[12].get("source", "").endswith("\n> E2E_QUOTE") is not True \
        or blocks[15].get("kind") != "list" \
        or blocks[15].get("source", "").endswith("\n- E2E_LIST **BOLD**") is not True \
        or not math.isclose(float(active.get("scrollY", -1)), 650, abs_tol=0.5):
    raise SystemExit(1)
visual = diagnostic.get("visual", {})
find = diagnostic.get("find", {})
if diagnostic.get("schemaVersion") != 1 \
        or diagnostic.get("document") != "格式示例.md" \
        or diagnostic.get("mode") != "edit" \
        or diagnostic.get("blockID") is not None \
        or diagnostic.get("blockType") is not None \
        or diagnostic.get("selection") is not None \
        or diagnostic.get("activeTableCell") is not None \
        or diagnostic.get("dirty") is not True \
        or diagnostic.get("localMutationCount") != 4 \
        or diagnostic.get("parseCount") != 5 \
        or not math.isclose(float(diagnostic.get("scrollY", -1)), 650, abs_tol=0.5) \
        or find.get("query") != "" \
        or find.get("matchCount") != 0 \
        or find.get("invalidRegex") is not False \
        or visual.get("documentVisible") is not True \
        or visual.get("sidebarVisible") is not True \
        or visual.get("paletteVisible") is not False \
        or visual.get("findPanelVisible") is not False \
        or visual.get("previewActive") is not False \
        or visual.get("sourceEditorVisible") is not False \
        or visual.get("tableGridVisible") is not False:
    raise SystemExit(1)
for path in (fixture_path, workspace_path):
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != fixture_sha:
        raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground editor state was not persisted or diagnosed" >&2
        exit 5
    fi
    python3 - \
        "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" "$OUTPUT" \
        > "$assertion" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha, output = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
expected = fixture.replace(
    "> \u2014\u2014 设计原则：读起来像一页纸，而不是一个应用。",
    "> \u2014\u2014 设计原则：读起来像一页纸，而不是一个应用。\n> E2E_QUOTE",
    1,
).replace(
    "- 另一个第一层项目",
    "- 另一个第一层项目\n- E2E_LIST **BOLD**",
    1,
)
active = next(tab for tab in session["tabs"] if tab.get("id") == session["activeTabID"])
blocks = active["markdownDocument"]["blocks"]
rebuilt = "".join(
    block.get("leadingTrivia", "") + block["source"]
    for block in blocks
) + active["markdownDocument"].get("trailingTrivia", "")
fixture_hash = hashlib.sha256(pathlib.Path(fixture_path).read_bytes()).hexdigest()
workspace_hash = hashlib.sha256(pathlib.Path(workspace_path).read_bytes()).hexdigest()
print(json.dumps({
    "label": "foreground-editor-session",
    "assertions": {
        "onlyExpectedStructuredEditsPersisted": active["text"] == expected,
        "blockModelRoundTripsExactly": rebuilt == expected,
        "blockCountPreserved": len(blocks) == 37,
        "quoteContinuationPersisted": blocks[12]["source"].endswith("\n> E2E_QUOTE"),
        "listContinuationAndBoldPersisted": (
            blocks[15]["source"].endswith("\n- E2E_LIST **BOLD**")
        ),
        "tabAndShiftTabNetIndentPreserved": "\n  - E2E_LIST" not in blocks[15]["source"],
        "undoRedoRestoredFinalEdit": active["text"] == expected,
        "fourLocalHistoryMutationsRecorded": (
            diagnostic["localMutationCount"] == 4
            and diagnostic["parseCount"] == 5
        ),
        "escapeClosedSourceEditor": (
            diagnostic["blockID"] is None
            and diagnostic["visual"]["sourceEditorVisible"] is False
        ),
        "scrollPositionPreserved": (
            math.isclose(active["scrollY"], 650, abs_tol=0.5)
            and math.isclose(diagnostic["scrollY"], 650, abs_tol=0.5)
        ),
        "bundleFixtureUnchanged": fixture_hash == fixture_sha,
        "workspaceFixtureUnchanged": workspace_hash == fixture_sha,
    },
    "sessionPath": os.path.relpath(session_path, output),
    "fixtureSHA256": fixture_hash,
    "workspaceFixtureSHA256": workspace_hash,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    python3 - "$diagnostic" > "$diagnostic_assertion" <<'PY'
import json
import pathlib
import sys

snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({
    "label": "foreground-editor-completion",
    "assertions": {
        "sourceEditorClosed": (
            snapshot["blockID"] is None
            and snapshot["blockType"] is None
            and snapshot["selection"] is None
            and snapshot["visual"]["sourceEditorVisible"] is False
        ),
        "documentDirty": snapshot["dirty"] is True,
        "expectedHistoryMutationCounts": (
            snapshot["localMutationCount"] == 4
            and snapshot["parseCount"] == 5
        ),
        "overlaysClosed": (
            snapshot["visual"]["findPanelVisible"] is False
            and snapshot["visual"]["paletteVisible"] is False
            and snapshot["visual"]["tableGridVisible"] is False
        ),
    },
    "snapshot": snapshot,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_editor_structure() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-editor-plan.py"

    register_foreground_checkpoint \
        "quote-source-edited" "$raw_dir/quote-source-edited.png"
    register_foreground_checkpoint \
        "list-source-edited" "$raw_dir/list-source-edited.png"
    register_foreground_checkpoint \
        "list-undone" "$raw_dir/list-undone.png"
    register_foreground_checkpoint \
        "editor-structure-final" "$raw_dir/editor-structure-final.png"
    record_comparison "foreground-quote-source-edit" \
        "baseline" "quote-source-edited" "0.005"
    record_comparison "foreground-list-source-edit" \
        "quote-source-edited" "list-source-edited" "0.005"
    record_comparison "foreground-list-undo" \
        "list-source-edited" "list-undone" "0.00001"
    record_comparison "foreground-list-redo" \
        "list-undone" "editor-structure-final" "0.00001"
    record_visual_text_assertion \
        "foreground-quote-source-edited" "quote-source-edited" \
        --contains "E2E_QUOTE"
    record_visual_text_assertion \
        "foreground-list-source-edited" "list-source-edited" \
        --contains "E2E_LIST" \
        --contains "BOLD"
    record_visual_text_assertion \
        "foreground-list-undone" "list-undone" \
        --contains "E2E_QUOTE" \
        --not-contains "E2E_LIST"
    record_visual_text_assertion \
        "foreground-editor-structure-final" "editor-structure-final" \
        --contains "E2E_QUOTE" \
        --contains "E2E_LIST"
    assert_foreground_element_reports
    assert_foreground_editor_session
}

assert_foreground_editor_boundaries_session() {
    local session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local fixture="$ROOT/ui/格式示例.md"
    local workspace_fixture="$PROFILE_ROOT/Temporary/Workspace/docs/格式示例.md"
    local assertion="$SIZE_DIR/session-foreground-editor-boundaries.json"
    local diagnostic_assertion="$SIZE_DIR/diagnostic-foreground-editor-boundaries.json"
    local ready=0
    for _ in {1..60}; do
        if [[ -s "$session" && -s "$diagnostic" ]] && python3 - \
            "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" \
            >/dev/null <<'PY'
import hashlib
import json
import math
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
p10 = (
    "正文里可以有 **加粗**、*斜体*、***粗斜体***、~~删除线~~、<u>下划线</u>，"
    "以及行内代码 `const answer = 42`。还支持上标 x<sup>2</sup>、下标 "
    "H<sub>2</sub>O，和 emoji 😀 🎉 ✅。"
)
p11 = (
    "转义与边界：带空格的星号不会被误当作强调 \u2014\u2014 2 * 3 = 6、4 * 5 = 20；"
    "需要字面标记时用反斜杠转义，如 \\*星号\\*、\\_下划线\\_、\\`反引号\\`。"
)
pair = p10 + "\n\n" + p11
if fixture.count(pair) != 1:
    raise SystemExit(1)
merged = p10 + "`E2E_CODE`" + "*E2E_ITALIC*" + p11
expected = fixture.replace(pair, merged, 1)
active = next(
    (tab for tab in session.get("tabs", []) if tab.get("id") == session.get("activeTabID")),
    None,
)
if active is None or active.get("name") != "格式示例.md":
    raise SystemExit(1)
blocks = active.get("markdownDocument", {}).get("blocks", [])
rebuilt = "".join(
    block.get("leadingTrivia", "") + block.get("source", "")
    for block in blocks
) + active.get("markdownDocument", {}).get("trailingTrivia", "")
visual = diagnostic.get("visual", {})
if active.get("isMarkdown") is not True \
        or active.get("isDirty") is not True \
        or active.get("text") != expected \
        or rebuilt != expected \
        or len(blocks) != 36 \
        or blocks[10].get("kind") != "paragraph" \
        or blocks[10].get("source") != merged \
        or blocks[11].get("kind") != "quote" \
        or not math.isclose(float(active.get("scrollY", -1)), 500, abs_tol=0.5) \
        or diagnostic.get("schemaVersion") != 1 \
        or diagnostic.get("document") != "格式示例.md" \
        or diagnostic.get("mode") != "edit" \
        or diagnostic.get("blockID") is not None \
        or diagnostic.get("blockType") is not None \
        or diagnostic.get("selection") is not None \
        or diagnostic.get("activeTableCell") is not None \
        or diagnostic.get("dirty") is not True \
        or diagnostic.get("localMutationCount") != 3 \
        or diagnostic.get("parseCount") != 4 \
        or not math.isclose(float(diagnostic.get("scrollY", -1)), 500, abs_tol=0.5) \
        or visual.get("documentVisible") is not True \
        or visual.get("sourceEditorVisible") is not False \
        or visual.get("tableGridVisible") is not False:
    raise SystemExit(1)
for path in (fixture_path, workspace_path):
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != fixture_sha:
        raise SystemExit(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: foreground editor-boundaries state was not persisted or diagnosed" >&2
        exit 5
    fi
    python3 - \
        "$session" "$diagnostic" "$fixture" "$workspace_fixture" "$FIXTURE_SHA" "$OUTPUT" \
        > "$assertion" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import sys

session_path, diagnostic_path, fixture_path, workspace_path, fixture_sha, output = sys.argv[1:]
session = json.loads(pathlib.Path(session_path).read_text(encoding="utf-8"))
diagnostic = json.loads(pathlib.Path(diagnostic_path).read_text(encoding="utf-8"))
fixture = pathlib.Path(fixture_path).read_text(encoding="utf-8")
p10 = (
    "正文里可以有 **加粗**、*斜体*、***粗斜体***、~~删除线~~、<u>下划线</u>，"
    "以及行内代码 `const answer = 42`。还支持上标 x<sup>2</sup>、下标 "
    "H<sub>2</sub>O，和 emoji 😀 🎉 ✅。"
)
p11 = (
    "转义与边界：带空格的星号不会被误当作强调 \u2014\u2014 2 * 3 = 6、4 * 5 = 20；"
    "需要字面标记时用反斜杠转义，如 \\*星号\\*、\\_下划线\\_、\\`反引号\\`。"
)
pair = p10 + "\n\n" + p11
merged = p10 + "`E2E_CODE`" + "*E2E_ITALIC*" + p11
expected = fixture.replace(pair, merged, 1)
active = next(tab for tab in session["tabs"] if tab.get("id") == session["activeTabID"])
blocks = active["markdownDocument"]["blocks"]
rebuilt = "".join(
    block.get("leadingTrivia", "") + block["source"]
    for block in blocks
) + active["markdownDocument"].get("trailingTrivia", "")
fixture_hash = hashlib.sha256(pathlib.Path(fixture_path).read_bytes()).hexdigest()
workspace_hash = hashlib.sha256(pathlib.Path(workspace_path).read_bytes()).hexdigest()
print(json.dumps({
    "label": "foreground-editor-boundaries-session",
    "assertions": {
        "onlyExpectedBoundaryEditsPersisted": active["text"] == expected,
        "blockModelRoundTripsExactly": rebuilt == expected,
        "adjacentParagraphsMerged": (
            len(blocks) == 36
            and blocks[10]["kind"] == "paragraph"
            and blocks[10]["source"] == merged
            and blocks[11]["kind"] == "quote"
        ),
        "italicAndInlineCodePersisted": (
            "*E2E_ITALIC*" in blocks[10]["source"]
            and "`E2E_CODE`" in blocks[10]["source"]
        ),
        "threeLocalBoundaryMutationsRecorded": (
            diagnostic["localMutationCount"] == 3
            and diagnostic["parseCount"] == 4
        ),
        "escapeClosedSourceEditor": (
            diagnostic["blockID"] is None
            and diagnostic["visual"]["sourceEditorVisible"] is False
        ),
        "scrollPositionPreserved": (
            math.isclose(active["scrollY"], 500, abs_tol=0.5)
            and math.isclose(diagnostic["scrollY"], 500, abs_tol=0.5)
        ),
        "bundleFixtureUnchanged": fixture_hash == fixture_sha,
        "workspaceFixtureUnchanged": workspace_hash == fixture_sha,
    },
    "sessionPath": os.path.relpath(session_path, output),
    "fixtureSHA256": fixture_hash,
    "workspaceFixtureSHA256": workspace_hash,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$SESSION_ASSERTION_LIST"
    python3 - "$diagnostic" > "$diagnostic_assertion" <<'PY'
import json
import pathlib
import sys

snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({
    "label": "foreground-editor-boundaries-completion",
    "assertions": {
        "sourceEditorClosed": (
            snapshot["blockID"] is None
            and snapshot["blockType"] is None
            and snapshot["selection"] is None
            and snapshot["visual"]["sourceEditorVisible"] is False
        ),
        "documentDirty": snapshot["dirty"] is True,
        "expectedBoundaryMutationCounts": (
            snapshot["localMutationCount"] == 3
            and snapshot["parseCount"] == 4
        ),
        "overlaysClosed": (
            snapshot["visual"]["findPanelVisible"] is False
            and snapshot["visual"]["paletteVisible"] is False
            and snapshot["visual"]["tableGridVisible"] is False
        ),
    },
    "snapshot": snapshot,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_editor_boundaries() {
    local raw_dir="$SIZE_DIR/foreground-raw"
    run_bounded_foreground_plan \
        "$ROOT/scripts/e2e/build-foreground-editor-boundaries-plan.py"

    register_foreground_checkpoint \
        "boundary-next-italic" "$raw_dir/boundary-next-italic.png"
    register_foreground_checkpoint \
        "boundary-previous-code" "$raw_dir/boundary-previous-code.png"
    register_foreground_checkpoint \
        "boundary-merged" "$raw_dir/boundary-merged.png"
    record_comparison "foreground-boundary-next" \
        "baseline" "boundary-next-italic" "0.005"
    record_comparison "foreground-boundary-previous" \
        "boundary-next-italic" "boundary-previous-code" "0.005"
    record_comparison "foreground-boundary-merge" \
        "boundary-previous-code" "boundary-merged" "0.005"
    record_visual_text_assertion \
        "foreground-boundary-next-italic" "boundary-next-italic" \
        --contains "E2E_ITALIC"
    record_visual_text_assertion \
        "foreground-boundary-previous-code" "boundary-previous-code" \
        --contains "E2E_CODE"
    record_visual_text_assertion \
        "foreground-boundary-merged" "boundary-merged" \
        --contains "E2E_CODE" \
        --contains "E2E_ITALIC"
    assert_foreground_element_reports
    assert_foreground_editor_boundaries_session
}

run_tab_session_phase() {
    local phase="$1"
    local session="${2:-$PROFILE_ROOT/Application Support/MarkdownViewer/session.json}"
    local phase_dir="$SIZE_DIR/tab-session/$phase"
    local raw_dir="$phase_dir/raw"
    local plan="$phase_dir/foreground-plan.json"
    local plan_validation="$phase_dir/foreground-plan-validation.json"
    local report="$phase_dir/foreground-report.json"
    mkdir -p "$raw_dir"
    python3 "$ROOT/scripts/e2e/build-foreground-tab-session-plan.py" \
        --phase "$phase" \
        --session "$session" \
        --raw-dir "$raw_dir" \
        --output "$plan"
    run_foreground_plan_file "$plan" "$plan_validation" "$report"
}

write_tab_session_aggregate_evidence() {
    local phases=(
        switch-commit
        close-right-reopen
        close-left-seed
        seed-layout
        relaunch-scroll-check
    )
    local aggregate_validation="$SIZE_DIR/foreground-plan-validation.json"
    local aggregate_report="$SIZE_DIR/foreground-report.json"
    python3 - \
        "$FOREGROUND_BUDGET" "$SIZE_DIR/tab-session" \
        "${phases[@]}" \
        > "$aggregate_validation" <<'PY'
import json
import pathlib
import sys

budget_ms = int(round(float(sys.argv[1]) * 1_000))
root = pathlib.Path(sys.argv[2])
phase_names = sys.argv[3:]
phases = []
actions = []
for phase_index, name in enumerate(phase_names):
    phase_root = root / name
    plan = json.loads(
        (phase_root / "foreground-plan.json").read_text(encoding="utf-8")
    )
    validation = json.loads(
        (phase_root / "foreground-plan-validation.json").read_text(encoding="utf-8")
    )
    phases.append({
        "name": name,
        "plan": plan,
        "validation": validation,
    })
    for phase_action_index, action in enumerate(plan["actions"]):
        actions.append({
            **action,
            "phase": name,
            "phaseIndex": phase_index,
            "phaseActionIndex": phase_action_index,
        })
print(json.dumps({
    "schemaVersion": 1,
    "suite": "tab-session-lifecycle",
    "phaseCount": len(phases),
    "perPhaseBudgetMs": budget_ms,
    "totalBudgetMs": budget_ms * len(phases),
    "actions": actions,
    "phases": phases,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    python3 - \
        "$FOREGROUND_BUDGET" "$SIZE_DIR/tab-session" \
        "${phases[@]}" \
        > "$aggregate_report" <<'PY'
import json
import pathlib
import sys

budget_ms = int(round(float(sys.argv[1]) * 1_000))
root = pathlib.Path(sys.argv[2])
phase_names = sys.argv[3:]
phases = []
actions = []
duration_ms = 0
for phase_index, name in enumerate(phase_names):
    phase_root = root / name
    validation = json.loads(
        (phase_root / "foreground-plan-validation.json").read_text(encoding="utf-8")
    )
    report = json.loads(
        (phase_root / "foreground-report.json").read_text(encoding="utf-8")
    )
    phases.append({
        "name": name,
        "planValidation": validation,
        "report": report,
    })
    duration_ms += report["durationMs"]
    for phase_action_index, action in enumerate(report["actions"]):
        actions.append({
            **action,
            "index": len(actions),
            "phase": name,
            "phaseIndex": phase_index,
            "phaseActionIndex": phase_action_index,
        })
all_completed = all(phase["report"]["completed"] is True for phase in phases)
all_focus = all(
    phase["report"]["focusRestore"]["restored"] is True for phase in phases
)
all_pointer = all(
    phase["report"]["pointerRestore"]["restored"] is True for phase in phases
)
all_pasteboard = all(
    phase["report"]["pasteboardRestore"]["restored"] is True for phase in phases
)
print(json.dumps({
    "schemaVersion": 1,
    "suite": "tab-session-lifecycle",
    "pid": phases[0]["report"]["pid"],
    "pids": [phase["report"]["pid"] for phase in phases],
    "phaseCount": len(phases),
    "perPhaseBudgetMs": budget_ms,
    "totalBudgetMs": budget_ms * len(phases),
    "budgetMs": budget_ms * len(phases),
    "durationMs": duration_ms,
    "targetActivationRequestCount": sum(
        phase["report"]["targetActivationRequestCount"] for phase in phases
    ),
    "completed": all_completed,
    "deadlineExceeded": any(
        phase["report"]["deadlineExceeded"] for phase in phases
    ),
    "error": None,
    "actions": actions,
    "interference": {
        "detected": any(
            phase["report"]["interference"]["detected"] for phase in phases
        ),
        "pointerInputDetected": any(
            phase["report"]["interference"]["pointerInputDetected"]
            for phase in phases
        ),
        "pointerPositionInterferenceDetected": any(
            phase["report"]["interference"]["pointerPositionInterferenceDetected"]
            for phase in phases
        ),
        "eventTapReliable": all(
            phase["report"]["interference"]["eventTapReliable"]
            for phase in phases
        ),
    },
    "focusRestore": {"attempted": True, "restored": all_focus},
    "pointerRestore": {"attempted": True, "restored": all_pointer},
    "pasteboardRestore": {"attempted": False, "restored": all_pasteboard},
    "phases": phases,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

assert_tab_session_runtime_geometry() {
    local seeded_session="$1"
    local phase5_report="$SIZE_DIR/tab-session/relaunch-scroll-check/foreground-report.json"
    local assertion="$SIZE_DIR/tab-session/runtime-geometry-assertion.json"
    python3 - \
        "$seeded_session" "$phase5_report" \
        > "$assertion" <<'PY'
import json
import math
import pathlib
import sys

session = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
phase5 = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
tabs = {tab["name"]: tab for tab in session["tabs"]}
fixture_id = f"tab-{tabs['格式示例.md']['id']}"
second_id = f"tab-{tabs['未命名 2.md']['id']}"

def elements(report, identifier, kind=None):
    return [
        action["element"]
        for action in report["actions"]
        if isinstance(action.get("element"), dict)
        and action["element"].get("identifier") == identifier
        and (kind is None or action.get("kind") == kind)
    ]

def one(report, identifier, kind="element-check"):
    matches = elements(report, identifier, kind=kind)
    if len(matches) != 1:
        raise SystemExit(f"expected one runtime element report for {identifier}")
    return matches[0]

def finite_frame(element):
    frame = element.get("frame", {})
    values = [frame.get(key) for key in ("x", "y", "width", "height")]
    if not all(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        for value in values
    ) or frame["width"] <= 0 or frame["height"] <= 0:
        raise SystemExit("runtime element frame is not finite and positive")
    return frame

phase5_second = one(phase5, second_id)
phase5_paragraph = one(phase5, "document-block-0-paragraph")
phase5_sidebar = one(phase5, "sidebar-surface")
phase5_fixture_matches = elements(phase5, fixture_id, kind="element-check")
if len(phase5_fixture_matches) != 2:
    raise SystemExit("relaunch phase did not report fixture tab before and after activation")
phase5_fixture_before, phase5_fixture_after = phase5_fixture_matches
frames = {
    "relaunchFixtureTabBefore": finite_frame(phase5_fixture_before),
    "relaunchFixtureTabAfter": finite_frame(phase5_fixture_after),
    "relaunchSecondTab": finite_frame(phase5_second),
    "relaunchParagraph": finite_frame(phase5_paragraph),
    "relaunchSidebar": finite_frame(phase5_sidebar),
}
if phase5_second.get("selected") is not True \
        or phase5_fixture_after.get("selected") is not True:
    raise SystemExit("runtime tab selection did not survive relaunch and activation")
if not frames["relaunchFixtureTabBefore"]["x"] \
        < frames["relaunchSecondTab"]["x"]:
    raise SystemExit("runtime tab order did not match the persisted order")
print(json.dumps({
    "label": "tab-session-runtime-geometry",
    "assertions": {
        "nonFirstTabSelectedAfterRelaunch": True,
        "tabOrderVisibleInAccessibilityFrames": True,
        "restoredActiveDocumentFrameResolved": True,
        "restoredSidebarSurfaceResolved": True,
        "fixtureWorkspaceRowActivatedOriginalTab": True,
    },
    "frames": frames,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    printf '%s\n' "$assertion" >> "$DIAGNOSTIC_LIST"
}

run_foreground_tab_session_lifecycle() {
    local stage1_session stage1_diagnostic
    local stage2_session stage2_diagnostic
    local stage3_session stage3_diagnostic
    local stage4_session stage4_diagnostic
    local initial_pid="$CURRENT_PID"

    run_tab_session_phase "switch-commit"
    assert_foreground_element_reports \
        "$SIZE_DIR/tab-session/switch-commit/foreground-report.json" \
        "$SIZE_DIR/tab-session/switch-commit/foreground-plan.json" \
        "$SIZE_DIR/tab-session/switch-commit/foreground-window-after.json"
    verify_tab_session_stage "switch-commit"
    stage1_session="$TAB_SESSION_STAGE_SESSION"
    stage1_diagnostic="$TAB_SESSION_STAGE_DIAGNOSTIC"

    run_tab_session_phase "close-right-reopen"
    assert_foreground_element_reports \
        "$SIZE_DIR/tab-session/close-right-reopen/foreground-report.json" \
        "$SIZE_DIR/tab-session/close-right-reopen/foreground-plan.json" \
        "$SIZE_DIR/tab-session/close-right-reopen/foreground-window-after.json"
    verify_tab_session_stage \
        "close-right-reopen" "$stage1_session" "$stage1_diagnostic"
    stage2_session="$TAB_SESSION_STAGE_SESSION"
    stage2_diagnostic="$TAB_SESSION_STAGE_DIAGNOSTIC"

    run_tab_session_phase "close-left-seed"
    assert_foreground_element_reports \
        "$SIZE_DIR/tab-session/close-left-seed/foreground-report.json" \
        "$SIZE_DIR/tab-session/close-left-seed/foreground-plan.json" \
        "$SIZE_DIR/tab-session/close-left-seed/foreground-window-after.json"

    run_tab_session_phase "seed-layout" "$stage2_session"
    assert_foreground_element_reports \
        "$SIZE_DIR/tab-session/seed-layout/foreground-report.json" \
        "$SIZE_DIR/tab-session/seed-layout/foreground-plan.json" \
        "$SIZE_DIR/tab-session/seed-layout/foreground-window-after.json"
    verify_tab_session_stage \
        "close-left-seed" "$stage2_session" "$stage2_diagnostic"
    stage3_session="$TAB_SESSION_STAGE_SESSION"
    stage3_diagnostic="$TAB_SESSION_STAGE_DIAGNOSTIC"

    local terminate_dir="$SIZE_DIR/tab-session/terminate-before-relaunch"
    mkdir -p "$terminate_dir"
    PASSIVE_ARTIFACT_DIR="$terminate_dir"
    "$DRIVER" desktop-state > "$terminate_dir/passive-desktop-before.json"
    start_passive_frontmost_observer
    publish_passive_target_pid "$CURRENT_PID"
    prove_normal_termination_session_flush \
        "$stage3_session" "$terminate_dir" \
        "tab-session-pre-relaunch-normal-termination"
    finish_passive_frontmost_observer "$initial_pid"
    printf '%s\n' "$terminate_dir/passive-lifecycle-assertion.json" \
        >> "$PASSIVE_LIFECYCLE_LIST"

    local relaunch_dir="$SIZE_DIR/tab-session/passive-relaunch"
    mkdir -p "$relaunch_dir"
    PASSIVE_ARTIFACT_DIR="$relaunch_dir"
    "$DRIVER" desktop-state > "$relaunch_dir/passive-desktop-before.json"
    start_passive_frontmost_observer
    launch_restored_visual_session "$relaunch_dir/launch.log"
    local relaunch_pid="$CURRENT_PID"
    publish_passive_target_pid "$relaunch_pid"
    "$DRIVER" window \
        --pid "$CURRENT_PID" \
        --timeout 8 \
        --width "$SIZE_WIDTH" \
        --height "$SIZE_HEIGHT" \
        --allow-uniform-presentation-scale \
        --include-offscreen \
        --require-offscreen \
        --main-window-only \
        > "$relaunch_dir/window.json"
    validate_passive_main_window "$relaunch_dir/window.json"
    WINDOW_NUMBER="$(python3 - "$relaunch_dir/window.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["windowNumber"])
PY
    )"
    verify_tab_session_stage \
        "relaunch" "$stage3_session" "$stage3_diagnostic"
    local relaunch_session="$TAB_SESSION_STAGE_SESSION"
    local relaunch_diagnostic="$TAB_SESSION_STAGE_DIAGNOSTIC"
    "$DRIVER" window \
        --pid "$CURRENT_PID" \
        --timeout 8 \
        --width "$SIZE_WIDTH" \
        --height "$SIZE_HEIGHT" \
        --allow-uniform-presentation-scale \
        --include-offscreen \
        --require-offscreen \
        --main-window-only \
        > "$relaunch_dir/window-before-capture.json"
    validate_passive_main_window "$relaunch_dir/window-before-capture.json"
    "$DRIVER" windows \
        --pid "$CURRENT_PID" \
        --include-offscreen \
        > "$relaunch_dir/process-windows-before-capture.json"
    validate_passive_process_windows \
        "$relaunch_dir/process-windows-before-capture.json" \
        "$relaunch_dir/window-before-capture.json"
    WINDOW_NUMBER="$(python3 - "$relaunch_dir/window-before-capture.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["windowNumber"])
PY
    )"
    assert_passive_frontmost_observer_alive
    capture_window "tab-session-passive-relaunch"
    finish_passive_frontmost_observer "$relaunch_pid" "may-run"
    printf '%s\n' "$relaunch_dir/passive-lifecycle-assertion.json" \
        >> "$PASSIVE_LIFECYCLE_LIST"

    run_tab_session_phase "relaunch-scroll-check"
    assert_foreground_element_reports \
        "$SIZE_DIR/tab-session/relaunch-scroll-check/foreground-report.json" \
        "$SIZE_DIR/tab-session/relaunch-scroll-check/foreground-plan.json" \
        "$SIZE_DIR/tab-session/relaunch-scroll-check/foreground-window-after.json"
    verify_tab_session_stage \
        "relaunch-scroll-check" "$stage3_session" "$stage3_diagnostic"
    stage4_session="$TAB_SESSION_STAGE_SESSION"
    stage4_diagnostic="$TAB_SESSION_STAGE_DIAGNOSTIC"
    assert_tab_session_runtime_geometry "$stage3_session"

    local final_terminate_dir="$SIZE_DIR/tab-session/terminate-after-relaunch-check"
    mkdir -p "$final_terminate_dir"
    PASSIVE_ARTIFACT_DIR="$final_terminate_dir"
    "$DRIVER" desktop-state > "$final_terminate_dir/passive-desktop-before.json"
    start_passive_frontmost_observer
    publish_passive_target_pid "$CURRENT_PID"
    prove_normal_termination_session_flush \
        "$stage4_session" "$final_terminate_dir" \
        "tab-session-post-relaunch-normal-termination"
    finish_passive_frontmost_observer "$relaunch_pid"
    printf '%s\n' "$final_terminate_dir/passive-lifecycle-assertion.json" \
        >> "$PASSIVE_LIFECYCLE_LIST"
    unset PASSIVE_ARTIFACT_DIR

    local phase1_raw="$SIZE_DIR/tab-session/switch-commit/raw"
    local phase2_raw="$SIZE_DIR/tab-session/close-right-reopen/raw"
    local phase3_raw="$SIZE_DIR/tab-session/close-left-seed/raw"
    local phase4_raw="$SIZE_DIR/tab-session/seed-layout/raw"
    local phase5_raw="$SIZE_DIR/tab-session/relaunch-scroll-check/raw"
    register_foreground_checkpoint \
        "tab-switch-fixture" "$phase1_raw/tab-switch-fixture.png"
    register_foreground_checkpoint \
        "tab-switch-draft-restored" "$phase1_raw/tab-switch-draft-restored.png"
    register_foreground_checkpoint \
        "tab-close-right-confirm" "$phase2_raw/tab-close-right-confirm.png"
    register_foreground_checkpoint \
        "tab-close-right-neighbor" "$phase2_raw/tab-close-right-neighbor.png"
    register_foreground_checkpoint \
        "tab-close-right-reopened" "$phase2_raw/tab-close-right-reopened.png"
    register_foreground_checkpoint \
        "tab-close-left-confirm" "$phase3_raw/tab-close-left-confirm.png"
    register_foreground_checkpoint \
        "tab-close-left-neighbor" "$phase3_raw/tab-close-left-neighbor.png"
    register_foreground_checkpoint \
        "tab-session-relaunch-seed" "$phase4_raw/tab-session-relaunch-seed.png"
    register_foreground_checkpoint \
        "tab-session-restored-scroll" "$phase5_raw/tab-session-restored-scroll.png"
    record_visual_text_assertion \
        "tab-switch-draft-restored" "tab-switch-draft-restored" \
        --contains "E2E_SWITCH_COMMIT"
    record_visual_text_assertion \
        "tab-close-right-neighbor" "tab-close-right-neighbor" \
        --contains "E2E_RIGHT_NEIGHBOR"
    record_visual_text_assertion \
        "tab-close-left-neighbor" "tab-close-left-neighbor" \
        --contains "E2E_RIGHT_NEIGHBOR"

    write_tab_session_aggregate_evidence
    python3 - \
        "$initial_pid" "$relaunch_pid" \
        "$terminate_dir/termination-report.json" \
        "$terminate_dir/passive-lifecycle-assertion.json" \
        "$relaunch_dir/window.json" \
        "$relaunch_dir/passive-lifecycle-assertion.json" \
        "$relaunch_session" "$relaunch_diagnostic" \
        "$final_terminate_dir/termination-report.json" \
        "$final_terminate_dir/passive-lifecycle-assertion.json" \
        > "$SIZE_DIR/session-relaunch.json" <<'PY'
import json
import pathlib
import sys

(
    initial_pid, relaunch_pid, initial_termination_path,
    initial_lifecycle_path, relaunch_window_path, relaunch_lifecycle_path,
    relaunch_session_path, relaunch_diagnostic_path,
    final_termination_path, final_lifecycle_path,
) = sys.argv[1:]
load = lambda path: json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
print(json.dumps({
    "schemaVersion": 1,
    "initialPID": int(initial_pid),
    "relaunchPID": int(relaunch_pid),
    "pidChanged": int(initial_pid) != int(relaunch_pid),
    "initialNormalTermination": load(initial_termination_path),
    "initialTerminationLifecycle": load(initial_lifecycle_path),
    "passiveRelaunchWindow": load(relaunch_window_path),
    "passiveRelaunchLifecycle": load(relaunch_lifecycle_path),
    "restoredSession": load(relaunch_session_path),
    "restoredDiagnostic": load(relaunch_diagnostic_path),
    "finalNormalTermination": load(final_termination_path),
    "finalTerminationLifecycle": load(final_lifecycle_path),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

seed_save_lifecycle_fixture() {
    local kind="$1"
    local workspace="$PROFILE_ROOT/Temporary/Workspace"
    python3 - "$workspace" "$kind" <<'PY'
import os
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
readme = workspace / "README.md"
config = workspace / "docs" / "config.yaml"
saved_as = workspace / "saved-as.md"
symlink = workspace / "README-link.md"
if not workspace.is_dir() or not config.parent.is_dir():
    raise SystemExit("isolated save lifecycle workspace is unavailable")

bom = b"\xef\xbb\xbf"
fixtures = {
    "markdown": bom + b"# Save lifecycle\r\n\r\nmarkdown original\r\n",
    "table": (
        b"# Table lifecycle\n\n"
        b"| Name | Value |\n"
        b"| --- | --- |\n"
        b"| row | table original |"
    ),
    "conflict": b"# Conflict lifecycle\n\nconflict baseline\n",
    "session": b"# Session lifecycle\n\nsession baseline\n",
}
if kind in fixtures:
    readme.write_bytes(fixtures[kind])
elif kind == "plain":
    config.write_bytes(bom + b"model: gpt-4o\r\ntemperature: 0.2\r\n")
else:
    raise SystemExit(f"unsupported save lifecycle fixture kind: {kind}")

if kind == "conflict":
    saved_as.unlink(missing_ok=True)
    symlink.unlink(missing_ok=True)
    os.symlink("README.md", symlink)
PY
}

replace_save_lifecycle_external_file() {
    local kind="$1"
    local readme="$PROFILE_ROOT/Temporary/Workspace/README.md"
    python3 - "$readme" "$kind" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
payloads = {
    "conflict": b"# Conflict lifecycle\n\nexternal replacement\n",
    "session": b"# Session lifecycle\n\nsession external replacement\n",
}
try:
    payload = payloads[kind]
except KeyError as error:
    raise SystemExit(f"unsupported external replacement kind: {kind}") from error
path.write_bytes(payload)
PY
}

run_save_lifecycle_plan() {
    local phase="$1"
    local evidence_name="${2:-$phase}"
    local phase_dir="$SIZE_DIR/save-lifecycle/$evidence_name"
    local raw_dir="$phase_dir/raw"
    local plan="$phase_dir/foreground-plan.json"
    local validation="$phase_dir/foreground-plan-validation.json"
    local report="$phase_dir/foreground-report.json"
    mkdir -p "$raw_dir"
    python3 "$ROOT/scripts/e2e/build-foreground-save-lifecycle-plan.py" \
        --phase "$phase" \
        --raw-dir "$raw_dir" \
        --output "$plan"
    run_foreground_plan_file "$plan" "$validation" "$report"
    if [[ -s "$raw_dir/$phase.png" ]]; then
        register_foreground_checkpoint \
            "save-lifecycle-$evidence_name" "$raw_dir/$phase.png"
    fi
}

capture_save_lifecycle_stage() {
    local stage="$1"
    local stage_dir="$SIZE_DIR/save-lifecycle/$stage"
    local live_session="$PROFILE_ROOT/Application Support/MarkdownViewer/session.json"
    local live_diagnostic="$PROFILE_ROOT/Diagnostics/state.json"
    local session_snapshot="$stage_dir/session.json"
    local diagnostic_snapshot="$stage_dir/diagnostic.json"
    local report="$stage_dir/foreground-report.json"
    local screenshot="$stage_dir/raw/$stage.png"
    local ocr="$stage_dir/ocr.json"
    local verifier="$ROOT/scripts/e2e/verify-foreground-save-lifecycle.py"
    local workspace="$PROFILE_ROOT/Temporary/Workspace"
    local session_assertion="$stage_dir/session-assertion.json"
    local diagnostic_assertion="$stage_dir/diagnostic-assertion.json"
    local verification_error="$stage_dir/verification.err"
    local verifier_options=(
        --stage "$stage"
        --foreground-report "$report"
        --workspace-root "$workspace"
        --expected-session-path "$live_session"
        --output-root "$OUTPUT"
    )

    rm -f "$ocr"
    case "$stage" in
        conflict-save|conflict-save-as-current|conflict-save-as-symlink|restored-conflict-save)
            "$DRIVER" screenshot-text \
                --screenshot "$screenshot" \
                --contains "磁盘上" \
                --contains "未覆盖" \
                > "$ocr"
            verifier_options+=(--ocr "$ocr")
            ;;
        plain-open-diagnostic)
            "$DRIVER" screenshot-text \
                --screenshot "$screenshot" \
                --contains "doc=config.yaml" \
                --contains "mode=source" \
                > "$ocr"
            verifier_options+=(--ocr "$ocr")
            ;;
    esac

    local ready=0
    for _ in {1..80}; do
        if [[ -s "$live_session" && -s "$live_diagnostic" ]] \
            && python3 "$verifier" \
                "${verifier_options[@]}" \
                --session "$live_session" \
                --diagnostic "$live_diagnostic" \
                --check-only >/dev/null 2>&1; then
            cp "$live_session" "$session_snapshot"
            cp "$live_diagnostic" "$diagnostic_snapshot"
            if python3 "$verifier" \
                "${verifier_options[@]}" \
                --session "$session_snapshot" \
                --diagnostic "$diagnostic_snapshot" \
                --check-only >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        python3 "$verifier" \
            "${verifier_options[@]}" \
            --session "$live_session" \
            --diagnostic "$live_diagnostic" \
            --check-only > /dev/null 2> "$verification_error" || true
        echo "run-real-app-e2e.sh: save lifecycle stage did not verify: $stage" >&2
        if [[ -s "$verification_error" ]]; then
            sed 's/^/  /' "$verification_error" >&2
        fi
        exit 5
    fi

    python3 "$verifier" \
        "${verifier_options[@]}" \
        --session "$session_snapshot" \
        --diagnostic "$diagnostic_snapshot" \
        --report-kind session \
        > "$session_assertion"
    python3 "$verifier" \
        "${verifier_options[@]}" \
        --session "$session_snapshot" \
        --diagnostic "$diagnostic_snapshot" \
        --report-kind diagnostic \
        > "$diagnostic_assertion"
    printf '%s\n' "$session_assertion" >> "$SESSION_ASSERTION_LIST"
    printf '%s\n' "$diagnostic_assertion" >> "$DIAGNOSTIC_LIST"
}

write_save_lifecycle_aggregate_evidence() {
    local phases=(
        markdown-save
        close-clean-1
        table-save
        close-clean-2
        conflict-open
        conflict-save
        save-as-new
        close-clean-3
        conflict-open-current
        conflict-save-as-current
        conflict-save-as-symlink
        discard-dirty-close
        session-draft
        restored-conflict-save
        plain-open-diagnostic
        plain-save
    )
    local aggregate_validation="$SIZE_DIR/foreground-plan-validation.json"
    local aggregate_report="$SIZE_DIR/foreground-report.json"
    python3 - \
        "$FOREGROUND_BUDGET" "$SIZE_DIR/save-lifecycle" \
        "${phases[@]}" \
        > "$aggregate_validation" <<'PY'
import json
import pathlib
import sys

budget_ms = int(round(float(sys.argv[1]) * 1_000))
root = pathlib.Path(sys.argv[2])
phase_names = sys.argv[3:]
phases = []
actions = []
for phase_index, name in enumerate(phase_names):
    phase_root = root / name
    plan = json.loads((phase_root / "foreground-plan.json").read_text(encoding="utf-8"))
    validation = json.loads(
        (phase_root / "foreground-plan-validation.json").read_text(encoding="utf-8")
    )
    phases.append({"name": name, "plan": plan, "validation": validation})
    for phase_action_index, action in enumerate(plan["actions"]):
        actions.append({
            **action,
            "phase": name,
            "phaseIndex": phase_index,
            "phaseActionIndex": phase_action_index,
        })
print(json.dumps({
    "schemaVersion": 1,
    "suite": "save-lifecycle",
    "logicalSize": "1180x760",
    "phaseCount": len(phases),
    "perPhaseBudgetMs": budget_ms,
    "totalBudgetMs": budget_ms * len(phases),
    "actions": actions,
    "phases": phases,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    python3 - \
        "$FOREGROUND_BUDGET" "$SIZE_DIR/save-lifecycle" \
        "${phases[@]}" \
        > "$aggregate_report" <<'PY'
import json
import pathlib
import sys

budget_ms = int(round(float(sys.argv[1]) * 1_000))
root = pathlib.Path(sys.argv[2])
phase_names = sys.argv[3:]
phases = []
actions = []
duration_ms = 0
for phase_index, name in enumerate(phase_names):
    phase_root = root / name
    validation = json.loads(
        (phase_root / "foreground-plan-validation.json").read_text(encoding="utf-8")
    )
    report = json.loads(
        (phase_root / "foreground-report.json").read_text(encoding="utf-8")
    )
    phases.append({"name": name, "planValidation": validation, "report": report})
    duration_ms += report["durationMs"]
    for phase_action_index, action in enumerate(report["actions"]):
        actions.append({
            **action,
            "index": len(actions),
            "phase": name,
            "phaseIndex": phase_index,
            "phaseActionIndex": phase_action_index,
        })
all_completed = all(phase["report"]["completed"] is True for phase in phases)
print(json.dumps({
    "schemaVersion": 1,
    "suite": "save-lifecycle",
    "logicalSize": "1180x760",
    "pid": phases[0]["report"]["pid"],
    "pids": [phase["report"]["pid"] for phase in phases],
    "phaseCount": len(phases),
    "perPhaseBudgetMs": budget_ms,
    "totalBudgetMs": budget_ms * len(phases),
    "budgetMs": budget_ms * len(phases),
    "durationMs": duration_ms,
    "targetActivationRequestCount": sum(
        phase["report"]["targetActivationRequestCount"] for phase in phases
    ),
    "completed": all_completed,
    "deadlineExceeded": any(
        phase["report"]["deadlineExceeded"] for phase in phases
    ),
    "error": None,
    "actions": actions,
    "interference": {
        "detected": any(
            phase["report"]["interference"]["detected"] for phase in phases
        ),
        "pointerInputDetected": any(
            phase["report"]["interference"]["pointerInputDetected"]
            for phase in phases
        ),
        "pointerPositionInterferenceDetected": any(
            phase["report"]["interference"]["pointerPositionInterferenceDetected"]
            for phase in phases
        ),
        "eventTapReliable": all(
            phase["report"]["interference"]["eventTapReliable"] for phase in phases
        ),
    },
    "focusRestore": {
        "attempted": True,
        "restored": all(
            phase["report"]["focusRestore"]["restored"] for phase in phases
        ),
    },
    "pointerRestore": {
        "attempted": True,
        "restored": all(
            phase["report"]["pointerRestore"]["restored"] for phase in phases
        ),
    },
    "pasteboardRestore": {
        "attempted": False,
        "restored": all(
            phase["report"]["pasteboardRestore"]["restored"] for phase in phases
        ),
    },
    "phases": phases,
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

run_foreground_save_lifecycle() {
    if [[ "$SIZE" != "1180x760" || "$SIZE_WIDTH" != "1180" \
        || "$SIZE_HEIGHT" != "760" ]]; then
        echo "run-real-app-e2e.sh: save-lifecycle is locked to 1180x760" >&2
        exit 5
    fi

    seed_save_lifecycle_fixture markdown
    run_save_lifecycle_plan markdown-save
    capture_save_lifecycle_stage markdown-save

    run_save_lifecycle_plan close-clean close-clean-1
    seed_save_lifecycle_fixture table
    run_save_lifecycle_plan table-save
    capture_save_lifecycle_stage table-save

    run_save_lifecycle_plan close-clean close-clean-2
    seed_save_lifecycle_fixture conflict
    run_save_lifecycle_plan conflict-open
    capture_save_lifecycle_stage conflict-open
    replace_save_lifecycle_external_file conflict
    run_save_lifecycle_plan conflict-save
    capture_save_lifecycle_stage conflict-save
    run_save_lifecycle_plan save-as-new
    capture_save_lifecycle_stage save-as-new

    run_save_lifecycle_plan close-clean close-clean-3
    seed_save_lifecycle_fixture conflict
    run_save_lifecycle_plan conflict-open conflict-open-current
    replace_save_lifecycle_external_file conflict
    run_save_lifecycle_plan conflict-save-as-current
    capture_save_lifecycle_stage conflict-save-as-current
    run_save_lifecycle_plan conflict-save-as-symlink
    capture_save_lifecycle_stage conflict-save-as-symlink

    run_save_lifecycle_plan discard-dirty-close
    seed_save_lifecycle_fixture session
    run_save_lifecycle_plan session-draft
    capture_save_lifecycle_stage session-draft
    local termination_dir="$SIZE_DIR/save-lifecycle/terminate-dirty-session"
    mkdir -p "$termination_dir"
    normal_terminate_current_app "$termination_dir/termination-report.json"
    replace_save_lifecycle_external_file session
    launch_restored_visual_session "$termination_dir/relaunch.log"
    run_save_lifecycle_plan restored-conflict-save
    capture_save_lifecycle_stage restored-conflict-save

    seed_save_lifecycle_fixture plain
    run_save_lifecycle_plan plain-open-diagnostic
    capture_save_lifecycle_stage plain-open-diagnostic
    run_save_lifecycle_plan plain-save
    capture_save_lifecycle_stage plain-save
    write_save_lifecycle_aggregate_evidence
}

run_foreground_smoke() {
    case "$FOREGROUND_BATCH_NAME" in
        palette-find) run_foreground_palette_find ;;
        block-activation) run_foreground_block_activation ;;
        find-options) run_foreground_find_options ;;
        find-regex-replace) run_foreground_find_regex_replace ;;
        preview-content) run_foreground_preview_content ;;
        preview-footnotes) run_foreground_preview_footnotes ;;
        outline-navigation) run_foreground_outline_navigation ;;
        sidebar-filter-navigation) run_foreground_sidebar_filter_navigation ;;
        sidebar-layout-controls) run_foreground_sidebar_layout_controls ;;
        tab-session-lifecycle) run_foreground_tab_session_lifecycle ;;
        save-lifecycle) run_foreground_save_lifecycle ;;
        table-controls) run_foreground_table_controls ;;
        table-navigation) run_foreground_table_navigation ;;
        editor-structure) run_foreground_editor_structure ;;
        editor-boundaries) run_foreground_editor_boundaries ;;
        *)
            echo "run-real-app-e2e.sh: internal foreground batch error: $FOREGROUND_BATCH_NAME" >&2
            exit 2
            ;;
    esac
}

start_passive_frontmost_observer() {
    local artifact_dir="${PASSIVE_ARTIFACT_DIR:-$SIZE_DIR}"
    PASSIVE_OBSERVER_READY_FILE="$artifact_dir/passive-frontmost-observer-ready.json"
    PASSIVE_OBSERVER_STOP_FILE="$artifact_dir/passive-frontmost-observer.stop"
    PASSIVE_OBSERVER_TARGET_PID_FILE="$artifact_dir/passive-frontmost-target.pid"
    PASSIVE_OBSERVER_REPORT="$artifact_dir/passive-frontmost-observer.json"
    PASSIVE_OBSERVER_ERROR="$artifact_dir/passive-frontmost-observer.err"
    rm -f \
        "$PASSIVE_OBSERVER_READY_FILE" \
        "$PASSIVE_OBSERVER_STOP_FILE" \
        "$PASSIVE_OBSERVER_TARGET_PID_FILE" \
        "$PASSIVE_OBSERVER_REPORT" \
        "$PASSIVE_OBSERVER_ERROR"

    "$DRIVER" observe-frontmost \
        --target-pid-file "$PASSIVE_OBSERVER_TARGET_PID_FILE" \
        --ready-file "$PASSIVE_OBSERVER_READY_FILE" \
        --stop-file "$PASSIVE_OBSERVER_STOP_FILE" \
        --timeout 300 \
        > "$PASSIVE_OBSERVER_REPORT" \
        2> "$PASSIVE_OBSERVER_ERROR" &
    PASSIVE_OBSERVER_PID="$!"

    for _ in {1..100}; do
        if [[ -s "$PASSIVE_OBSERVER_READY_FILE" ]]; then
            break
        fi
        if ! kill -0 "$PASSIVE_OBSERVER_PID" 2>/dev/null; then
            wait "$PASSIVE_OBSERVER_PID" 2>/dev/null || true
            echo "run-real-app-e2e.sh: passive frontmost observer exited before ready" >&2
            tail -n 20 "$PASSIVE_OBSERVER_ERROR" >&2 || true
            exit 5
        fi
        sleep 0.05
    done
    if [[ ! -s "$PASSIVE_OBSERVER_READY_FILE" ]]; then
        echo "run-real-app-e2e.sh: passive frontmost observer did not become ready" >&2
        exit 5
    fi
    python3 - "$PASSIVE_OBSERVER_READY_FILE" "$PASSIVE_OBSERVER_PID" <<'PY'
import json
import pathlib
import sys

ready = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(ready) != {
    "schemaVersion", "observerPID", "notificationObserverRegistered",
    "sampleIntervalMs",
}:
    raise SystemExit("passive observer ready file has an unexpected schema")
if ready["schemaVersion"] != 1:
    raise SystemExit("passive observer ready schema version is invalid")
if ready["observerPID"] != int(sys.argv[2]):
    raise SystemExit("passive observer ready PID does not match its process")
if ready["notificationObserverRegistered"] is not True:
    raise SystemExit("passive observer notification registration is not ready")
if ready["sampleIntervalMs"] != 25:
    raise SystemExit("passive observer sampling interval is not 25 ms")
PY
}

assert_passive_frontmost_observer_alive() {
    if [[ -z "$PASSIVE_OBSERVER_PID" ]] \
        || ! kill -0 "$PASSIVE_OBSERVER_PID" 2>/dev/null; then
        wait "$PASSIVE_OBSERVER_PID" 2>/dev/null || true
        echo "run-real-app-e2e.sh: passive frontmost observer exited early" >&2
        tail -n 20 "$PASSIVE_OBSERVER_ERROR" >&2 || true
        exit 5
    fi
}

publish_passive_target_pid() {
    local target_pid="$1"
    local temporary="$PASSIVE_OBSERVER_TARGET_PID_FILE.tmp.$$"
    assert_passive_frontmost_observer_alive
    printf '%s\n' "$target_pid" > "$temporary"
    mv "$temporary" "$PASSIVE_OBSERVER_TARGET_PID_FILE"
    assert_passive_frontmost_observer_alive
}

finish_passive_frontmost_observer() {
    local target_pid="$1"
    local target_lifecycle="${2:-exited}"
    local artifact_dir="${PASSIVE_ARTIFACT_DIR:-$SIZE_DIR}"
    local before="$artifact_dir/passive-desktop-before.json"
    local after="$artifact_dir/passive-desktop-after.json"
    local assertion="$artifact_dir/passive-lifecycle-assertion.json"
    local temporary_stop="$PASSIVE_OBSERVER_STOP_FILE.tmp.$$"
    local observer_pid="$PASSIVE_OBSERVER_PID"

    assert_passive_frontmost_observer_alive
    "$DRIVER" desktop-state > "$after"
    : > "$temporary_stop"
    mv "$temporary_stop" "$PASSIVE_OBSERVER_STOP_FILE"
    for _ in {1..100}; do
        kill -0 "$observer_pid" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$observer_pid" 2>/dev/null; then
        kill "$observer_pid" 2>/dev/null || true
        wait "$observer_pid" 2>/dev/null || true
        PASSIVE_OBSERVER_PID=""
        echo "run-real-app-e2e.sh: passive frontmost observer did not stop promptly" >&2
        exit 5
    fi
    local observer_status=0
    if wait "$observer_pid"; then
        observer_status=0
    else
        observer_status="$?"
    fi
    PASSIVE_OBSERVER_PID=""
    if [[ "$observer_status" -ne 0 ]]; then
        echo "run-real-app-e2e.sh: passive frontmost observer failed" >&2
        tail -n 20 "$PASSIVE_OBSERVER_ERROR" >&2 || true
        exit 5
    fi

    local lifecycle_options=()
    if [[ "$target_lifecycle" == "may-run" ]]; then
        lifecycle_options+=(--target-may-remain-running)
    elif [[ "$target_lifecycle" != "exited" ]]; then
        echo "run-real-app-e2e.sh: invalid passive target lifecycle: $target_lifecycle" >&2
        exit 2
    fi
    python3 "$PASSIVE_LIFECYCLE_VERIFIER" \
        --before "$before" \
        --after "$after" \
        --ready "$PASSIVE_OBSERVER_READY_FILE" \
        --observer "$PASSIVE_OBSERVER_REPORT" \
        --target-pid "$target_pid" \
        ${lifecycle_options[@]+"${lifecycle_options[@]}"} \
        --output "$assertion"
}

passive_visual_state_scroll_y() {
    local state="$1"
    local size="$2"
    if [[ "$state" != "table-editor" ]]; then
        printf '0\n'
        return 0
    fi
    # The authoritative table grid is centered at a fixed viewport position.
    # These offsets are the exact default page origin minus the reference page
    # origin for each required size. The diagnostic verifier proves that the
    # native scroll view reached the requested value before capture.
    case "$size" in
        1180x760) printf '2326\n' ;;
        860x560) printf '2516\n' ;;
        1440x900) printf '2256\n' ;;
        *)
            echo "run-real-app-e2e.sh: no deterministic table scroll for $size" >&2
            return 1
            ;;
    esac
}

validate_passive_main_window() {
    local metadata="$1"
    python3 - "$metadata" "$SIZE_WIDTH" "$SIZE_HEIGHT" "$CURRENT_PID" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    window = json.load(handle)
expected_width, expected_height = map(float, sys.argv[2:4])
expected_pid = int(sys.argv[4])
bounds = window["bounds"]
scale_x = bounds["width"] / expected_width
scale_y = bounds["height"] / expected_height
exact = math.isclose(scale_x, 1, abs_tol=0.0005) \
    and math.isclose(scale_y, 1, abs_tol=0.0005)
uniform_presentation_scale = 0.75 <= scale_x <= 1 \
    and 0.75 <= scale_y <= 1 \
    and math.isclose(scale_x, scale_y, abs_tol=0.005)
if not exact and not uniform_presentation_scale:
    raise SystemExit(
        f"window presentation mismatch: {bounds['width']}x{bounds['height']} "
        f"for logical {expected_width}x{expected_height}"
    )
if window["pid"] != expected_pid:
    raise SystemExit(f"passive window PID mismatch: {window['pid']} != {expected_pid}")
if window["owner"] != "MarkdownViewerDebug":
    raise SystemExit(f"unexpected window owner: {window['owner']}")
if window["layer"] != 0:
    raise SystemExit(f"passive main-window selection resolved layer {window['layer']}")
if window["onScreen"] is not False:
    raise SystemExit("passive main window is on screen")
PY
}

validate_passive_process_windows() {
    local process_windows_path="$1"
    local selected_window_path="$2"
    python3 - \
        "$process_windows_path" "$selected_window_path" "$CURRENT_PID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    process_windows = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    selected_window = json.load(handle)
expected_pid = int(sys.argv[3])
if not isinstance(process_windows, list) or not process_windows:
    raise SystemExit("passive process window list is empty or malformed")

window_numbers = []
selected_matches = 0
for index, process_window in enumerate(process_windows):
    if not isinstance(process_window, dict):
        raise SystemExit(f"passive process window {index} is not an object")
    if process_window.get("pid") != expected_pid:
        raise SystemExit(f"passive process window {index} PID mismatch")
    window_number = process_window.get("windowNumber")
    if isinstance(window_number, bool) or not isinstance(window_number, int) \
            or window_number <= 0:
        raise SystemExit(f"passive process window {index} has an invalid windowNumber")
    window_numbers.append(window_number)
    if window_number == selected_window.get("windowNumber"):
        selected_matches += 1
    if process_window.get("onScreen") is not False:
        raise SystemExit(f"passive process window {index} is on screen")

if len(window_numbers) != len(set(window_numbers)):
    raise SystemExit("passive process windowNumber values are not unique")
if selected_matches != 1:
    raise SystemExit(
        "passive process window list does not contain exactly one selected main window"
    )
PY
}

write_passive_sidebar_normalization() {
    python3 - "$CURRENT_PID" "$INTERACTION_TIER" \
        > "$SIZE_DIR/sidebar-normalization.json" <<'PY'
import json
import sys

print(json.dumps({
    "pid": int(sys.argv[1]),
    "accessibilityTrusted": False,
    "previousValue": None,
    "currentValue": None,
    "reset": False,
    "reason": "interaction-tier-forbids-sidebar-filter-mutation",
    "interactionTier": sys.argv[2],
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

run_passive_visual_matrix_for_size() {
    local state_spec state label state_dir expected_scroll state_pid
    local state_window state_process_windows state_launch
    local representative_pid="" representative_state=""
    for state_spec in "${PASSIVE_VISUAL_STATES[@]}"; do
        state="${state_spec%%:*}"
        label="${state_spec#*:}"
        state_dir="$SIZE_DIR/states/$state"
        expected_scroll="$(passive_visual_state_scroll_y "$state" "$SIZE")"
        PROFILE_ROOT="$OUTPUT/profiles/$SIZE/$state"
        PASSIVE_ARTIFACT_DIR="$state_dir"
        state_window="$state_dir/window.json"
        state_process_windows="$state_dir/process-windows.json"
        state_launch="$state_dir/visual-state-launch.json"
        mkdir -p "$state_dir"

        "$DRIVER" desktop-state > "$state_dir/passive-desktop-before.json"
        start_passive_frontmost_observer

        : > "$state_dir/launch.log"
        local launch_succeeded=0
        local attempt
        for attempt in 1 2 3; do
            printf 'Launch attempt %s\n' "$attempt" >> "$state_dir/launch.log"
            assert_debug_app_binary_unchanged
            if "$ROOT/scripts/run-debug.sh" \
                --reset \
                --background \
                --skip-build \
                --visual-test-root "$PROFILE_ROOT" \
                --visual-test-size "$SIZE" \
                --visual-test-state "$state" \
                --visual-test-scroll "$expected_scroll" \
                --visual-test-hide-hud \
                >> "$state_dir/launch.log" 2>&1; then
                launch_succeeded=1
                break
            fi
            sleep 0.5
        done
        if [[ "$launch_succeeded" -ne 1 ]]; then
            echo "run-real-app-e2e.sh: Debug app launch failed for $SIZE/$state" >&2
            tail -n 20 "$state_dir/launch.log" >&2
            exit 4
        fi

        CURRENT_PID="$(tr -dc '0-9' < "$PROFILE_ROOT/app.pid")"
        CURRENT_BINARY="$DEBUG_APP_BINARY"
        CURRENT_PROFILE_ROOT="$PROFILE_ROOT"
        if [[ ! -f "$PROFILE_ROOT/launch.token" ]]; then
            echo "run-real-app-e2e.sh: Debug app launch token is missing for $SIZE/$state" >&2
            exit 4
        fi
        CURRENT_LAUNCH_TOKEN="$(tr -dc '[:alnum:]-' < "$PROFILE_ROOT/launch.token")"
        if [[ -z "$CURRENT_PID" ]] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then
            echo "run-real-app-e2e.sh: Debug app did not remain running for $SIZE/$state" >&2
            exit 4
        fi
        if [[ -z "$CURRENT_LAUNCH_TOKEN" ]] || ! debug_process_matches_identity \
            "$CURRENT_PID" "$CURRENT_BINARY" \
            "$CURRENT_PROFILE_ROOT" "$CURRENT_LAUNCH_TOKEN"; then
            echo "run-real-app-e2e.sh: Debug app identity mismatch for $SIZE/$state" >&2
            exit 4
        fi
        state_pid="$CURRENT_PID"
        publish_passive_target_pid "$state_pid"

        "$DRIVER" window \
            --pid "$CURRENT_PID" \
            --timeout 8 \
            --width "$SIZE_WIDTH" \
            --height "$SIZE_HEIGHT" \
            --allow-uniform-presentation-scale \
            --include-offscreen \
            --require-offscreen \
            --main-window-only \
            > "$state_window"
        validate_passive_main_window "$state_window"
        WINDOW_NUMBER="$(python3 - "$state_window" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["windowNumber"])
PY
        )"
        assert_passive_frontmost_observer_alive

        "$DRIVER" windows \
            --pid "$CURRENT_PID" \
            --include-offscreen \
            > "$state_process_windows"
        validate_passive_process_windows \
            "$state_process_windows" "$state_window"

        python3 "$VISUAL_LAUNCH_VERIFIER" \
            --diagnostic "$PROFILE_ROOT/Diagnostics/state.json" \
            --window "$state_window" \
            --process-windows "$state_process_windows" \
            --profile-root "$PROFILE_ROOT" \
            --requested-state "$state" \
            --logical-size "$SIZE" \
            --expected-scroll-y "$expected_scroll" \
            --pid "$CURRENT_PID" \
            --output "$state_launch" \
            --timeout 5
        capture_window "$label"

        if [[ -z "$representative_pid" ]]; then
            representative_pid="$state_pid"
            representative_state="$state"
            cp "$state_window" "$SIZE_DIR/window.json"
        fi

        if [[ "$state" == "default" ]]; then
            cp "$state_launch" "$SIZE_DIR/visual-state-launch-baseline.json"
            write_passive_sidebar_normalization
            "$DRIVER" sidebar \
                --passive \
                --pid "$CURRENT_PID" \
                --screenshot "$SIZE_DIR/baseline.png" \
                > "$SIZE_DIR/sidebar.json"
        fi

        assert_passive_frontmost_observer_alive
        if ! stop_current_app; then
            echo "run-real-app-e2e.sh: passive target did not exit for $SIZE/$state" >&2
            exit 5
        fi
        finish_passive_frontmost_observer "$state_pid"
        printf '%s\n' "$state_launch" >> "$VISUAL_STATE_LAUNCH_LIST"
        printf '%s\n' "$state_dir/passive-lifecycle-assertion.json" \
            >> "$PASSIVE_LIFECYCLE_LIST"
        if [[ "$state" == "default" ]]; then
            cp "$state_dir/passive-lifecycle-assertion.json" \
                "$PASSIVE_LIFECYCLE_ASSERTION"
        fi
    done
    unset PASSIVE_ARTIFACT_DIR
    if [[ -z "$representative_pid" || -z "$representative_state" ]]; then
        echo "run-real-app-e2e.sh: passive visual launch was not recorded" >&2
        exit 5
    fi
    if [[ ! -f "$SIZE_DIR/sidebar.json" ]]; then
        python3 - "$representative_state" > "$SIZE_DIR/sidebar.json" <<'PY'
import json
import sys

print(json.dumps({
    "observed": False,
    "reason": "development-probe-did-not-capture-default-sidebar",
    "representativeVisualState": sys.argv[1],
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    fi
    if [[ ! -f "$SIZE_DIR/sidebar-normalization.json" ]]; then
        python3 - "$representative_state" \
            > "$SIZE_DIR/sidebar-normalization.json" <<'PY'
import json
import sys

print(json.dumps({
    "reset": False,
    "reason": "development-probe-did-not-capture-default-sidebar",
    "representativeVisualState": sys.argv[1],
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    fi
    SIZE_APP_PID="$representative_pid"
    SIZE_REPRESENTATIVE_VISUAL_STATE="$representative_state"
}

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for SIZE in "${SIZES[@]}"; do
    stop_current_app
    SIZE_WIDTH="${SIZE%x*}"
    SIZE_HEIGHT="${SIZE#*x}"
    SIZE_DIR="$OUTPUT/sizes/$SIZE"
    PROFILE_ROOT="$OUTPUT/profiles/$SIZE"
    SIZE_APP_PID=""
    SIZE_REPRESENTATIVE_VISUAL_STATE=""
    mkdir -p "$SIZE_DIR"
    ACTION_LIST="$SIZE_DIR/action-files.txt"
    COMPARISON_LIST="$SIZE_DIR/comparison-files.txt"
    SCREENSHOT_LIST="$SIZE_DIR/screenshot-files.txt"
    SESSION_ASSERTION_LIST="$SIZE_DIR/session-assertion-files.txt"
    DIAGNOSTIC_LIST="$SIZE_DIR/diagnostic-files.txt"
    VISUAL_ASSERTION_LIST="$SIZE_DIR/visual-assertion-files.txt"
    FOREGROUND_CHECKPOINT_LIST="$SIZE_DIR/foreground-checkpoint-files.txt"
    FOREGROUND_PLAN_VALIDATION="$SIZE_DIR/foreground-plan-validation.json"
    FOREGROUND_REPORT="$SIZE_DIR/foreground-report.json"
    SESSION_RELAUNCH="$SIZE_DIR/session-relaunch.json"
    PASSIVE_LIFECYCLE_ASSERTION="$SIZE_DIR/passive-lifecycle-assertion.json"
    PASSIVE_LIFECYCLE_LIST="$SIZE_DIR/passive-lifecycle-assertion-files.txt"
    VISUAL_STATE_LAUNCH_LIST="$SIZE_DIR/visual-state-launch-files.txt"
    : > "$ACTION_LIST"
    : > "$COMPARISON_LIST"
    : > "$SCREENSHOT_LIST"
    : > "$SESSION_ASSERTION_LIST"
    : > "$DIAGNOSTIC_LIST"
    : > "$VISUAL_ASSERTION_LIST"
    : > "$FOREGROUND_CHECKPOINT_LIST"
    : > "$PASSIVE_LIFECYCLE_LIST"
    : > "$VISUAL_STATE_LAUNCH_LIST"
    printf 'null\n' > "$FOREGROUND_PLAN_VALIDATION"
    printf 'null\n' > "$FOREGROUND_REPORT"
    printf 'null\n' > "$SESSION_RELAUNCH"
    printf 'null\n' > "$PASSIVE_LIFECYCLE_ASSERTION"

    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        run_passive_visual_matrix_for_size
    else

    FOREGROUND_LAUNCH_OPTIONS=(
        --visual-test-state default
        --visual-test-scroll 0
    )
    if [[ "$FOREGROUND_BATCH_NAME" == "block-activation" \
        || "$FOREGROUND_BATCH_NAME" == "sidebar-filter-navigation" \
        || "$FOREGROUND_BATCH_NAME" == "sidebar-layout-controls" \
        || "$FOREGROUND_BATCH_NAME" == "tab-session-lifecycle" \
        || "$FOREGROUND_BATCH_NAME" == "save-lifecycle" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 0
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "preview-content" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 1600
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "preview-footnotes" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 3000
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "outline-navigation" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 650
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "table-controls" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 2326
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "table-navigation" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 2326
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "editor-structure" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 650
        )
    elif [[ "$FOREGROUND_BATCH_NAME" == "editor-boundaries" ]]; then
        FOREGROUND_LAUNCH_OPTIONS=(
            --visual-test-state default
            --visual-test-scroll 500
        )
    fi
    FOREGROUND_HUD_OPTIONS=(--visual-test-hide-hud)
    if [[ "$FOREGROUND_BATCH_NAME" == "save-lifecycle" ]]; then
        FOREGROUND_HUD_OPTIONS=(--show-hud)
    fi
    : > "$SIZE_DIR/launch.log"
    LAUNCH_SUCCEEDED=0
    for attempt in 1 2 3; do
        printf 'Launch attempt %s\n' "$attempt" >> "$SIZE_DIR/launch.log"
        assert_debug_app_binary_unchanged
        if "$ROOT/scripts/run-debug.sh" \
            --reset \
            --background \
            --skip-build \
            --visual-test-root "$PROFILE_ROOT" \
            --visual-test-size "$SIZE" \
            "${FOREGROUND_LAUNCH_OPTIONS[@]}" \
            "${FOREGROUND_HUD_OPTIONS[@]}" \
            >> "$SIZE_DIR/launch.log" 2>&1; then
            LAUNCH_SUCCEEDED=1
            break
        fi
        sleep 0.5
    done
    if [[ "$LAUNCH_SUCCEEDED" -ne 1 ]]; then
        echo "run-real-app-e2e.sh: Debug app launch failed after 3 attempts for $SIZE" >&2
        tail -n 20 "$SIZE_DIR/launch.log" >&2
        exit 4
    fi
    CURRENT_PID="$(tr -dc '0-9' < "$PROFILE_ROOT/app.pid")"
    CURRENT_BINARY="$DEBUG_APP_BINARY"
    CURRENT_PROFILE_ROOT="$PROFILE_ROOT"
    if [[ ! -f "$PROFILE_ROOT/launch.token" ]]; then
        echo "run-real-app-e2e.sh: Debug app launch token is missing" >&2
        exit 4
    fi
    CURRENT_LAUNCH_TOKEN="$(tr -dc '[:alnum:]-' < "$PROFILE_ROOT/launch.token")"
    if [[ -z "$CURRENT_PID" ]] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then
        echo "run-real-app-e2e.sh: Debug app did not remain running for $SIZE" >&2
        exit 4
    fi
    if [[ -z "$CURRENT_LAUNCH_TOKEN" ]] || ! debug_process_matches_identity \
        "$CURRENT_PID" "$CURRENT_BINARY" \
        "$CURRENT_PROFILE_ROOT" "$CURRENT_LAUNCH_TOKEN"; then
        echo "run-real-app-e2e.sh: Debug app launch identity does not match its profile" >&2
        exit 4
    fi
    SIZE_APP_PID="$CURRENT_PID"
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        publish_passive_target_pid "$SIZE_APP_PID"
    fi

    WINDOW_LOOKUP_OPTIONS=(
        --allow-uniform-presentation-scale
        --include-offscreen
    )
    "$DRIVER" window \
        --pid "$CURRENT_PID" \
        --timeout 8 \
        --width "$SIZE_WIDTH" \
        --height "$SIZE_HEIGHT" \
        "${WINDOW_LOOKUP_OPTIONS[@]}" \
        > "$SIZE_DIR/window.json"
    python3 - "$SIZE_DIR/window.json" "$SIZE_WIDTH" "$SIZE_HEIGHT" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    window = json.load(handle)
expected_width, expected_height = map(float, sys.argv[2:4])
bounds = window["bounds"]
scale_x = bounds["width"] / expected_width
scale_y = bounds["height"] / expected_height
exact = math.isclose(scale_x, 1, abs_tol=0.0005) \
    and math.isclose(scale_y, 1, abs_tol=0.0005)
uniform_presentation_scale = 0.75 <= scale_x <= 1 \
    and 0.75 <= scale_y <= 1 \
    and math.isclose(scale_x, scale_y, abs_tol=0.005)
if not exact and not uniform_presentation_scale:
    raise SystemExit(
        f"window presentation mismatch: {bounds['width']}x{bounds['height']} "
        f"for logical {expected_width}x{expected_height}"
    )
if window["owner"] != "MarkdownViewerDebug":
    raise SystemExit(f"unexpected window owner: {window['owner']}")
PY
    WINDOW_NUMBER="$(python3 - "$SIZE_DIR/window.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["windowNumber"])
PY
    )"
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        assert_passive_frontmost_observer_alive
    fi
    if [[ "$STATIC_ONLY" -eq 1 || "$FOREGROUND_SMOKE" -eq 1 ]]; then
        python3 - "$CURRENT_PID" "$ACCESSIBILITY_TRUSTED" "$INTERACTION_TIER" \
            > "$SIZE_DIR/sidebar-normalization.json" <<'PY'
import json
import sys

print(json.dumps({
    "pid": int(sys.argv[1]),
    "accessibilityTrusted": sys.argv[2] == "1",
    "previousValue": None,
    "currentValue": None,
    "reset": False,
    "reason": "interaction-tier-forbids-sidebar-filter-mutation",
    "interactionTier": sys.argv[3],
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    elif [[ "$ACCESSIBILITY_TRUSTED" == "1" ]]; then
        if ! "$DRIVER" reset-sidebar-filter \
            --pid "$CURRENT_PID" \
            > "$SIZE_DIR/sidebar-normalization.json" \
            2> "$SIZE_DIR/sidebar-normalization.err"; then
            python3 - \
                "$CURRENT_PID" "$SIZE_DIR/sidebar-normalization.err" \
                > "$SIZE_DIR/sidebar-normalization.json" <<'PY'
import json
import pathlib
import sys

pid, error_path = sys.argv[1:3]
print(json.dumps({
    "pid": int(pid),
    "accessibilityTrusted": True,
    "previousValue": None,
    "currentValue": None,
    "reset": False,
    "reason": pathlib.Path(error_path).read_text(encoding="utf-8").strip(),
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
        fi
    else
        python3 - "$CURRENT_PID" > "$SIZE_DIR/sidebar-normalization.json" <<'PY'
import json
import sys

print(json.dumps({
    "pid": int(sys.argv[1]),
    "accessibilityTrusted": False,
    "previousValue": None,
    "currentValue": None,
    "reset": False,
    "reason": "accessibility-unavailable",
}, ensure_ascii=False, indent=2, sort_keys=True))
PY
    fi
    if [[ "$EXTENDED_FULL_POINTER" -eq 1 ]]; then
        record_action "pointer-rest" "move:outside"
    fi
    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        record_diagnostic_snapshot "baseline" "edit"
        sleep 0.1
        capture_window "baseline"
    else
        sleep 0.8
        capture_window "baseline"
        record_diagnostic_snapshot "baseline" "edit"
    fi
    if [[ "$STATIC_ONLY" -eq 1 || "$FOREGROUND_SMOKE" -eq 1 ]]; then
        "$DRIVER" sidebar \
            --passive \
            --pid "$CURRENT_PID" \
            --screenshot "$SIZE_DIR/baseline.png" \
            > "$SIZE_DIR/sidebar.json"
    else
        "$DRIVER" sidebar \
            --pid "$CURRENT_PID" \
            --screenshot "$SIZE_DIR/baseline.png" \
            > "$SIZE_DIR/sidebar.json"
    fi

    if [[ "$FOREGROUND_SMOKE" -eq 1 ]]; then
        run_foreground_smoke
    fi

    if [[ "$EXTENDED_FULL_POINTER" -eq 1 ]]; then
        record_action "outline-hover" "move:outline"
        capture_window "outline-expanded"
        record_comparison "outline-expanded" "baseline" "outline-expanded" "0.001"
        record_action "outline-leave" "move:outside"
    fi

    if [[ "$KEYBOARD_ONLY" -eq 1 || "$EXTENDED_FULL_POINTER" -eq 1 ]]; then
        record_action "sidebar-hide" "key:command+backslash"
        capture_window "sidebar-hidden"
        record_comparison "sidebar-hidden" "baseline" "sidebar-hidden" "0.05"
        record_action "sidebar-show" "key:command+backslash"

        record_action "preview-on" "key:command+shift+p"
        capture_window "preview-on"
        record_diagnostic_snapshot "preview-on" "preview"
        record_comparison "preview-on" "baseline" "preview-on" "0.00001"
        record_action "preview-off" "key:command+shift+p"
        sleep 1.8

        record_action "palette-open" "key:command+k"
        capture_window "palette-open"
        record_comparison "palette-open" "baseline" "palette-open" "0.10"

        record_action "palette-filter" "text:字号"
        capture_window "palette-filtered"

        record_action "palette-close" "key:escape"
        capture_window "palette-closed"
        record_comparison "palette-close" "palette-filtered" "palette-closed" "0.10"

        record_action "find-open" "key:command+f"
        capture_window "find-open"
        record_comparison "find-open" "baseline" "find-open" "0.005"

        record_action "find-query" "text:一级标题" "key:return" "key:shift+return"
        capture_window "find-results"
        record_diagnostic_snapshot "find-results" "edit" "一级标题"
        record_comparison "find-results" "find-open" "find-results" "0.0005"

        record_action "find-close" "key:escape"
        capture_window "find-closed"

        if [[ "$KEYBOARD_ONLY" -eq 1 ]]; then
            record_action "find-scroll" \
                "key:command+f" \
                "key:command+a" \
                "text:脚注" \
                "key:return" \
                "key:escape"
        else
            record_action "pointer-scroll" \
                "scroll:-650" \
                "scroll:-650" \
                "scroll:-650"
        fi
        capture_window "scrolled"
        record_diagnostic_snapshot "scrolled" "edit"
        record_comparison "scrolled" "find-closed" "scrolled" "0.01"

        if [[ "$KEYBOARD_ONLY" -eq 1 && "$SIZE" == "1180x760" ]]; then
            record_action_with_delay \
                "palette-double-shift" "0.08" \
                "modifier:shift" "modifier:shift"
            capture_window "palette-double-shift"
            record_comparison \
                "palette-double-shift" "scrolled" "palette-double-shift" "0.05"
            record_action "palette-double-shift-close" "key:escape"

            record_action "palette-command-preview" \
                "key:command+k" \
                "text:切换纯预览" \
                "key:return"
            capture_window "palette-command-preview"
            record_diagnostic_snapshot "palette-command-preview" "preview"
            record_action "palette-command-preview-off" "key:command+shift+p"
            sleep 1.8

            record_action "open-plain-source" \
                "key:command+k" \
                "text:config.yaml" \
                "key:return"
            capture_window "plain-source"
            assert_active_session_document "plain-source" "config.yaml" "false"
            record_diagnostic_snapshot \
                "plain-source" "source" "" "config.yaml" \
                "null" "absent" "present"

            record_action "return-fixture" \
                "key:command+k" \
                "text:格式示例.md" \
                "key:return"
            assert_active_session_document "fixture-return" "格式示例.md" "true"

            record_action "new-untitled" "key:command+n" "text:E2E_UNTITLED"
            capture_window "untitled-dirty"
            record_diagnostic_snapshot "untitled-dirty" "edit" "" "未命名.md"
            assert_session_marker "untitled" "E2E_UNTITLED"

            record_action "untitled-close-confirm" "key:command+w"
            capture_window "untitled-close-confirm"
            record_action "untitled-close-discard" "key:command+w"
            capture_window "after-untitled-close"

            record_action "untitled-reopen" "key:command+shift+t"
            capture_window "untitled-reopened"
            record_diagnostic_snapshot "untitled-reopened" "edit" "" "未命名.md"
            assert_session_marker "untitled-reopened" "E2E_UNTITLED"

            record_action "untitled-reclose-confirm" "key:command+w"
            record_action "untitled-reclose-discard" "key:command+w"
            record_action "activate-plain-source-for-close" \
                "key:command+k" \
                "text:config.yaml" \
                "key:return"
            assert_active_session_document "plain-source-before-close" "config.yaml" "false"
            record_action "plain-source-close" "key:command+w"
            assert_active_session_document "fixture-before-close" "格式示例.md" "true"
            record_action "fixture-close" "key:command+w"
            capture_window "empty-state"
            assert_empty_session "empty-state"
            record_diagnostic_snapshot \
                "empty-workspace" "empty" "" "" \
                "null" "absent" "absent"
            record_visual_text_assertion \
                "empty-state" "empty-state" \
                --contains "没有打开的文档" \
                --contains "新建" \
                --contains "打开一篇" \
                --not-contains "1,599 字" \
                --not-contains "113 行"
            record_comparison "empty-state" "baseline" "empty-state" "0.01"
            record_action "fixture-reopen" "key:command+shift+t"
            capture_window "fixture-reopened"
            record_diagnostic_snapshot "fixture-reopened" "edit"
            assert_active_session_document "fixture-reopened" "格式示例.md" "true"
        fi

        if [[ "$KEYBOARD_ONLY" -ne 1 ]]; then
            assert_fixture_source_state "pointer-visual-start" "clean"
            record_action "table-target-search" \
                "key:command+f" \
                "key:command+a" \
                "text:快捷键" \
                "key:escape"
            capture_window "table-target"
            record_text_click_action "table-open" "table-target" "快捷键"
            capture_window "table-grid"
            record_diagnostic_snapshot \
                "table-grid" "edit" "" "格式示例.md" \
                "table" "present" "absent"
            record_comparison "table-grid" "scrolled" "table-grid" "0.005"
            assert_fixture_source_state "table-grid-clean" "clean"
            record_action "table-visual-close" "key:escape"

            record_action "source-target-search" \
                "key:command+f" \
                "key:command+a" \
                "text:Markdown 全格式示例" \
                "key:escape"
            capture_window "source-target"
            record_text_click_action \
                "source-open" "source-target" "Markdown 全格式示例"
            capture_window "source-editing"
            record_diagnostic_snapshot \
                "source-editing" "edit" "" "格式示例.md" \
                "heading" "absent" "present"
            record_comparison "source-editing" "baseline" "source-editing" "0.0005"
            assert_fixture_source_state "source-editing-clean" "clean"
            record_action "source-visual-close" "key:escape"
            assert_fixture_source_state "visual-states-clean" "clean"

            if [[ "$SIZE" == "1180x760" ]]; then
                record_action "find-replace-new-document" \
                    "key:command+n" \
                    "text:red red RED redwood red"
                record_action "find-replace-open" "key:command+f"
                record_action "find-replace-instant-query" "text:red"
                capture_window "find-replace-instant"
                record_find_diagnostic_snapshot \
                    "find-replace-instant" "red" "1/5" "5" "0" "false" "false"
                assert_find_replace_session "find-replace-initial" "initial"

                record_action "find-replace-previous-wrap" "key:shift+return"
                capture_window "find-replace-previous-wrap"
                record_find_diagnostic_snapshot \
                    "find-replace-previous-wrap" "red" "5/5" "5" "4" "false" "false"

                record_action "find-replace-next-wrap" "key:return"
                record_find_diagnostic_snapshot \
                    "find-replace-next-wrap" "red" "1/5" "5" "0" "false" "false"

                record_action "find-replace-whole-word" "find-click:whole-word"
                capture_window "find-replace-whole-word"
                record_find_diagnostic_snapshot \
                    "find-replace-whole-word" "red" "1/4" "4" "0" "false" "true"

                record_action "find-replace-disclosure" "find-click:disclosure"
                record_action "find-replace-value" \
                    "find-click:replace-field" \
                    "key:command+a" \
                    "text:blue"
                record_action "find-replace-disclosure-refresh" \
                    "find-click:query-field" \
                    "key:command+a" \
                    "text:red"
                capture_window "find-replace-disclosure"
                record_find_diagnostic_snapshot \
                    "find-replace-disclosure" "red" "1/4" "4" "0" "true" "true"
                record_visual_text_assertion \
                    "find-replace-disclosure" "find-replace-disclosure" \
                    --contains "替换" \
                    --contains "全部替换"
                record_comparison \
                    "find-replace-disclosure" \
                    "find-replace-whole-word" \
                    "find-replace-disclosure" \
                    "0.005"

                record_action "find-replace-current" "find-click:replace-current"
                capture_window "find-replace-current"
                record_find_diagnostic_snapshot \
                    "find-replace-current" "red" "1/3" "3" "0" "true" "true"
                assert_find_replace_session \
                    "find-replace-current" "replace-current"

                record_action "find-replace-all" "find-click:replace-all"
                capture_window "find-replace-all"
                record_find_diagnostic_snapshot \
                    "find-replace-all" "red" "无结果" "0" "0" "true" "true"
                assert_find_replace_session "find-replace-all" "replace-all"

                record_action "find-replace-reset-whole-word" "find-click:whole-word"
                record_action "find-replace-close" "key:escape"
                record_action "find-replace-tab-close-confirm" "key:command+w"
                record_action "find-replace-tab-close-discard" "key:command+w"
                assert_active_session_document \
                    "find-replace-fixture-return" "格式示例.md" "true"
                assert_fixture_source_state \
                    "find-replace-fixture-unchanged" "clean"
            fi

            record_action "table-mutation-target-search" \
                "key:command+f" \
                "key:command+a" \
                "text:快捷键" \
                "key:escape"
            record_text_click_action \
                "table-mutation-open" "table-target" "快捷键"
            record_action "table-edit" "text:E2E_TABLE" "key:tab" "key:escape"
            capture_window "table-committed"
            record_diagnostic_snapshot \
                "table-committed" "edit" "" "格式示例.md" \
                "null" "absent" "absent"
            assert_fixture_source_state "table-committed" "table"

            record_action "source-mutation-target-search" \
                "key:command+f" \
                "key:command+a" \
                "text:Markdown 全格式示例" \
                "key:escape"
            record_text_click_action \
                "source-mutation-open" "source-target" "Markdown 全格式示例"
            record_action "source-edit" "text: E2E_SOURCE" "key:escape"
            capture_window "source-committed"
            record_diagnostic_snapshot \
                "source-committed" "edit" "" "格式示例.md" \
                "null" "absent" "absent"
            assert_fixture_source_state "source-committed" "table-source"
        fi
    fi

    if [[ "$STATIC_ONLY" -eq 1 ]]; then
        assert_passive_frontmost_observer_alive
        if ! stop_current_app; then
            echo "run-real-app-e2e.sh: passive target did not exit safely before observer stop" >&2
            exit 5
        fi
        finish_passive_frontmost_observer "$SIZE_APP_PID"
    fi
    fi

    python3 - \
        "$SIZE" "$SIZE_APP_PID" "$SIZE_DIR/window.json" \
        "$ACTION_LIST" "$SCREENSHOT_LIST" "$COMPARISON_LIST" "$SIZE_DIR/sidebar.json" \
        "$SIZE_DIR/sidebar-normalization.json" \
        "$SESSION_ASSERTION_LIST" \
        "$DIAGNOSTIC_LIST" \
        "$VISUAL_ASSERTION_LIST" \
        "$FOREGROUND_CHECKPOINT_LIST" \
        "$FOREGROUND_PLAN_VALIDATION" \
        "$FOREGROUND_REPORT" \
        "$SESSION_RELAUNCH" \
        "$PASSIVE_LIFECYCLE_ASSERTION" \
        "$PASSIVE_LIFECYCLE_LIST" \
        "$VISUAL_STATE_LAUNCH_LIST" \
        "$INTERACTION_TIER" \
        "$FOREGROUND_BATCH_NAME" \
        "$EVIDENCE_MODE" \
        "$RUN_SCOPE" \
        "$STRICT_VISUAL_ACCEPTANCE_ELIGIBLE" \
        "$VISUAL_STATE_NAMES_CSV" \
        "$SIZE_REPRESENTATIVE_VISUAL_STATE" \
        > "$SIZE_DIR/manifest.json" <<'PY'
import json
import pathlib
import sys

(
    size,
    pid,
    window_path,
    action_list,
    screenshot_list,
    comparison_list,
    sidebar_path,
    sidebar_normalization_path,
    session_assertion_list,
    diagnostic_list,
    visual_assertion_list,
    foreground_checkpoint_list,
    foreground_plan_validation_path,
    foreground_report_path,
    session_relaunch_path,
    passive_lifecycle_assertion_path,
    passive_lifecycle_list,
    visual_state_launch_list,
    interaction_tier,
    foreground_batch_name,
    mode,
    run_scope,
    strict_visual_acceptance_eligible,
    requested_visual_states_csv,
    representative_visual_state,
) = sys.argv[1:26]

def load_paths(list_path):
    paths = pathlib.Path(list_path).read_text(encoding="utf-8").splitlines()
    return [json.loads(pathlib.Path(path).read_text(encoding="utf-8")) for path in paths]

window = json.loads(pathlib.Path(window_path).read_text(encoding="utf-8"))
sidebar = json.loads(pathlib.Path(sidebar_path).read_text(encoding="utf-8"))
sidebar_normalization = json.loads(
    pathlib.Path(sidebar_normalization_path).read_text(encoding="utf-8")
)
visual_state_launches = load_paths(visual_state_launch_list)
foreground_plan_validation = json.loads(
    pathlib.Path(foreground_plan_validation_path).read_text(encoding="utf-8")
)
foreground_report = json.loads(
    pathlib.Path(foreground_report_path).read_text(encoding="utf-8")
)
session_relaunch = json.loads(
    pathlib.Path(session_relaunch_path).read_text(encoding="utf-8")
)
requested_visual_states = (
    requested_visual_states_csv.split(",") if interaction_tier == "passive" else []
)
resolved_visual_states = [
    launch.get("requestedState") for launch in visual_state_launches
]
required_visual_states = [
    "default", "palette", "find", "preview", "sidebar-hidden",
    "source-editor", "table-editor",
]
manifest = {
    "status": "passed",
    "interactionTier": interaction_tier,
    "foregroundBatchName": foreground_batch_name or None,
    "mode": mode,
    "runScope": run_scope,
    "strictVisualAcceptanceEligible": strict_visual_acceptance_eligible == "1",
    "size": size,
    "pid": int(pid),
    "window": window,
    "actions": load_paths(action_list),
    "screenshots": load_paths(screenshot_list),
    "comparisons": load_paths(comparison_list),
    "sidebar": sidebar,
    "sidebarNormalization": sidebar_normalization,
    "sessionAssertions": load_paths(session_assertion_list),
    "diagnostics": load_paths(diagnostic_list),
    "visualAssertions": load_paths(visual_assertion_list),
    "foregroundCheckpoints": load_paths(foreground_checkpoint_list),
    "foregroundPlanValidation": foreground_plan_validation,
    "foregroundReport": foreground_report,
    "foregroundPhases": (
        foreground_report.get("phases", [])
        if isinstance(foreground_report, dict) else []
    ),
    "sessionRelaunch": session_relaunch,
    "passiveLifecycleAssertion": json.loads(
        pathlib.Path(passive_lifecycle_assertion_path).read_text(encoding="utf-8")
    ),
    "passiveLifecycleAssertions": load_paths(passive_lifecycle_list),
    "visualStateLaunches": visual_state_launches,
    "requestedVisualStates": requested_visual_states,
    "representativeVisualState": representative_visual_state or None,
    "coverage": {
        "visualCoverageApplicable": interaction_tier == "passive",
        "requiredVisualStates": required_visual_states,
        "requestedVisualStates": requested_visual_states,
        "requiredPairCount": len(required_visual_states),
        "requestedPairCount": len(requested_visual_states),
        "resolvedPairCount": len(visual_state_launches),
        "requestedPairsComplete": (
            interaction_tier == "passive"
            and len(resolved_visual_states) == len(set(resolved_visual_states))
            and set(resolved_visual_states) == set(requested_visual_states)
        ),
        "strictMatrixComplete": (
            strict_visual_acceptance_eligible == "1"
            and requested_visual_states == required_visual_states
            and resolved_visual_states == required_visual_states
        ),
    },
    "interactionCoverage": {
        "applicable": interaction_tier == "foreground-smoke",
        "requestedBatchName": (
            foreground_batch_name if interaction_tier == "foreground-smoke" else None
        ),
        "plannedActionCount": (
            len(foreground_plan_validation.get("actions", []))
            if interaction_tier == "foreground-smoke" else 0
        ),
        "phaseCount": (
            foreground_report.get("phaseCount", 1)
            if interaction_tier == "foreground-smoke"
                and isinstance(foreground_report, dict) else 0
        ),
        "perPhaseBudgetMs": (
            foreground_report.get("perPhaseBudgetMs")
            if interaction_tier == "foreground-smoke"
                and isinstance(foreground_report, dict) else None
        ),
        "completedActionCount": (
            sum(
                action.get("status") == "completed"
                for action in (foreground_report or {}).get("actions", [])
            ) if interaction_tier == "foreground-smoke" else 0
        ),
        "allPlannedActionsCompleted": (
            foreground_report.get("completed") is True
            and len(foreground_report.get("actions", []))
                == len(foreground_plan_validation.get("actions", []))
            and all(
                action.get("status") == "completed"
                for action in foreground_report.get("actions", [])
            )
            if interaction_tier == "foreground-smoke" else False
        ),
        "targetActivationRequestCount": (
            foreground_report.get("targetActivationRequestCount")
            if interaction_tier == "foreground-smoke" else 0
        ),
        "interferenceDetected": (
            foreground_report.get("interference", {}).get("detected")
            if interaction_tier == "foreground-smoke" else False
        ),
        "deadlineExceeded": (
            foreground_report.get("deadlineExceeded")
            if interaction_tier == "foreground-smoke" else False
        ),
        "focusRestored": (
            foreground_report.get("focusRestore", {}).get("restored")
            if interaction_tier == "foreground-smoke" else False
        ),
        "pointerRestored": (
            foreground_report.get("pointerRestore", {}).get("restored")
            if interaction_tier == "foreground-smoke" else False
        ),
        "pasteboardRestored": (
            foreground_report.get("pasteboardRestore", {}).get("restored")
            if interaction_tier == "foreground-smoke" else False
        ),
    },
}
hashes = [item["sha256"] for item in manifest["screenshots"]]
duplicate_groups = {
    value: [item["label"] for item in manifest["screenshots"] if item["sha256"] == value]
    for value in sorted(set(hashes))
    if hashes.count(value) > 1
}
allowed_equivalent_labels = {
    frozenset({"palette-closed", "find-closed"}),
    frozenset({"baseline", "foreground-baseline"}),
    frozenset({"baseline", "table-reading-rest"}),
}
equivalent_groups = []
unexpected_duplicates = []
for sha, labels in duplicate_groups.items():
    if frozenset(labels) in allowed_equivalent_labels:
        equivalent_groups.append({"sha256": sha, "labels": labels})
    else:
        unexpected_duplicates.append(sha)
manifest["equivalentScreenshotGroups"] = equivalent_groups
manifest["duplicateScreenshotHashes"] = unexpected_duplicates
if unexpected_duplicates:
    raise SystemExit(
        f"unexpected duplicate screenshot hashes for {size}: {unexpected_duplicates}"
    )
print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
PY

    if [[ "$KEEP_LAST_APP" -eq 1 && "$SIZE" == "$LAST_SIZE" ]]; then
        CURRENT_PID=""
        CURRENT_BINARY=""
        CURRENT_PROFILE_ROOT=""
        CURRENT_LAUNCH_TOKEN=""
    else
        stop_current_app
    fi
done

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! APP_SHA="$(debug_app_binary_sha256)"; then
    echo "run-real-app-e2e.sh: Debug app binary became unavailable while evidence was being recorded" >&2
    exit 5
fi
if [[ "$APP_SHA" != "$APP_SHA_START" ]]; then
    echo "run-real-app-e2e.sh: Debug app binary changed while evidence was being recorded" >&2
    exit 5
fi
SOURCE_TREE_SHA_FINISH="$(source_tree_sha256)"
SOURCE_TREE_DIRTY_FINISH="$(source_tree_dirty)"
if [[ "$SOURCE_TREE_SHA_FINISH" != "$SOURCE_TREE_SHA_START" ]]; then
    echo "run-real-app-e2e.sh: source tree changed while evidence was being recorded" >&2
    exit 5
fi
if [[ "$SOURCE_TREE_DIRTY_FINISH" != "$SOURCE_TREE_DIRTY_START" ]]; then
    echo "run-real-app-e2e.sh: source tree dirty state changed while evidence was being recorded" >&2
    exit 5
fi
python3 - \
    "$STARTED_AT" "$FINISHED_AT" "$GIT_SHA" "$FIXTURE_SHA" "$APP_SHA" \
    "$HTML_SHA" "$VISUAL_CONTRACT_SHA" "$E2E_SCRIPT_SHA" "$DRIVER_SOURCE_SHA" "$DRIVER_BINARY_SHA" \
    "$SOURCE_TREE_SHA_START" "$SOURCE_TREE_DIRTY_START" "$OS_VERSION" \
    "$STATIC_ONLY" "$KEYBOARD_ONLY" "$EXTENDED_FULL_POINTER" \
    "$INTERACTION_TIER" "$FOREGROUND_BATCH_NAME" \
    "$EVIDENCE_MODE" "$FOREGROUND_BUDGET" \
    "$LEGACY_STATIC_ALIAS" "$SIZE_NAMES_CSV" \
    "$RUN_SCOPE" "$STRICT_VISUAL_ACCEPTANCE_ELIGIBLE" "$VISUAL_STATE_NAMES_CSV" \
    "$OUTPUT/preflight.json" "$OUTPUT/sizes" \
    > "$OUTPUT/evidence.json" <<'PY'
import json
import pathlib
import sys

(
    started_at,
    finished_at,
    git_sha,
    fixture_sha,
    app_sha,
    html_sha,
    visual_contract_sha,
    script_sha,
    driver_source_sha,
    driver_binary_sha,
    source_tree_sha,
    source_tree_dirty,
    os_version,
    static_only,
    keyboard_only,
    extended_full_pointer,
    interaction_tier,
    foreground_batch_name,
    mode,
    foreground_budget,
    legacy_static_alias,
    size_names_csv,
    run_scope,
    strict_visual_acceptance_eligible,
    requested_visual_states_csv,
    preflight_path,
    sizes_root,
) = sys.argv[1:28]
size_names = size_names_csv.split(",")
sizes = []
for name in size_names:
    path = pathlib.Path(sizes_root) / name / "manifest.json"
    sizes.append(json.loads(path.read_text(encoding="utf-8")))
preflight = json.loads(pathlib.Path(preflight_path).read_text(encoding="utf-8"))
required_sizes = ["1180x760", "860x560", "1440x900"]
required_visual_states = [
    "default", "palette", "find", "preview", "sidebar-hidden",
    "source-editor", "table-editor",
]
requested_visual_states = (
    requested_visual_states_csv.split(",") if interaction_tier == "passive" else []
)
resolved_launches = (
    [
        launch
        for item in sizes
        for launch in item["visualStateLaunches"]
    ]
    if interaction_tier == "passive" else []
)
resolved_pairs = [
    (launch.get("logicalSize"), launch.get("requestedState"))
    for launch in resolved_launches
]
requested_pairs = [
    (size, state)
    for size in size_names
    for state in requested_visual_states
]
strict_eligible = strict_visual_acceptance_eligible == "1"
evidence = {
    "schemaVersion": 2,
    "kind": "real-macos-app-e2e",
    "status": "passed",
    "startedAt": started_at,
    "finishedAt": finished_at,
    "gitCommit": git_sha,
    "fixtureSHA256": fixture_sha,
    "appBinarySHA256": app_sha,
    "authoritativeHTMLSHA256": html_sha,
    "visualAcceptanceContractSHA256": visual_contract_sha,
    "e2eScriptSHA256": script_sha,
    "driverSourceSHA256": driver_source_sha,
    "driverBinarySHA256": driver_binary_sha,
    "sourceTreeSHA256": source_tree_sha,
    "sourceTreeDirty": source_tree_dirty == "1",
    "sourceTreeSHA256Algorithm": (
        "SHA-256 over sorted git ls-files cached and untracked non-ignored paths, "
        "entry kind, and current worktree bytes"
    ),
    "macOSVersion": os_version,
    "interactionTier": interaction_tier,
    "foregroundBatchName": foreground_batch_name or None,
    "runScope": run_scope,
    "strictVisualAcceptanceEligible": strict_eligible,
    "staticOnly": static_only == "1",
    "keyboardOnly": keyboard_only == "1",
    "extendedFullPointer": extended_full_pointer == "1",
    "legacyStaticOnlyAlias": legacy_static_alias == "1",
    "mode": mode,
    "requestedSizes": size_names,
    "coverage": {
        "visualCoverageApplicable": interaction_tier == "passive",
        "requiredSizes": required_sizes,
        "requestedSizes": size_names,
        "requiredVisualStates": required_visual_states,
        "requestedVisualStates": requested_visual_states,
        "requiredPairCount": len(required_sizes) * len(required_visual_states),
        "requestedPairCount": len(requested_pairs),
        "resolvedPairCount": len(resolved_pairs),
        "requestedPairsComplete": (
            interaction_tier == "passive"
            and len(resolved_pairs) == len(set(resolved_pairs))
            and set(resolved_pairs) == set(requested_pairs)
        ),
        "strictMatrixComplete": (
            strict_eligible
            and size_names == required_sizes
            and requested_visual_states == required_visual_states
            and resolved_pairs == requested_pairs
        ),
    },
    "interactionCoverage": (
        sizes[0]["interactionCoverage"]
        if interaction_tier == "foreground-smoke"
        else {
            "applicable": False,
            "status": "not-applicable",
            "requestedBatchName": None,
            "plannedActionCount": 0,
            "completedActionCount": 0,
            "allPlannedActionsCompleted": False,
            "targetActivationRequestCount": 0,
            "interferenceDetected": False,
            "deadlineExceeded": False,
            "focusRestored": False,
            "pointerRestored": False,
            "pasteboardRestored": False,
        }
    ),
    "foregroundBudgetSeconds": (
        float(foreground_budget) if interaction_tier == "foreground-smoke" else None
    ),
    "foregroundReport": (
        sizes[0]["foregroundReport"] if interaction_tier == "foreground-smoke" else None
    ),
    "passiveLifecycleAssertions": [
        assertion
        for item in sizes
        for assertion in item["passiveLifecycleAssertions"]
    ],
    "requestedVisualStates": (
        requested_visual_states
        if interaction_tier == "passive" else []
    ),
    "resolvedVisualStateLaunches": (
        resolved_launches
        if interaction_tier == "passive" else []
    ),
    "interactionClaims": {
        "takesFocus": interaction_tier != "passive",
        "postsKeyboardInput": interaction_tier != "passive",
        "movesPointer": interaction_tier in {
            "foreground-smoke", "extended-full-pointer",
        },
    },
    "preflight": preflight,
    "sizes": sizes,
}
print(json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True))
PY

if [[ "$PROBE_MODE" -eq 1 ]]; then
    echo "Real-App development probe evidence: $OUTPUT/evidence.json"
    echo "This probe is not eligible for strict visual acceptance."
else
    echo "Real-App E2E evidence: $OUTPUT/evidence.json"
fi
