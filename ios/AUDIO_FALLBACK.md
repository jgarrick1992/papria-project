# iOS audio fallback audit

The iOS target links and embeds MobileVLCKit `3.7.2` as a local-file-only
fallback for AVFoundation decoder failures. It is deliberately not eligible
for BookOrbit URLs or any request carrying headers: AVFoundation remains the
only authenticated Range/redirect transport.

| Item | Value |
| --- | --- |
| Official archive | `https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.2-3e42ae47-79128878.tar.xz` |
| SHA-256 | `77b867667e5e62aa4062e71b7a4f76a0e2f505425916091c0eb0f94d9ad4af80` |
| Archive format | prebuilt `MobileVLCKit.xcframework` for device and simulator, nested under `MobileVLCKit-binary/` |
| License stated by upstream | LGPL-2.1-or-later |

Run `bash ios/scripts/fetch_mobilevlckit.sh` before a direct Xcode build. The
script enforces HTTPS-only redirects, verifies the archive SHA-256, extracts
to a staging directory, and atomically replaces the expected framework. The
Xcode target verifies the already-fetched framework, links it, and embeds it
with Code Sign On Copy; it never downloads dependencies during compilation.

Before release, validate actual framework headers and Swift delegate calls,
device initial load/seek, and the embedded IPA contents. Complete LGPL source,
notice/relinkability, codec, patent, and App Store distribution review. Do not
add an authenticated streaming fallback or a compatibility transport path.
