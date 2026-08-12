#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const LARGE_FIXTURE_BYTES = 64 * 1024 * 1024 + 1;
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

const SPECIAL_FILENAME = (extension) => `Páprïa 水墨:fixture?*<>|.${extension}`;

// These four payloads are deterministic, synthetic audio generated once from
// a 440 Hz sine wave. They contain no speech, music, cover art, or third-party
// content. Keeping the bytes here makes fixture regeneration independent of
// FFmpeg, platform codecs, clocks, and encoder versions.
const AUDIO = Object.freeze({
  m4a: "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",
  mp3: "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",
  opus: "T2dnUwACAAAAAAAAAAAAAAAAAAAAAGS5xGoBE09wdXNIZWFkAQE4AUAfAAAAAABPZ2dTAAAAAAAAAAAAAAAAAAABAAAASZW+VAEuT3B1c1RhZ3MGAAAAZmZtcGVnAQAAABQAAABlbmNvZGVyPUxhdmMgbGlib3B1c09nZ1MABBgwAAAAAAAAAAAAAAIAAACHEF8sDW03NjY1NjY3NjU3N2qYcklEpTPELXnhGkBx+9Bar065rnBGqjgp7EnHmHk7g2Gl71rlSsqDsgA6AglVSr7JmomjesYY+YyPZ3Gb+ArVeD38udmXFDArol+uQ+wsZe9tQdAVerdTlA8vV67agOud6Ran4RE+fT8gSGRKmB0mS2Sg5sFlYe99wyj/sGc7BdVxQCKbJ/Se5iyaY3JZrG9sPifugW68ZeZx3LKcA5tEupbbsJgh/zPxAPTKhXMUnW75p0Mw2VTohwcaRZQF0uPdnY10mKz62VefeBbaOOsJOxC9JwTG2f7IepgF07XzBOhobfT0HDrFDpH2n85dqJVaq9XowUyGydfUvTTsV1FndHTf46zoxjgVUP97ixMKOJgYJC+KiJec7YlK0JyMvCOvozjQVX5mLq/yM79zRWRkD/YA0nJL7ed8fMeUpStOY+BptDk7mCRu9/S3DAyBbCqF2mzOJEQ34vDPxWBbAyH7hxDuDJ0U/GJI4mwYyMZSAmexivvMPM7BFYwumBgjbrlkJdiQCz4feRF+Zl7Pkp2iMBPKPpTmLJpjclmsb2w+J+6Bbrxl5nHcspwDm0S0kaFfmCH/M/EA9MuvEGGD0HKORuaGJeyISl0KYBc/G92djXYko762Va83gWyChU4k7EL0n14O2X7IepgF07XzBOhobfT0HDrFDpH2n85Qa7Y1v9XowUyGyde/+tTsV1FndHTf46zoxjgVUP97ixOKOJgYJDEBlIN6zKguXiSOJz6ePhsINTHGh63xnfuaKyMgf7AGk5Jd2c74+Y8pZStOY+Bp07k7mCRu9/S3DAyGXWhOB5kvQuZC6tlR5ZARqSH7hNCrgyRR8QYkjgfQYyMZSAmexivvMp20wRWMLpgYI265ZCXYfdUM9BigVbVOzUQSn3HSJdFqzFk0xuSzWRTD/xP3fG3YuRzPTCsp+483/ukjQr+YeGe/KR+Ek+9IwY70f79m7WriTvwrKlSlWJj7LdXMU6S7H0jKLHIGYf4k9Onnguo9mmVIpfgJ+fN8G8XWcQKn5IsoAgGKh7LLDh7/WyNCJTRYB7wONLkYwl6LvNHg8U65JGJN5lPgyerq",
  flac: "ZkxhQwAAACIQABAAAAGTAAGTAfQA8AAAAyAQwjlZxu/PiF5P0MPupVblhAAAKCAAAAByZWZlcmVuY2UgbGliRkxBQyAxLjUuMCAyMDI1MDIxMQAAAAD/+HQIAAMf90gAAAVrCjINxQ+2tK+tV/n5vnSgBEmGxCZJPSrK7JDEQma3FXP5GxDMRE18df7MhEERGkjrXqpoYmM2a3vevS4yMImIuh4qy7MghMhvc61Z0SCEhm28V+tsRsYjMmlWlt+2MRDISzOsfzojGRiNUj3lsUkw2ITJJ6VZXZIYiEzW4q5/I2IZiImvjr/ZkIgiI0kda9VNDExmzW9716XGRhExF0PFWXZkEJkN7nWrOiQQkM23iv1tiNjEZk0q0tv2xiIZCWZ1j+dEYyMRqke8tikmGxCZJPSrK7JDEQma3FXP5GxDMRE18df7MhEERGkjrXqpoYmM2a3vevS4yMImIuh4qy7MghMhvc61Z0SCEhm28V+tsRsYjMmlWlt+2MRDISzOsfzojGRiNUj3lsUkw2ITJJ6VZXZIYiEzW4q5/I2IZiImvjr/ZkIgiI0kda9VNDExmzW9716XGRhExF0PFWXZkEJkN7nWrOiQQkM23iv1tiNjEZk0q0tv2xiIZCWZ1j+dEYyMRqkegIM6"
});

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+KDGnKwAAAABJRU5ErkJggg==",
  "base64",
);
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function writeU16LE(value) {
  const output = Buffer.alloc(2);
  output.writeUInt16LE(value);
  return output;
}

