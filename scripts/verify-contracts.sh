#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR" <<'NODE'
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const contractDir = path.join(root, "shared", "contracts");

function fail(message) {
  throw new Error(message);
}

function parseStrictJson(text, filename) {
  // JSON.parse accepts duplicate object keys and silently keeps the last
  // value. Contracts are wire/API sources of truth, so duplicate keys must
  // fail closed instead of hiding an accidental alias.
  let index = 0;
  const length = text.length;

  function whitespace() {
    while (index < length && /\s/.test(text[index])) index += 1;
  }

  function string() {
    const start = index;
    if (text[index] !== '"') fail(`${filename}: expected string at ${index}`);
    index += 1;
    let escaped = false;
    while (index < length) {
      const character = text[index];
      index += 1;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        return JSON.parse(text.slice(start, index));
      }
    }
    fail(`${filename}: unterminated string`);
  }

  function value() {
    whitespace();
    const character = text[index];
    if (character === '"') return string();
    if (character === "{") return object();
    if (character === "[") return array();
    for (const literal of ["true", "false", "null"]) {
      if (text.startsWith(literal, index)) {
        index += literal.length;
        return literal === "true" ? true : literal === "false" ? false : null;
      }
    }
    const number = text.slice(index).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (number) {
      index += number[0].length;
      return Number(number[0]);
    }
    fail(`${filename}: invalid JSON value at ${index}`);
  }

  function object() {
    // A null-prototype object keeps `__proto__` as an ordinary JSON key, so it
    // cannot mutate the validator's prototype and evade the exact-key check.
    const output = Object.create(null);
    const keys = new Set();
    index += 1;
    whitespace();
    if (text[index] === "}") {
      index += 1;
      return output;
    }
    while (index < length) {
      whitespace();
      const key = string();
      if (keys.has(key)) fail(`${filename}: duplicate key ${key}`);
      keys.add(key);
      whitespace();
      if (text[index] !== ":") fail(`${filename}: expected ':' at ${index}`);
      index += 1;
      output[key] = value();
      whitespace();
      if (text[index] === "}") {
        index += 1;
        return output;
      }
      if (text[index] !== ",") fail(`${filename}: expected ',' at ${index}`);
      index += 1;
    }
    fail(`${filename}: unterminated object`);
  }

  function array() {
    const output = [];
    index += 1;
    whitespace();
    if (text[index] === "]") {
      index += 1;
      return output;
    }
    while (index < length) {
      output.push(value());
      whitespace();
      if (text[index] === "]") {
        index += 1;
        return output;
      }
      if (text[index] !== ",") fail(`${filename}: expected ',' at ${index}`);
      index += 1;
    }
    fail(`${filename}: unterminated array`);
  }

  const parsed = value();
  whitespace();
  if (index !== length) fail(`${filename}: trailing JSON data at ${index}`);
  return parsed;
}

function read(name) {
  return readJson(path.join(contractDir, name));
}

function readJson(file) {
  if (!fs.existsSync(file)) fail(`missing contract: ${file}`);
  const text = fs.readFileSync(file, "utf8");
  try {
    return parseStrictJson(text, file);
  } catch (error) {
    throw new Error(error.message);
  }
}

function readFixture(name) {
  return readJson(path.join(contractDir, "fixtures", name));
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function keys(value, expected, label) {
  if (!isObject(value)) fail(`${label}: expected object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label}: exact keys required; expected ${JSON.stringify(wanted)}, received ${JSON.stringify(actual)}`);
  }
}

function stringValue(value, label) {
  if (typeof value !== "string") fail(`${label}: expected string`);
}

function booleanValue(value, label) {
  if (typeof value !== "boolean") fail(`${label}: expected boolean`);
}

function integerValue(value, label, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) fail(`${label}: expected integer >= ${minimum}`);
}

