#!/usr/bin/env bash
set -euo pipefail

required=(
  .gitignore
  README.md
  LICENSE
  CONTRIBUTING.md
  SECURITY.md
  SUPPORT.md
  CODE_OF_CONDUCT.md
  THIRD_PARTY_NOTICES.md
  android/settings.gradle.kts
  android/app/build.gradle.kts
  android/app/src/main/AndroidManifest.xml
  android/gradlew
  android/scripts/test_with_emulator.sh
  ios/Papria.xcodeproj/project.pbxproj
  ios/Papria.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  ios/Papria/Resources/Info.plist
  ios/scripts/native_core_build.sh
  ios/scripts/fetch_mobilevlckit.sh
  ios/ThirdParty/MobileVLCKit.lock.json
  shared/contracts/bookorbit-v2.5.0.json
  shared/format-core/Cargo.toml
  third_party/licenses/JUNRAR-7.5.5-UNRAR.txt
  scripts/build-format-core.sh
  RELEASING.md
  .github/workflows/ci.yml
  .github/workflows/release-candidate.yml
  .github/workflows/release.yml
  .github/workflows/supply-chain.yml
  .github/CODEOWNERS
  .github/ISSUE_TEMPLATE/config.yml
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/dependabot.yml
  docs/README.md
  docs/bookorbit-mobile-reader-spec.md
  docs/bookorbit-mobile-reader-spec.full.md
  docs/acceptance.md
  docs/testing.md
  docs/supply-chain.md
  docs/license-inventory.md
  docs/spec-audit.md
  CHANGELOG.md
  VERSION.md
  third_party/licenses/LIBMOBI-0.12-LGPL-3.0-or-later.txt
  third_party/licenses/LIBMOBI-0.12-NOTICE.md
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "missing required project file: $path" >&2; exit 1; }
done

[[ -d android ]] && [[ -d ios ]] || { echo "android/ and ios/ are required" >&2; exit 1; }
for script in \
  scripts/build-format-core.sh \
  scripts/generate-format-bindings.sh \
  scripts/verify-contracts.sh \
  scripts/verify-fixtures.sh \
  scripts/verify-structure.sh \
  scripts/verify-repository.sh \
  android/scripts/test_with_emulator.sh \
  ios/scripts/native_core_build.sh; do
  [[ -x "$script" ]] || { echo "$script must be executable" >&2; exit 1; }
done
bash -n ios/scripts/native_core_build.sh
for script in scripts/*.sh android/scripts/*.sh ios/scripts/*.sh; do
  bash -n "$script"
done
node --check scripts/generate-format-fixtures.mjs
grep -q '<key>CFBundleExecutable</key>' ios/Papria/Resources/Info.plist || {
  echo "iOS Info.plist must declare CFBundleExecutable" >&2
  exit 1
}
echo "project structure: ok (${#required[@]} required files)"
