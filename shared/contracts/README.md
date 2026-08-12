# Wire contracts

The JSON files in this directory are the checked-in contract surface used by Android, iOS, and the shared test fixtures. They describe exact field names, methods, and route shapes. They are not compatibility schemas: an unknown field or alternate spelling is not silently accepted.

The initial BookOrbit contract is the `v2.5.0` REST surface. The Wi-Fi receiver contract is app-local and versioned independently.

## Contract ownership

| File | Owner | Scope |
| --- | --- | --- |
| `bookorbit-v2.5.0.json` | BookOrbit server adapter | Login/refresh, app-version gate, library queries, bounded cover retrieval, ranged file serving, book progress, and audiobook progress. |
| `progress-v1.json` | Shared sync layer | Local-first envelopes, conflict policy, and the exact locator fields sent to BookOrbit for each media type. |
| `wifi-upload-v1.json` | Native foreground receiver | QR/session security, chunked browser upload, local-only storage, and unfinished-upload retention. |

The Android and iOS implementations read the same names from these fixtures;
they do not import BookOrbit's Vue/TypeScript types and must not add a second
spelling for an existing key. A server change requires a new versioned fixture,
adapter tests, and an explicit compatibility decision.

## Validation

From the repository root, run:

```bash
./scripts/verify-contracts.sh
```

The check parses every fixture as JSON and verifies the required identity and
route invariants (HTTP method/path, range support, progress fields, and the
Wi-Fi bearer/chunk rules). Wi-Fi upload fixtures use exact keys and must prove
the chunk index, 8 MiB alignment, `Content-Range`, declared total,
`Content-Length`, and body byte count all agree. It also rejects unknown keys,
duplicate JSON keys, wrong primitive types, and duplicate field names. It
intentionally fails closed when a required key is missing or has a different
value; it is not a permissive compatibility schema.

Small synthetic request examples live in [`fixtures/`](fixtures/README.md).
The format-core vector manifest is separate at
`shared/format-core/fixtures/manifest.json` so that contract fixtures never
become a reader/parser dependency.
