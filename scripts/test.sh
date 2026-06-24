#!/usr/bin/env bash
set -euo pipefail

# One-shot test runner for the Markdown viewer.
#
# Builds the app via scripts/build.sh, then runs every headless test mode the
# binary supports against fresh temp directories and reports a final summary:
#   - --self-test    : layout / live-markdown / palette state assertions
#   - --ui-test      : real-event-driven behavioral assertions (incl. the
#                      scroll-wheel regression guard)
#   - --golden-test  : pixel-compares corpus + self-test renders to baselines
#                      (on first run, when tests/golden/ has no baselines, this
#                      prints `GOLDEN NEW ...` and still succeeds so a human can
#                      review and commit the generated candidates)
#
# Exits nonzero if any stage fails, and prints which stage failed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MarkdownViewer.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/MarkdownViewer"

# Temp output dirs for the test artifacts (snapshots, fixtures). Cleaned on exit.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mdviewer-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SELF_DIR="$TMP_DIR/self-test"
UI_DIR="$TMP_DIR/ui-test"
GOLDEN_SCRATCH="$TMP_DIR/golden-test"
mkdir -p "$SELF_DIR" "$UI_DIR" "$GOLDEN_SCRATCH"

FAILED_STAGES=()

run_stage() {
  local name="$1"
  shift
  echo "======================================================================"
  echo "[test.sh] running stage: $name"
  echo "----------------------------------------------------------------------"
  if "$@"; then
    echo "[test.sh] stage PASS: $name"
  else
    echo "[test.sh] stage FAIL: $name"
    FAILED_STAGES+=("$name")
  fi
}

# 1) Build (fail fast — nothing else can run without a binary).
echo "[test.sh] building via scripts/build.sh ..."
if ! bash "$ROOT_DIR/scripts/build.sh" >/dev/null; then
  echo "[test.sh] BUILD FAILED"
  echo "ALL TESTS FAIL (stage: build)"
  exit 1
fi
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "[test.sh] build did not produce an executable at $EXECUTABLE"
  echo "ALL TESTS FAIL (stage: build)"
  exit 1
fi
echo "[test.sh] build OK: $EXECUTABLE"

# 2) Test stages. Each runs against its own temp dir. The golden stage resolves
#    tests/ from the repo root we pass explicitly.
run_stage "self-test"   "$EXECUTABLE" --self-test "$SELF_DIR"
run_stage "ui-test"     "$EXECUTABLE" --ui-test "$UI_DIR"
run_stage "golden-test" "$EXECUTABLE" --golden-test "$ROOT_DIR"

echo "======================================================================"
if [[ ${#FAILED_STAGES[@]} -eq 0 ]]; then
  echo "ALL TESTS PASS"
  exit 0
fi
echo "TESTS FAILED in stage(s): ${FAILED_STAGES[*]}"
exit 1
