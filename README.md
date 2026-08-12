# Papria Mobile Reader

Papria is a native Android and iOS reading client for self-hosted [BookOrbit](https://github.com/bookorbit/bookorbit) servers. It combines an offline-first local library, a focused reader, BookOrbit file/progress synchronization, and a temporary Wi-Fi upload page.

The Android client includes a manually selected black-and-white e-ink profile for compact 5-inch phones and 6-inch reader-sized displays. Normal color mode uses the same data and sync layer. A Kindle e-reader is a layout reference only; the app targets Android and iOS devices.

## Project status

This is an untagged, unsigned `0.1.0` source snapshot. It is not an app-store
release and no release artifact, signing material, or support commitment is
provided with this repository.

This repository follows [`docs/bookorbit-mobile-reader-spec.md`](docs/bookorbit-mobile-reader-spec.md). The native projects are intentionally separated from BookOrbit's Vue/TypeScript application and share only explicit wire contracts and the format-core boundary.

The current checkout contains a native implementation with Android JDK 21
build gates and a locked iOS Readium dependency graph: BookOrbit
login/list/detail, Range downloads, local progress outbox, Android/iOS Wi-Fi
import, SQLite/secure credential storage, Readium EPUB/KEPUB and PDF reader
paths, PDF/CBZ/CB7/CBR readers (including bounded compressed RAR4 decoding on
Android), DRM-free FB2/MOBI/AZW/AZW3 conversion through the mandatory shared
format core, and foreground audio queues. Android Debug/Release APK gates and
the iOS App-only build pass locally with the locked Readium/PDFium and
MobileVLCKit inputs; device, server, browser, XCTest-runner, and signed-IPA
acceptance are still required before a store release.

The shared Rust core has a reproducible native packaging path in
[`scripts/build-format-core.sh`](scripts/build-format-core.sh). Android variants
invoke it before every build and iOS invokes it through the app target build
phase, so the generated UniFFI bindings and native libraries are required
delivery inputs rather than optional fallbacks. Generated binaries remain
ignored and are not committed.

## Repository layout

```text
android/                 Android app and platform integrations
ios/                     iOS app and platform integrations
shared/contracts/        Exact wire contracts and fixtures
shared/format-core/      Cross-platform format/archive core boundary
docs/                    Architecture, API, Wi-Fi, and development notes
scripts/                 Repository-level contract and fixture checks
third_party/licenses/    Checked-in third-party license texts
.github/                 CI, issue templates, and contribution metadata
```

The directory decisions are documented in [`docs/project-structure.md`](docs/project-structure.md), including which server and web directories are intentionally excluded from this repository.

The full documentation index is [`docs/README.md`](docs/README.md).

## Support and contributions

This repository is published as source code only. It does not accept feature
requests, external pull requests, or general support requests. Reproducible
bugs may be filed with the Bug report form; see [`SUPPORT.md`](SUPPORT.md).
Report security vulnerabilities only through
[`SECURITY.md`](SECURITY.md), never in a public issue.

## Design constraints

- BookOrbit Web UI and TypeScript source are not copied into this client.
- The initial remote contract is BookOrbit `v2.5.0`.
- Wire field names are exact. No compatibility aliases or alternate key mappings are implemented.
- Wi-Fi imports are local-only and never upload files to BookOrbit automatically.
- DRM-protected books are not decrypted or bypassed.
- Credentials are stored in Android Keystore or iOS Keychain.

## Development

See [`docs/development.md`](docs/development.md) for toolchain setup and verification commands.

## License

Application code is Apache-2.0. Third-party components retain their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). BookOrbit is an independent AGPL-3.0 server dependency and is not bundled into this repository.
