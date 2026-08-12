# Releasing Papria

This repository can create two kinds of evidence. They must not be confused:

- **Release candidate evidence** is an unsigned Android APK, checksums, SBOM,
  provenance attestation, lint/unit-test reports, and iOS simulator test
  evidence. It is for review and is not installable/distributable proof.
- **Signed release output** is produced only by
  `.github/workflows/release.yml` in the protected GitHub `production`
  environment after it imports real administrator-managed credentials. It
  creates an APK, AAB, IPA, SHA-256 manifest, and GitHub provenance
  attestation. It never generates a fake signature or marks an unsigned file
  as signed.

## One-time administrator setup

The source tree cannot perform these actions by itself. Before the first
public or store release, an administrator must provide all of the following:

1. A real GitHub repository remote, a verified `main` branch-protection rule,
   required CI checks, and real teams/users for `CODEOWNERS`.
2. GitHub Private Vulnerability Reporting and a monitored fallback security
   contact. Replace the placeholders in `SECURITY.md` and the issue-template
   contact link; test both routes.
3. A protected `production` GitHub Environment with release-manager approval
   and these **environment secrets**:

   | Secret | Required purpose |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | Base64 of the project-owned Android JKS/PKCS12 keystore. |
   | `ANDROID_KEY_ALIAS` | Alias for the release key. |
   | `ANDROID_KEYSTORE_PASSWORD` | Keystore password. |
   | `ANDROID_KEY_PASSWORD` | Private-key password. |
   | `APPLE_TEAM_ID` | Apple Developer Team ID that owns the release identity. |
   | `IOS_CERTIFICATE_BASE64` | Base64 of the distribution `.p12` certificate. |
   | `IOS_CERTIFICATE_PASSWORD` | Password for that `.p12`; may be empty only if the certificate was intentionally exported without one. |
   | `IOS_PROVISIONING_PROFILE_BASE64` | Base64 of the matching distribution provisioning profile. |
   | `IOS_PROVISIONING_PROFILE_NAME` | Exact profile name used by Xcode archive signing. |
   | `IOS_KEYCHAIN_PASSWORD` | Ephemeral keychain password used only on the macOS runner. |
   | `IOS_EXPORT_OPTIONS_PLIST_BASE64` | Base64 of an administrator-reviewed Xcode export-options plist with the correct distribution method and profile mapping. |

4. Permit the final `publish` job's `GITHUB_TOKEN` to create releases and
   attestations, or provide an administrator-approved replacement. Build and
   signing jobs retain read-only repository access. Do not put a personal
   access token into the workflow file.
5. Store credentials and review processes if uploading to Google Play or App
   Store Connect. This repository deliberately does **not** automate store
   upload because those credentials, release tracks, and compliance approvals
   are organization-specific.
6. The final notice/source/relinkability package described in
   `THIRD_PARTY_NOTICES.md` and `docs/supply-chain.md`.

The Android module intentionally has no signing configuration in source. The
signed workflow builds the normal Release artifact first and applies the
administrator's ephemeral keystore afterward with `apksigner`/`jarsigner`;
this keeps credentials out of Gradle files and verifies the resulting bytes.
On macOS, it imports the distribution certificate into a temporary keychain,
sets the `apple-tool`, `apple`, and `codesign` key partitions required for
non-interactive signing, then deletes that keychain and all decoded credential
files at job exit.

GitHub-hosted runners may update their image and Xcode/Android platform-tools
between runs. The workflows pin the runner major image, actions by SHA, JDK,
Rust, UniFFI source revision, cargo-ndk, NDK, Android platform/build-tools,
and Gradle distribution hash. cargo-ndk remains at `3.5.4` because its current
4.x line requires Rust 1.86; upgrading it requires a coordinated Rust/toolchain
review. The workflows also archive the observed toolchain
versions. A fully immutable macOS/Xcode image requires a controlled self-hosted
runner and is outside this repository's authority.

## Release procedure

1. Complete the product acceptance evidence in `docs/acceptance.md`, including
   real BookOrbit, browser/Wi-Fi, device, accessibility, and license evidence.
   Passing a CI job does not replace those tests.
2. Update `VERSION.md`, Android `versionName`/`versionCode`, iOS
   `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, shared-core version, and
   `CHANGELOG.md` in one reviewed pull request. The tag must exactly equal
   `v` plus the `VERSION.md` version.
3. Ensure `THIRD_PARTY_NOTICES.md` has been reconciled against the final
   dependency closure and the administrator has supplied all required license
   texts/source offers. Do not publish while any release review item remains.
4. Create and push the reviewed tag. If your organization requires signed Git
   tags, verify it using the organization's trusted public keys before
   dispatching a workflow. GitHub release provenance does not replace a Git
   tag signature.
5. Manually dispatch **Release candidate evidence** for the tag. Review the
   unsigned Android asset, `SHA256SUMS.txt`, CycloneDX SBOM, GitHub attestation,
   native-core `releaseRuntimeClasspath` report, Gradle/Rust/Xcode logs, test
   reports, and all acceptance material. An
   unsigned candidate is never uploaded to a store or presented as a release.
6. After production-environment approval, manually dispatch **Signed GitHub
   release** with `publish=false`. It must fail if any signing secret is
   absent. Review `apksigner`/`jarsigner`/`codesign` reports and verify:

   ```bash
   cd downloaded-release-directory
   shasum -a 256 -c SHA256SUMS.txt
   ```

7. Re-run the signed workflow with `publish=true` only after review. It creates
   the GitHub release and attaches exactly the generated APK, AAB, IPA,
   checksum manifest, and release manifest. Store upload remains a separate
   administrator-controlled step.
8. Publish an advisory for any security fixes, retain release evidence under
   the organization retention policy, and update `CHANGELOG.md`.

## What the workflow proves—and does not prove

The supplied workflows prove the commands and artifact bytes that ran inside
the GitHub job, then obtain a GitHub build-provenance attestation for those
bytes when the repository supports attestations. They do not prove a Store
review, physical-device acceptance, legal clearance, ownership of a signing
key, BookOrbit interoperability, or a signed Git tag. Keep those external
records with the release decision.
