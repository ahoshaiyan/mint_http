## [Unreleased]

## [1.2.0] - 2026-10-05

Connection reliability fixes. Before these, successful calls could fail, hang, or receive another request's response. There are no breaking changes: methods, raised exceptions, requests sent and defaults are unchanged, and the new behaviours are opt-in.

- Pool health checks no longer read sockets that other threads are using. This stopped the pool from freezing under concurrency and fixed ReadTimeouts on responses that had already arrived.
- Health checks never block or raise, and idle connections with unread data are discarded.
- Interrupted requests (`Timeout.timeout`, `Thread#raise`, Rack::Timeout) never return their connection to the pool.
- Interrupts can no longer leak pool slots: connections left checked out by a dead thread, or by an interrupt landing right after check-out, are reclaimed.
- The caller's `Thread.handle_interrupt` mask is respected.
- Interrupts that are `StandardError`s, such as Rack::Timeout's, are never swallowed by MintHttp's internal error handling (health checks and logging).
- Pool waiters are served first come, first served and are woken as soon as a connection is released, instead of sleeping and polling.
- A full pool closes idle connections to other hosts instead of making requests to a new host wait and time out.
- The pool is fork-safe.
- Pool timeouts raise `MintHttp::PoolTimeoutError`, a `RuntimeError` with the same message as before.
- Connections are no longer shared between requests with a different CA, TLS min/max versions or proxy password, and client certificates are identified by fingerprint.
- Request logging can no longer fail a request. Binary or non-UTF-8 bodies are logged as `[BINARY n bytes]` or transcoded from their charset.
- Logs are not built when nothing would be written (the default `/dev/null` logger).
- Logs record interrupted requests and retries.
- `filter_param` no longer appends duplicates to `MintHttp.config.filter_params_list` (it grew on every request).
- Filtered params are redacted from query strings and form bodies in logs, including bracketed keys such as `source[number]`.
- New, opt-in: `MintHttp::Pool.new(retry_stale: true)` sends safe requests once more on a new connection when a reused connection turns out to be closed by the server. This covers `GET`/`HEAD`/`OPTIONS`, and other methods only with an `Idempotency-Key`/`X-Idempotency-Key` header.
- New, opt-in: `raise_on_truncated_body` raises `MintHttp::ProtocolError` when the connection closes before the whole body arrived.

## [1.1.2] - 2025-05-27

- Log local and remote addresses

## [1.0.1] - 2025-05-26

- Add SSL min and max version support

## [1.0.0] - 2024-11-05

- Improve error handling by introducing new error base class that makes it easy for users to catch and deal with errors.
- Add more HTTP error classes.


## [0.1.12] - 2024-10-13

- Fix Logging when server returns a UTF-8 response with invalid encoding set in header


## [0.1.0] - 2023-07-03

- Initial release
