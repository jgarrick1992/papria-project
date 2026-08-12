# Papria mobile reader acceptance checklist

This checklist turns `docs/bookorbit-mobile-reader-spec.full.md` into
repeatable gates. It deliberately distinguishes checks completed in the
repository from device/server acceptance that still belongs to Android and
iOS implementation work.

## Shared/core gates

| Gate | Evidence | Expected result |
| --- | --- | --- |
| Required repository layout | `bash scripts/verify-structure.sh` | Android, iOS, shared contracts, `.gitignore`, CI and issue/PR metadata exist |
| Repository policy | `./scripts/verify-repository.sh` | Third-party Actions are SHA-pinned, repository scripts parse, generated/secrets paths are ignored, and no tracked file is ignored |
| Exact BookOrbit v2.5.0 routes and fields | `./scripts/verify-contracts.sh` | Strict keys, primitive types, values, and duplicate-key rejection pass |
| Every declared format has fixture metadata | `shared/format-core/fixtures/manifest.json` | 16 formats × normal/malformed/large/special-name cases present |
| Extension and bounded signature detection | `cargo test --manifest-path shared/format-core/Cargo.toml` | ZIP/RAR/7z/PDF mismatch fails closed |
| Content identity | Same test command plus stream test | SHA-256 is lower-case, deterministic, and incremental |
| Filename safety | Same test command | Controls, reserved names, path separators, and device names reject or sanitize deterministically |
| Archive safety | Same test command | Traversal, absolute paths, excessive entries/sizes/ratios fail before extraction |
| Rust quality | `cargo fmt ... -- --check`; `cargo clippy ... -- -D warnings` | No formatting or lint errors |
| Native core default delivery | `scripts/build-format-core.sh ios` and the Android/iOS project build phases | Android runs the core builder before every `preBuild`; iOS runs it before directly linking `PapriaFormatCore.xcframework`. Generated artifacts are ignored and a missing toolchain, binding, or ABI fails the build. The iOS App-only build and Android package linkage have been verified locally. |
| Android native-core package gates | `android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:verifyNativeCoreDebugPackage :app:assembleRelease :app:verifyNativeCoreReleasePackage :app:verifyLibVlcReleasePackage` | Debug and Release package checks pass with the generated UniFFI/JNA binding, all four native-core ABI entries, and LibVLC packaging. There is no `nativeCore` flag or native-free product variant. A connected emulator smoke test remains external evidence. |

The checked-in Android emulator runner now passes `bash -n`, selects a JDK
17+ and installed NDK automatically, and writes the connected test report
under `android/app/build/outputs/androidTest-results/connected/`. A previous
API 26 run passed the Room migration and packaged native-core smoke tests;
reproducing that run in the current sandbox was blocked by the environment's
ADB/Gradle permissions and unavailable Gradle distribution network. The
current runner now fails fast at `adb start-server` with
`could not install *smartsocket* listener: Operation not permitted` and writes
the diagnostic to the `PAPRIA_ADB_LOG` path instead of waiting for the full
emulator timeout.

## Platform/device gates

These require real platform test targets and cannot be proven by the shared
crate alone:

- Android API 23+, ordinary color mode, manual e-ink mode, compact 360 dp, and
  600×800 reference layout.
- iOS 15+ SwiftUI reader and iPhone SE layout.
- SQLite persistence, content-addressed `.part` downloads, Range restart,
  BookOrbit authentication refresh, progress outbox, and conflict prompt.
- Foreground Wi-Fi receiver: token in URL fragment, bearer enforcement,
  8 MiB chunks, resume after interruption, 24-hour cleanup, local-only import,
  and Safari/Chrome/desktop browser interoperability.
- Android Readium EPUB/KEPUB/PDFium, CBZ/CB7/RAR4/text/Media3 audio and iOS
  Readium EPUB/PDF, libarchive, AVFoundation/MobileVLCKit fallback behavior,
  including lock screen, interruption, Bluetooth, process restart, exact
  locators, Range and redirect handling. Current Readium/PDFium and
  MobileVLCKit source integration is not a substitute for this evidence. The
  archive adapters enforce bounded streaming and reject DRM/encrypted entries.
- DRM rejection, disk-space preflight, and archive extraction into an
  app-private directory with no symlink/path escape.

## Release evidence package

Before a release candidate is tagged, attach the following artifacts to the
release or CI summary:

1. Output of the shared/core command set in `docs/testing.md`.
2. Android unit/instrumentation test report and screenshots at 360 dp and
   600×800, including e-ink no-animation assertions.
3. iOS unit/UI test report and iPhone SE screenshot.
4. A local BookOrbit `v2.5.0` integration run showing login, paged list,
   Range resume, pull-before-push progress, and post-upload verification.
5. Wi-Fi transfer logs with tokens redacted, showing an interrupted chunk,
   successful resume, duplicate SHA-256 deduplication, and server isolation.
6. Dependency/license report for the exact reader/audio artifacts. The source
   declares Readium Kotlin 3.1.2/PDFium on Android, Readium Swift Toolkit 3.8.0
   on iOS, Android LibVLC 3.6.5, and MobileVLCKit 3.7.2; the final resolved
   transitive closure, notices, and final-artifact contents must be attached
   rather than inferred from these declarations.
7. The release-candidate artifact, `SHA256SUMS.txt`, CycloneDX SBOM, build
   provenance attestation, Android/iOS test reports, and observed toolchain
   report from the exact release tag. See `RELEASING.md` and
   `docs/supply-chain.md`; an unsigned candidate must not be described as a
   signed, store-ready package.

No acceptance report may claim a Kindle installation target: the Kindle
6-inch/600×800 profile is a layout reference only.
