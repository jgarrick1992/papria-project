# Contributing

Papria is a native Android/iOS client for self-hosted BookOrbit servers. Keep the client independent from BookOrbit's Vue/TypeScript implementation and preserve the exact wire field names defined in `shared/contracts`.

## Public-source policy

This is a source-only public repository. The maintainer does not accept
feature requests, external pull requests, or general support requests, and
does not promise review, response, maintenance, or merges. GitHub issues are
reserved for reproducible bugs. Security vulnerabilities must be reported only
through the Private Vulnerability Reporting link in `SECURITY.md`.

You may fork this repository under the terms of its license. Any unsolicited
pull request may be closed without review.

## Bug reports

Use the Bug report issue form only when the problem is reproducible and does
not disclose credentials, private books, personal data, or private server
URLs. Include the affected commit, platform/device, and minimal reproduction
steps. The maintainer may close reports that are not reproducible or fall
outside the repository's scope.

## API changes

Do not add compatibility aliases or silently accept alternate JSON keys. Update the contract documentation and fixtures first, then update both platform clients.

Never include credentials, cookies, local library paths, or real book content in commits.

## Dependency, license, and workflow changes

Changes to a direct runtime dependency, native library, GitHub Action, Gradle
wrapper, or release tool are supply-chain changes. Keep their version keys
exact; do not add aliases, fallback keys, or compatibility mappings.

For any local derivative or maintainer change:

1. update `THIRD_PARTY_NOTICES.md` when the shipped dependency set, version,
   source URL, or license obligations change;
2. retain the relevant lockfile change and run the affected platform checks;
3. use a 40-character commit SHA for every third-party GitHub Action, with a
   human-readable version comment beside it;
4. update `RELEASING.md` or `docs/supply-chain.md` if the build/release
   credential, artifact, checksum, SBOM, or provenance procedure changes; and
5. never commit signing keys, provisioning profiles, store credentials,
   generated release packages, dependency caches, SBOMs containing private
   paths, or test reports with private books.

Do not change `LICENSE` or state that a package is distribution-ready merely
because a dependency resolver accepted it. The release owner must reconcile
the final APK/AAB/IPA, CycloneDX SBOM, third-party notices, and any LGPL/MPL
or other source/notice obligations before publication.