function writeU32LE(value) {
  const output = Buffer.alloc(4);
  output.writeUInt32LE(value >>> 0);
  return output;
}

function writeU64LE(value) {
  const output = Buffer.alloc(8);
  output.writeBigUInt64LE(BigInt(value));
  return output;
}

function storedZip(entries) {
  const locals = [];
  const central = [];
  let offset = 0;
  for (const [name, bytes] of entries) {
    const nameBytes = Buffer.from(name, "utf8");
    const body = Buffer.from(bytes);
    const crc = crc32(body);
    const local = Buffer.concat([
      Buffer.from("504b0304", "hex"), writeU16LE(20), writeU16LE(0), writeU16LE(0),
      writeU16LE(0), writeU16LE(0), writeU32LE(crc), writeU32LE(body.length),
      writeU32LE(body.length), writeU16LE(nameBytes.length), writeU16LE(0), nameBytes, body,
    ]);
    locals.push(local);
    central.push(Buffer.concat([
      Buffer.from("504b0102", "hex"), writeU16LE(20), writeU16LE(20), writeU16LE(0),
      writeU16LE(0), writeU16LE(0), writeU16LE(0), writeU32LE(crc), writeU32LE(body.length),
      writeU32LE(body.length), writeU16LE(nameBytes.length), writeU16LE(0), writeU16LE(0),
      writeU16LE(0), writeU16LE(0), writeU32LE(0), writeU32LE(offset), nameBytes,
    ]));
    offset += local.length;
  }
  const directory = Buffer.concat(central);
  return Buffer.concat([
    ...locals,
    directory,
    Buffer.from("504b0506", "hex"), writeU16LE(0), writeU16LE(0),
    writeU16LE(entries.length), writeU16LE(entries.length), writeU32LE(directory.length),
    writeU32LE(offset), writeU16LE(0),
  ]);
}

function epub(isKepub) {
  const chapter = isKepub
    ? '<html xmlns="http://www.w3.org/1999/xhtml"><body><p><span class="koboSpan" id="kobo.1.1">Papria fixture</span></p></body></html>'
    : '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Papria fixture</p></body></html>';
  return storedZip([
    ["mimetype", Buffer.from("application/epub+zip")],
    ["META-INF/container.xml", Buffer.from('<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')],
    ["OEBPS/content.opf", Buffer.from('<?xml version="1.0"?><package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">papria-fixture</dc:identifier><dc:title>Papria fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>')],
    ["OEBPS/nav.xhtml", Buffer.from('<html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol><li><a href="chapter.xhtml">Papria fixture</a></li></ol></nav></body></html>')],
    ["OEBPS/chapter.xhtml", Buffer.from(chapter)],
  ]);
}

function pdf() {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>",
    "<< /Length 35 >>\nstream\nBT /F1 12 Tf 10 50 Td (Papria fixture) Tj ET\nendstream",
  ];
  const chunks = [Buffer.from("%PDF-1.4\n%\xff\xff\xff\xff\n")];
  const offsets = [0];
  let offset = chunks[0].length;
  for (let index = 0; index < objects.length; index += 1) {
    offsets.push(offset);
    const bytes = Buffer.from(`${index + 1} 0 obj\n${objects[index]}\nendobj\n`);
    chunks.push(bytes);
    offset += bytes.length;
  }
  const xref = offset;
  chunks.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map((value) => `${String(value).padStart(10, "0")} 00000 n \n`).join("")}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

