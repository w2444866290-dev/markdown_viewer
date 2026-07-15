#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/visual/visual-matrix.sh"
HTML="$ROOT/ui/Markdown Viewer.dc.html"
SUPPORT_JS="$ROOT/ui/support.js"
TOOLS_DIR="$ROOT/build/visual-tools"
CACHE_DIR="$TOOLS_DIR/cache"
RUNNER="$TOOLS_DIR/ReferenceSnapshot"
EXPECTED_HTML_SHA="269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
REACT_URL="https://unpkg.com/react@18.3.1/umd/react.production.min.js"
REACT_SRI="DGyLxAyjq0f9SPpVevD6IgztCFlnMF6oW/XQGmfe+IsZ8TqEiDrcHkMLKI6fiB/Z"
REACT_DOM_URL="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js"
REACT_DOM_SRI="gTGxhz21lVGYNMcdJOyq01Edg0jhn/c22nsx0kyqP0TxaV5WVdsSH1fSDUf5YJj1"

usage() {
    cat <<'EOF'
Usage: ./scripts/visual/capture-reference.sh [ReferenceSnapshot options]

Capture the authoritative .dc.html in an isolated WebKit view.
The default output is build/visual-reference at normalized 2x pixels.
Pinned React UMD files are cached under build/visual-tools/cache after SRI verification.

Common examples:
  ./scripts/visual/capture-reference.sh
  ./scripts/visual/capture-reference.sh --states default,palette,find,preview
  ./scripts/visual/capture-reference.sh --sizes 1180x760 --states table-editor

Run with --runner-help for the complete runner option list.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

python3 "$ROOT/scripts/visual/verify-support-runtime.py" \
    --support-js "$SUPPORT_JS" \
    --react-url "$REACT_URL" \
    --react-sri "sha384-$REACT_SRI" \
    --react-dom-url "$REACT_DOM_URL" \
    --react-dom-sri "sha384-$REACT_DOM_SRI"

ACTUAL_HTML_SHA="$(shasum -a 256 "$HTML" | awk '{print $1}')"
if [[ "$ACTUAL_HTML_SHA" != "$EXPECTED_HTML_SHA" ]]; then
    echo "capture-reference.sh: authoritative HTML SHA-256 mismatch" >&2
    echo "capture-reference.sh: expected $EXPECTED_HTML_SHA" >&2
    echo "capture-reference.sh: actual   $ACTUAL_HTML_SHA" >&2
    exit 2
fi

mkdir -p "$CACHE_DIR"

verify_sri() {
    local file="$1"
    local expected="$2"
    [[ -s "$file" ]] || return 1
    local actual
    actual="$(openssl dgst -sha384 -binary "$file" | openssl base64 -A)"
    [[ "$actual" == "$expected" ]]
}

fetch_pinned() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    if verify_sri "$destination" "$expected"; then
        return 0
    fi
    local temporary="$destination.download"
    rm -f "$temporary"
    curl --fail --location --silent --show-error --retry 3 "$url" --output "$temporary"
    if ! verify_sri "$temporary" "$expected"; then
        rm -f "$temporary"
        echo "capture-reference.sh: SRI verification failed for $url" >&2
        exit 3
    fi
    mv "$temporary" "$destination"
}

fetch_pinned "$REACT_URL" "$CACHE_DIR/react.production.min.js" "$REACT_SRI"
fetch_pinned "$REACT_DOM_URL" "$CACHE_DIR/react-dom.production.min.js" "$REACT_DOM_SRI"

xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -framework AppKit \
    -framework WebKit \
    "$ROOT/scripts/visual/ReferenceSnapshot.swift" \
    -o "$RUNNER"

if [[ "${1:-}" == "--runner-help" ]]; then
    exec "$RUNNER" --help
fi

cd "$ROOT"
exec "$RUNNER" \
    --html "$HTML" \
    --react "$CACHE_DIR/react.production.min.js" \
    --react-dom "$CACHE_DIR/react-dom.production.min.js" \
    --contract "$ROOT/scripts/visual/acceptance-contract.json" \
    --sizes "$VISUAL_DEFAULT_SIZES" \
    --states "$VISUAL_DEFAULT_STATES" \
    "$@"
