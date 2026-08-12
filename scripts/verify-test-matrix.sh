#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=()

fail() {
  failures+=("$*")
}

collect_sources() {
  local directory

  directory="$1"
  [[ -d "$directory" ]] || return 0
  while IFS= read -r -d '' source; do
    sources+=("$source")
  done < <(find "$directory" -type f \( -name '*.kt' -o -name '*.java' \) -print0)
}

has_android_test() {
  awk '
    /^[[:space:]]*@(org\.junit\.)?Test([[:space:]]*\(|[[:space:]]*$)/ { remaining = 12; next }
    remaining > 0 && /^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|internal[[:space:]]+|protected[[:space:]]+)*(suspend[[:space:]]+)?fun[[:space:]]+[[:alnum:]_]+[[:space:]]*\(/ { found = 1; exit }
    remaining > 0 && /^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)*(static[[:space:]]+)?void[[:space:]]+[[:alnum:]_]+[[:space:]]*\(/ { found = 1; exit }
    remaining > 0 { remaining -= 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

has_xctest() {
  awk '
    /^[[:space:]]*import[[:space:]]+XCTest([[:space:]]|$)/ { imports_xctest = 1 }
    /^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[[:alnum:]_]+[[:space:]]*:[[:space:]]*XCTestCase([[:space:]]|\{|$)/ { has_test_case = 1 }
    /^[[:space:]]*(override[[:space:]]+)?func[[:space:]]+test[[:alnum:]_]*[[:space:]]*\(/ { has_test_method = 1 }
    END { exit(imports_xctest && has_test_case && has_test_method ? 0 : 1) }
  ' "$1"
}

has_rust_test() {
  awk '
    /^[[:space:]]*#\[(test|tokio::test|async_std::test)(\([^]]*\))?\][[:space:]]*$/ { remaining = 8; next }
    remaining > 0 && /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+[[:alnum:]_]+[[:space:]]*\(/ { found = 1; exit }
    remaining > 0 { remaining -= 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

check_android_source_set() {
  local label="$1"
  shift
  local -a sources=()
  local directory

  for directory in "$@"; do
    collect_sources "$directory"
  done

  if (( ${#sources[@]} == 0 )); then
    fail "Android $label source set has no Kotlin or Java files"
    return
  fi

  if [[ "$label" == "JVM test" || "$label" == "instrumentation test" ]]; then
    local source
    for source in "${sources[@]}"; do
      has_android_test "$source" || fail "Android $label file has no @Test-backed test function: $source"
    done
  fi
}

check_ios_sources_phase() {
  local project="ios/Papria.xcodeproj/project.pbxproj"
  local target_line
  local phase_id
  local source_phase_id=""
  local source_phase_line
  local source_build_ids=""
  local file
  local base_name
  local build_id
  local build_line
  local file_ref_id
  local file_ref_line
  local included
  local seen_name
  local -a swift_files=()
  local -a swift_names=()

  [[ -f "$project" ]] || {
    fail "missing Xcode project: $project"
    return
  }

  while IFS= read -r -d '' file; do
    swift_files+=("$file")
  done < <(find ios/PapriaTests -type f -name '*.swift' -print0 2>/dev/null)

  if (( ${#swift_files[@]} == 0 )); then
    fail "Swift XCTest source set has no .swift files"
    return
  fi

  for file in "${swift_files[@]}"; do
    has_xctest "$file" || fail "Swift XCTest file has no XCTestCase test method: $file"
    base_name="${file##*/}"
    if (( ${#swift_names[@]} > 0 )); then
      for seen_name in "${swift_names[@]}"; do
        [[ "$seen_name" != "$base_name" ]] || fail "duplicate Swift XCTest filename prevents unambiguous Xcode membership check: $base_name"
      done
    fi
    swift_names+=("$base_name")
  done

  # Xcode serialises target attributes over several lines: `isa` and `name`
  # are not required to appear together.  Extract the complete target block
  # before checking its identity and build phases.
  target_line="$(awk '
    /isa = PBXNativeTarget;/ { in_target = 1; block = $0 ORS; next }
    in_target { block = block $0 ORS }
    in_target && /^[[:space:]]*};/ {
      if (block ~ /name = PapriaTests;/) print block
      in_target = 0
    }
  ' "$project")"
  if [[ -z "$target_line" ]]; then
    fail "Xcode project has no PapriaTests target"
    return
  fi

  while IFS= read -r phase_id; do
    source_phase_line="$(awk -v id="$phase_id" '
      $1 == id { in_phase = 1; block = $0 ORS; next }
      in_phase { block = block $0 ORS }
      in_phase && /^[[:space:]]*};/ {
        if (block ~ /isa = PBXSourcesBuildPhase;/) print block
        in_phase = 0
      }
    ' "$project")"
    if [[ -n "$source_phase_line" ]]; then
      source_phase_id="$phase_id"
      break
    fi
  done < <(printf '%s\n' "$target_line" | grep -oE '[[:alnum:]]{24,}' || true)

  if [[ -z "$source_phase_id" ]]; then
    fail "PapriaTests target has no Sources build phase"
    return
  fi

  source_build_ids="$(printf '%s\n' "$source_phase_line" | sed -E 's/.*files = \(([^)]*)\).*/\1/' | grep -oE '[[:alnum:]]{24,}' || true)"
  for file in "${swift_files[@]}"; do
    base_name="${file##*/}"
    included=0
    while IFS= read -r build_id; do
      [[ -n "$build_id" ]] || continue
      build_line="$(awk -v id="$build_id" '$0 ~ "^[[:space:]]*" id " " && /isa = PBXBuildFile;/' "$project")"
      [[ -n "$build_line" ]] || continue
      file_ref_id="$(printf '%s\n' "$build_line" | sed -nE 's/.*fileRef = ([[:alnum:]]{24,}) .*/\1/p')"
      [[ -n "$file_ref_id" ]] || continue
      file_ref_line="$(awk -v id="$file_ref_id" '$0 ~ "^[[:space:]]*" id " " && /isa = PBXFileReference;/' "$project")"
      if [[ "$file_ref_line" == *"path = $base_name;"* ]]; then
        included=1
        break
      fi
    done <<< "$source_build_ids"
    (( included )) || fail "Swift XCTest file is absent from PapriaTests Sources build phase: $file"
  done
}

check_rust_tests() {
  local -a rust_files=()
  local file

  for directory in shared/format-core/src shared/format-core/tests; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' file; do
      rust_files+=("$file")
    done < <(find "$directory" -type f -name '*.rs' -print0)
  done

  if (( ${#rust_files[@]} == 0 )); then
    fail "Rust test source set has no .rs files"
    return
  fi

  local test_files=0
  for file in "${rust_files[@]}"; do
    if has_rust_test "$file"; then
      ((test_files += 1))
    fi
  done
  (( test_files > 0 )) || fail "Rust test source set has no #[test]-backed test function"
}

check_android_source_set "main" android/app/src/main/java android/app/src/main/kotlin
check_android_source_set "JVM test" android/app/src/test/java android/app/src/test/kotlin
check_android_source_set "instrumentation test" android/app/src/androidTest/java android/app/src/androidTest/kotlin
check_ios_sources_phase
check_rust_tests

if (( ${#failures[@]} > 0 )); then
  printf 'test matrix verification failed:\n' >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "test matrix: ok (Android JVM/instrumentation, Swift XCTest sources, and Rust tests)"
