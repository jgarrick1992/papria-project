# Android client

The Android app targets API 23 and compiles against API 36. It uses Kotlin,
Jetpack Compose, Room, WorkManager, and a foreground local transfer boundary.
The intended production reader route uses Readium Kotlin for EPUB/KEPUB and
shared-core conversions, and Readium's PDFium adapter for PDF. CBZ/CB7 image
pages, a bounded RAR4 adapter (including compressed RAR4 members), DRM-free
FB2/PalmDOC conversion, and a foreground `MediaSession` audio queue remain
separate platform boundaries. Readium/PDFium dependencies now resolve and
`:app:compileDebugKotlin`, lint, Debug/Release APK packaging, native-core and
LibVLC package gates pass locally; device gates remain separate evidence.
Storage and sync contracts do not
depend on a particular reader engine. RAR4 compression is decoded in-memory by
Junrar only after the local scanner has checked the RAR4 signature, complete
headers, canonical UTF-8 names, duplicate/traversal paths, declared
packed/unpacked sizes, compression ratio, and aggregate limits. A second
bounded output stream verifies that decoding produces exactly the validated
uncompressed length. Encrypted, split, large-address and RAR Unicode-encoded
members still fail closed before image filtering; those formats require a
native libarchive integration with the same limits before they can be
advertised as supported. No archive is extracted to a directory.

```bash
JAVA_HOME="${JAVA_HOME:?Set JAVA_HOME to JDK 21 or newer}" \
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME:?Set Android NDK path}" \
  android/gradlew --no-daemon -p android testDebugUnitTest lintDebug assembleDebug
```

Android Studio can import this directory directly. The checked-in module keeps BookOrbit wire fields exact and exposes `DisplayMode.EINK` as a manual profile. Vendor-specific e-ink refresh APIs belong in separate adapters and must not be selected by compatibility aliases.

## Implemented client boundaries

- `core/local/PapriaDatabase` is the Room-backed offline model for publications,
  remote books/files, resumable downloads, reading/audio progress, sync outbox,
  one server profile, and temporary Wi-Fi uploads. The v4→v5→v6→v7 migrations
  are additive and preserve existing local records; v7 stores local audio speed
  and sleep-timer state without adding fields to BookOrbit requests.
- `core/storage/ContentAddressedStore` writes SHA-256 addressed files and keeps
  `.part` files separate until length/hash verification succeeds.
- `core/bookorbit/BookOrbitRepository` enforces the `v2.5.0` app-info gate,
  caches the exact `/books/query` page, stores progress locally first, and
  uploads it through `WorkManager` after a pull-before-push check.
- `core/sync/DownloadWorker` uses `Range` and restarts safely when a server
  ignores a range request. `BookOrbitSyncWorker` retries the outbox on network
  recovery. Access tokens and refresh cookies are encrypted with Android
  Keystore before being written to SQLite.
- `core/transfer/WifiTransferServer` is a foreground-only LAN HTTP receiver.
  It implements the tokenized HTML page, metadata creation, sequential 8 MiB
  `Content-Range` chunks, completion hash/import, cancellation, storage checks,
  filename/path checks, and 24-hour stale-upload cleanup. Imported files are
  marked `source=wifi` and never enter the BookOrbit outbox. FB2 conversion
  keeps bounded embedded images in the private EPUB cache; the comic adapter
  validates every archive member before selecting image pages, including
  duplicate names, traversal, aggregate size, and compression ratio limits.
  Every Android build variant generates the shared binding and native ABI
  libraries before `preBuild`, then sends the same metadata to the Rust
  `inspect_archive_entries` boundary after the local format-specific checks.
  JVM unit tests deliberately keep a non-ELF path because an Android ELF cannot
  load in a desktop test process; that is not a production fallback. Commons
  Compress does not expose packed 7z sizes, so that adapter sets
  `compressed_size_known=false` and still enforces entry/aggregate limits.
- The Compose shell includes local file import/open, BookOrbit login and page
  cache, download queue, progress sync, Wi-Fi address display, and manual
  `NORMAL`/`EINK` mode selection. The 6-inch/600×800 layout remains a compact
  single-column profile; vendor refresh SDKs are intentionally out of scope.

The `scripts/` helpers mirror the eeclass Android workflow and can be run from
any working directory:

```bash
android/scripts/debug.sh
android/scripts/unit_test.sh
android/scripts/rebuild.sh
android/scripts/qa_unit_and_release.sh
bash android/scripts/test_with_emulator.sh
```

The QA helper runs Android lint, unit tests, a debug APK build, and a release
bundle. Jacoco coverage is intentionally not listed until a project-wide
coverage policy and plugin task are added.

`test_with_emulator.sh` reuses the AVD named by `PAPRIA_AVD_NAME` (default
`Papria_API33`) when present. If it is missing, it installs the pinned Google
Play API 33 system image and creates the AVD before waiting for boot and
running connected instrumentation tests. `PAPRIA_EMULATOR_PORT` selects the
ADB transport, and an installed JDK 17+ plus NDK are selected automatically
when the corresponding environment variables are absent. ADB startup errors
are written to `PAPRIA_ADB_LOG` (defaulting to the system temporary directory)
and stop immediately instead of waiting through the emulator timeout.

The Rust format core is a mandatory Android build input, not an opt-in Gradle
variant. Every `preBuild` runs `../scripts/build-format-core.sh android`, which
regenerates the UniFFI binding and produces all four ABI libraries. It requires
an Android NDK, `cargo-ndk`, and the four declared Rust Android targets. The
script normalises each cargo-ndk output to
`libuniffi_papria_format_core.so`, the exact name expected by the generated
UniFFI loader; generated ABI directories remain ignored under
`shared/format-core/artifacts/android/`.

Use the following command on a machine with those prerequisites:

```bash
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:?Set Android NDK path}" \
  ./gradlew --no-daemon :app:assembleRelease :app:verifyNativeCoreReleasePackage
```

The Debug and Release verification tasks check the generated Kotlin binding,
all four ABI libraries, and the corresponding APK entries. A missing Rust
toolchain, binding, or library fails the build instead of switching to a
platform parser. The retired opt-in Gradle switch must not be added back to
invocation or release documentation. CI is configured to run the
same default-core package checks; a successful APK is not proof of a device
runtime, so connected instrumentation remains a separate gate.
