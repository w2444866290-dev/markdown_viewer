#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/visual/visual-matrix.sh"

REFERENCE="$ROOT/build/visual-reference"
APP_EVIDENCE="$ROOT/build/e2e/real-app-latest"
OUTPUT="$ROOT/build/visual-diff/real-app-latest"
CONTRACT="$ROOT/scripts/visual/acceptance-contract.json"
THRESHOLD="8"
STRICT_THRESHOLD="8"
STATES="$VISUAL_DEFAULT_STATES"
SIZES="$VISUAL_DEFAULT_SIZES"
MARKER_NAME=".markdownviewer-visual-diff"

usage() {
    cat <<EOF
Usage: ./scripts/visual/compare-real-app.sh [options]

Compare authoritative WebKit captures with real-app E2E window screenshots.
Every requested size/state pair must exist in both input manifests.
Acceptance requires schema-v2, screenshot-bound state and geometry evidence.

Options:
  --reference PATH      Reference root. Default: build/visual-reference.
  --app-evidence PATH   Real-app evidence root. Default: build/e2e/real-app-latest.
  --output PATH         Diff output root. Default: build/visual-diff/real-app-latest.
  --sizes LIST          Comma-separated logical sizes. Default: $VISUAL_DEFAULT_SIZES.
  --states LIST         Comma-separated reference states. Default: $VISUAL_DEFAULT_STATES.
  --threshold N         Pinned pixel gate threshold. Must remain 8.
  -h, --help            Show this help.

State mapping:
  default -> baseline
  palette -> palette-open
  find -> find-open
  preview -> preview-on
  sidebar-hidden -> sidebar-hidden
  source-editor -> source-editing
  table-editor -> table-grid

The reference-only replace state has no matching real-app screenshot label.
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "compare-real-app.sh: $option requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reference)
            require_value "$1" "${2:-}"
            REFERENCE="$2"
            shift 2
            ;;
        --reference=*)
            REFERENCE="${1#*=}"
            require_value "--reference" "$REFERENCE"
            shift
            ;;
        --app-evidence)
            require_value "$1" "${2:-}"
            APP_EVIDENCE="$2"
            shift 2
            ;;
        --app-evidence=*)
            APP_EVIDENCE="${1#*=}"
            require_value "--app-evidence" "$APP_EVIDENCE"
            shift
            ;;
        --output)
            require_value "$1" "${2:-}"
            OUTPUT="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT="${1#*=}"
            require_value "--output" "$OUTPUT"
            shift
            ;;
        --sizes)
            require_value "$1" "${2:-}"
            SIZES="$2"
            shift 2
            ;;
        --sizes=*)
            SIZES="${1#*=}"
            require_value "--sizes" "$SIZES"
            shift
            ;;
        --states)
            require_value "$1" "${2:-}"
            STATES="$2"
            shift 2
            ;;
        --states=*)
            STATES="${1#*=}"
            require_value "--states" "$STATES"
            shift
            ;;
        --threshold)
            require_value "$1" "${2:-}"
            THRESHOLD="$2"
            shift 2
            ;;
        --threshold=*)
            THRESHOLD="${1#*=}"
            require_value "--threshold" "$THRESHOLD"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "compare-real-app.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]] || (( THRESHOLD < 0 || THRESHOLD > 255 )); then
    echo "compare-real-app.sh: --threshold must be from 0 through 255" >&2
    exit 2
fi
if [[ "$THRESHOLD" != "$STRICT_THRESHOLD" ]]; then
    echo "compare-real-app.sh: --threshold is pinned to $STRICT_THRESHOLD by the acceptance contract" >&2
    exit 2
fi

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_requested_states() {
    if [[ -z "$STATES" || "$STATES" == ,* || "$STATES" == *, || "$STATES" == *,,* ]]; then
        echo "compare-real-app.sh: --states must be a nonempty comma-separated list" >&2
        exit 2
    fi
    IFS=',' read -r -a REQUESTED_STATES <<< "$STATES"
    local seen="|"
    local index state
    for index in "${!REQUESTED_STATES[@]}"; do
        state="$(trim_whitespace "${REQUESTED_STATES[$index]}")"
        if [[ -z "$state" || ! "$state" =~ ^[a-z0-9-]+$ ]]; then
            echo "compare-real-app.sh: invalid state '$state'" >&2
            exit 2
        fi
        if [[ "$seen" == *"|$state|"* ]]; then
            echo "compare-real-app.sh: duplicate requested state '$state'" >&2
            exit 2
        fi
        if ! app_label="$(visual_state_to_app_label "$state")"; then
            echo "compare-real-app.sh: state '$state' has no real-app E2E mapping" >&2
            exit 2
        fi
        REQUESTED_STATES[$index]="$state"
        APP_LABELS+=("$state=$app_label")
        seen+="$state|"
    done
}