function mobi(text) {
  const body = Buffer.from(text, "utf8");
  const firstRecord = 78 + 2 * 8;
  const output = Buffer.alloc(firstRecord + 16 + body.length);
  output.write("BOOKMOBI", 60, "ascii");
  output.writeUInt16BE(2, 76);
  output.writeUInt32BE(firstRecord, 78);
  output.writeUInt32BE(firstRecord + 16, 86);
  output.writeUInt16BE(1, firstRecord);
  output.writeUInt32BE(body.length, firstRecord + 4);
  output.writeUInt16BE(1, firstRecord + 8);
  body.copy(output, firstRecord + 16);
  return output;
}

function rarHeader(type, body) {
  // Keep this byte-for-byte aligned with the shared core's `rar4_header`
  // test helper: RAR4 stores the low 16 bits of the complemented CRC-32.
  const crc = (~crc32(Buffer.concat([Buffer.from([type]), body]))) & 0xffff;
  return Buffer.concat([Buffer.from([crc & 0xff, (crc >>> 8) & 0xff, type]), body]);
}

function cbr() {
  const main = rarHeader(0x73, Buffer.from([0, 0, 13, 0, 0, 0, 0, 0, 0, 0]));
  const end = rarHeader(0x7b, Buffer.from([0, 0, 7, 0]));
  return Buffer.concat([Buffer.from("526172211a0700", "hex"), main, end]);
}

function sevenZipUint(value) {
  const numeric = Number(value);
  for (let extra = 0; extra < 8; extra += 1) {
    const payloadBits = 7 - extra;
    if (numeric < 2 ** (8 * extra + payloadBits)) {
      const prefix = extra === 0 ? 0 : (0xff << (8 - extra)) & 0xff;
      const output = [prefix | ((numeric >> (8 * extra)) & ((1 << payloadBits) - 1))];
      for (let byte = 0; byte < extra; byte += 1) output.push((numeric >> (8 * byte)) & 0xff);
      return Buffer.from(output);
    }
  }
  throw new Error("fixture 7z integer exceeds safe compact encoding");
}

function cb7() {
  // Deterministic, unencoded 7z with one synthetic image payload. Its
  // StreamsInfo / FilesInfo layout deliberately matches the bounded shared
  // parser, so this fixture exercises real 7z metadata handling rather than
  // a magic-byte-only path.
  const packed = PNG.length;
  const name = Buffer.from("page-001.png\0", "utf16le");
  const header = Buffer.concat([
    Buffer.from([0x01, 0x04, 0x06]), sevenZipUint(0), sevenZipUint(1), Buffer.from([0x09]), sevenZipUint(packed), Buffer.from([0x00]),
    Buffer.from([0x07, 0x0b]), sevenZipUint(1), Buffer.from([0x00, 0x01, 0x01, 0x00, 0x0c]), sevenZipUint(packed),
    // End UnpackInfo, then the enclosing StreamsInfo. This exact sequence
    // mirrors `make_minimal_7z` in the shared core tests.
    Buffer.from([0x00, 0x00, 0x05]), sevenZipUint(1),
    Buffer.from([0x11]), sevenZipUint(1 + name.length), Buffer.from([0x00]), name,
    Buffer.from([0x00, 0x00]),
  ]);
  const startHeader = Buffer.concat([writeU64LE(packed), writeU64LE(header.length), writeU32LE(crc32(header))]);
  return Buffer.concat([
    Buffer.from("377abcaf271c", "hex"), Buffer.from([0, 4]), writeU32LE(crc32(startHeader)), startHeader, PNG, header,
  ]);
}

function fb2() {
  return Buffer.from('<?xml version="1.0" encoding="utf-8"?><FictionBook><description><title-info><book-title>Papria fixture</book-title></title-info></description><body><section><title>One</title><p>Papria fixture text.</p></section></body></FictionBook>');
}

