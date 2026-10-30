# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Mixed operators are parenthesized where Zig master refuses them as ambiguous (`x catch … orelse y`): the parentheses say what Zig 0.17 already did, and nothing changes at runtime.

## [0.8.0] - 2026-10-28

### Breaking

- 2025-03-26 and 2024-11-05 are served through the session layer: `Revision` gains `@"2025-03-26"` and `@"2024-11-05"` (and `batches()`), `server/discover` and the version refusal name the five revisions served, and `Client.Options.revisions` offers all five by default. Nothing is down-levelled: fields the older revisions lack go out as they are.

### Added

- JSON-RPC batches where the revision has them (2025-03-26, 2024-11-05), read by one decoder (`wire.decodeBatch`; `wire.decodeFrame` for a frame that is one message or a batch; each `wire.Element` keeps the bytes it was written as): a session takes one on stdio and Streamable HTTP, refuses `initialize` inside one, and answers its requests as one array (Streamable HTTP: 202 when it holds no request, else one JSON array or one event stream). The client takes a server's batch and answers its requests as one array (`Client.Replies`); it sends none of its own.
- `parley.http.SseEndpoint`: 2024-11-05's HTTP+SSE transport on the server's side, behind the session layer. A GET opens a session and its stream, whose `endpoint` event names where to POST; each POST is answered 202, its answer sent on the stream.
- `stdio.Connection` and `stdio.Out`: the connection `serve` reads line by line, for a transport whose messages come and go in other frames (`take` one message, `finish`, `keepAlive`); HTTP+SSE is one.
- The fixture server serves HTTP+SSE at `/sse` beside `/mcp`.

## [0.7.0] - 2026-10-25

### Breaking

- `Client.Transport.VTable.opened` returns `Io.ConcurrentError!void`, and `Client.connect` returns its `ConcurrencyUnavailable`: an HTTP session whose `Io` gave no task for its GET stream connected without it, and missed every request and notification the server sent outside a request.
- `stdio.serve` returns `ConcurrencyUnavailable` when a session opens and the `Io` gives no task to send its list changes on, where it served on and the client never heard of them. Requests are still answered inline when no task is to be had.

## [0.6.0] - 2026-10-21

### Breaking

- Pins clearance 0.4.0, uplink 0.8.7, conduit 0.10.1 and aegis 0.1.14 (were 0.3.0, 0.8.2, 0.8.5 and 0.1.11): a build with parley moves to cloak 0.19's line through them, and `parley.oauth`'s signers take cloak 0.19's `PrivateKey`. A private JWK now signs a client's assertion (`clearance.jws.Signer.fromJwk`).

### Fixed

- The process tests failed on every macOS and Windows leg (`FileNotFound`): they were given the fixture server's path in the building runner's cache, which a runner replaying them has not. The fixture is named through preflight 0.13.0's `addTestProgram`, by its path from the package root, and replays with the tests; the benchmarks' fixture likewise, under its own name.
- The stdio test of a stream ended by its client's cancellation changed the tools before the server had read the cancellation, so the still open stream was told of the change first (6 of 15 runs in ReleaseFast under load): it now waits for the next request's answer, which follows the cancellation in reading order.

## [0.5.2] - 2026-10-17

### Added

- `Sink.end` (`Sink.End`): a transport ends a stream a request opened by an explicit act, never by canceling its task. stdio ends a `subscriptions/listen` stream when its client cancels it or the input ends, and the session's stream at the input's end, then waits for each to return; HTTP ends a `subscriptions/listen` stream when its client leaves, and a session's GET stream when the session is deleted (it ran on until the server closed). A lost cancellation can no longer hang a stream at shutdown.

## [0.5.1] - 2026-10-17

### Added

- `parley.oauth.Authorizer` grants `.enterprise` and `.jwt_bearer`. `.enterprise` is MCP's enterprise-managed authorization: the user's token at the enterprise's identity provider (`Options.enterprise`: its issuer, its token endpoint or discovery, the client there, the token as a `TokenSource` the application keeps) exchanged for an ID-JAG naming the authorization server, the client and the resource, which the authorization server redeems for the access token; no sign-in, and a step-up is a new exchange for the wider scope. `.jwt_bearer` presents a workload's identity token (`Options.assertion`) as the grant, with the client registered beforehand or none. Conformance: `auth/enterprise-managed-authorization` and `auth/wif-jwt-bearer` pass at both revisions (not scored); every scored client scenario is unchanged.
- A secret registered beforehand is also sent as `client_secret_jwt` where the server lists only that.

### Changed

- `parley.oauth` pins clearance 0.3.0.

## [0.5.0] - 2026-10-17

### Breaking

