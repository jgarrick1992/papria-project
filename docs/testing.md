# Testing strategy

## Contract tests

`shared/contracts` is checked as JSON and used by both clients. Tests must assert exact route methods, paths, request fields, and no-alias behavior.

Run the fail-closed checker from the repository root:

```bash
bash scripts/verify-structure.sh
./scripts/verify-contracts.sh
./scripts/verify-test-matrix.sh
./scripts/verify-repository.sh
```

The checker rejects unknown keys, wrong primitive types, changed route values,
duplicate JSON keys, duplicate field names, invalid pagination/sort values,
out-of-range progress values, malformed Wi-Fi chunk ranges, and a missing
contract file. It validates every checked-in request fixture (login, query,
EPUB progress, audio progress, Wi-Fi create, and Wi-Fi chunk) with exact keys.
The files under `shared/contracts/fixtures/` are synthetic request examples for
platform serialization tests; they never contain credentials or real books.

## Test matrix integrity

`scripts/verify-test-matrix.sh` is a structural gate for the platform test
matrix. It requires non-empty Android main, JVM test, and instrumentation test
source sets; each Android test source must contain an `@Test` annotation paired
with a test function. It also requires XCTestCase test methods in
`ios/PapriaTests`, confirms every `.swift` file in that directory is in the
`PapriaTests` target's Sources build phase, and requires a Rust `#[test]` test
function under `shared/format-core`.

The gate deliberately checks test discoverability and project membership rather
than a fixed number of tests. Run it directly during test-file or Xcode project
changes; `scripts/verify-repository.sh` runs it as part of the repository gate.

## Shared core tests

- Format extension recognition for all BookOrbit formats.
- Bounded header sniffing for ZIP/RAR/7z comic archives and PDF magic bytes;
  extension/signature mismatches fail closed.
- SHA-256 stability.
- Incremental/streaming SHA-256 never requires the whole publication in memory.
- Filename controls, reserved characters, Windows device names, and UTF-8
  truncation.
- Converter cache key stability.
- FB2 conversion retains section navigation and bounded embedded images in the
  deterministic internal EPUB output.
- Archive path safety (absolute paths, drive prefixes, backslashes, `.` and
  `..`) before decompression.
- Archive entry count, per-entry size, aggregate size, zero-byte bombs, and
  compression-ratio limits before decompression.

## Android tests

- BookOrbit request construction and Range headers.
- Wi-Fi transfer token expiry and uniqueness.
- SQLite schema migrations and content-addressed `.part` recovery.
- WorkManager retry and conflict handling.
- CBZ/CBR/CB7 safety checks run before image filtering; Android CBR fixtures
  cover valid stored-member CRC32 reads, compressed-member decoder admission
  and ratio rejection, plus encrypted, traversal, and malformed inputs that
  must fail closed. Release validation still requires a license-cleared real
  compressed RAR4 fixture and physical-device decode test.
  Android FB2 conversion regression covers embedded image bytes.
- e-ink profile snapshot tests at compact 360dp and 600×800 reference sizes;
  Media3 session/queue commands must preserve the same local progress scope.

## iOS tests

- Exact Codable field names for query cards and detail file records.
- Keychain save/load behavior.
- Local receiver lifecycle and token expiry.
- Offline progress outbox behavior.
- Launch and navigation UI tests.
- ZIP duplicate/traversal rejection and bounded one-entry reads.

## Format fixtures

Every supported format requires normal, malformed, large, and special-filename
fixtures. The bounded vector manifest is checked in at
`shared/format-core/fixtures/manifest.json`; large files are generated in a
temporary directory and streamed, not committed to Git. Platform parser tests
must use license-cleared samples and assert that DRM files are rejected without
attempting decryption.

## Acceptance command set

The shared gates used by CI are:

```bash
./scripts/verify-contracts.sh
./scripts/verify-structure.sh
./scripts/verify-fixtures.sh
./scripts/verify-test-matrix.sh
./scripts/verify-repository.sh
cargo fmt --manifest-path shared/format-core/Cargo.toml -- --check
cargo test --manifest-path shared/format-core/Cargo.toml
cargo clippy --manifest-path shared/format-core/Cargo.toml --all-targets -- -D warnings
scripts/build-format-core.sh ios  # requires Rust Apple targets; CI packages this artifact
JAVA_HOME="${JAVA_HOME:?Set JAVA_HOME to JDK 21 or newer}" \
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME:?Set Android NDK path}" \
  android/gradlew --no-daemon -p android :app:testDebugUnitTest :app:lintDebug \
    :app:assembleDebug :app:verifyNativeCoreDebugPackage :app:assembleRelease \
    :app:verifyNativeCoreReleasePackage :app:verifyLibVlcReleasePackage
IOS_DESTINATION='generic/platform=iOS Simulator' \
  sh ios/scripts/qa_build.sh Debug -derivedDataPath /tmp/papria-ios-derived
```

The Android command triggers the mandatory format-core build; the retired
opt-in Gradle switch is not supported. These are required gates, and the current
checkout has produced a complete Android Debug/Release APK and an iOS App-only
build. They are not proof of device execution. Android
dependency resolution, lint, Debug/Release packaging, native-core checks, and
`compileDebugKotlin` have passed. An API 26 emulator has executed the database
migration and packaged native-core instrumentation tests; broader connected
coverage, including the Wi-Fi HTTP server path, remains a device gate. The iOS
app and test targets execute on an arm64 iPhone 17 Pro simulator (iOS 26.3.1),
with 77 XCTest/UI tests passing. These checks do not replace real-device
acceptance:
Android e-ink refresh, BookOrbit server integration, local-network Wi-Fi
transfer, and iOS simulator/runtime tests still require the device/server
evidence listed in [`acceptance.md`](acceptance.md).
