#!/bin/zsh
set -euo pipefail

# Rebuild, repackage and relaunch the SwiftPM app for dev iteration.
# Pass "release" to iterate against the release configuration.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-debug}"

pkill -x SkymapText 2>/dev/null || true
APP_PATH="$("$ROOT_DIR/scripts/make_app.sh" "$MODE" | tail -n 1)"
open -n "$APP_PATH"
