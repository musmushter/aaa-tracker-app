#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

cd "$SCRIPT_DIR"

# If the compiled Linux bundle exists and --rebuild wasn't passed, launch it directly (instant startup).
BUNDLE_BIN="$SCRIPT_DIR/build/linux/x64/debug/bundle/aaa_tracker_app"
if [[ -x "$BUNDLE_BIN" && "$1" != "--dev" && "$1" != "--rebuild" ]]; then
  exec "$BUNDLE_BIN"
else
  exec flutter run -d linux
fi
