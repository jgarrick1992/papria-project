# Vendored libmobi source

This directory is an unmodified source export of
[`bfabiszewski/libmobi`](https://github.com/bfabiszewski/libmobi).

| Field | Value |
| --- | --- |
| Upstream tag | `v0.12` |
| Resolved commit | `85dcfe803fc2a21020ddcf15c3eb66b93d388add` |
| Source export | `git archive --format=tar 85dcfe803fc2a21020ddcf15c3eb66b93d388add` |
| SHA-256 of source export | `73bfb526dc11f5ecc1e57835aa84e0c8719a2a43427036d177fb529db0ac951b` |
| Upstream license | LGPL-3.0-or-later; see [`COPYING`](COPYING) |

Papria compiles only the parser subset needed by
`native/libmobi_shim.c`: encryption support and OPF/XML writing are disabled,
and libmobi's bundled `miniz.c` is used instead of system zlib. The shim is
outside this directory so the upstream source remains unmodified. The release
owner must still provide the LGPL source and relinkability materials appropriate
to each shipped binary; the checked-in license delivery copy is
[`third_party/licenses/LIBMOBI-0.12-LGPL-3.0-or-later.txt`](../../../../third_party/licenses/LIBMOBI-0.12-LGPL-3.0-or-later.txt).
