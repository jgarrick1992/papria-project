# License inventory generation

`THIRD_PARTY_NOTICES.md` is the human-reviewed release inventory. It must be
reconciled with the exact release artifact; a package manager's license field
is not, by itself, legal clearance.

## Repeatable source reports

Run these commands from a clean checkout at the release commit, using the
versions in `docs/supply-chain.md`:

```bash
REPORT_DIR="${REPORT_DIR:-$HOME/Downloads/Codex/papria-license}"
mkdir -p "$REPORT_DIR"

./android/gradlew --no-daemon -p android \
  :app:dependencies --configuration releaseRuntimeClasspath \
  > "$REPORT_DIR/android-release-runtime.txt"

cargo metadata --locked --manifest-path shared/format-core/Cargo.toml \
  --format-version=1 > "$REPORT_DIR/rust-metadata.json"

xcodebuild -project ios/Papria.xcodeproj -scheme Papria \
  -configuration Release -showBuildSettings \
  > "$REPORT_DIR/ios-release-build-settings.txt"
```

The weekly/manual Supply-chain evidence workflow archives the first two
reports, a CycloneDX SBOM, and toolchain hashes. The format core is included by
default; `nativeCore` is not a supported property. The iOS release workflow
archives Xcode and signing evidence. The example writes local reports outside
the source tree under `~/Downloads/Codex`; set `REPORT_DIR` if another approved
location is required.

## Current reader/decoder evidence (not a release clearance)

| Component | Recorded evidence | What remains before release |
| --- | --- | --- |
| Readium Kotlin 3.1.2 | Four direct Android coordinates are declared; the Debug/Release package gates resolved them, and the inspected Readium license text is BSD-3-Clause. | Retain exact artifact versions/hashes from the release graph and reproduce the BSD license/attribution in the release materials. |
| Readium PDFium adapter | `readium-adapter-pdfium:3.1.2` is declared; JitPack is limited to `com.github.marain87`, and the Android package gates pass. | Capture the actual PdfiumAndroid/AndroidPdfViewer transitive artifacts, native ABIs, license/NOTICE texts and hashes from the resolved release graph. |
| Readium Swift Toolkit 3.8.0 | `Package.resolved` pins revision `f7d10d2bf5876408feae14d634416f69d1473fd8`; the checked toolkit `LICENSE` is BSD-3-Clause and the iOS App-only link passes. | Reconcile every pinned Swift package against the signed IPA. |
| MobileVLCKit 3.7.2 | The lock file and official podspec identify the VideoLAN archive, SHA-256 `77b867667e5e62aa4062e71b7a4f76a0e2f505425916091c0eb0f94d9ad4af80`, `COPYING.txt`, and LGPL v2.1. The source project fetches it with checksum verification and the iOS App-only link passes. | Inspect its included notices/source-offer and relinking obligations, then reconcile the actual signed IPA contents. |

## Human reconciliation checklist

For every component in the final APK/AAB/IPA and native XCFramework:

1. identify the exact version and source commit/URL;
2. obtain the upstream `LICENSE`, `NOTICE`, attribution, and source-offer or
   relinkability materials required by its license;
3. record static, dynamic, system-provided, and generated-code boundaries;
4. compare the result with `THIRD_PARTY_NOTICES.md` and add missing exact
   texts before tagging; and
5. obtain administrator/legal approval for LGPL, MPL, UnRAR, codec, Apple,
   patent, and app-store obligations.

Do not claim that the current source tree is fully license-cleared. The iOS
Readium package is locked and the App-only link passes, but no IPA has been
inspected; Android Readium/PDFium has produced local Debug/Release packages;
MobileVLCKit is pinned, downloaded, compiled, and linked into the App target,
but its signed IPA closure still needs reconciliation; and
LibVLC's coordinate/checksum still need final
artifact reconciliation. The final transitive closure is only known after the
release build is run.
