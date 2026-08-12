# Format core

`papria-format-core` is the deterministic native boundary shared by the Android
and iOS clients. It keeps format decisions, content identity, safe archive
limits, and bounded DRM-free text conversion out of platform UI code. It is
not a full layout engine: platform adapters still own Readium/PDF, comic, and
audio presentation.

## Stable API

`src/papria_format_core.udl` records the public FFI boundary. UniFFI scaffolding
and Kotlin/Swift bindings can be regenerated with
`bash scripts/generate-format-bindings.sh`; generated files are intentionally
ignored build artifacts. Native packaging is reproducible with
`scripts/build-format-core.sh ios` once the pinned Rust Apple targets are
installed; Android packaging additionally requires an Android NDK and
`cargo-ndk`. Android packaging emits the exact
`libuniffi_papria_format_core.so` name used by generated UniFFI/JNA bindings and
the enabled Android release gate loads it before calling shared checks. The
default app target remains independent of downloaded artifacts. iOS still uses
platform adapters until an XCFramework is explicitly linked by a release
target. No aliases or alternate field spellings are introduced during
generation.

The UDL `SupportedFormat` enum corresponds one-for-one to Rust
`SupportedFormat`; this is a binding-generation name, not a second wire
format. Likewise, UDL dictionaries map directly to the public Rust records
and every field remains snake_case in the generated contract.

| Rust API | Purpose |
| --- | --- |
| `SupportedFormat::from_extension` | Trim whitespace and one leading dot, then compare a lower-case extension. Unknown extensions return `None`. |
| `format_from_filename` | Examine only the final filename extension. |
| `detect_format` | Combine the final extension with a bounded magic-header check. Archive extension/signature mismatches and invalid PDF headers fail closed. |
| `detect_archive_kind` | Recognize ZIP, RAR4/RAR5, and 7z signatures without parsing or allocating the archive. |
| `reader_strategy` | FFI-friendly value form of `SupportedFormat::strategy`. |
| `archive_kind_from_extension` / `archive_kind_from_format` | FFI-friendly archive mapping helpers. |
| `SupportedFormat::strategy` | EPUB/KEPUB → Readium EPUB; MOBI/AZW/AZW3/FB2 → conversion; PDF → Readium PDF; CBZ/CBR/CB7 → comic archive; audio extensions → audio playback. |
| `sha256_hex` | Return a deterministic lower-case 64-character SHA-256 digest for a byte slice. |
| `sha256_reader` | Hash a `Read` stream in 128 KiB chunks; platform downloaders use this pattern rather than loading a whole book. |
| `ContentHasher` | Incremental FFI-safe hasher. `finalize_hex` is a non-consuming checkpoint and `reset` starts a new digest. |
| `converter_cache_key` | Return `sourceSha256:converterVersion`; changing either input invalidates a conversion cache entry. |
| `convert_fb2_to_html` | Convert bounded FB2 text/title/paragraph markup into escaped internal HTML without resolving external entities. |
| MOBI/AZW/AZW3 conversion | The pinned C `libmobi` v0.12 parser receives the bounded byte buffer through an anonymous `tmpfile()` shim, rejects DRM before parsing, then exposes copied raw HTML and supported image resources for internal EPUB construction. There is no Rust `mobi` crate or PalmDOC fallback on the production path. |
| `convert_to_internal_html` | Dispatch FB2/MOBI/AZW/AZW3 through the same bounded conversion policy. |
| `convert_to_internal_epub` | Emit a deterministic stored-ZIP EPUB 3 container (`mimetype`, container, OPF, nav and chapter) for converted text; FB2 keeps bounded `binary` images and section-based TOC entries, while DRM-free MOBI/AZW/AZW3 retain libmobi-extracted JPEG/PNG/GIF/BMP resources as `Images/` members. FB2 binary ids are restricted before they enter ZIP paths or XML attributes, duplicate ids are rejected, and the aggregate embedded-image budget is bounded. Android and the opt-in iOS native bridge call this entry point for MOBI/AZW/AZW3/FB2. |
| `validate_filename` / `sanitize_filename` | Fail-closed validation for storage names plus a deterministic display-name sanitizer for UI-only fallback. |
| `validate_archive_entry_path` | Reject absolute paths, Windows drive paths, backslashes, controls, `.` and `..` components before extraction. |
| `inspect_archive_entries` | Enforce entry count, per-entry size, total uncompressed size, path length, and compression-ratio limits before decompression. |

## Archive policy

The default mobile limits are deliberately explicit and versioned in code:

| Limit | Default |
| --- | ---: |
| `max_entries` | 10,000 |
| `max_uncompressed_bytes` | 1 GiB |
| `max_entry_uncompressed_bytes` | 256 MiB |
| `max_compression_ratio` | 100:1 |
| maximum member path | 4,096 UTF-8 bytes |
| maximum local filename | 255 UTF-8 bytes |
| maximum conversion input | 256 MiB |

An adapter must read a central directory or equivalent metadata and call
`inspect_archive_entries` before opening a write stream. A limit of zero is
invalid. `compressed_size_known = false` is reserved for adapters which
genuinely do not expose packed-size metadata (currently 7z); the core then
enforces all other limits but cannot calculate a compression ratio. ZIP/RAR
adapters set it to true, so a known zero-byte packed member with non-zero
uncompressed size is rejected as a compression bomb. The core never extracts,
follows symlinks,
creates directories, or writes to a path itself; the platform adapter must
extract into an app-private directory and use the validated relative path.

`sanitize_filename` is intentionally not a security authorization step: it
strips directory components, replaces controls/reserved characters with `_`,
handles Windows device names, and truncates at a UTF-8 boundary. Upload and
import endpoints must call `validate_filename` and reject unsafe input when
the original name is required for auditability.

## Content identity

Completed downloads are written to a temporary `.part` file, length-checked,
stream-hashed with SHA-256, and atomically moved to the content-addressed
store. The resulting digest is the only deduplication key. `sha256_reader`
and `ContentHasher` are bounded-memory operations; callers must not pass an
entire archive to an FFI call solely to calculate its identity.

## FFI stability rules

- Keep `src/papria_format_core.udl` and the Rust public API changes in the same pull request.
- Treat enum labels, dictionary field names, error labels, and function
  signatures as wire/API contracts. A spelling change requires a new contract
  version and regenerated bindings.
- Generated Kotlin/Swift sources are build artifacts. They belong under the
  ignored `bindings/generated/` path and are copied into native packaging output
  by the build script; they must not be hand-edited or committed as a second
  source of truth.
- Do not expose `std::path::Path`, platform handles, network clients, or
  mutable global state through FFI.
- Errors are fail-closed. A failed archive/path check must be surfaced to the
  caller; do not silently coerce an unsafe path into a different archive
  member.

## Checks

Run the shared-core checks from the repository root:

```bash
cargo fmt --manifest-path shared/format-core/Cargo.toml -- --check
cargo test --manifest-path shared/format-core/Cargo.toml
cargo clippy --manifest-path shared/format-core/Cargo.toml --all-targets -- -D warnings
```

The checked-in `Cargo.lock` pins the native dependency graph so CI and binding
builds use the same SHA-256 implementation. Rust compilation (via `build.rs`)
validates UDL parsing/scaffolding, while the binding-generation script emits the
Kotlin/Swift sources. `scripts/build-format-core.sh` validates the required
cross-compilation prerequisites and packages the native library; it is not run
by the default app build because CI machines may not have Apple targets or an
Android NDK installed.
