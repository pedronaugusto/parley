# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/pedronaugusto/parley/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pedronaugusto/parley/releases/tag/v0.1.0
