#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/shared/format-core/fixtures"
MANIFEST="$FIXTURE_DIR/manifest.json"
GENERATOR="$ROOT_DIR/scripts/generate-format-fixtures.mjs"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/papria-format-fixtures.XXXXXX")"
GENERATED="$TMP_ROOT/generated"
DRIVER_TARGET="${CARGO_TARGET_DIR:-$TMP_ROOT/cargo-target}"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

node "$GENERATOR" --output "$GENERATED"

node - "$ROOT_DIR" "$MANIFEST" "$GENERATED" <<'NODE'
const fs = require("fs");
const path = require("path");

const [root, manifestPath, generated] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const formats = [
  "epub", "kepub", "mobi", "azw", "azw3", "fb2", "pdf", "cbz", "cbr", "cb7",
  "m4b", "m4a", "mp3", "opus", "ogg", "flac",
];
const expectedManifestKeys = [
  "extension", "normal", "malformed", "special", "large", "normalMagicHex",
  "normalMagicOffset", "malformedDetection", "conversion",
];
const largeBytes = 64 * 1024 * 1024 + 1;

function fail(message) {
  throw new Error(message);
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label}: expected object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label}: expected keys ${JSON.stringify(wanted)}, received ${JSON.stringify(actual)}`);
  }
}

exactKeys(manifest, ["version", "license", "generator", "largeFixtureBytes", "cases"], manifestPath);
if (manifest.version !== "v2" || manifest.license !== "Apache-2.0") fail(`${manifestPath}: unsupported fixture manifest`);
if (manifest.generator !== "scripts/generate-format-fixtures.mjs") fail(`${manifestPath}: generator path is not canonical`);
if (manifest.largeFixtureBytes !== largeBytes) fail(`${manifestPath}: largeFixtureBytes must equal ${largeBytes}`);
exactKeys(manifest.cases, formats, `${manifestPath}.cases`);

function readBytes(filename) {
  return fs.readFileSync(filename);
}

function hasMagic(bytes, magicHex, offset) {
  const magic = Buffer.from(magicHex, "hex");
  return bytes.subarray(offset, offset + magic.length).equals(magic);
}

function relativeAsset(relative) {
  if (relative.startsWith("/") || relative.includes("..")) fail(`unsafe manifest path: ${relative}`);
  const filename = path.join(root, "shared", "format-core", "fixtures", relative);
  if (!fs.existsSync(filename) || !fs.statSync(filename).isFile()) fail(`missing tracked fixture: ${filename}`);
  return filename;
}

function generatedAsset(relative) {
  if (relative.startsWith("/") || relative.includes("..")) fail(`unsafe generated path: ${relative}`);
  const filename = path.join(generated, relative);
  if (!fs.existsSync(filename) || !fs.statSync(filename).isFile()) fail(`missing generated fixture: ${filename}`);
  return filename;
}

for (const format of formats) {
  const fixture = manifest.cases[format];
  exactKeys(fixture, expectedManifestKeys, `${format} fixture`);
  if (fixture.extension !== format || !Number.isSafeInteger(fixture.normalMagicOffset) || fixture.normalMagicOffset < 0) {
    fail(`${format}: invalid extension or magic offset`);
  }
  if (!/^[0-9a-f]+$/i.test(fixture.normalMagicHex) || fixture.normalMagicHex.length % 2 !== 0) fail(`${format}: invalid normal magic`);
  if (!Number.isSafeInteger(fixture.normalMagicOffset)) fail(`${format}: invalid normal magic offset`);
  if (!["accept", "reject"].includes(fixture.malformedDetection)) fail(`${format}: invalid malformedDetection`);
  if (typeof fixture.conversion !== "boolean") fail(`${format}: conversion must be boolean`);

  const normal = relativeAsset(fixture.normal);
  const malformed = relativeAsset(fixture.malformed);
  const special = relativeAsset(fixture.special);
  const normalGenerated = generatedAsset(fixture.normal);
  const malformedGenerated = generatedAsset(fixture.malformed);
  const specialGenerated = generatedAsset(fixture.special);
  const normalBytes = readBytes(normal);
  const malformedBytes = readBytes(malformed);
  if (!normalBytes.length || !malformedBytes.length) fail(`${format}: normal/malformed fixture must not be empty`);
  if (!hasMagic(normalBytes, fixture.normalMagicHex, fixture.normalMagicOffset)) fail(`${format}: normal fixture magic mismatch`);
  if (normalBytes.equals(malformedBytes)) fail(`${format}: normal and malformed bytes must differ`);
  if (!normalBytes.equals(readBytes(normalGenerated)) || !malformedBytes.equals(readBytes(malformedGenerated)) || !normalBytes.equals(readBytes(specialGenerated))) {
    fail(`${format}: tracked assets differ from deterministic generator output`);
  }
  if (path.basename(special) !== path.basename(specialGenerated) || !/[<>:"|?*]/.test(path.basename(special))) {
    fail(`${format}: special filename does not contain reserved-character coverage`);
  }
  const largeGenerated = generatedAsset(fixture.large);
  const largeStat = fs.statSync(largeGenerated);
  if (largeStat.size !== manifest.largeFixtureBytes || largeStat.size !== largeBytes) fail(`${format}: large fixture boundary mismatch`);
  if (!hasMagic(readBytes(largeGenerated), fixture.normalMagicHex, fixture.normalMagicOffset)) fail(`${format}: large fixture magic mismatch`);

  // The malformed vector must destroy a format-specific structural boundary;
  // text/audio formats intentionally retain extension-only detection in the
  // shared core, while archive/PDF vectors must fail bounded magic sniffing.
  if (fixture.malformedDetection === "reject" && hasMagic(malformedBytes, fixture.normalMagicHex, fixture.normalMagicOffset)) {
    fail(`${format}: malformed vector still has the normal magic`);
  }
}

console.log(`fixture files: ok (${formats.length} formats × normal/malformed/large/special)`);
NODE

if [[ "${PAPRIA_SKIP_FIXTURE_DRIVER:-0}" != "1" ]]; then
  # The CI cache can be cold on its first run, so the locked fixture driver
  # must be allowed to fetch its declared dependencies before it executes.
  CARGO_TARGET_DIR="$DRIVER_TARGET" cargo run --locked --manifest-path "$FIXTURE_DIR/driver/Cargo.toml" -- "$GENERATED"
fi

echo "fixtures: ok (tracked assets, deterministic regeneration, magic/size/corruption checks, Rust entry driver)"
