#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "repository verification failed: $*" >&2
  exit 1
}

workflow_files=(
  .github/workflows/ci.yml
  .github/workflows/release-candidate.yml
  .github/workflows/release.yml
  .github/workflows/supply-chain.yml
)
for workflow in "${workflow_files[@]}"; do
  [[ -f "$workflow" ]] || fail "missing workflow: $workflow"
done

third_party_actions="$(grep -RHE '^[[:space:]]*(-[[:space:]]+)?uses:' .github/workflows \
  | grep -Ev 'uses:[[:space:]]+\./' || true)"
[[ -n "$third_party_actions" ]] || fail "no third-party GitHub Actions found"
if printf '%s\n' "$third_party_actions" \
  | grep -Ev '@[[:xdigit:]]{40}([[:space:]]|#|$)'; then
  fail "every third-party GitHub Action must use an exact 40-character commit SHA"
fi

if grep -REn 'runs-on:[[:space:]]*(ubuntu|macos)-latest' .github/workflows; then
  fail "GitHub-hosted runners must use explicit image labels"
fi

for script in scripts/*.sh; do
  bash -n "$script"
done
node --check scripts/generate-format-fixtures.mjs
bash scripts/verify-test-matrix.sh
bash scripts/verify-public-source.sh

ignored_artifacts=(
  android/app/build/example.apk
  android/app/src/main/jniLibs/arm64-v8a/libexample.so
  ios/DerivedData/Build/Products/Papria.app
  ios/ThirdParty/Build/MobileVLCKit.xcframework/Info.plist
  shared/format-core/target/debug/papria
  .env.local
  reports/example.log
)
for artifact in "${ignored_artifacts[@]}"; do
  git check-ignore --no-index -q -- "$artifact" \
    || fail "generated or secret path is not ignored: $artifact"
done

tracked_ignored="$(git ls-files -ci --exclude-standard)"
[[ -z "$tracked_ignored" ]] || fail "tracked files are ignored by .gitignore:\n$tracked_ignored"

echo "repository policy: ok (workflow pins, syntax, test matrix, ignored outputs, and tracked-file hygiene)"
