#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

# Keep this list aligned with tasks provided by the Android Gradle Plugin and
# the Papria module. Coverage is intentionally omitted until a Jacoco policy
# and report task are added to the project build.
exec "$PROJECT_DIR/gradlew" -p "$PROJECT_DIR" \
  lintDebug \
  lintRelease \
  :app:testDebugUnitTest \
  :app:assembleDebug \
  :app:bundleRelease \
  "$@"
