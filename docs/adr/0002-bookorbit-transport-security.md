# ADR 0002: BookOrbit transport security

## Decision

BookOrbit remote login, listing, downloads, and progress synchronization use
HTTPS by default. A self-signed HTTPS host may be used only after the user
confirms the current host's SHA-256 leaf-certificate fingerprint. The
fingerprint is scoped to that host and never enables a trust-all manager.

The client also supports a deliberately narrow LAN-only HTTP path: the user
must explicitly confirm the current private-network or `.local` host, and the
confirmation is persisted only as non-secret host metadata bound to that exact
server profile. Public HTTP hosts, unconfirmed profiles, and host mismatches
fail closed; background workers may reuse only a profile that already passed
the same bound confirmation check.

Android's Network Security Config cannot express a user-selected host and port
at runtime. The installed configuration therefore exposes only the platform
capability required by OkHttp; `BookOrbitClient` is the authorization boundary
and requires a private/LAN host, the exact persisted host-and-port confirmation,
and the platform cleartext policy on every exchange. Its network interceptor
repeats the check after redirects, so the confirmation cannot escape its
origin. HTTPS remains the default and no other cleartext path may reuse this
client without that boundary.

## Consequences

- Local reading, local progress, and Wi-Fi transfer remain available when a
  BookOrbit server cannot be used.
- Android and iOS share the same host-bound confirmation policy. Android's
  static platform capability never grants a user-selected host permission;
  only the client-side exact host-and-port check does.