const FORMATS = Object.freeze([
  { name: "epub", extension: "epub", magic: "504b0304", offset: 0, malformedDetection: "reject", conversion: false, normal: () => epub(false) },
  { name: "kepub", extension: "kepub", magic: "504b0304", offset: 0, malformedDetection: "reject", conversion: false, normal: () => epub(true) },
  { name: "mobi", extension: "mobi", magic: "424f4f4b4d4f4249", offset: 60, malformedDetection: "accept", conversion: true, normal: () => mobi("Papria MOBI fixture") },
  { name: "azw", extension: "azw", magic: "424f4f4b4d4f4249", offset: 60, malformedDetection: "accept", conversion: true, normal: () => mobi("Papria AZW fixture") },
  { name: "azw3", extension: "azw3", magic: "424f4f4b4d4f4249", offset: 60, malformedDetection: "accept", conversion: true, normal: () => mobi("Papria AZW3 fixture") },
  { name: "fb2", extension: "fb2", magic: "3c3f786d6c", offset: 0, malformedDetection: "accept", conversion: true, normal: fb2 },
  { name: "pdf", extension: "pdf", magic: "255044462d", offset: 0, malformedDetection: "reject", conversion: false, normal: pdf },
  { name: "cbz", extension: "cbz", magic: "504b0304", offset: 0, malformedDetection: "reject", conversion: false, normal: () => storedZip([["page-001.png", PNG]]) },
  { name: "cbr", extension: "cbr", magic: "526172211a0700", offset: 0, malformedDetection: "reject", conversion: false, normal: cbr },
  { name: "cb7", extension: "cb7", magic: "377abcaf271c", offset: 0, malformedDetection: "reject", conversion: false, normal: cb7 },
  { name: "m4b", extension: "m4b", magic: "66747970", offset: 4, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.m4a, "base64") },
  { name: "m4a", extension: "m4a", magic: "66747970", offset: 4, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.m4a, "base64") },
  { name: "mp3", extension: "mp3", magic: "494433", offset: 0, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.mp3, "base64") },
  { name: "opus", extension: "opus", magic: "4f676753", offset: 0, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.opus, "base64") },
  { name: "ogg", extension: "ogg", magic: "4f676753", offset: 0, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.opus, "base64") },
  { name: "flac", extension: "flac", magic: "664c6143", offset: 0, malformedDetection: "accept", conversion: false, normal: () => Buffer.from(AUDIO.flac, "base64") },
]);

function malformed(spec, normal) {
  if (spec.name === "fb2") return Buffer.from([0xff, 0xfe, 0xfd, 0x3c, 0x70, 0x3e]);
  const output = Buffer.from(normal);
  output[spec.offset] ^= 0xff;
  if (["mobi", "azw", "azw3"].includes(spec.name)) {
    output.writeUInt32BE(0, 78);
  }
  return output;
}

function writeFile(outputRoot, relativePath, bytes) {
  const target = path.join(outputRoot, relativePath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes, { mode: 0o644 });
}

function writeLarge(outputRoot, spec, normal) {
  const relativePath = path.join("large", spec.name, `large.${spec.extension}`);
  const target = path.join(outputRoot, relativePath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const descriptor = fs.openSync(target, "w", 0o644);
  try {
    fs.writeSync(descriptor, normal);
    fs.ftruncateSync(descriptor, LARGE_FIXTURE_BYTES);
  } finally {
    fs.closeSync(descriptor);
  }
}

function main() {
  const arguments_ = process.argv.slice(2);
  const assetsOnly = arguments_[0] === "--assets-only";
  const offset = assetsOnly ? 1 : 0;
  if (arguments_[offset] !== "--output" || !arguments_[offset + 1] || arguments_.length !== offset + 2) {
    throw new Error("usage: generate-format-fixtures.mjs [--assets-only] --output <directory>");
  }
  const outputRoot = path.resolve(arguments_[offset + 1]);
  if (outputRoot === ROOT || outputRoot.startsWith(`${ROOT}${path.sep}`) && !outputRoot.startsWith(path.join(ROOT, "shared", "format-core", "fixtures") + path.sep)) {
    throw new Error("output must not overwrite the repository outside format fixtures");
  }
  fs.mkdirSync(outputRoot, { recursive: true });
  for (const spec of FORMATS) {
    const normal = spec.normal();
    writeFile(outputRoot, path.join("assets", spec.name, `normal.${spec.extension}`), normal);
    writeFile(outputRoot, path.join("assets", spec.name, `malformed.${spec.extension}`), malformed(spec, normal));
    writeFile(outputRoot, path.join("assets", spec.name, SPECIAL_FILENAME(spec.extension)), normal);
    if (!assetsOnly) writeLarge(outputRoot, spec, normal);
  }
  process.stdout.write(`generated ${FORMATS.length} ${assetsOnly ? "asset" : "fixture"} sets at ${outputRoot}\n`);
}

main();
