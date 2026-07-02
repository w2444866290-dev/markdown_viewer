#!/usr/bin/env bash
set -euo pipefail

# Developer launcher: builds the .app via scripts/build.sh, then opens it with the
# --debug flag so the on-screen DIAG HUD (gated behind AppEnv.debug) is enabled.
# A normal double-click / `open` launch stays in plain USER mode with no HUD.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/build.sh" | tail -n 1)"   # build.sh echoes the .app path on its last line
open "$APP" --args --debug
