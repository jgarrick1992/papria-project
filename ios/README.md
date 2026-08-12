# iOS client

The iOS project follows the layered structure used by `eeclass-project`: `App`, `Core`, `DesignSystem`, `Features`, `GeneratedAPI`, `Resources`, and separate unit/UI test targets.

Open `Papria.xcodeproj` in Xcode 16.4 or newer. The target deployment is iOS 15. The target contains a system-framework reader and sync implementation:

- `Core/Persistence/SQLiteStore.swift` creates the `publications`, `remote_books`, `remote_files`, `reading_progress`, `audio_progress`, `download_tasks`, `sync_outbox`, and singleton `server_profile` tables. An explicit `schema_migrations` ledger records the additive profile migration. Files are imported into SHA-256 content-addressed storage with streaming hashing and atomic moves.
- `server_profile` stores only the endpoint, username, optional user-confirmed certificate SHA-256 fingerprint, and optional user-confirmed local HTTP target (canonical host plus port). Host-only confirmation records from earlier builds are never mapped to this field and therefore expire until the user re-confirms the endpoint. SQLite is the sole source for the non-secret profile; no legacy UserDefaults profile keys are read or migrated. Passwords, bearer tokens, and refresh cookies are never persisted in SQLite and remain Keychain-owned by `BookOrbitAPIClient`.
- `Core/API/APIClient.swift` is an actor-backed URLSession client for the exact BookOrbit v2.5.0 paths. Login stores the access token in Keychain and keeps the refresh cookie in the URLSession cookie store. File downloads use Range and stream into `.part` files; a 200 response to a resumed request restarts from zero.
- `Core/API/ProgressSync.swift` implements pull-before-push, outbox retry, and post-upload verification. Local/Wi-Fi publications never enter the outbox.
- `App/AppEnvironment.swift` retries the outbox when a satisfied network path
  returns and schedules the permitted `BGProcessingTask`; expiration cancels
  the in-flight retry so iOS does not report a false successful background
  sync.
- `Core/Transfer/LocalTransferReceiver.swift` starts a foreground-only `NWListener` on Wi-Fi. It serves the browser upload page and exact v1 create/status/chunk/complete/cancel routes, checks the 128-bit bearer token, writes chunks directly to disk, validates ranges, and imports the completed file into content-addressed storage.
- `Core/Audio/AudioPlaybackService.swift` provides an AVPlayer/AVAudioSession
  boundary for local or HTTP audiobook tracks, five-second position callbacks,
  whole-book multi-track percentage calculation, persisted playback speed and
  exact sleep deadlines, background audio, and lock-screen/earbud remote
  commands including seek and playback-rate changes. Progress callbacks are
  bound to the exact file IDs of the active book so an asynchronously opened
  second book cannot receive the previous book's playback position.

`Core/Audio/AudioFallback.swift` keeps audio transport and decoder selection
separate. The app registers the locked MobileVLCKit 3.7.2 decoder only for
local file URLs with no headers. AVFoundation remains the sole player for
authenticated BookOrbit Range streams and redirects, so no bearer token can
be passed to LibVLC through a URL or undocumented media option. The dynamic
framework is checksum-fetched by an explicit script and embedded with Code
Sign On Copy; a decoder failure still fails closed with a user-visible error.

The SwiftUI library lists local publications and BookOrbit books, exposes file download and position controls, and wires the Wi-Fi, audio, and settings screens to the same environment. `Papria.xcodeproj` declares Readium Swift Toolkit 3.8.0, locked in `Package.resolved`, and routes EPUB/KEPUB to Readium EPUB Navigator and PDF to Readium PDF Navigator. The dependency graph is locked; the App-only build and 77 XCTest/UI tests pass on an arm64 iPhone 17 Pro simulator running iOS 26.3.1. System text readers, Apple `libarchive` for CBR/CB7 streaming, and AVFoundation for a multi-track audio queue remain native. FB2 conversion preserves bounded embedded images, and ZIP/libarchive archive enumeration validates every member before image filtering. DRM-protected content remains rejected.

From `ios/`, the reference-project-style scripts are available at `scripts/debug.sh`, `scripts/unit_test.sh`, `scripts/rebuild.sh`, `scripts/qa_build.sh`, and `scripts/qa_test.sh`. Set `IOS_DESTINATION` when a different simulator destination is required; device signing and TestFlight steps remain release-environment work.

The shared Rust core is packaged with `../scripts/build-format-core.sh ios`.
That command requires the Apple Rust targets and `uniffi-bindgen` 0.28.3; it
produces an ignored `PapriaFormatCore.xcframework` under
`shared/format-core/artifacts/`. Every app build invokes that packaging step
and directly links/imports the UniFFI interface. `Core/Reader/FormatCoreRuntime.swift`
probes the required contract symbol and `Core/Reader/FormatCoreNativeBridge.swift`
calls the exact Rust conversion entry point for MOBI/AZW/AZW3/FB2; there is no
Swift PalmDOC/FB2 fallback path.

Before a direct Xcode invocation, run `bash ios/scripts/fetch_mobilevlckit.sh`
to download and checksum-verify the pinned framework. The helper
`bash ios/scripts/native_core_build.sh` performs that explicit fetch, packages
the XCFramework, and runs `build-for-testing`. No native artifact or generated
binding is committed; the helper fails with an actionable prerequisite message
when the Rust Apple targets or the required iOS runtime are absent.
