# Contract fixtures

These small, synthetic payloads exercise exact field names without containing
credentials, cookies, bearer tokens, real library paths, or copyrighted book
content. They are intentionally versioned with the contract and are suitable
for Android/iOS request-construction tests.

The fixture files are examples, not permissive schemas:

- a request must use exactly the keys shown in the matching contract;
- adding a convenience alias is a contract failure;
- the Wi-Fi chunk example models an actual HTTP request with a fixed 8 MiB
  first chunk: `contentRange`, `chunkIndex`, `chunkSizeBytes`,
  `contentLength`, and `bodyBytes` must agree exactly;
- values such as `percentage` are validated by the client domain model, not by
  this wire-name fixture;
- no fixture is sent to a live BookOrbit server.

The root `scripts/verify-contracts.sh` check validates the three contract files
with strict key, type, value, and duplicate-key checks. Platform tests may load
the examples below to assert request serialization.
