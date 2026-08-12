#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "public source gate failed: $*" >&2
  exit 1
}

matches=""

collect_content_matches() {
  local pattern="$1"
  local description="$2"
  matches="$(git grep -nI -E "$pattern" -- . ':!scripts/verify-public-source.sh' ':!shared/format-core/vendor/**' || true)"
  [[ -z "$matches" ]] || fail "$description:\n$matches"
}

# File-name checks are deliberately separate from text checks: CI and
# .gitignore legitimately mention generated output names, but must not track
# those files themselves.
tracked_sensitive_paths="$(git ls-files | grep -E '(^|/)[.]env([.][^/]*)?$|[.](pem|key|p12|p8|jks|keystore|mobileprovision|cer|crt|der|csr|sig|asc|gpg|apk|aab|ipa|xcarchive|xcresult)$' || true)"
[[ -z "$tracked_sensitive_paths" ]] || fail "tracked secret, signing, or release artifact filename:\n$tracked_sensitive_paths"

collect_content_matches '(^|[^[:alnum:]_])(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)' \
  'high-confidence credential pattern'

collect_content_matches '(^|[^[:alnum:]])(/Users/|/home/|C:[\\/](Users|home)[\\/])' \
  'local absolute path'

collect_content_matches 'OWNER/REPOSITORY|@papria-[[:alnum:]_-]+' \
  'GitHub placeholder'

tracked_artifacts="$(git ls-files | grep -E '(^|/)(build|DerivedData|target|reports|jniLibs|Generated)(/|$)|[.](apk|aab|ipa|xcarchive|xcresult|framework|xcframework|aar|so)$' || true)"
[[ -z "$tracked_artifacts" ]] || fail "tracked build artifact or generated output:\n$tracked_artifacts"

echo 'public source gate: ok (no sensitive paths, placeholders, credentials, or generated release outputs)'
