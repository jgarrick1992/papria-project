# Third-party notices and release inventory

Papria's own source is licensed under [Apache-2.0](LICENSE). Papria is an
independent client: it does **not** bundle BookOrbit server code, its AGPL
license, its UI, its TypeScript, icons, or brand assets.

This is a source-tree inventory, not a statement that a store-ready binary has
already been license-cleared. It records the direct dependencies declared on
2026-08-11. The final runtime closure must be generated from the exact release
commit and reconciled with the APK/AAB/IPA and CycloneDX SBOM as described in
[`docs/supply-chain.md`](docs/supply-chain.md). A release is blocked until the
release owner replaces every **release review required** entry with the exact
upstream notice/source material required by the shipped artifact.

## Shipped source/runtime dependencies

| Component | Declared version/source | License status | Distribution action |
| --- | --- | --- | --- |
| AndroidX Core, Activity, Lifecycle, Room, WorkManager, Compose and Media3 | Exact coordinates in `android/app/build.gradle.kts` | Apache-2.0 upstream | Include required upstream NOTICE/attribution from the resolved release graph if any. |
| OkHttp | `com.squareup.okhttp3:okhttp:4.12.0` | Apache-2.0 | Reconcile transitive Okio/Kotlin notices from the resolved graph. |
| Apache Commons Compress | `org.apache.commons:commons-compress:1.21` | Apache-2.0 | Retain Apache-2.0 and upstream NOTICE if present in the shipped artifact. |
| XZ for Java | `org.tukaani:xz:1.9` | Public-domain / 0BSD-style upstream terms | Preserve the exact upstream notice and verify the resolved artifact's license text. |
| Junrar | `com.github.junrar:junrar:7.5.5` | UnRAR License | The checked-in text is [`third_party/licenses/JUNRAR-7.5.5-UNRAR.txt`](third_party/licenses/JUNRAR-7.5.5-UNRAR.txt). Do not use it to recreate the RAR compression algorithm. |
| SLF4J Android | `org.slf4j:slf4j-android:1.7.36` | MIT | Include the exact MIT notice if the release graph packages it. |
| ZXing Core | `com.google.zxing:core:3.5.3` | Apache-2.0 | Include required attribution/NOTICE from the resolved release graph. |
| Java Native Access (JNA) | `net.java.dev.jna:jna:5.14.0@aar`, native-core builds | Dual Apache-2.0 / LGPL-2.1-or-later upstream | **Release review required.** Record the chosen license path and provide the required notice/source or relinkability material for the actual AAR/native binaries. |
| libmobi | Vendored upstream `v0.12`, commit `85dcfe803fc2a21020ddcf15c3eb66b93d388add`; source-export SHA-256 `73bfb526dc11f5ecc1e57835aa84e0c8719a2a43427036d177fb529db0ac951b` | LGPL-3.0-or-later | The matching source, upstream `COPYING`, full license text and provenance are in [`shared/format-core/vendor/libmobi`](shared/format-core/vendor/libmobi) and [`third_party/licenses`](third_party/licenses). **Release review required:** provide the final Android/iOS binary's corresponding-source and relinkability materials. |
| Rust `sha2` and transitive Rust crates | Locked by `shared/format-core/Cargo.lock` | Per-crate (commonly Apache-2.0/MIT, but do not assume) | **Release review required.** Generate and reconcile the full locked Rust closure; direct crate names are not a license conclusion. |
| UniFFI runtime | `uniffi:0.28.3` | MPL-2.0 | **Release review required.** Preserve MPL-2.0 obligations for the actual linked native runtime and source modifications, if any. |
| Readium Kotlin | `readium-shared`, `readium-streamer`, `readium-navigator` `3.1.2` | BSD-3-Clause and transitive notices | **Release review required.** The Android source declares the production EPUB/KEPUB route, but Gradle has not yet produced a resolved release graph. Reconcile the exact POMs, notices, and transitive artifacts. |
| Readium PDFium adapter | `readium-adapter-pdfium:3.1.2`, with JitPack restricted to `com.github.marain87` | BSD-3-Clause and transitive/native notices | **Release review required.** Record the resolved PdfiumAndroid/AndroidPdfViewer artifacts, ABIs, hashes, and notices after a successful Android release build. |
| Readium Swift Toolkit | Official SPM package `readium/swift-toolkit`, exact `3.8.0` revision `f7d10d2bf5876408feae14d634416f69d1473fd8` in `Package.resolved` | BSD-3-Clause and transitive notices | **Release review required.** Reconcile the locked package graph, actual IPA contents, and all notices before shipment. |
| LibVLC Android | `org.videolan.android:libvlc-all:3.6.5`; reviewed AAR SHA-256 `6a15a1f7acd0738a31acce0c7e5eb6f5f340b62e6b64d8f83df547da56a44b47` | Distribution/license and codec obligations require review | **Release review required.** It is a declared Android runtime dependency. Preserve its exact source, notices, native-library relinkability materials and codec/patent review for the final APK/AAB. |
| MobileVLCKit iOS | `3.7.2`, official VideoLAN archive SHA-256 `77b867667e5e62aa4062e71b7a4f76a0e2f505425916091c0eb0f94d9ad4af80` | LGPL-2.1-or-later and codec obligations require review | **Release review required.** The framework is checksum-fetched, linked, and embedded for local files only. Preserve corresponding source, notices, relinkability material, and codec/patent review for the final IPA. |
| Apple system frameworks and `libarchive` | Xcode/iOS system runtime; `OTHER_LDFLAGS=-larchive` | Apple SDK terms and libarchive's upstream BSD-style terms | Document that these are OS-provided/dynamically linked and preserve any required app attribution. Confirm the exact iOS SDK/runtime terms for the release target. |

