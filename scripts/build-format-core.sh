#!/usr/bin/env bash
set -euo pipefail

# Xcode Run Script phases do not source the user's shell profile.
if [[ -n "${HOME:-}" && -d "$HOME/.cargo/bin" ]]; then
  export PATH="$HOME/.cargo/bin${PATH:+:$PATH}"
fi

# Build the Rust format core for Apple platforms and package the C ABI as an
# XCFramework. Android uses the same crate, but requires an installed Android
# NDK and cargo-ndk; use the explicit `android` target after those prerequisites
# are present. No prebuilt native binaries are checked into the repository.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/shared/format-core"
OUT_DIR="${PAPRIA_NATIVE_OUT:-$CRATE_DIR/artifacts}"
PROFILE="${PAPRIA_NATIVE_PROFILE:-release}"
TARGET="${1:-ios}"
IOS_DEPLOYMENT_TARGET="15.0"

die() {
  printf 'build-format-core: %s\n' "$*" >&2
  exit 1
}

command -v cargo >/dev/null || die "cargo is required"
command -v rustup >/dev/null || die "rustup is required"
# The generated Kotlin/Swift code is part of the native ABI. Recreate it for
# every platform build so a changed UDL can never be paired with stale FFI.
"$ROOT_DIR/scripts/generate-format-bindings.sh"

installed_target() {
  rustup target list --installed | grep -Fxq "$1"
}

build_ios() {
  local device_target="aarch64-apple-ios"
  local simulator_arm="aarch64-apple-ios-sim"
  local simulator_x86="x86_64-apple-ios"

  for target in "$device_target" "$simulator_arm" "$simulator_x86"; do
    installed_target "$target" || die "Rust target $target is not installed; run: rustup target add $target"
  done
  command -v xcodebuild >/dev/null || die "xcodebuild is required to create an XCFramework"
  build_ios_target() {
    local rust_target="$1"
    local deployment_flag="$2"
    shift 2
    local inherited_rustflags="${RUSTFLAGS:-}"
    local rustflags="-C link-arg=$deployment_flag"
    if [[ -n "$inherited_rustflags" ]]; then
      rustflags="$inherited_rustflags $rustflags"
    fi
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" RUSTFLAGS="$rustflags" \
      cargo build --locked --manifest-path "$CRATE_DIR/Cargo.toml" --target "$rust_target" "$@"
  }

  mkdir -p "$OUT_DIR/ios"
  case "$PROFILE" in
    release)
      build_ios_target "$device_target" "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET" --release
      build_ios_target "$simulator_arm" "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET" --release
      build_ios_target "$simulator_x86" "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET" --release
      ;;
    debug)
      build_ios_target "$device_target" "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
      build_ios_target "$simulator_arm" "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
      build_ios_target "$simulator_x86" "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
      ;;
    *) die "PAPRIA_NATIVE_PROFILE must be exactly release or debug (got: $PROFILE)" ;;
  esac

  local device_lib="$CRATE_DIR/target/$device_target/$PROFILE/libpapria_format_core.a"
  local sim_arm_lib="$CRATE_DIR/target/$simulator_arm/$PROFILE/libpapria_format_core.a"
  local sim_x86_lib="$CRATE_DIR/target/$simulator_x86/$PROFILE/libpapria_format_core.a"
  local sim_lib="$OUT_DIR/ios/libpapria_format_core_sim.a"
  [[ -f "$device_lib" && -f "$sim_arm_lib" && -f "$sim_x86_lib" ]] || die "Rust static library output is missing"
  lipo -create "$sim_arm_lib" "$sim_x86_lib" -output "$sim_lib"

  local headers="$OUT_DIR/ios/headers"
  rm -rf "$headers"
  mkdir -p "$headers"
  cp "$CRATE_DIR/bindings/generated/papria_format_coreFFI.h" "$headers/"
  cp "$CRATE_DIR/bindings/generated/papria_format_coreFFI.modulemap" "$headers/module.modulemap"

  rm -rf "$OUT_DIR/PapriaFormatCore.xcframework"
  xcodebuild -create-xcframework \
    -library "$device_lib" -headers "$headers" \
    -library "$sim_lib" -headers "$headers" \
    -output "$OUT_DIR/PapriaFormatCore.xcframework"

  cp "$CRATE_DIR/bindings/generated/papria_format_core.swift" "$OUT_DIR/ios/"
  printf 'Built %s\n' "$OUT_DIR/PapriaFormatCore.xcframework"
}

build_android() {
  command -v cargo-ndk >/dev/null || die "cargo-ndk is required for Android targets"
  [[ -n "${ANDROID_NDK_HOME:-}" ]] || die "ANDROID_NDK_HOME must point to an installed Android NDK"
  mkdir -p "$OUT_DIR/android"
  (
    cd "$CRATE_DIR"
    case "$PROFILE" in
      release)
        cargo ndk -t arm64-v8a -t armeabi-v7a -t x86 -t x86_64 \
          -o "$OUT_DIR/android" build --release
        ;;
      debug)
        cargo ndk -t arm64-v8a -t armeabi-v7a -t x86 -t x86_64 \
          -o "$OUT_DIR/android" build
        ;;
      *) die "PAPRIA_NATIVE_PROFILE must be exactly release or debug (got: $PROFILE)" ;;
    esac
  )

  # UniFFI's generated Kotlin loader resolves the component as
  # `uniffi_papria_format_core`. cargo-ndk names the cdylib after the Rust
  # crate (`papria_format_core`), so normalise every ABI output before Gradle
  # consumes the jniLibs directory. Keeping one canonical name avoids a
  # second compatibility loader or a hidden library-name mapping in app code.
  local found=0
  while IFS= read -r -d '' library; do
    local directory
    directory="$(dirname "$library")"
    mv -f "$library" "$directory/libuniffi_papria_format_core.so"
    found=$((found + 1))
  done < <(find "$OUT_DIR/android" -type f -name 'libpapria_format_core.so' -print0)
  [[ "$found" -eq 4 ]] || die "expected one libpapria_format_core.so for each Android ABI, found $found"
  printf 'Built Android native libraries under %s/android\n' "$OUT_DIR"
}

case "$TARGET" in
  ios) build_ios ;;
  android) build_android ;;
  all) build_ios; build_android ;;
  *) die "usage: $0 [ios|android|all]" ;;
esac
