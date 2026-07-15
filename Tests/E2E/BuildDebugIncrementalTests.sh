#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/markdown-viewer-build-debug-tests.XXXXXX")"
TEMP_ROOT="$(cd -P "$TEMP_ROOT" && pwd)"
TEST_ROOT="$TEMP_ROOT/repo"
FAKE_BIN="$TEMP_ROOT/fake-bin"
SWIFT_LOG="$TEMP_ROOT/swift.log"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "BuildDebugIncrementalTests: $*" >&2
    exit 1
}

swift_build_call_count() {
    if [[ ! -f "$SWIFT_LOG" ]]; then
        echo 0
        return
    fi
    wc -l < "$SWIFT_LOG" | tr -d '[:space:]'
}

assert_output_path() {
    local output_file="$1"
    local label="$2"
    local output
    output="$(tr -d '\r\n' < "$output_file")"
    [[ "$output" == "$EXPECTED_APP" ]] \
        || fail "$label output path is incorrect: $output"
}

bash -n "$ROOT/scripts/build-debug.sh"

mkdir -p \
    "$TEST_ROOT/Fixtures/Debug" \
    "$TEST_ROOT/Resources" \
    "$TEST_ROOT/Sources/MarkdownViewer" \
    "$TEST_ROOT/scripts" \
    "$FAKE_BIN"

cp "$ROOT/scripts/build-debug.sh" "$TEST_ROOT/scripts/build-debug.sh"
cp "$ROOT/Fixtures/Debug/格式示例.md" "$TEST_ROOT/Fixtures/Debug/格式示例.md"
cp "$ROOT/Resources/Info.plist" "$TEST_ROOT/Resources/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$TEST_ROOT/Resources/AppIcon.icns"
cp "$ROOT/Package.swift" "$TEST_ROOT/Package.swift"
cp "$ROOT/VERSION" "$TEST_ROOT/VERSION"
printf 'struct IncrementalBuildFixture {}\n' > "$TEST_ROOT/Sources/MarkdownViewer/Input.swift"
chmod +x "$TEST_ROOT/scripts/build-debug.sh"

cat > "$FAKE_BIN/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 1 && "$1" == "--version" ]]; then
    printf 'Swift version 6.1-test (swift-6.1-test-RELEASE)\n'
    printf 'Target: arm64-apple-macosx15.0\n'
    exit 0
fi

if [[ "$#" -eq 1 && "$1" == "-print-target-info" ]]; then
    printf '{"compilerVersion":"Swift version 6.1-test","target":{"triple":"arm64-apple-macosx15.0"}}\n'
    exit 0
fi

if [[ "$#" -eq 3 && "$1" == "build" && "$2" == "-c" && "$3" == "debug" ]]; then
    printf '%s\n' "$*" >> "$FAKE_SWIFT_LOG"
    sleep 0.5
    mkdir -p "$FAKE_SWIFT_BIN_DIR"
    cp /usr/bin/true "$FAKE_SWIFT_BIN_DIR/MarkdownViewer"
    chmod +x "$FAKE_SWIFT_BIN_DIR/MarkdownViewer"
    exit 0
fi

if [[ "$#" -eq 4 \
    && "$1" == "build" \
    && "$2" == "-c" \
    && "$3" == "debug" \
    && "$4" == "--show-bin-path" ]]; then
    printf '%s\n' "$*" >> "$FAKE_SWIFT_LOG"
    printf '%s\n' "$FAKE_SWIFT_BIN_DIR"
    exit 0
fi

echo "unexpected fake swift invocation: $*" >&2
exit 64
EOF
chmod +x "$FAKE_BIN/swift"

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" \
    -c user.name='Build Debug Test' \
    -c user.email='build-debug-test@example.invalid' \
    commit -qm 'test fixture'

SCRIPT="$TEST_ROOT/scripts/build-debug.sh"
EXPECTED_APP="$TEST_ROOT/dist/debug/MarkdownViewer.app"
EXPECTED_MANIFEST="$EXPECTED_APP/Contents/Resources/BuildDebugInputs.manifest"
SOURCE_INPUT="$TEST_ROOT/Sources/MarkdownViewer/Input.swift"
export FAKE_SWIFT_BIN_DIR="$TEMP_ROOT/swift-bin"
export FAKE_SWIFT_LOG="$SWIFT_LOG"
export PATH="$FAKE_BIN:$PATH"

set +e
"$SCRIPT" --unknown > "$TEMP_ROOT/unknown.stdout" 2> "$TEMP_ROOT/unknown.stderr"
UNKNOWN_STATUS=$?
set -e
[[ "$UNKNOWN_STATUS" -eq 2 ]] || fail "unknown option did not exit with status 2"

"$SCRIPT" --if-needed > "$TEMP_ROOT/first.stdout" 2> "$TEMP_ROOT/first.stderr"
assert_output_path "$TEMP_ROOT/first.stdout" "first build"
[[ -x "$EXPECTED_APP/Contents/MacOS/MarkdownViewer" ]] \
    || fail "first build did not assemble an executable"
[[ -f "$EXPECTED_MANIFEST" && ! -L "$EXPECTED_MANIFEST" ]] \
    || fail "first build did not package its input manifest"
codesign --verify --deep --strict "$EXPECTED_APP" >/dev/null 2>&1 \
    || fail "first build is not validly signed"
