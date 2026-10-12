# Local proxy

Use Node.js 22 or later. Copy `.env.example` to the ignored repository-root `.env` and set your HTTPS API URL and WSS speech URL. Both upstream values are empty in the example. Keep credentials in protected local configuration.

```sh
npm ci
npm start
```

The proxy listens on `127.0.0.1:8787`. HTTP requests go to the configured API base path; WebSocket connections at `/speech` go to the configured speech endpoint. Request and response bodies, including compressed bytes, authorization values and WebSocket messages pass through unchanged. Redirects are returned to the client.

Browser origins must be listed in `ALLOWED_ORIGINS`. Requests from other origins or with a non-local Host header are refused. The proxy forwards only selected HTTP headers, bounds request bodies to 1 MiB and response bodies to 8 MiB, and limits pending WebSocket sends to 1 MiB and 1,024 messages with a five-second progress timeout. Transport failures return fixed errors without logging payloads or credentials.

`GET /health` reports whether upstream configuration is valid. Run `npm test` for the synthetic transport checks.
