# Changelog

All notable Papria changes will be recorded here. The project is pre-release;
the first entry describes the current repository baseline rather than a store
release.

## 0.1.0 - 2026-08-12

- Implement the Android and iOS 0.1 UI information architecture: `书库`,
  `BookOrbit`, `传书`, and `设置`.
- Add BookOrbit catalog/detail/task flows, offline cache handling, server
  editing, re-login, and explicit cache-retention confirmation on disconnect.
- Add reader, audio, Wi-Fi transfer, sync-conflict, accessibility, and
  Android e-ink presentation updates while preserving existing contracts.
- Add Android, iOS, Rust boundary tests and repository/test-matrix release
  checks.

Real-device, browser, BookOrbit-server, accessibility, and signed-artifact
acceptance remain required before a store distribution.