FIRST_SWIFT_CALLS="$(swift_build_call_count)"
[[ "$FIRST_SWIFT_CALLS" -eq 2 ]] \
    || fail "first build made $FIRST_SWIFT_CALLS fake Swift build calls, expected 2"

"$SCRIPT" --if-needed > "$TEMP_ROOT/second.stdout" 2> "$TEMP_ROOT/second.stderr"
assert_output_path "$TEMP_ROOT/second.stdout" "reuse"
SECOND_SWIFT_CALLS="$(swift_build_call_count)"
[[ "$SECOND_SWIFT_CALLS" -eq "$FIRST_SWIFT_CALLS" ]] \
    || fail "reuse unexpectedly invoked Swift build"
rg -q 'reusing current Debug app' "$TEMP_ROOT/second.stderr" \
    || fail "reuse was not reported"

"$SCRIPT" > "$TEMP_ROOT/default.stdout" 2> "$TEMP_ROOT/default.stderr"
assert_output_path "$TEMP_ROOT/default.stdout" "default build"
DEFAULT_SWIFT_CALLS="$(swift_build_call_count)"
[[ "$DEFAULT_SWIFT_CALLS" -eq $((SECOND_SWIFT_CALLS + 2)) ]] \
    || fail "default command did not force exactly one build"

MTIME_REFERENCE="$TEMP_ROOT/source-mtime-reference"
cp -p "$SOURCE_INPUT" "$MTIME_REFERENCE"
printf 'struct IncrementalBuildFixture { let changed = true }\n' > "$SOURCE_INPUT"
touch -r "$MTIME_REFERENCE" "$SOURCE_INPUT"

"$SCRIPT" --if-needed > "$TEMP_ROOT/content.stdout" 2> "$TEMP_ROOT/content.stderr"
assert_output_path "$TEMP_ROOT/content.stdout" "content-addressed rebuild"
CONTENT_SWIFT_CALLS="$(swift_build_call_count)"
[[ "$CONTENT_SWIFT_CALLS" -eq $((DEFAULT_SWIFT_CALLS + 2)) ]] \
    || fail "source content change with preserved mtime did not force exactly one build"
rg -q 'signed input manifest does not match current inputs' "$TEMP_ROOT/content.stderr" \
    || fail "content mismatch reason was not reported"

cp -p "$SOURCE_INPUT" "$MTIME_REFERENCE"
printf 'struct IncrementalBuildFixture { let concurrent = true }\n' > "$SOURCE_INPUT"
touch -r "$MTIME_REFERENCE" "$SOURCE_INPUT"
BEFORE_CONCURRENT_CALLS="$(swift_build_call_count)"

"$SCRIPT" --if-needed > "$TEMP_ROOT/concurrent-a.stdout" 2> "$TEMP_ROOT/concurrent-a.stderr" &
PID_A=$!
"$SCRIPT" --if-needed > "$TEMP_ROOT/concurrent-b.stdout" 2> "$TEMP_ROOT/concurrent-b.stderr" &
PID_B=$!

set +e
wait "$PID_A"
STATUS_A=$?
wait "$PID_B"
STATUS_B=$?
set -e
[[ "$STATUS_A" -eq 0 && "$STATUS_B" -eq 0 ]] \
    || fail "concurrent --if-needed calls failed with statuses $STATUS_A and $STATUS_B"
assert_output_path "$TEMP_ROOT/concurrent-a.stdout" "concurrent call A"
assert_output_path "$TEMP_ROOT/concurrent-b.stdout" "concurrent call B"

AFTER_CONCURRENT_CALLS="$(swift_build_call_count)"
[[ "$AFTER_CONCURRENT_CALLS" -eq $((BEFORE_CONCURRENT_CALLS + 2)) ]] \
    || fail "concurrent --if-needed calls performed more than one build"
CONCURRENT_REUSE_COUNT="$(rg -l 'reusing current Debug app' \
    "$TEMP_ROOT/concurrent-a.stderr" \
    "$TEMP_ROOT/concurrent-b.stderr" | wc -l | tr -d '[:space:]')"
[[ "$CONCURRENT_REUSE_COUNT" -eq 1 ]] \
    || fail "exactly one concurrent caller should reuse the app after locking"
[[ -f "$EXPECTED_MANIFEST" && -x "$EXPECTED_APP/Contents/MacOS/MarkdownViewer" ]] \
    || fail "concurrent publication exposed an incomplete app"
codesign --verify --deep --strict "$EXPECTED_APP" >/dev/null 2>&1 \
    || fail "concurrent publication produced an invalid signature"

chmod u+w "$EXPECTED_MANIFEST"
printf '\ncorrupt\n' >> "$EXPECTED_MANIFEST"
"$SCRIPT" --if-needed > "$TEMP_ROOT/corrupt.stdout" 2> "$TEMP_ROOT/corrupt.stderr"
assert_output_path "$TEMP_ROOT/corrupt.stdout" "corrupt manifest rebuild"
CORRUPT_SWIFT_CALLS="$(swift_build_call_count)"
[[ "$CORRUPT_SWIFT_CALLS" -eq $((AFTER_CONCURRENT_CALLS + 2)) ]] \
    || fail "corrupt packaged manifest did not force exactly one rebuild"
codesign --verify --deep --strict "$EXPECTED_APP" >/dev/null 2>&1 \
    || fail "manifest recovery did not restore a valid signature"

echo "BuildDebugIncrementalTests: passed"
