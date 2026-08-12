# Format-core fixtures

This directory contains the deterministic, license-clear fixture corpus for
all 16 declared Papria formats. Every `normal`, `malformed`, and special-name
sample is an actual tracked file under `assets/`; it is generated from
[`scripts/generate-format-fixtures.mjs`](../../../scripts/generate-format-fixtures.mjs).
The inputs are synthetic: the EPUB/KEPUB/CBZ files are script-built ZIPs, the
PDF and FB2 files are script-built text containers, the CBR/CB7 archives are
minimal synthetic archives, and the audio payloads are a generated 440 Hz
test tone. No books, recordings, cover art, or third-party media are included.
All fixture data and generator source are licensed under Apache-2.0.

The `large` member for every format has a logical size of 64 MiB + 1 byte. It
is generated as a sparse file in a temporary directory by the verifier, so the
repository does not carry approximately 1 GiB of binary padding. The verifier
checks the exact logical length, normal magic at its format-specific offset,
and streams representative PDF/CBZ/CBR/CB7 large files through
`papria_format_core::sha256_reader`. Every one of the 16 large files is still
materialized and checked for exact logical size, magic and format detection.

Run the complete fixture gate:

```bash
./scripts/verify-fixtures.sh
```

The gate regenerates all vectors in a temporary directory, byte-compares the
tracked assets, checks manifest paths, filenames, byte sizes, magic, malformed
vectors, and uses the Rust fixture driver to call the public detection API for
all 16 formats. It also calls the public FB2/MOBI/AZW/AZW3 internal-EPUB
conversion API on normal and malformed cases, and validates CBZ/CBR/CB7
through the public archive inspector. This is an entry-boundary test;
it does not claim platform-reader, Readium, PDFium, LibVLC, or complete
RAR/7z parser coverage.
