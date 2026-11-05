#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="$HOME/.local/share/jdk-17"
export PATH="$HOME/.local/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH"

cd "$SCRIPT_DIR"

if [[ "$1" == "--android" || "$1" == "-a" ]]; then
  exec flutter run --release -d android "${@:2}"
fi

# Prefer release Linux bundle for 60/120fps native AOT performance; fall back to debug bundle or flutter run --release
RELEASE_BIN="$SCRIPT_DIR/build/linux/x64/release/bundle/aaa_tracker_app"
DEBUG_BIN="$SCRIPT_DIR/build/linux/x64/debug/bundle/aaa_tracker_app"
if [[ -x "$RELEASE_BIN" && "$1" != "--dev" && "$1" != "--rebuild" ]]; then
  exec "$RELEASE_BIN"
elif [[ -x "$DEBUG_BIN" && "$1" != "--dev" && "$1" != "--rebuild" ]]; then
  exec "$DEBUG_BIN"
else
  exec flutter run --release -d linux
fi
