#!/usr/bin/env bash
set -euo pipefail

# Build the iOS app through its normal target. Papria's first build phase always
# generates and links the Rust XCFramework, so this script is only a convenient
# CI entry point instead of a separate opt-in native-core mode.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA="${DERIVED_DATA_PATH:-/tmp/papria-native-core-derived}"
DESTINATION="${IOS_DESTINATION:-generic/platform=iOS Simulator}"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "native_core_build: macOS/Xcode is required" >&2
  exit 1
}

# Keep network acquisition explicit in this command instead of giving every
# Xcode build an implicit downloader. The app target itself only verifies that
# the checksum-validated framework is already present.
bash "$ROOT_DIR/ios/scripts/fetch_mobilevlckit.sh"

case "$DESTINATION" in
  *"iOS Simulator"*) sdk="iphonesimulator" ;;
  *) sdk="iphoneos" ;;
esac

xcodebuild \
  -project "$ROOT_DIR/ios/Papria.xcodeproj" \
  -scheme Papria \
  -sdk "$sdk" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
