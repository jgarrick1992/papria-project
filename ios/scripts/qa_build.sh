#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
DESTINATION=${IOS_DESTINATION:-"generic/platform=iOS Simulator"}
CONFIGURATION=${1:-Debug}
if [ "$#" -gt 0 ]; then shift; fi

bash "$PROJECT_DIR/scripts/fetch_mobilevlckit.sh"
exec xcodebuild \
  -project "$PROJECT_DIR/Papria.xcodeproj" \
  -scheme Papria \
  -configuration "$CONFIGURATION" \
  -sdk iphonesimulator \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing \
  "$@"
