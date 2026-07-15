#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
DIST_ROOT="$ROOT_DIR/dist"
DIST_DIR="$DIST_ROOT/debug"
APP_DIR="$DIST_DIR/MarkdownViewer.app"
FIXTURE="$ROOT_DIR/Fixtures/Debug/格式示例.md"
EXPECTED_FIXTURE_SHA="cbcdfe19a3383f175f1e9beb78afce473f335fd0e8e814bc799f3a1deade0d9f"
MANIFEST_RELATIVE_PATH="Contents/Resources/BuildDebugInputs.manifest"
LOCK_FILE="$DIST_DIR/.build-debug.lock"
LOCK_HELD=0
WORK_DIR=""
PUBLISH_BACKUP=""
PUBLISHED_NEW_APP=0
PUBLICATION_COMMITTED=0
BUILD_SHA=""
BUILD_FULL_SHA=""
BUILD_NUMBER=""
MARKETING_VERSION=""
REUSE_REASON=""

usage() {
    cat <<'EOF'
Usage: ./scripts/build-debug.sh [--if-needed]

Without arguments, always rebuild and assemble the Debug application.
With --if-needed, reuse a complete Debug application whose signed input
manifest exactly matches the current source tree and build environment.
EOF
}

IF_NEEDED=0
case "${1:-}" in
    "")
        ;;
    --if-needed)
        IF_NEEDED=1
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

fail() {
    echo "build-debug.sh: $*" >&2
    exit 1
}

reject_reuse() {
    REUSE_REASON="$1"
    return 1
}

ensure_real_directory() {
    local path="$1"
    local label="$2"

    if [[ -L "$path" ]]; then
        fail "$label must not be a symbolic link: $path"
    fi
    if [[ -e "$path" ]]; then
        [[ -d "$path" ]] || fail "$label is not a directory: $path"
        return 0
    fi

    mkdir "$path"
    [[ -d "$path" && ! -L "$path" ]] \
        || fail "could not create a safe $label: $path"
}

safe_remove_tree() {
    local path="$1"

    [[ -n "$path" ]] || return 0
    case "$path" in
        "$DIST_DIR"/.build-debug.work.*|"$DIST_DIR"/.MarkdownViewer.app.previous.*)
            ;;
        *)
            echo "build-debug.sh: refusing to remove an unexpected path: $path" >&2
            return 1
            ;;
    esac

    [[ "$path" != "$DIST_DIR" && "$path" != "$DIST_ROOT" && "$path" != "$ROOT_DIR" ]] \
        || return 1
    if [[ -L "$path" ]]; then
        echo "build-debug.sh: refusing to recursively remove a symbolic link: $path" >&2
        return 1
    fi
    [[ ! -e "$path" ]] || rm -rf "$path"
}

