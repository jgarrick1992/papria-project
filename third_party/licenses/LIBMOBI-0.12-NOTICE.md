# libmobi v0.12 notice

Papria vendors the unmodified source of `bfabiszewski/libmobi` tag `v0.12`,
resolved at commit `85dcfe803fc2a21020ddcf15c3eb66b93d388add`. The reproducible
Git source export SHA-256 is
`73bfb526dc11f5ecc1e57835aa84e0c8719a2a43427036d177fb529db0ac951b`.

Upstream source: <https://github.com/bfabiszewski/libmobi/tree/v0.12>

libmobi is licensed under LGPL-3.0-or-later. Its complete license text is
provided in [`LIBMOBI-0.12-LGPL-3.0-or-later.txt`](LIBMOBI-0.12-LGPL-3.0-or-later.txt),
and the matching vendored source is at
[`shared/format-core/vendor/libmobi`](../../shared/format-core/vendor/libmobi).

The Papria adapter at `shared/format-core/native/libmobi_shim.c` is separate
Apache-2.0-licensed application code. It does not enable libmobi encryption or
decryption. Before a release, the artifact owner must provide the corresponding
source and relinkability materials required by LGPL-3.0-or-later for the exact
Android and iOS binaries. This notice records source provenance; it is not a
legal determination of a store distribution method.
