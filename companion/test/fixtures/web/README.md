# Web API contract fixtures

One file per case of the `wfsync-web` API (`POST /api/v1/sync`, `GET /api/v1/players`).
The companion's tests replay `response` to the client; the server's tests set up `given`,
send `request` and compare the answer.

- `given.now`: server clock (Unix seconds). `given.players`: stored state per handle.
  `given.lastRequestAgo`: seconds since this token's previous request.
- Tokens: `tok-mf` belongs to `mf`, `tok-lois` to `lois`. Anything else is unknown.
- `request.body` is JSON. `rawBody` is sent as text. `bodyBytes` means a JSON body padded to that size.
- `response.body` is compared as a subset (objects: listed keys only; arrays: equal).
- Errors are always `{"error": "<code>"}`.
