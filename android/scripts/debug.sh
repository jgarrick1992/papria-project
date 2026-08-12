#!/usr/bin/env sh
set -eu

# Resolve the Android project from this script so the command works when it is
# invoked from the repository root, android/, or android/scripts/.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

exec "$PROJECT_DIR/gradlew" -p "$PROJECT_DIR" :app:assembleDebug "$@"
