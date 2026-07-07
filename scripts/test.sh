#!/usr/bin/env bash
set -euo pipefail

# Run the MarkdownViewer test suite (Swift Testing) with ONE command on any Mac,
# whether it has full Xcode or only the Command Line Tools installed.
#
# WHY THIS SCRIPT EXISTS
# The tests are written against Apple's Swift Testing framework (`import Testing`),
# because this project is developed on a machine that ships only the Command Line
# Tools (no Xcode → no XCTest.framework to build or run against). On a full-Xcode
# machine `swift test` finds Testing.framework on its own default search paths. On
# a CLT-only machine the framework IS present, but under the CLT developer dir and
# NOT on the default search paths, so `swift test` cannot locate it unless we point
# the compiler (-F) and the runtime loader (rpath) at it explicitly.
#
# We derive every path from `xcode-select -p` at run time — nothing absolute is
# hard-coded here or in Package.swift — so the same script works on both setups and
# survives an Xcode/CLT move or version bump.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEV="$(xcode-select -p)"
FRAMEWORKS="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
    # Command Line Tools layout: Testing.framework lives under the CLT developer
    # dir, off the default search paths. Add it for the compiler (-F) and both the
    # framework dir and the Swift runtime lib dir to the loader's rpath so the test
    # bundle can find and load it at run time.
    echo "test.sh: CLT layout — adding Testing.framework search paths under $DEV" >&2
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$LIB" \
        "$@"
else
    # Full Xcode: Testing.framework is on the default toolchain search paths.
    echo "test.sh: Xcode layout — using default Testing.framework search paths" >&2
    exec swift test "$@"
fi
