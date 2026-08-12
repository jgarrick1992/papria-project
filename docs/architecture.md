# Architecture

```text
Android Kotlin/Compose         iOS SwiftUI
        |                            |
        +------ exact contracts ----+
                       |
             native storage + sync
                       |
              Rust/C format core
                       |
                 local file store
                       |
             BookOrbit REST (v2.5.0)
```

The platform applications own lifecycle, secure storage, background work, UI, audio sessions, and platform reader views. The shared core owns format sniffing, streaming content hashing, deterministic MOBI/AZW/FB2 conversion boundaries, and bounded archive access. Its archive API validates member paths, entry counts, sizes, and compression ratios before a platform library can extract anything. BookOrbit code and BookOrbit Web UI are not linked into the client.

## Source boundaries

- `android/`: Android app, Room entities/DAO with additive v4→v5→v6→v7 migrations, WorkManager, Keystore, bounded 7z/RAR4/CBZ readers, Readium Kotlin EPUB/KEPUB and PDFium source integration, AndroidX Media3/MediaSession audio, and the e-ink display profile. Readium/PDFium resolution, lint, Debug/Release APK packaging, R8, native-core and LibVLC gates pass; connected device evidence remains separate.
- `ios/`: iOS app, SQLite3 actor store, URLSession/Keychain, Apple libarchive comic adapter, Readium Swift EPUB/PDF source integration, AVFoundation audio queue with a local-file-only MobileVLCKit fallback source adapter, SwiftUI reader surface, and Local Network permission handling. Swift Package resolution, the App-only build, and 77 arm64 simulator XCTest/UI tests pass; physical-device evidence remains separate.
- `shared/contracts/`: exact JSON and HTTP contracts. The same wire names are used on both platforms without aliases.
- `shared/format-core/`: Rust crate, UDL, generated UniFFI scaffolding and Kotlin/Swift binding boundary for cross-platform parsing, hashing, archive validation, and conversion policy. `scripts/build-format-core.sh` packages iOS/Android native artifacts when the platform cross-compilers are installed; Android invokes it from every `preBuild`, and the iOS project invokes it from its build phase before directly linking `PapriaFormatCore.xcframework`. Generated artifacts are ignored, and a missing prerequisite or artifact is a build failure rather than a platform-parser fallback. Both default platform app paths have local build evidence.
- `docs/`: decisions and test requirements, not generated API types.

## Progress model

Local progress is saved before any network request. Remote progress is pulled when opening a publication and uploaded through an outbox. `percentage` follows BookOrbit's 0–100 scale; EPUB uses `cfi`, paged media uses `pageNumber`, and audio uses `currentFileId` plus `positionSeconds`. MOBI/AZW/FB2 retain an exact local locator while BookOrbit synchronization falls back to `percentage` when the converted DOM cannot be proven compatible.
