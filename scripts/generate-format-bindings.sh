#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDL="$ROOT_DIR/shared/format-core/src/papria_format_core.udl"
OUT_DIR="$ROOT_DIR/shared/format-core/bindings/generated"

if ! command -v uniffi-bindgen >/dev/null 2>&1; then
  cat >&2 <<'EOF'
uniffi-bindgen is required to generate the Papria format-core bindings.
Install the pinned UniFFI 0.28.3 CLI, then rerun this script.
EOF
  exit 127
fi

mkdir -p "$OUT_DIR"
# UniFFI refuses to overwrite an existing generated module. These files are
# ignored build artifacts, so remove only the outputs owned by this script
# before regenerating them. The UDL and Rust sources are never touched.
rm -rf "$OUT_DIR/uniffi" \
  "$OUT_DIR/papria_format_core.swift" \
  "$OUT_DIR/papria_format_coreFFI.h" \
  "$OUT_DIR/papria_format_coreFFI.modulemap"
uniffi-bindgen generate --language kotlin --out-dir "$OUT_DIR" "$UDL"
uniffi-bindgen generate --language swift --out-dir "$OUT_DIR" "$UDL"

echo "Generated Kotlin and Swift bindings under $OUT_DIR"