parse_requested_sizes() {
    if [[ -z "$SIZES" || "$SIZES" == ,* || "$SIZES" == *, || "$SIZES" == *,,* ]]; then
        echo "compare-real-app.sh: --sizes must be a nonempty comma-separated list" >&2
        exit 2
    fi
    IFS=',' read -r -a REQUESTED_SIZES <<< "$SIZES"
    local seen="|"
    local index size
    for index in "${!REQUESTED_SIZES[@]}"; do
        size="$(trim_whitespace "${REQUESTED_SIZES[$index]}")"
        if [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
            echo "compare-real-app.sh: invalid size '$size'" >&2
            exit 2
        fi
        if [[ "$seen" == *"|$size|"* ]]; then
            echo "compare-real-app.sh: duplicate requested size '$size'" >&2
            exit 2
        fi
        REQUESTED_SIZES[$index]="$size"
        seen+="$size|"
    done
}

REQUESTED_STATES=()
REQUESTED_SIZES=()
APP_LABELS=()
parse_requested_states
parse_requested_sizes

if [[ ! -f "$REFERENCE/manifest.json" ]]; then
    echo "compare-real-app.sh: missing reference manifest: $REFERENCE/manifest.json" >&2
    exit 3
fi
if [[ ! -f "$APP_EVIDENCE/evidence.json" ]]; then
    echo "compare-real-app.sh: missing app evidence: $APP_EVIDENCE/evidence.json" >&2
    exit 3
fi
if [[ ! -f "$CONTRACT" ]]; then
    echo "compare-real-app.sh: missing acceptance contract: $CONTRACT" >&2
    exit 3
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/markdownviewer-visual-compare.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM
PLAN="$TEMP_ROOT/comparison-plan.tsv"
STATE_CSV="$(IFS=','; echo "${REQUESTED_STATES[*]}")"
SIZE_CSV="$(IFS=','; echo "${REQUESTED_SIZES[*]}")"
MAPPING_CSV="$(IFS=','; echo "${APP_LABELS[*]}")"

python3 - \
    "$REFERENCE" "$APP_EVIDENCE" "$STATE_CSV" "$SIZE_CSV" "$MAPPING_CSV" \
    > "$PLAN" <<'PY'
import json
import pathlib
import sys

reference_root = pathlib.Path(sys.argv[1]).resolve()
evidence_root = pathlib.Path(sys.argv[2]).resolve()
states = sys.argv[3].split(",")
sizes = sys.argv[4].split(",")
mapping = dict(item.split("=", 1) for item in sys.argv[5].split(","))

reference = json.loads((reference_root / "manifest.json").read_text(encoding="utf-8"))
evidence = json.loads((evidence_root / "evidence.json").read_text(encoding="utf-8"))
errors = []

if evidence.get("status") == "blocked":
    errors.append("real-app evidence status is blocked")

reference_records = {}
for record in reference.get("snapshots", []):
    key = (f"{record.get('viewportWidth')}x{record.get('viewportHeight')}", record.get("state"))
    if key in reference_records:
        errors.append(f"duplicate reference manifest record for {key[0]}/{key[1]}")
    reference_records[key] = record

evidence_records = {}
for size_record in evidence.get("sizes", []):
    size = size_record.get("size")
    for screenshot in size_record.get("screenshots", []):
        key = (size, screenshot.get("label"))
        if key in evidence_records:
            errors.append(f"duplicate app evidence record for {key[0]}/{key[1]}")
        evidence_records[key] = screenshot


def checked_path(root: pathlib.Path, raw: object, description: str):
    if not isinstance(raw, str) or not raw:
        errors.append(f"{description} has no path")
        return None
    candidate = (root / raw).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        errors.append(f"{description} escapes its evidence root: {raw}")
        return None
    if not candidate.is_file():
        errors.append(f"{description} file is missing: {candidate}")
        return None
    if "\t" in str(candidate) or "\n" in str(candidate):
        errors.append(f"{description} path contains an unsupported control character")
        return None
    return candidate


plan = []
for size in sizes:
    for state in states:
        label = mapping[state]
        reference_record = reference_records.get((size, state))
        app_record = evidence_records.get((size, label))
        if reference_record is None:
            errors.append(f"missing requested reference pair {size}/{state}")
        if app_record is None:
            errors.append(f"missing requested app pair {size}/{state} (label {label})")
        if reference_record is None or app_record is None:
            continue
        reference_path = checked_path(
            reference_root,
            reference_record.get("relativePath"),
            f"reference {size}/{state}",
        )
        app_path = checked_path(
            evidence_root,
            app_record.get("path"),
            f"app {size}/{state}",
        )
        reference_pixels = (
            reference_record.get("pixelWidth"),
            reference_record.get("pixelHeight"),
        )
        app_pixels = app_record.get("pixelSize", {})
        app_pixel_pair = (app_pixels.get("width"), app_pixels.get("height"))
        if reference_pixels != app_pixel_pair:
            errors.append(
                f"pixel-size mismatch for {size}/{state}: "
                f"reference {reference_pixels}, app {app_pixel_pair}"
            )
        if reference_path is not None and app_path is not None:
            plan.append((size, state, label, reference_path, app_path))

if errors:
    print("compare-real-app.sh: requested matrix is incomplete or invalid:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(4)

expected_count = len(sizes) * len(states)
if len(plan) != expected_count:
    raise SystemExit(
        f"compare-real-app.sh: internal matrix error: planned {len(plan)}, expected {expected_count}"
    )
for row in plan:
    print("\t".join(map(str, row)))
PY

if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$PWD/$OUTPUT"
fi
if [[ -z "$OUTPUT" || "$OUTPUT" == "/" ]]; then
    echo "compare-real-app.sh: refusing unsafe output directory: $OUTPUT" >&2
    exit 2
fi
if [[ -d "$OUTPUT" ]]; then
    if [[ ! -f "$OUTPUT/$MARKER_NAME" ]] && [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "compare-real-app.sh: refusing unmarked nonempty output directory: $OUTPUT" >&2
        exit 2
    fi
    if [[ -f "$OUTPUT/$MARKER_NAME" ]]; then
        rm -rf "$OUTPUT"
    fi
fi
mkdir -p "$OUTPUT"
touch "$OUTPUT/$MARKER_NAME"

METRICS_LIST="$TEMP_ROOT/metrics-files.txt"
: > "$METRICS_LIST"
while IFS=$'\t' read -r size state app_label reference_png app_png; do
    comparison_dir="$OUTPUT/$size/$state"
    metrics_path="$comparison_dir/$state-metrics.json"
    python3 "$ROOT/scripts/visual/compose-diff.py" \
        --reference "$reference_png" \
        --app "$app_png" \
        --output-dir "$comparison_dir" \
        --label "$state" \
        --threshold "$THRESHOLD" \
        >/dev/null
    printf '%s\n' "$metrics_path" >> "$METRICS_LIST"
    echo "Measured $size/$state against app label $app_label"
done < "$PLAN"

MANIFEST_TEMP="$OUTPUT/.manifest.json.tmp"
python3 "$ROOT/scripts/visual/evaluate-acceptance.py" \
    --reference-manifest "$REFERENCE/manifest.json" \
    --app-evidence "$APP_EVIDENCE/evidence.json" \
    --contract "$CONTRACT" \
    --metrics-list "$METRICS_LIST" \
    --states "$STATE_CSV" \
    --sizes "$SIZE_CSV" \
    --mapping "$MAPPING_CSV" \
    --threshold "$THRESHOLD" \
    > "$MANIFEST_TEMP"
mv "$MANIFEST_TEMP" "$OUTPUT/manifest.json"

ACCEPTANCE_STATUS="$(python3 - "$OUTPUT/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(manifest["acceptance"]["status"])
PY
)"
echo "Visual acceptance manifest: $OUTPUT/manifest.json"
echo "Acceptance status: $ACCEPTANCE_STATUS"
if [[ "$ACCEPTANCE_STATUS" != "passed" ]]; then
    python3 - "$OUTPUT/manifest.json" >&2 <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print("compare-real-app.sh: visual acceptance failed:")
for failure in manifest["acceptance"]["failures"]:
    print(f"  - {failure}")
PY
    exit 5
fi
