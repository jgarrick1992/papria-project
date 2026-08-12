#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${MOBILEVLCKIT_OUT_DIR:-$ROOT_DIR/ThirdParty/Build}"
ARCHIVE="$OUT_DIR/MobileVLCKit-3.7.2.tar.xz"
FRAMEWORK="$OUT_DIR/MobileVLCKit.xcframework"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.2-3e42ae47-79128878.tar.xz"
SHA256="77b867667e5e62aa4062e71b7a4f76a0e2f505425916091c0eb0f94d9ad4af80"

mkdir -p "$OUT_DIR"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 2 --connect-timeout 20 --output "$ARCHIVE.partial" "$URL"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum --algorithm 256 --check --status

# The signed archive nests the framework under MobileVLCKit-binary/. Always
# extract the checksum-verified archive into a new directory, then atomically
# replace the installed framework. This never treats an arbitrary pre-existing
# framework directory as trusted.
STAGING_DIR="$(mktemp -d "$OUT_DIR/.mobilevlckit.XXXXXX")"
BACKUP_FRAMEWORK="$OUT_DIR/.MobileVLCKit.xcframework.previous"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

tar --extract --xz --file "$ARCHIVE" --directory "$STAGING_DIR"
EXTRACTED_FRAMEWORK="$STAGING_DIR/MobileVLCKit-binary/MobileVLCKit.xcframework"
[[ -d "$EXTRACTED_FRAMEWORK" && -f "$EXTRACTED_FRAMEWORK/Info.plist" ]] || {
  echo "Verified MobileVLCKit archive did not contain its expected XCFramework" >&2
  exit 1
}

rm -rf "$BACKUP_FRAMEWORK"
if [[ -e "$FRAMEWORK" ]]; then
  mv "$FRAMEWORK" "$BACKUP_FRAMEWORK"
fi
if ! mv "$EXTRACTED_FRAMEWORK" "$FRAMEWORK"; then
  [[ ! -e "$FRAMEWORK" && -e "$BACKUP_FRAMEWORK" ]] && mv "$BACKUP_FRAMEWORK" "$FRAMEWORK"
  exit 1
fi
rm -rf "$BACKUP_FRAMEWORK"
printf 'Verified %s\n' "$FRAMEWORK"