- `http.Transport.init` takes `Options`; its `authorization` gives each request its credentials and answers a 401 or 403 (`parley.oauth.Authorizer` is one). A refusal that stands is `Client.RequestError.Unauthorized`, which `Client.connect` returns instead of trying a session.
- `http.Endpoint.Options.principal` is `access`: an `Access` checks every request (POST, GET and DELETE) before anything else is read of it, and admits it for a principal or refuses it with a status, a `WWW-Authenticate` challenge and a body (`parley.oauth.Guard` is one).
- `Server.Reply.result` is a `Server.Body`, not bytes: a tool's result and a resource's contents are counted when the reply is made (one past the message limit is still refused before a byte goes out) and written from what the handler returned as the transport writes the answer (`Body.write`), so the answer holds no copy of them; every other result is `.json`. `Body.whole` makes one whole on an arena.

### Added

- `parley.oauth` (build option `oauth`, on by default with `http`; fetches clearance): MCP's authorization. `Authorizer`, a client's side: on a 401 or a 403 `insufficient_scope`, the resource's metadata (RFC 9728) from the challenge or its well-known locations, its `resource` held to the server's URL, the authorization server's metadata, the client as that server knows it (registered beforehand, a client ID metadata document, or registered now with RFC 7591 as a `native` or `web` application), the scope (the challenge's, else the resource's, what was granted before kept, `offline_access` where listed), and the tokens: kept ones, a refresh, a sign-in (the authorization code with PKCE, RFC 8707's resource, RFC 9207's `iss`), or the client's own credentials (`client_secret_basic`, `client_secret_post`, `private_key_jwt`); a token store between runs; a server that changes forgets what the old one issued. `Guard`, a server's side: an endpoint's `access` holding every request to a bearer token for this resource (a JWT against the authorization server's keys, or introspection) and the scopes it needs, 401 and 403 with the challenge. `ResourceMetadata`: the resource's metadata document and where it is served. Conformance: both client legs' `auth/*` scenarios pass (25 at 2026-07-28, 14 at 2025-11-25), and the client credentials ones (not scored).

### Changed

- A large message costs about its own size: stdio reads each line onto the allocator, not the request's arena (whose growth kept every size the line passed through), and HTTP its body; stdio and HTTP write an answer straight to the stream (as JSON of its declared length, or as the stream's last event through uplink's `wire.sse.EventWriter`) instead of framing a copy. A 64 MiB echo over stdio peaks at 82 MiB on macOS, from 297 MiB.
- Pins uplink 0.8.2 (`wire.sse.EventWriter`); `parley.oauth` pins clearance 0.2.3.

### Fixed

- A tool result or resource past one of strand's limits inside the message limit (a string longer than it) was answered "out of memory"; it is answered as past the message limit.

## [0.4.0] - 2026-10-17

### Breaking

- One message limit governs every read and write: `Server.Options.limits.message` (and `Client.Options.limits.message` on the client side), 16 MiB by default. The transports read it (`stdio.Options.max_message`, `http.Endpoint.Options.max_body` and `stdio.Channel`'s options are gone; `Channel.init` takes no options, `process.Options.channel` is gone), and every decode takes strand's limits from it through `wire.limitsFor`: the envelope, params, a tool's arguments, `_meta`, the client's reads of results. Before, a message within a raised limit was refused "past a limit" by strand's 16 MiB defaults inside it. An answer longer than the limit is answered with an internal error rather than written.
- `wire.DecodeOptions.limits` is required; `wire.idFrom`, `meta.read`, `types.ClientCapabilities.hasExtension`, `registry.headerParams`, `registry.list*`, `tasks.Table.answer` take the limits; `types.read_options` and `types.write_options` are `types.readOptions(limits)` and `types.writeOptions(limits)`; `Server.notify` is a method; `Client.Transport.VTable.listed` takes the client.

### Added

- `wire.limitsFor`, `wire.default_message`, `Server.jsonLimits`, `Client.jsonLimits`, `Client.Limits`; `Call.limits` for a handler that reads a value it is given.

### Fixed

- stdio refused a line exactly as long as its limit.

## [0.3.1] - 2026-10-17

### Changed

- Pins conduit 0.8.5 (`Child.memory`, which the benchmarks read a server's memory with) and, for development, shakedown 0.4.10 (latency rows).
- The benchmarks drive a server process as a client does, over stdio and Streamable HTTP, in both eras: cold start, `tools/list` of 100 tools with large schemas and an echo call (each request timed alone: p50 and p99), a `ping`, an echo and a cancellation beside a long call, and TM Dev Lab's MCP workload (50 clients at once, a session per call); `parley-bench memory` reads the server's memory at rest and after a large message. Any server that takes the fixture server's arguments is measured the same way: `parley-bench -- <server>`. The fixture server serves over HTTP too (`--port`), on a reactor runtime.

## [0.3.0] - 2026-10-17

### Breaking

- `parley.http` is on uplink 0.8.0, whose TLS options name cloak 0.14's types: a program that pins uplink pins 0.8.

### Changed

- Pins uplink 0.8.0 (`Request.gone`; cloak 0.14 under it).

### Added

- `parley.process` (a module of its own, on conduit, fetched only when built; `.process = false` leaves it out): `Child.spawn` launches an MCP server as a child process with a `parley.Client` on its standard streams; `Child.close` ends it as stdio's shutdown says (its input closed, a grace to exit, then asked to stop, then killed), and what the server started ends with it unless `Options.descendants` says otherwise; its standard error is this process's, the null device, a file, or its latest bytes kept (`Child.stderrTail`).
- `parley.http`: a 2026-07-28 request whose client closes its stream is canceled while its handler runs (the revision's cancellation over HTTP), not only at its next write: the handler runs beside uplink's `Request.gone`. The session era keeps a disconnect apart from a cancellation, as its revisions say.
- `stdio.Channel.end`: nothing more is written, so the stream under it can be closed while answers already asked for are read.

## [0.2.0] - 2026-10-17

### Breaking

- `registry.freeHeaderParams` frees the slice `headerParams` returned too; the caller freed it apart.
- `Server.AddError` has `TasksNotServed`: a tool that may run as a task, on a server without `Options.tasks`.

### Fixed

- `registry.headerParams` kept the marks it had found when it refused a schema: a client listing a server's tools lost memory with each input schema it refused.
- stdio: `logging/setLevel`, `resources/subscribe` and `resources/unsubscribe` are answered before the next line is read, so the requests after them find them applied (a tool's log line sent right after `logging/setLevel` could be dropped).

### Added

- The tasks extension (`io.modelcontextprotocol/tasks`), both sides. Server: `Options.tasks` (how many held, their time to live, the poll interval), `ToolSpec.task` (`forbidden`, `optional`, `required`), `Call.runAsTask` (the call answered with a task, the handler going on as it), `tasks/get`, `tasks/update` (input given, the handler run again with it), `tasks/cancel`, task statuses on `subscriptions/listen` (`taskIds`, `notifications/tasks`), `-32021` for a required-task tool or a task method asked by a client that did not declare it, `Mcp-Name` held to the task's id over HTTP. Client: `Options.tasks` declares it; a tool call answered with a task is polled to its end, its input given, and returned as if answered at once. The conformance server's task fixtures; the suite's ten tasks scenarios pass.
- `Server.Limits.quiet_rounds`: rounds a task's handler may run back to back asking for nothing.
- Properties, fuzzed, over the header values a peer sends (the Base64 sentinel) and over the `x-mcp-header` marks of any input schema.

## [0.1.0] - 2026-10-17

### Added

- `Server`, the core: a 2026-07-28 request answered from what it carries (`serve`: the `_meta` version, client capabilities and identity; `-32602` without them, `-32022` naming the versions served), one reply per request. `server/discover`; tools, resources, resource templates (RFC 6570) and prompts, listed in the order they were added, a page at a time with cursors refused once their list changed, with `ttlMs` and `cacheScope` set per list; `completion/complete`; progress and per-request log lines on the request's stream; `subscriptions/listen`, acknowledged, tagged, and fed by coalescing per-stream flags.
- Tools typed by their handlers: input and output JSON Schemas derived from the argument and result types at compile time (`strand.json.schema`), arguments decoded into them (a bad one an error the model reads), structured results; dynamic tools and prompts with schemas of their own, kept byte for byte.
- Input across rounds (multi round-trip requests): `Call.elicit`, `sample`, `roots`, `error.InputRequired`; the handler's state sealed with XChaCha20-Poly1305, bound to the principal, the method, the tool, prompt or resource and an expiry (`state.Sealer`); `-32021` naming a capability the client did not declare.
- `compat.Session`: the session revisions (2025-11-25 and 2025-06-18) above the core: `initialize`, `ping`, `logging/setLevel`, `resources/subscribe` and `unsubscribe`, input asked as the server's own requests, list changes and resource updates on the session's stream.
- `stdio.serve`: a server over stdio, one message a line, a task per request, `notifications/cancelled`, both eras.
- `Client`: era detection (`server/discover`, else `initialize`), requests with their `_meta`, input answered by the application's handlers and retried, a session server's requests answered, form defaults applied; `stdio.Channel`, its transport over a process's streams.
- `parley.http`, Streamable HTTP on uplink: `Endpoint` (Host and Origin checked, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and `x-mcp-header` arguments held to the body, JSON or an event stream, sessions with their GET stream and DELETE) and `Transport`, the client's side (the same headers sent, a session's stream read and resumed).
- `conformance/server.zig` and `conformance/client.zig`, what the official conformance suite drives.
- `wire`: JSON-RPC 2.0 as MCP speaks it. `decode` reads a message's envelope and tells a request, a notification, a result and an error apart, leaving `params` and `result` as their bytes; a refusal names its code and, when it could be read, the id. `writeRequest`, `writeNotification`, `writeResult` (and `beginResult`/`endResult` around a result written in place) and `writeFailure`.
- `Revision`: the protocol revisions parley speaks.

[Unreleased]: https://github.com/pedronaugusto/parley/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/pedronaugusto/parley/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/pedronaugusto/parley/compare/v0.5.1...v0.7.0
[0.5.1]: https://github.com/pedronaugusto/parley/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/pedronaugusto/parley/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/pedronaugusto/parley/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/pedronaugusto/parley/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/pedronaugusto/parley/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/pedronaugusto/parley/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pedronaugusto/parley/releases/tag/v0.1.0
