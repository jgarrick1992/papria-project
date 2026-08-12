# Security policy

## Reporting a vulnerability

Do **not** open a public issue for a suspected vulnerability, and do not send
books, access tokens, refresh cookies, QR URLs, archives, or personally
identifiable data through an issue.

The only reporting route is GitHub Private Vulnerability Reporting (PVR):

`https://github.com/jgarrick1992/papria-project/security/advisories/new`

Do not use public issues, pull requests, or any other channel for security
reports. PVR must be enabled in the repository's Security settings for this
link to accept reports.

A useful report contains the affected version/commit, platform and device,
minimal reproduction steps, impact, and whether credentials, local Wi-Fi
transfer, archive parsing, or BookOrbit synchronization are involved. State
whether a proof of concept includes private content and ask for an encrypted
transfer route before sending it.

## Disclosure handling

Reports may be reviewed at the maintainer's discretion. If a fix is prepared,
keep the report private and use a GitHub security advisory for disclosure;
credit reporters only with their permission. No response time or security-fix
commitment is implied.

## Local transfer security

The Wi-Fi receiver is intended for a trusted local network. It must bind only
to the local interface, require an expiring random token, reject path
traversal, stream to temporary files, and shut down when the transfer screen
closes.
