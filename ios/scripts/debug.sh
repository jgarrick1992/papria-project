#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
DESTINATION=${IOS_DESTINATION:-"platform=iOS Simulator,name=iPhone 15"}

bash "$PROJECT_DIR/scripts/fetch_mobilevlckit.sh"

exec xcodebuild \
  -project "$PROJECT_DIR/Papria.xcodeproj" \
  -scheme Papria \
  -sdk iphonesimulator \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  "$@"
