# BookOrbit compatibility

The first supported server contract is BookOrbit `v2.5.0`.

## Required routes

- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `GET /api/v1/auth/me`
- `GET /api/v1/app-info`
- `POST /api/v1/books/query`
- `GET /api/v1/books/:id`
- `GET /api/v1/books/:id/cover` (bounded to 16 MiB)
- `GET /api/v1/books/files/:fileId/serve`
- `GET /api/v1/books/files/:fileId/progress`
- `POST /api/v1/books/files/:fileId/progress`
- `GET /api/v1/books/:bookId/audio-progress`
- `PATCH /api/v1/books/:bookId/audio-progress`

The client uses the exact field names published by this contract. It does not accept aliases or silently switch to KOReader credentials. A server version outside the certified set disables remote features with an actionable error while keeping local reading available.

## Response shapes used by the clients

`POST /books/query` is zero-based pagination (`pagination.page * pagination.size`
is the server offset). Each `items[]` card supplies `id`, `title`,
`authors: string[]`, and `files[]` references containing `id`, `format`,
`role`, and `sizeBytes`. The mobile clients keep the card as a list item and
fetch the detail endpoint before a download.

`GET /books/:id` returns `title`, `authors` records with the exact `name`
field, and `files[]` detail records containing `id`, `format`, `role`,
`sizeBytes`, `absolutePath`, `createdAt`, `filename`, and `durationSeconds`.
`absolutePath` is server-only and is never used as a local device path; the
client uses `filename` for the local display name and the serve endpoint for
bytes. The server does not provide a content hash, so the client computes
SHA-256 after download.

The app-info response must report the certified string `v2.5.0`. Progress
uploads contain only the documented progress fields and audio saves expect the
server's successful `204` response.

The app-info, auth-token, and library response decoders are fail-closed at the
client boundary: required fields such as `title`, `filename`, `format`,
`sizeBytes`, and `accessToken` must be present, and those decoded objects
reject keys outside the v2.5.0 shape.
The detail-file allowlist includes the documented server-only `absolutePath`
and `createdAt` fields; neither is used as a device path or compatibility
alias. No alternate key, endpoint, or legacy local profile key is supported.

The primary Android Media3 and iOS AVFoundation transports are the only
authenticated BookOrbit Range-stream paths. LibVLC/MobileVLCKit fallback is
local-file-only until a reviewed loopback Range proxy is added; credentials are
never passed to the secondary decoder or placed in a URL.