release_lock() {
    (( LOCK_HELD == 1 )) || return 0

    if [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        local owner
        owner="$(tr -d '[:space:]' < "$LOCK_FILE" 2>/dev/null || true)"
        if [[ "$owner" == "$$" ]]; then
            rm -f "$LOCK_FILE"
        else
            echo "build-debug.sh: lock ownership changed; leaving lock file in place" >&2
        fi
    fi
    LOCK_HELD=0
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    set +e

    if [[ -n "$PUBLISH_BACKUP" && -d "$PUBLISH_BACKUP" && ! -L "$PUBLISH_BACKUP" ]]; then
        if (( PUBLICATION_COMMITTED == 0 )); then
            if (( PUBLISHED_NEW_APP == 1 )) \
                && [[ -d "$APP_DIR" && ! -L "$APP_DIR" \
                    && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
                mv "$APP_DIR" "$WORK_DIR/failed-published-app"
            fi
            if [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]]; then
                mv "$PUBLISH_BACKUP" "$APP_DIR"
            else
                echo "build-debug.sh: could not safely restore the previous Debug app" >&2
            fi
        else
            safe_remove_tree "$PUBLISH_BACKUP"
        fi
    fi
    safe_remove_tree "$WORK_DIR"
    release_lock
    exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_real_directory "$DIST_ROOT" "distribution directory"
ensure_real_directory "$DIST_DIR" "Debug distribution directory"

acquire_lock() {
    local waited=0

    command -v /usr/bin/shlock >/dev/null 2>&1 \
        || fail "/usr/bin/shlock is required for safe Debug build locking"

    while true; do
        [[ ! -L "$LOCK_FILE" ]] || fail "lock file must not be a symbolic link: $LOCK_FILE"
        if /usr/bin/shlock -f "$LOCK_FILE" -p "$$"; then
            LOCK_HELD=1
            return 0
        fi
        if (( waited >= 6000 )); then
            fail "timed out waiting 300 seconds for Debug build lock"
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
}

acquire_lock

TOKEN="$(/usr/bin/uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
[[ -n "$TOKEN" ]] || TOKEN="$$.$RANDOM"
WORK_DIR="$DIST_DIR/.build-debug.work.$TOKEN"
[[ ! -e "$WORK_DIR" && ! -L "$WORK_DIR" ]] \
    || fail "temporary build directory already exists: $WORK_DIR"
mkdir "$WORK_DIR"
[[ -d "$WORK_DIR" && ! -L "$WORK_DIR" ]] \
    || fail "could not create a safe temporary build directory"

file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

hex_value() {
    LC_ALL=C od -An -tx1 | tr -d ' \n'
}

append_metadata() {
    local output="$1"
    local key="$2"
    local value="$3"
    local encoded

    encoded="$(printf '%s' "$value" | hex_value)"
    printf 'metadata\t%s\t%s\n' "$key" "$encoded" >> "$output"
}

command_output() {
    "$@" 2>&1 || true
}

resolved_command() {
    command -v "$1" 2>/dev/null || true
}

validate_manifest_inputs() {
    local required_directory
    for required_directory in \
        "$ROOT_DIR/Sources" \
        "$ROOT_DIR/Resources" \
        "$ROOT_DIR/Fixtures/Debug"; do
        [[ -d "$required_directory" && ! -L "$required_directory" ]] \
            || fail "required input directory is missing or unsafe: $required_directory"
    done

    local required_file
    for required_file in \
        "$ROOT_DIR/Package.swift" \
        "$ROOT_DIR/VERSION" \
        "$ROOT_DIR/scripts/build-debug.sh"; do
        [[ -f "$required_file" && ! -L "$required_file" ]] \
            || fail "required input file is missing or unsafe: $required_file"
    done

    if [[ -e "$ROOT_DIR/Package.resolved" || -L "$ROOT_DIR/Package.resolved" ]]; then
        [[ -f "$ROOT_DIR/Package.resolved" && ! -L "$ROOT_DIR/Package.resolved" ]] \
            || fail "Package.resolved must be a regular file when present"
    fi

    local unsafe_path
    while IFS= read -r -d '' unsafe_path; do
        fail "symbolic links are not accepted as Debug build inputs: ${unsafe_path#"$ROOT_DIR/"}"
    done < <(
        find \
            "$ROOT_DIR/Sources" \
            "$ROOT_DIR/Resources" \
            "$ROOT_DIR/Fixtures/Debug" \
            -type l -print0
    )

    while IFS= read -r -d '' unsafe_path; do
        fail "unsupported Debug build input type: ${unsafe_path#"$ROOT_DIR/"}"
    done < <(
        find \
            "$ROOT_DIR/Sources" \
            "$ROOT_DIR/Resources" \
            "$ROOT_DIR/Fixtures/Debug" \
            ! -type f ! -type d ! -type l -print0
    )

    if [[ ! -f "$FIXTURE" || -L "$FIXTURE" ]]; then
        fail "Debug fixture not found at $FIXTURE"
    fi
    local actual_fixture_sha
    actual_fixture_sha="$(file_sha256 "$FIXTURE")"
    [[ "$actual_fixture_sha" == "$EXPECTED_FIXTURE_SHA" ]] \
        || fail "Debug fixture SHA-256 mismatch"
}

capture_build_identity() {
    BUILD_FULL_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    BUILD_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
    BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
    MARKETING_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)"
    [[ -n "$MARKETING_VERSION" ]] || MARKETING_VERSION="1.0.0"
}

initialize_static_build_context() {
    local output="$1"
    local swift_bin swiftc_bin xcodebuild_bin xcrun_bin codesign_bin
    local sdk_path sdk_version sdk_build_version target_info

    : > "$output"

    swift_bin="$(resolved_command swift)"
    [[ -n "$swift_bin" ]] || fail "swift command is unavailable"
    if [[ -n "${SWIFT_EXEC:-}" ]]; then
        swiftc_bin="$SWIFT_EXEC"
    else
        swiftc_bin="$(resolved_command swiftc)"
    fi
    [[ -n "$swiftc_bin" ]] || fail "swiftc command is unavailable"
    xcodebuild_bin="$(resolved_command xcodebuild)"
    xcrun_bin="$(resolved_command xcrun)"
    codesign_bin="$(resolved_command codesign)"

    sdk_path="$(command_output /usr/bin/xcrun --sdk macosx --show-sdk-path)"
    sdk_version="$(command_output /usr/bin/xcrun --sdk macosx --show-sdk-version)"
    sdk_build_version="$(command_output /usr/bin/xcrun --sdk macosx --show-sdk-build-version)"
    target_info="$(command_output "$swift_bin" -print-target-info)"

    append_metadata "$output" build.command "swift build -c debug"
    append_metadata "$output" build.configuration "debug"
    append_metadata "$output" build.product "MarkdownViewer"
    append_metadata "$output" build.codesign-identity "ad-hoc"
    append_metadata "$output" host.uname-machine "$(uname -m)"
    append_metadata "$output" host.arch-command "$(command_output /usr/bin/arch)"
    append_metadata "$output" tool.swift.path "$swift_bin"
    append_metadata "$output" tool.swift.version "$(command_output "$swift_bin" --version)"
    append_metadata "$output" tool.swift.target-info "$target_info"
    append_metadata "$output" tool.swiftc.path "$swiftc_bin"
    append_metadata "$output" tool.swiftc.version "$(command_output "$swiftc_bin" --version)"
    append_metadata "$output" tool.xcode-select.path "$(command_output /usr/bin/xcode-select -p)"
    append_metadata "$output" tool.xcodebuild.path "$xcodebuild_bin"
    append_metadata "$output" tool.xcodebuild.version "$(command_output "$xcodebuild_bin" -version)"
    append_metadata "$output" tool.xcrun.path "$xcrun_bin"
    append_metadata "$output" tool.codesign.path "$codesign_bin"
    append_metadata "$output" tool.codesign.version "$(command_output "$codesign_bin" --version)"
    append_metadata "$output" sdk.macosx.path "$sdk_path"
    append_metadata "$output" sdk.macosx.version "$sdk_version"
    append_metadata "$output" sdk.macosx.build-version "$sdk_build_version"

    if [[ -n "$swift_bin" && -f "$swift_bin" ]]; then
        append_metadata "$output" tool.swift.binary-sha256 "$(file_sha256 "$swift_bin")"
    else
        append_metadata "$output" tool.swift.binary-sha256 "unavailable"
    fi
    if [[ -n "$swiftc_bin" && -f "$swiftc_bin" ]]; then
        append_metadata "$output" tool.swiftc.binary-sha256 "$(file_sha256 "$swiftc_bin")"
    else
        append_metadata "$output" tool.swiftc.binary-sha256 "unavailable"
    fi

    local environment_key environment_value
    for environment_key in \
        PATH \
        DEVELOPER_DIR \
        SDKROOT \
        TOOLCHAINS \
        SWIFT_EXEC \
        CC \
        CXX \
        CFLAGS \
        CPPFLAGS \
        LDFLAGS \
        ARCHFLAGS \
        MACOSX_DEPLOYMENT_TARGET \
        SWIFTPM_BUILD_DIR \
        SWIFTPM_MODULECACHE_OVERRIDE \
        SWIFTPM_DISABLE_SANDBOX \
        SOURCE_DATE_EPOCH \
        ZERO_AR_DATE; do
        environment_value="${!environment_key-}"
        append_metadata "$output" "environment.$environment_key" "$environment_value"
    done

    append_metadata "$output" input.build-script-mode \
        "$(stat -f '%Lp' "$ROOT_DIR/scripts/build-debug.sh" 2>/dev/null \
            || stat -c '%a' "$ROOT_DIR/scripts/build-debug.sh")"
    chmod 0444 "$output"
}

append_input_records() {
    local output="$1"
    local paths="$WORK_DIR/manifest-paths.$$.tmp"
    local files="$WORK_DIR/manifest-files.$$.tmp"
    local hashes="$WORK_DIR/manifest-hashes.$$.tmp"
    local records="$WORK_DIR/manifest-records.$$.tmp"

    : > "$paths"
    : > "$files"
    : > "$hashes"
    : > "$records"

    local input relative
    while IFS= read -r -d '' input; do
        relative="${input#"$ROOT_DIR/"}"
        case "$relative" in
            *$'\n'*|*$'\r'*|*$'\t'*)
                fail "Debug build input path contains a control character"
                ;;
        esac
        printf '%s\n' "$relative" >> "$paths"
    done < <(
        find \
            "$ROOT_DIR/Sources" \
            "$ROOT_DIR/Resources" \
            "$ROOT_DIR/Fixtures/Debug" \
            \( -type f -o -type d \) -print0
        printf '%s\0' \
            "$ROOT_DIR/Package.swift" \
            "$ROOT_DIR/VERSION" \
            "$ROOT_DIR/scripts/build-debug.sh"
        if [[ -f "$ROOT_DIR/Package.resolved" && ! -L "$ROOT_DIR/Package.resolved" ]]; then
            printf '%s\0' "$ROOT_DIR/Package.resolved"
        fi
    )

    LC_ALL=C sort -o "$paths" "$paths"

    local -a file_paths
    file_paths=()
    while IFS= read -r relative; do
        input="$ROOT_DIR/$relative"
        if [[ -d "$input" && ! -L "$input" ]]; then
            printf 'directory\t-\t%s\n' "$relative" >> "$records"
        elif [[ -f "$input" && ! -L "$input" ]]; then
            printf '%s\n' "$relative" >> "$files"
            file_paths[${#file_paths[@]}]="$input"
        else
            fail "Debug build input changed type while creating manifest: $relative"
        fi
    done < "$paths"

    if (( ${#file_paths[@]} > 0 )); then
        shasum -a 256 "${file_paths[@]}" > "$hashes"
    fi

    local hash_line digest
    exec 3< "$hashes"
    while IFS= read -r relative; do
        IFS= read -r hash_line <&3 \
            || fail "missing SHA-256 result for Debug build input: $relative"
        digest="${hash_line%%[[:space:]]*}"
        digest="${digest#\\}"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
            || fail "invalid SHA-256 result for Debug build input: $relative"
        printf 'file\t%s\t%s\n' "$digest" "$relative" >> "$records"
    done < "$files"
    exec 3<&-

    LC_ALL=C sort "$records" >> "$output"
    rm -f "$paths" "$files" "$hashes" "$records"
}

generate_manifest() {
    local output="$1"
    local static_line

    validate_manifest_inputs
    : > "$output"
    printf 'markdown-viewer-debug-input-manifest\t2\n' >> "$output"
    while IFS= read -r static_line || [[ -n "$static_line" ]]; do
        printf '%s\n' "$static_line" >> "$output"
    done < "$STATIC_BUILD_CONTEXT"
    append_metadata "$output" build.git-full-sha "$BUILD_FULL_SHA"
    append_metadata "$output" build.git-short-sha "$BUILD_SHA"
    append_metadata "$output" build.git-commit-count "$BUILD_NUMBER"
    append_metadata "$output" build.marketing-version "$MARKETING_VERSION"
    if [[ -f "$ROOT_DIR/Package.resolved" ]]; then
        append_metadata "$output" optional.Package.resolved "present"
    else
        append_metadata "$output" optional.Package.resolved "absent"
    fi

    append_input_records "$output"
    chmod 0444 "$output"
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

debug_app_is_reusable() {
    local candidate="$1"
    local expected_manifest="$2"
    local binary="$candidate/Contents/MacOS/MarkdownViewer"
    local plist="$candidate/Contents/Info.plist"
    local icon="$candidate/Contents/Resources/AppIcon.icns"
    local packaged_fixture="$candidate/Contents/Resources/DebugFixtures/格式示例.md"
    local packaged_manifest="$candidate/$MANIFEST_RELATIVE_PATH"
    local unsafe_path

    [[ -d "$candidate" && ! -L "$candidate" \
        && -d "$candidate/Contents" && ! -L "$candidate/Contents" \
        && -d "$candidate/Contents/MacOS" && ! -L "$candidate/Contents/MacOS" \
        && -d "$candidate/Contents/Resources" && ! -L "$candidate/Contents/Resources" \
        && -d "$candidate/Contents/Resources/DebugFixtures" \
        && ! -L "$candidate/Contents/Resources/DebugFixtures" \
        && -f "$binary" && -x "$binary" && ! -L "$binary" \
        && -f "$plist" && ! -L "$plist" \
        && -f "$icon" && ! -L "$icon" \
        && -f "$packaged_fixture" && ! -L "$packaged_fixture" \
        && -f "$packaged_manifest" && ! -L "$packaged_manifest" ]] \
        || reject_reuse "bundle is incomplete or contains an unsafe required path" \
        || return 1

    while IFS= read -r -d '' unsafe_path; do
        reject_reuse "bundle contains a symbolic link: ${unsafe_path#"$candidate/"}"
        return 1
    done < <(find "$candidate" -type l -print0)

    cmp -s "$expected_manifest" "$packaged_manifest" \
        || reject_reuse "signed input manifest does not match current inputs" \
        || return 1
    cmp -s "$ROOT_DIR/Resources/AppIcon.icns" "$icon" \
        || reject_reuse "packaged icon does not match Resources/AppIcon.icns" \
        || return 1

    local packaged_fixture_sha
    packaged_fixture_sha="$(file_sha256 "$packaged_fixture")"
    [[ "$packaged_fixture_sha" == "$EXPECTED_FIXTURE_SHA" ]] \
        || reject_reuse "packaged Debug fixture SHA-256 is incorrect" \
        || return 1

    [[ "$(plist_value "$plist" CFBundleExecutable || true)" == "MarkdownViewer" \
        && "$(plist_value "$plist" CFBundleIdentifier || true)" == "local.codex.markdownviewer.debug" \
        && "$(plist_value "$plist" CFBundleName || true)" == "MarkdownViewerDebug" \
        && "$(plist_value "$plist" CFBundleShortVersionString || true)" == "$MARKETING_VERSION" \
        && "$(plist_value "$plist" CFBundleVersion || true)" == "$BUILD_NUMBER" \
        && "$(plist_value "$plist" MVGitCommit || true)" == "$BUILD_SHA" ]] \
        || reject_reuse "Info.plist build identity is stale" \
        || return 1

    codesign --verify --deep --strict "$candidate" >/dev/null 2>&1 \
        || reject_reuse "bundle signature is invalid" \
        || return 1

    return 0
}

STATIC_BUILD_CONTEXT="$WORK_DIR/static-build-context"
initialize_static_build_context "$STATIC_BUILD_CONTEXT"
capture_build_identity
CURRENT_MANIFEST="$WORK_DIR/current.manifest"
generate_manifest "$CURRENT_MANIFEST"

if (( IF_NEEDED == 1 )); then
    if debug_app_is_reusable "$APP_DIR" "$CURRENT_MANIFEST"; then
        VERIFY_MANIFEST="$WORK_DIR/reuse-verify.manifest"
        capture_build_identity
        generate_manifest "$VERIFY_MANIFEST"
        if cmp -s "$CURRENT_MANIFEST" "$VERIFY_MANIFEST"; then
            echo "build-debug.sh: reusing current Debug app" >&2
            echo "$APP_DIR"
            exit 0
        fi
        REUSE_REASON="inputs changed while validating the cached app"
    fi
    echo "build-debug.sh: rebuilding Debug app ($REUSE_REASON)" >&2
fi

cd "$ROOT_DIR"
STABLE_MANIFEST=""
STAGE_ROOT="$WORK_DIR/stage"
STAGE_APP="$STAGE_ROOT/MarkdownViewer.app"

attempt=1
while (( attempt <= 3 )); do
    capture_build_identity
    BEFORE_MANIFEST="$WORK_DIR/before.$attempt.manifest"
    AFTER_MANIFEST="$WORK_DIR/after.$attempt.manifest"
    FINAL_MANIFEST="$WORK_DIR/final.$attempt.manifest"
    generate_manifest "$BEFORE_MANIFEST"

    swift build -c debug
    BIN_DIR="$(swift build -c debug --show-bin-path)"
    BINARY="$BIN_DIR/MarkdownViewer"
    [[ -x "$BINARY" && ! -L "$BINARY" ]] \
        || fail "Debug executable not found or unsafe at $BINARY"

    capture_build_identity
    generate_manifest "$AFTER_MANIFEST"
    if ! cmp -s "$BEFORE_MANIFEST" "$AFTER_MANIFEST"; then
        echo "build-debug.sh: inputs changed during build; retrying" >&2
        attempt=$((attempt + 1))
        continue
    fi

    safe_remove_tree "$STAGE_ROOT"
    mkdir "$STAGE_ROOT"
    mkdir -p "$STAGE_APP/Contents/MacOS"
    mkdir -p "$STAGE_APP/Contents/Resources/DebugFixtures"
    cp "$BINARY" "$STAGE_APP/Contents/MacOS/MarkdownViewer"
    cp "$ROOT_DIR/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"
    cp "$FIXTURE" "$STAGE_APP/Contents/Resources/DebugFixtures/格式示例.md"
    cp "$AFTER_MANIFEST" "$STAGE_APP/$MANIFEST_RELATIVE_PATH"
    chmod 0444 "$STAGE_APP/$MANIFEST_RELATIVE_PATH"

    STAGE_PLIST="$STAGE_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$STAGE_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$STAGE_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGE_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$STAGE_PLIST"
    /usr/libexec/PlistBuddy -c "Set :MVGitCommit $BUILD_SHA" "$STAGE_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :MVGitCommit string $BUILD_SHA" "$STAGE_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.codex.markdownviewer.debug" "$STAGE_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName MarkdownViewerDebug" "$STAGE_PLIST"

    codesign --force --deep --sign - "$STAGE_APP"
    REUSE_REASON=""
    debug_app_is_reusable "$STAGE_APP" "$AFTER_MANIFEST" \
        || fail "staged Debug app failed validation: $REUSE_REASON"

    capture_build_identity
    generate_manifest "$FINAL_MANIFEST"
    if ! cmp -s "$AFTER_MANIFEST" "$FINAL_MANIFEST"; then
        echo "build-debug.sh: inputs changed during assembly; retrying" >&2
        attempt=$((attempt + 1))
        continue
    fi

    STABLE_MANIFEST="$AFTER_MANIFEST"
    break
done

[[ -n "$STABLE_MANIFEST" ]] \
    || fail "Debug build inputs did not remain stable after 3 attempts"

PUBLISH_BACKUP="$DIST_DIR/.MarkdownViewer.app.previous.$TOKEN"
[[ ! -e "$PUBLISH_BACKUP" && ! -L "$PUBLISH_BACKUP" ]] \
    || fail "publication backup path already exists"

if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] \
        || fail "refusing to replace an unsafe Debug app path: $APP_DIR"
    mv "$APP_DIR" "$PUBLISH_BACKUP"
fi

if ! mv "$STAGE_APP" "$APP_DIR"; then
    if [[ -d "$PUBLISH_BACKUP" && ! -L "$PUBLISH_BACKUP" \
        && ! -e "$APP_DIR" && ! -L "$APP_DIR" ]]; then
        mv "$PUBLISH_BACKUP" "$APP_DIR"
        PUBLISH_BACKUP=""
    fi
    fail "could not publish the staged Debug app"
fi
PUBLISHED_NEW_APP=1

REUSE_REASON=""
debug_app_is_reusable "$APP_DIR" "$STABLE_MANIFEST" \
    || fail "published Debug app failed validation: $REUSE_REASON"

PUBLICATION_COMMITTED=1
safe_remove_tree "$PUBLISH_BACKUP"
PUBLISH_BACKUP=""

echo "$APP_DIR"
