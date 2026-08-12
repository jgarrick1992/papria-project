# ADR 0001: Native project structure

## Decision

Use the layered native layout proven by `eeclass-project` as the Papria baseline:

```text
android/                Gradle project, app module, scripts
ios/Papria/              App, Core, DesignSystem, Features, GeneratedAPI, Resources
shared/                 Contracts and native format core
docs/                   Architecture, compatibility, testing, and release notes
.github/                CI, ownership, templates, and dependency automation
scripts/                Repository-level deterministic checks
```

The iOS target has separate `PapriaTests` and `PapriaUITests` targets. Android keeps unit tests under the app module and reserves instrumentation tests for device-level reader and e-ink checks.

## Rationale

The reference project separates app lifecycle, core services, feature screens, generated contracts, and resources. Papria keeps that separation while using BookOrbit-specific boundaries and native reader engines. Shared contracts are not generated directly from BookOrbit TypeScript, so the mobile client remains independently buildable.

## Consequences

- Platform-specific behavior stays in its platform target.
- API and format changes are visible in `shared/` and testable before UI changes.
- Xcode and Gradle build artifacts stay ignored and are not copied from the reference project.
- New features must declare their storage, offline, and platform lifecycle behavior.
