# Android audio fallback audit

`org.videolan.android:libvlc-all:3.6.5` is a real Android runtime dependency,
not a reflective optional class. `PapriaAudioService` moves only Media3
decoder/container failures to `LibVlcAudioFallback`. The Release verifier
checks both the official AAR SHA-256 and the final APK's `libvlc.so` plus
`libvlcjni.so` for `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`.

## Locked artifact

| Item | Value |
| --- | --- |
| Maven coordinate | `org.videolan.android:libvlc-all:3.6.5` |
| Official artifact URL | `https://repo1.maven.org/maven2/org/videolan/android/libvlc-all/3.6.5/libvlc-all-3.6.5.aar` |
| SHA-256 | `6a15a1f7acd0738a31acce0c7e5eb6f5f340b62e6b64d8f83df547da56a44b47` |
| Engine license | VideoLAN's Android source identifies the LibVLC engine as LGPL-2.1-or-later; the application source is GPL and is not bundled. |

## Credential and redirect boundary

LibVLC has no public, redirect-scoped `Authorization` API that can be tested
to retain a BookOrbit bearer on same-origin Range retries while dropping it on
a cross-origin redirect. Papria therefore never constructs LibVLC media for a
track with any request headers, including `Authorization`, and rejects URLs
with credential-like query parameter names. A BookOrbit authenticated Range
stream remains on Media3; LibVLC currently handles local files and headerless
remote streams only. This is an intentional safe boundary, not evidence that
authenticated LibVLC Range/redirect playback is implemented.

Run from `android/` on a machine with the Android NDK, `cargo-ndk`, and the
UniFFI generator. The mandatory default build prepares the shared format core
before Gradle packages the Release APK:

```bash
./gradlew --no-daemon :app:verifyLibVlcReleasePackage
```

Release distribution is still blocked pending legal review and delivery of the
exact LGPL notice, corresponding source, codec notices, and relinkability
materials for the final Android artifact. This command is a required package
check, not evidence that the current Android Readium/PDFium integration or any
authenticated LibVLC Range/redirect path has been built or device-tested.