function exact(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`${label}: expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  }
}

function stringArray(value, expected, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    fail(`${label}: expected an array of strings`);
  }
  if (new Set(value).size !== value.length) fail(`${label}: duplicate field names are forbidden`);
  exact(value, expected, label);
}

function route(value, label, method, routePath, routeKeys) {
  keys(value, routeKeys, label);
  exact(value.method, method, `${label}.method`);
  exact(value.path, routePath, `${label}.path`);
}

function identity(contract, name, version, expectedKeys) {
  keys(contract, expectedKeys, name);
  exact(contract.title, name, `${name}.title`);
  exact(contract.version, version, `${name}.version`);
  stringValue(contract.title, `${name}.title`);
  stringValue(contract.version, `${name}.version`);
}

const bookorbit = read("bookorbit-v2.5.0.json");
identity(bookorbit, "BookOrbit REST client contract", "v2.5.0", [
  "title", "version", "basePath", "authentication", "appInfo", "library", "progress",
]);
exact(bookorbit.basePath, "/api/v1", "bookorbit.basePath");
keys(bookorbit.authentication, ["login", "refresh", "me"], "authentication");
route(bookorbit.authentication.login, "authentication.login", "POST", "/auth/login", ["method", "path", "body"]);
stringArray(bookorbit.authentication.login.body, ["username", "password"], "authentication.login.body");
route(bookorbit.authentication.refresh, "authentication.refresh", "POST", "/auth/refresh", ["method", "path", "usesCookie"]);
exact(bookorbit.authentication.refresh.usesCookie, "refresh_token", "authentication.refresh.usesCookie");
route(bookorbit.authentication.me, "authentication.me", "GET", "/auth/me", ["method", "path"]);
route(bookorbit.appInfo, "appInfo", "GET", "/app-info", ["method", "path", "requiredResponseFields"]);
stringArray(bookorbit.appInfo.requiredResponseFields, ["version"], "appInfo.requiredResponseFields");
keys(bookorbit.library, ["query", "detail", "cover", "fileServe"], "library");
route(bookorbit.library.query, "library.query", "POST", "/books/query", ["method", "path", "body", "response"]);
stringArray(bookorbit.library.query.body, ["sort", "pagination", "collapseSeries", "q"], "library.query.body");
stringArray(bookorbit.library.query.response, ["items", "total", "page", "size"], "library.query.response");
route(bookorbit.library.detail, "library.detail", "GET", "/books/:id", ["method", "path"]);
route(bookorbit.library.cover, "library.cover", "GET", "/books/:id/cover", ["method", "path", "maxBytes"]);
integerValue(bookorbit.library.cover.maxBytes, "library.cover.maxBytes", 1);
exact(bookorbit.library.cover.maxBytes, 16 * 1024 * 1024, "library.cover.maxBytes");
route(bookorbit.library.fileServe, "library.fileServe", "GET", "/books/files/:fileId/serve", ["method", "path", "supportsRange"]);
booleanValue(bookorbit.library.fileServe.supportsRange, "library.fileServe.supportsRange");
exact(bookorbit.library.fileServe.supportsRange, true, "library.fileServe.supportsRange");
keys(bookorbit.progress, ["fileGet", "fileSave", "audioGet", "audioSave"], "progress");
route(bookorbit.progress.fileGet, "progress.fileGet", "GET", "/books/files/:fileId/progress", ["method", "path"]);
route(bookorbit.progress.fileSave, "progress.fileSave", "POST", "/books/files/:fileId/progress", ["method", "path", "body"]);
stringArray(bookorbit.progress.fileSave.body, [
  "percentage", "cfi", "pageNumber", "positionSeconds", "koboLocationSource",
  "koboLocationType", "koboLocationValue", "koboContentSourceProgressPercent", "koreaderProgress",
], "progress.fileSave.body");
route(bookorbit.progress.audioGet, "progress.audioGet", "GET", "/books/:bookId/audio-progress", ["method", "path"]);
route(bookorbit.progress.audioSave, "progress.audioSave", "PATCH", "/books/:bookId/audio-progress", ["method", "path", "body"]);
stringArray(bookorbit.progress.audioSave.body, ["percentage", "currentFileId", "positionSeconds"], "progress.audioSave.body");

const progress = read("progress-v1.json");
identity(progress, "Papria progress envelope", "v1", [
  "title", "version", "rules", "bookProgressFields", "audioProgressFields", "precision",
]);
keys(progress.rules, ["localFirst", "remoteSource", "conflict", "aliases"], "progress.rules");
exact(progress.rules, {
  localFirst: true,
  remoteSource: "bookorbit",
  conflict: "pull-before-push-and-verify",
  aliases: false,
}, "progress.rules");
booleanValue(progress.rules.localFirst, "progress.rules.localFirst");
booleanValue(progress.rules.aliases, "progress.rules.aliases");
stringArray(progress.bookProgressFields, ["percentage", "cfi", "pageNumber", "positionSeconds", "updatedAt", "dirty"], "progress.bookProgressFields");
stringArray(progress.audioProgressFields, ["percentage", "currentFileId", "positionSeconds", "updatedAt", "dirty"], "progress.audioProgressFields");
keys(progress.precision, ["epub", "pdf", "comic", "audio", "convertedText"], "progress.precision");
stringArray(progress.precision.epub, ["percentage", "cfi"], "progress.precision.epub");
stringArray(progress.precision.pdf, ["percentage", "pageNumber"], "progress.precision.pdf");
stringArray(progress.precision.comic, ["percentage", "pageNumber"], "progress.precision.comic");
stringArray(progress.precision.audio, ["percentage", "currentFileId", "positionSeconds"], "progress.precision.audio");
stringArray(progress.precision.convertedText, ["percentage"], "progress.precision.convertedText");

const wifi = read("wifi-upload-v1.json");
identity(wifi, "Papria local Wi-Fi upload contract", "v1", ["title", "version", "security", "chunkSizeBytes", "routes", "storage"]);
keys(wifi.security, ["authorization", "resumeAuthorization", "tokenInQrFragment", "foregroundOnly", "localInterfaceOnly"], "wifi.security");
exact(wifi.security, {
  authorization: "Bearer upload-session-token",
  resumeAuthorization: "X-Papria-Resume-Token",
  tokenInQrFragment: true,
  foregroundOnly: true,
  localInterfaceOnly: true,
}, "wifi.security");
integerValue(wifi.chunkSizeBytes, "wifi.chunkSizeBytes", 1);
exact(wifi.chunkSizeBytes, 8 * 1024 * 1024, "wifi.chunkSizeBytes");
keys(wifi.routes, ["index", "create", "status", "chunk", "complete", "cancel"], "wifi.routes");
route(wifi.routes.index, "routes.index", "GET", "/", ["method", "path"]);
route(wifi.routes.create, "routes.create", "POST", "/api/uploads", ["method", "path", "body", "response"]);
stringArray(wifi.routes.create.body, ["fileName", "sizeBytes"], "routes.create.body");
stringArray(wifi.routes.create.response, ["uploadId", "resumeToken", "receivedBytes"], "routes.create.response");
route(wifi.routes.status, "routes.status", "GET", "/api/uploads/:uploadId", ["method", "path", "header"]);
exact(wifi.routes.status.header, "X-Papria-Resume-Token", "routes.status.header");
route(wifi.routes.chunk, "routes.chunk", "PUT", "/api/uploads/:uploadId/chunks/:chunkIndex", ["method", "path", "header"]);
stringArray(wifi.routes.chunk.header, ["Content-Range", "X-Papria-Resume-Token"], "routes.chunk.header");
route(wifi.routes.complete, "routes.complete", "POST", "/api/uploads/:uploadId/complete", ["method", "path", "header"]);
exact(wifi.routes.complete.header, "X-Papria-Resume-Token", "routes.complete.header");
route(wifi.routes.cancel, "routes.cancel", "DELETE", "/api/uploads/:uploadId", ["method", "path", "header"]);
exact(wifi.routes.cancel.header, "X-Papria-Resume-Token", "routes.cancel.header");
keys(wifi.storage, ["destination", "hash", "temporarySuffix", "unfinishedRetentionHours"], "wifi.storage");
exact(wifi.storage, {
  destination: "local-only",
  hash: "sha256",
  temporarySuffix: ".part",
  unfinishedRetentionHours: 24,
}, "wifi.storage");
integerValue(wifi.storage.unfinishedRetentionHours, "wifi.storage.unfinishedRetentionHours", 1);

const fixtureDir = path.join(contractDir, "fixtures");
const uploadFixtureNames = fs.readdirSync(fixtureDir)
  .filter((name) => /^wifi-.*-request\.json$/.test(name))
  .sort();
exact(uploadFixtureNames, ["wifi-chunk-request.json", "wifi-create-request.json"], "Wi-Fi upload fixture names");

const wifiCreateRequest = readFixture("wifi-create-request.json");
keys(wifiCreateRequest, wifi.routes.create.body, "wifi-create-request");
stringValue(wifiCreateRequest.fileName, "wifi-create-request.fileName");
if (wifiCreateRequest.fileName.length === 0) fail("wifi-create-request.fileName: must not be empty");
integerValue(wifiCreateRequest.sizeBytes, "wifi-create-request.sizeBytes", 1);

const wifiChunkRequest = readFixture("wifi-chunk-request.json");
keys(wifiChunkRequest, ["contentRange", "chunkIndex", "chunkSizeBytes", "contentLength", "bodyBytes"], "wifi-chunk-request");
integerValue(wifiChunkRequest.chunkIndex, "wifi-chunk-request.chunkIndex", 0);
integerValue(wifiChunkRequest.chunkSizeBytes, "wifi-chunk-request.chunkSizeBytes", 1);
exact(wifiChunkRequest.chunkSizeBytes, wifi.chunkSizeBytes, "wifi-chunk-request.chunkSizeBytes");
integerValue(wifiChunkRequest.contentLength, "wifi-chunk-request.contentLength", 1);
integerValue(wifiChunkRequest.bodyBytes, "wifi-chunk-request.bodyBytes", 1);
stringValue(wifiChunkRequest.contentRange, "wifi-chunk-request.contentRange");

const contentRange = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(wifiChunkRequest.contentRange);
if (!contentRange) fail("wifi-chunk-request.contentRange: expected bytes <start>-<end>/<total>");
const [, startText, endText, totalText] = contentRange;
const start = Number(startText);
const end = Number(endText);
const total = Number(totalText);
integerValue(start, "wifi-chunk-request.contentRange.start", 0);
integerValue(end, "wifi-chunk-request.contentRange.end", 0);
integerValue(total, "wifi-chunk-request.contentRange.total", 1);
if (start >= total || end < start || end >= total) {
  fail("wifi-chunk-request.contentRange: range must be within the declared total");
}
const expectedStart = wifiChunkRequest.chunkIndex * wifi.chunkSizeBytes;
if (!Number.isSafeInteger(expectedStart) || start !== expectedStart) {
  fail("wifi-chunk-request: chunkIndex must select an 8 MiB-aligned range start");
}
const rangeLength = end - start + 1;
const isFinalChunk = end === total - 1;
if (!isFinalChunk && rangeLength !== wifi.chunkSizeBytes) {
  fail("wifi-chunk-request: every non-final chunk must be exactly 8 MiB");
}
if (rangeLength > wifi.chunkSizeBytes) {
  fail("wifi-chunk-request: chunk range must not exceed 8 MiB");
}
exact(wifiChunkRequest.contentLength, rangeLength, "wifi-chunk-request.contentLength");
exact(wifiChunkRequest.bodyBytes, wifiChunkRequest.contentLength, "wifi-chunk-request.bodyBytes");
exact(wifiCreateRequest.sizeBytes, total, "Wi-Fi upload fixture total size");

console.log("contract fixtures: ok (strict keys, types, values, duplicate-key rejection, and Wi-Fi request semantics)");
NODE
