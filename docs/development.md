# Development

## Prerequisites

- Android Studio Ladybug or newer, JDK 21, Android SDK 35 or newer.
- Xcode 16.4 or newer and Swift 6 toolchain.
- Rust `1.85.1` and `cargo` for parity with CI.
- UniFFI v0.28.3 CLI (`uniffi-bindgen`) when regenerating Kotlin/Swift bindings;
  install the reviewed source revision with
  `cargo install --git https://github.com/mozilla/uniffi-rs.git --rev 0d38fc51ec057c271233b70db51b13ef403e360d --locked uniffi-bindgen-cli`.
- For native-core packaging: the Rust Apple targets plus Xcode; Android also
  needs an Android NDK and `cargo-ndk`.
- A BookOrbit `v2.5.0` instance for integration tests.

## Repository checks

```bash
./scripts/verify-contracts.sh
./scripts/verify-structure.sh
./scripts/verify-fixtures.sh
./scripts/verify-repository.sh
cargo fmt --manifest-path shared/format-core/Cargo.toml -- --check
cargo test --manifest-path shared/format-core/Cargo.toml
cargo clippy --manifest-path shared/format-core/Cargo.toml --all-targets -- -D warnings
bash scripts/generate-format-bindings.sh  # direct binding check; requires uniffi-bindgen 0.28.3
scripts/build-format-core.sh ios          # direct XCFramework packaging check
JAVA_HOME="${JAVA_HOME:?Set JAVA_HOME to JDK 21 or newer}" \
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME:?Set Android NDK path}" \
  android/gradlew --no-daemon -p android :app:testDebugUnitTest :app:assembleDebug \
    :app:verifyNativeCoreDebugPackage :app:assembleRelease \
    :app:verifyNativeCoreReleasePackage :app:verifyLibVlcReleasePackage
IOS_DESTINATION='generic/platform=iOS Simulator' \
  sh ios/scripts/qa_build.sh Debug -derivedDataPath /tmp/papria-ios-derived
```

The iOS command requires macOS and an installed simulator runtime. The Android command uses the Gradle wrapper committed in this repository.

`scripts/build-format-core.sh ios` deliberately fails with an actionable
missing-target message when the Rust Apple targets are not installed. The iOS
project invokes that preparation in its build phase, so it is a default
delivery dependency rather than an optional native bridge. The Android Gradle
`preBuild` task likewise invokes the Android variant; it requires an NDK and
`cargo-ndk` and renames each ABI library to the generated binding's exact
`libuniffi_papria_format_core.so` name. No native binaries are checked into
source control. Both Debug and Release fail if the required shared-core output
is absent. The package checks cover the generated binding, JNA dependency,
jniLibs layout, all four shared-core ABI entries, the reviewed LibVLC AAR
checksum, and `libvlc.so`/`libvlcjni.so` in the final Release APK. There is no
`nativeCore` Gradle switch.

The Android Readium/PDFium dependencies now resolve and the Debug/Release
package gates, lint, native-core, and LibVLC checks pass with JDK 21. The
connected Android device gate still requires a working ADB/emulator service;
the iOS App-only build and 77 arm64 simulator XCTest/UI tests pass. See
[`spec-audit.md`](spec-audit.md) before claiming either integration works.

The shared gates are intentionally runnable without a BookOrbit server or
copyrighted book files. See [`acceptance.md`](acceptance.md) for the evidence
that must be added by platform/device integration tests before release.

For GitHub Actions pinning, SBOM, checksum, provenance, signing-secret and
release procedures, see [`supply-chain.md`](supply-chain.md) and
[`../RELEASING.md`](../RELEASING.md). Do not use a local unsigned APK or a
simulator `.app` as a store-ready release artifact.

## Local BookOrbit testing

Configure a test server URL and credentials only in local, untracked settings. Never put tokens, cookies, or real library paths in fixtures. The client initially validates the `v2.5.0` response shapes and refuses untested server versions for remote features.

## Offline testing

Disable the network after a book is downloaded, reopen the app, advance the position, and re-enable the network. The local position must remain readable and the outbox must retry the exact progress fields after connectivity returns.
