# Wi-Fi transfer

Both apps expose the same foreground-only local receiver. The receiver binds to a local interface, creates a 128-bit random bearer token valid for 10 minutes (or until shutdown), and shows a QR code containing the upload URL. A browser on iOS, Android, macOS, Windows, or Linux can upload files without installing a sender app.

Each newly created upload also receives a separate 256-bit `resumeToken`. The receiver keeps only its SHA-256 digest; the sending browser stores the plaintext with its `uploadId`. After a receiver restart, the user scans the new QR code to obtain a fresh bearer and the sender presents both that bearer and `X-Papria-Resume-Token`. This permits resume for the 24-hour temporary-file retention window without persisting or reusing an expired QR bearer.

## Upload lifecycle

1. `POST /api/uploads` creates an upload session with `fileName` and `sizeBytes`, returning `uploadId` and `resumeToken`.
2. The browser sends sequential 8 MiB chunks to `PUT /api/uploads/:uploadId/chunks/:chunkIndex` with `Content-Range`.
3. `GET /api/uploads/:uploadId` returns the next accepted chunk for resume.
4. `POST /api/uploads/:uploadId/complete` hashes and atomically imports the completed file.
5. `DELETE /api/uploads/:uploadId` removes an abandoned session.

The local receiver never calls BookOrbit upload endpoints. Imported files remain local-only and use the same content-addressed store as downloaded BookOrbit files.

## Security requirements

- The QR bearer expires and the listener shuts down when the transfer screen closes. A resume also needs the per-upload resume token; knowing an upload ID or scanning a new QR code alone is insufficient.
- No public-interface binding or WAN exposure.
- Streaming writes to temporary files.
- Path normalization, archive limits, free-space checks, and SHA-256 deduplication.
- No token in server logs or persistent application state.