## Not bundled by this source tree

BookOrbit server code is AGPL-3.0-or-later and is not part of Papria. It must
remain out of every client release package.

## Build-only tools

These are not automatically shipped in the client, but their versions are
part of reproducibility evidence and must be reviewed if they produce release
code or artifacts:

| Tool | Pinned selector | Why it matters |
| --- | --- | --- |
| Gradle Wrapper | Gradle `8.9`, ZIP SHA-256 in `android/gradle/wrapper/gradle-wrapper.properties` | Verifies the Gradle distribution downloaded by the wrapper. |
| JDK | Temurin `21.0.7+6` in GitHub Actions | Builds Android artifacts. |
| Rust | `1.85.1` in GitHub Actions | Builds the shared format core. |
| UniFFI generator source | commit `0d38fc51ec057c271233b70db51b13ef403e360d` (`v0.28.3`) | Generates bindings used for native-core packaging. |
| cargo-ndk | exact `=3.5.4` | Produces Android Rust ABIs. The 3.x line is intentional: cargo-ndk 4.1.2 declares Rust 1.86, while this repository pins Rust 1.85.1. Upgrade both in one reviewed change. |
| GitHub Actions | exact 40-character commit IDs enforced by CI | Prevents a mutable action tag from silently changing a workflow. |

## Release gate

Before publishing, the release owner must attach or make available:

1. the generated CycloneDX SBOM, Gradle `releaseRuntimeClasspath` report, and
   Rust locked dependency metadata for the exact commit;
2. an artifact-by-artifact notice table, exact upstream license texts/NOTICE
   files, source URLs, and any required source offer/relinkability material;
3. the SHA-256 checksum manifest, GitHub build provenance attestation, and
   Android/iOS test reports produced by the workflows;
4. proof that the final Android APK/AAB and iOS IPA were actually signed by
   release credentials controlled by the project—not merely named as signed;
   and
5. a legal/store review for any LGPL/MPL/UnRAR/codec obligations and for the
   Apple distribution method selected by the administrator.

No signing key, provisioning profile, account credential, token, or private
book belongs in this repository or in a public release asset.
