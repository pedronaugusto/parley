# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `Client.Options.validator` and `Server.Options.validator` are required, with no default: every client and server states whether it validates against JSON Schema, `&parley.validation.json_schema` or `null`. Null gives up the checks (a client hands on a server's structured content whatever its output schema says, a server runs a dynamic tool's handler on arguments no schema checked and takes an elicitation's content unchecked); validation is never turned off by a line not written. Migration: add `.validator = &validation.json_schema` (with `const validation = @import("parley.validation");` and the module in the build) or `.validator = null` to each `Client.Options` and `Server.Options`.
- The build options `http`, `process` and `oauth` are gone: `parley.http`, `parley.process`, `parley.oauth` and `parley.validation` are always declared, and uplink, conduit, clearance and strand_schema, lazy dependencies, are fetched with parley and compiled only in a program that imports the module over them. A library's option is a second instance of it for every distinct argument set, which Zig refuses in one program once two dependents differ. Migration: drop `.http`, `.process` and `.oauth` from `b.dependency("parley", ...)`. clearance is taken with its default options (clearance main c278fd1, where `clearance.oauth` is always declared).
- `Server.removeTool` and `Server.removePrompt` take `from`, the call asking when a handler removes one (null outside any call), and return `Server.RemoveError`: `Canceled` and `WaiterLimit`. `Server.removeResource` is unchanged.
- `http.Transport.Authorization`'s `credentials` takes the request's method and URL and returns `Credentials` (`authorization`, and a `dpop` proof), and its vtable gains `nonce`: what a DPoP-bound token needs per request.
- Every interface is embedded: its owner holds it as a field and recovers itself with `@fieldParentPtr`, where a `context: *anyopaque` was cast back. The interface's functions take a pointer to it, an option or a call takes that pointer, and the owner gives it from an accessor (`Stream.sink`, `Channel.transport`, `http.Transport.transport`, `oauth.Authorizer.authorization`, `oauth.Guard.access`). So it goes for `Sink` (its `Target`), `stdio.Out`, `Client.Transport`, `Client.Handlers` (`Client.Options.handlers` is `?*Handlers`), `http.Transport.Authorization`, `http.Endpoint.Access` (`access: ?*Access`), `oauth.Guard.Needs`, `oauth.Authorizer.TokenSource` and `SignIn` (the options hold pointers), `Server.Filter`, `Server.Completer` (`setCompleter(*Completer)`), `Call.TaskHook`, and `ToolHandler`, `ReadHandler` and `PromptHandler` (`addDynamicTool`, `addResource`, `addTemplate` and `addDynamicPrompt` take a pointer the server keeps; `typedTool` and `typedPrompt` give one that lives as long as the program). Each function is named for what it does with `Fn` after it (`sendFn`, `checkFn`, `callFn`), and a method of the same name calls it.
- The endpoints' uplink `Handler`s are embedded the same way, as uplink's `Server.init` takes `*Handler`.
- `Client.serveRequest` and `Client.Exchange.inbound` return `std.Io.Cancelable!Answer`: a handler that was canceled is `error.Canceled`, for the transport to return, where it became a JSON-RPC error sent back to the server.
- `stdio.Out.Error` is `error{ WriteFailed, Canceled }`, and `Out.beginFn` returns an `aegis.io.WriteEnd` (the writer, and why a write to it failed) where it returned the `*std.Io.Writer`. Migration: return `.causeless(writer)`, or `.init(writer, context, failureFn)` with your stream's recorded failure, and give a switch on `Out.Error` a `Canceled` arm.
- `stdio.serve` takes an `aegis.io.ReadEnd` and an `aegis.io.WriteEnd`, and so does `stdio.Channel.init` (`Channel.in` is a `ReadEnd`), where they took `*std.Io.Reader` and `*std.Io.Writer`: an end is the interface and what says why a read or write on it failed. Migration: pass `.fromFile(&reader)` and `.fromFile(&writer)` (or `.fromStream(…)` for a network stream) where `&reader.interface` and `&writer.interface` went, or `.causeless(&reader)` for an end that records no cause.
- `Server.HandleError` and `Call.Error` gain `Closed`: nothing to answer, because the stream the request came on is gone or a stream it opened was ended by its client. Handlers, `Server.notify`, `Call.progress`, `Call.log`, `subscriptions/listen` and the session layer said it with `Canceled`, and stdio's sink said `Canceled` for a request its client canceled; now `Canceled` from a handler always means its task was canceled. Migration: let a sink's `Closed` through (`try` does), and give a switch on either set a `Closed` arm that answers nothing.
- The declarations the two entries above change, by name. Every function that returns `Call.Error` or `Server.HandleError` returns `Closed` too: `Call.elicit`, `Call.input`, `Call.log`, `Call.progress`, `Call.roots`, `Call.runAsTask`, `Call.sample`, `Call.setState`, `Server.capabilitiesJson`, `Server.handle`, `Server.inputRequiredJson`, `Server.notify`, `Server.serve`, `compat.Session.handle` and `compat.Session.stream`; `registry.ownError` returns `Call.Error`. The embedded interfaces lose their `context` field and take the interface's pointer: `Sink` (`Sink.context`, `Sink.sendFn` and `Sink.keepAliveFn` are gone; a sink holds its `target`), `Call.TaskHook` (`Call.TaskHook.become` is `becomeFn`, `Call.TaskHook.context` is gone, and `Call.task` is a pointer), `Client.Transport` (`Client.Transport.context` is gone; `Client.Transport.request` and `Client.Transport.notify` take `*Transport`, as do `Client.Transport.VTable.request`, `Client.Transport.VTable.notify`, `Client.Transport.VTable.opened` and `Client.Transport.VTable.listed`; `Client.init` takes it and `Client.transport` is it), `Client.Handlers` (`Client.Handlers.context` is gone; `Client.Handlers.elicit`, `Client.Handlers.roots` and `Client.Handlers.sample` take `*Handlers`; `Client.Options.handlers` is `?*Handlers`), `ToolHandler`, `PromptHandler` and `ReadHandler`, also named `registry.ToolHandler`, `registry.PromptHandler` and `registry.ReadHandler` (`ToolHandler.context`, `PromptHandler.context`, `ReadHandler.context`, `registry.ToolHandler.context`, `registry.PromptHandler.context` and `registry.ReadHandler.context` are gone; `ToolHandler.call`, `PromptHandler.get`, `ReadHandler.read`, `registry.ToolHandler.call`, `registry.PromptHandler.get` and `registry.ReadHandler.read` are methods over `callFn`, `getFn` and `readFn`; `registry.Tool.handler` and `registry.Prompt.handler` are gone for `handling`, which a `registry.Tool` and a `registry.Prompt` require, and `registry.Resource.handler` and `registry.Template.handler` are pointers), `Server.Filter` (`Server.Filter.context` is gone, `Server.Filter.admit` is a method over `admitFn`, `Server.Options.filter` is a pointer), `Server.Completer` (`Server.Completer.context` is gone, `Server.Completer.complete` is a method over `completeFn`, `Server.completer` and `Server.setCompleter` take a pointer), and `Server.addDynamicTool`, `Server.addDynamicPrompt`, `Server.addResource` and `Server.addTemplate` take the handler's pointer. On `parley.http`: `http.Endpoint.Access` (`http.Endpoint.Access.context` is gone, `http.Endpoint.Access.check` is a method over `checkFn`, `http.Endpoint.Options.access` and `http.SseEndpoint.Options.access` are pointers), `http.Transport.Authorization` (`http.Transport.Authorization.context` is gone; `http.Transport.Authorization.credentials` and `http.Transport.Authorization.refused` are methods over `http.Transport.Authorization.VTable`, whose `http.Transport.Authorization.VTable.credentials` and `http.Transport.Authorization.VTable.refused` take `*Authorization`; `http.Transport.Options.authorization` is a pointer), and the accessors `http.Endpoint.handler`, `http.SseEndpoint.handler` and `http.Transport.transport`, which are methods where they were fields. On `parley.oauth`: `oauth.Authorizer.SignIn` and `oauth.Authorizer.TokenSource` (`oauth.Authorizer.SignIn.context` and `oauth.Authorizer.TokenSource.context` are gone; `oauth.Authorizer.SignIn.open` and `oauth.Authorizer.TokenSource.get` are methods over `openFn` and `getFn`; `oauth.Authorizer.Options.sign_in`, `oauth.Authorizer.Options.assertion`, `oauth.Authorizer.Options.store` and `oauth.Authorizer.Enterprise.subject` are pointers), `oauth.Guard.Needs` (`oauth.Guard.Needs.context` is gone, `oauth.Guard.Needs.scopes` is a method over `scopesFn`, `oauth.Guard.needs` is a pointer), and the accessors `oauth.Authorizer.authorization`, `oauth.Guard.access` and `oauth.ResourceMetadata.handler`. On stdio: `stdio.Out.context` and `stdio.Out.lines` are gone (`stdio.Out.Lines` embeds an `Out` for a writer), `stdio.Out.beginFn`, `stdio.Out.endFn` and `stdio.Out.keepAliveFn` take `*Out`, and `stdio.Connection.init` takes `*Out`; `stdio.Channel.in`, `stdio.Channel.init` and `stdio.serve` take aegis's stream ends, `stdio.Channel.out` is gone (a `stdio.Channel` holds its write end in its guarded `writing`), and `stdio.Channel.transport` is a method.
- A type's shared state is held by an aegis guard, which the type's methods take, where a public lock beside public fields was. Gone: `Server.lock`, `Server.tools`, `Server.resources`, `Server.templates`, `Server.prompts` and `Server.generations` (behind the guarded `Server.lists`); `Sink.End.mutex`, `Sink.End.ended` and `Sink.End.listener`; `compat.Session` (its fields: `compat.Session.mutex`, `compat.Session.arena`, `compat.Session.client`, `compat.Session.client_info`, `compat.Session.lifecycle`, `compat.Session.log_level` and `compat.Session.outgoing`), and `compat.Session.revision` is a method, as are `compat.Session.open` and `compat.Session.initialized`, which take the `Io` and answer under the guard; `stdio.Channel.mutex`, `stdio.Channel.write_mutex`, `stdio.Channel.closed` and `stdio.Channel.ended`, with `stdio.Channel.waiting` guarded; `stdio.Connection.jobs_mutex`, `stdio.Connection.take_mutex`, `stdio.Connection.write_mutex` and `stdio.Connection.ended`, with `stdio.Connection.jobs` and `stdio.Connection.out` guarded; `tasks.Table.mutex` and `tasks.Table.tasks`; `http.Endpoint.sessions_mutex` and `http.SseEndpoint.sessions_mutex`, with `http.Endpoint.sessions` and `http.SseEndpoint.sessions` guarded; `http.Transport.marks_mutex`, with `http.Transport.marks` guarded; and `oauth.Authorizer.mutex`, `oauth.Authorizer.active`, `oauth.Authorizer.issuer` and `oauth.Authorizer.registered`, with `oauth.Authorizer.failure` a method. `tasks.Table.answer`, `tasks.Table.ask`, `tasks.Table.cancelled`, `tasks.Table.complete`, `tasks.Table.fail`, `tasks.Table.find`, `tasks.Table.hold`, `tasks.Table.keepState` and `tasks.Table.sweep` take the table's `*Held`, from its guard.
- A time is an `aegis.units.Instant` (real time, milliseconds) where it was an `i64` of milliseconds: `tasks.Task.created`, `tasks.Task.updated`, `tasks.writeTime`, and the `now` that `tasks.Table.create` and the table's other methods take. A count is an `aegis.Atomic` of an `aegis.units.Count`: `Client.next_id`, `compat.Session.next_id`.
- `tasks.Task.cancel` is an `aegis.Signal(void)` where it was an `Io.Event`: set once, by the task's cancel. `process.Stderr.file` is an `aegis.own.Unowned(Io.File)`: the file is lent, never closed by the stderr it is, and read with `.get()`. `process.Child.kept` and `Server.Content.of` name their types, `process.Kept` and `Server.Content.Of`, now public.
- A task a transport starts and never reads the result of runs in an `std.Io.Group`, which ends it on `cancel` without a result to discard: `http.Transport.stream` and `stdio.Channel.reading` are `std.Io.Group`s where they were `?std.Io.Future`s, and `stdio.Connection.session_stream` is gone, the session's stream running in the connection's own `stdio.Connection.group`, which `finish` waits for and `deinit` cancels, as it does the requests.
- `build.zig.build` returns `error{LazyDependencyNeeded}!void`: it returns `error.LazyDependencyNeeded` once every lazy dependency the modules asked for is marked, as `std.Build.dependencyLazy` says, where it declared the modules without what was not fetched yet and returned `void`. A build that calls it directly `try`s it; the development build asks for its lazy dependencies with `dependency`, which ends the pass the same way.
- `tasks.Task.stop` is called under the table's lock, as every change to a task is: the first stop alone sets the task's cancel.
- `Client.CallError` gains `StructuredContentInvalid` and `OutputSchemaRefused` (a tool's result checked against its output schema, below), and so the errors of `Client.callTool`, `Client.list`, `Client.getPrompt` and `Client.readResource`, which return it.

### Changed

- A task's times (`tasks.writeTime`) are written through almanac's calendar, a new dependency, in place of std's epoch arithmetic: an instant past almanac's last year, 9999, is written as its last instant, where std's arithmetic ran on unchecked.
- Family move, part B: pins aegis f52eabe, the one aegis of the family, and strand main cb3d74c, uplink main e3cd60c, clearance main 61767a3, conduit main 60ee9d6 and shakedown main c29751d, each on it; preflight ci-standard 158c176. uplink's `Method` constants are named in lower case (`.get`, `.post`, `.delete`); a session's event stream is read through the response's `readEnd`, where a canceled read is `error.Canceled` itself; a child's standard error file goes to conduit as the `aegis.own.Unowned` handle parley holds; the token store's `forget`, now cancelable, passes a cancel on.
- aegis 0.3: contracts are `assert.invariant` where `assert.pre` and `assert.post` were, and a listener waits on its ordered guard (`held.wait(&condition, io, deadline)`). Pins aegis breaking-0.3 (7bdb587), and strand, uplink, clearance, conduit and shakedown on it. A child's stderr, which conduit now lends as the `std.Io.File` itself, is read without `.get()`.
- Pins aegis 525f909, whose `io.ReadEnd` and `io.WriteEnd` are the stream ends `stdio` takes.
- Mixed operators are parenthesized where Zig master refuses them as ambiguous (`x catch … orelse y`): the parentheses say what Zig 0.17 already did, and nothing changes at runtime.
- An error with nowhere to go is logged (scope `parley`, as a warning) where it was dropped: a frame of a server's (`stdio.Channel`) or an event of a session's stream (`http.Transport`) passed over for want of memory, a session stream never read for want of memory, a server `process.Child.spawn` or `process.Child.deinit` could not end, and a read of a kept standard error that failed other than at its end.
- A claim the code makes where an error cannot come is checked in every build (`aegis.assert.never`), where `catch unreachable` was undefined behaviour in a fast build: a counted body that fits, a task's or a session's state checked under its lock, a signal set once under its lock, a secret allocated to its length.
### Fixed

- A tool or a prompt removed while a call ran its handler was freed under it: a typed handler lives in the entry, and a call held a pointer into it past the server's lock (`tools/call`, a task's round, `prompts/get`). A remove now unlinks the entry and frees it when the last call that found it ends. From outside any call it waits for that, so once it returns no call runs the handler and an application may free one it owns; canceled while it waits, it returns `Canceled` with the entry unlinked, and the last call to end frees it. From inside a call it never waits, for its own entry or another's, so two handlers removing each other's tools cannot wait in a cycle, and a handler may remove its own.
- HTTP+SSE: a POST arriving while its stream's `endpoint` event was still being flushed answered on the stream at the same time as the GET's flush (a data race ThreadSanitizer found); a POST now waits until that event is written.
- A cancel is returned as `error.Canceled` where it was taken for something else. A call canceled while the application answered the server's input sent the server an error and carried on to its next round; it now ends with the cancel, as does the stdio channel's reading and the HTTP transport's session stream. A call canceled while its answer's event stream was read came back `Closed`, and the session stream ended as if the server closed it. On the server side, `http.Endpoint` and `http.SseEndpoint` handlers whose task was canceled (a server stopping) returned as if done, so uplink ended the response as an empty 200 and kept reading the connection; they now return `error.Canceled`, and the connection ends unanswered.
- A request answered on the task that reads it (a session's handshake, log level and subscriptions always; any request when no task is free) took a cancel of that task for the request's own: `stdio.serve` read on, and `stdio.Connection.take` returned as if answered. Both now return `error.Canceled`, as they do when an answer or a batch's array is canceled while it waits for its turn on the stream. A batch request answered on an `http.Endpoint` connection's task, and a task's round run on the `tasks/update` request's task, likewise return the cancel where they answered as if done (the task ends cancelled). `http.Endpoint`'s and `http.SseEndpoint`'s streams return a cancel that lands as the response ends. `process.Child.spawn` reaps a half-started child with cancels held off, so the child is never left running and the cancel lands at the caller's next cancelation point.
- A canceled write to a stream parley was handed came back as the stream broken, and the cancel was spent. `stdio.Connection` asks its `Out` why a write failed: an HTTP+SSE POST answered on its own task (a session's handshake, log level, subscriptions) whose answer's write to the stream was canceled answered 202 as if it went out; it now returns `error.Canceled`, unanswered. `stdio.serve` asks its ends the same: an answer on its own task whose flush to stdout was canceled was taken for a broken stream and `serve` read on with the cancel spent, and a canceled read of stdin was `ReadFailed`; both now end `serve` with `error.Canceled`. A `stdio.Channel` write that was canceled (`process.Child`'s, to the server's input) came back `Closed`; it is `Canceled`, and the channel's reading returns it when it was answering a request of the server's.
- Out of memory is no longer taken for input that does not read: a `notifications/cancelled` the server could not read for want of memory (`stdio.Connection`), a `tools/list` entry, a marked argument or an event in a request's stream (`http.Transport`) now return `error.OutOfMemory`, where they were passed over as malformed.
- A task whose round's outcome could not be recorded for want of memory, and whose failure could not be either, stayed working until its time ran out; it now fails as out of memory, which needs no memory (`tasks.Table.failOutOfMemory`).
- An answer to a request of the server's that could not be copied for want of memory left its request to time out as refused (the session layer) or timed out (`stdio.Channel`); the request now fails with `error.OutOfMemory` at once.
- A `stdio.Channel` request canceled or timed out tells the server with `notifications/cancelled` written straight to its input, so a string id of any length is told, where one past 128 bytes was not; a cancel landing while it is told is returned as `error.Canceled`, where it was spent and `TimedOut` returned.
- An elicitation form's property whose name was over 256 bytes got no default filled; every property's does now.
- A request answered on `stdio.serve`'s own task whose handler had nothing to answer (a progress report to a stdout that is gone, a `subscriptions/listen` its client ended) ended `serve` with `error.Canceled`, as if its task were canceled; `serve` now reads on. `http.Endpoint` likewise returns without an answer for it, where it returned `Canceled`, and a canceled write of an event to a request's stream is `Canceled`, where it was the stream gone.


### Added

- `tasks.Table.failOutOfMemory`: fails a task as out of memory without allocating, its message and outcome constants the task marks as its own (`tasks.Task.failed_for_memory`), which nothing frees.
- JSON Schema validation on both sides, through a validator the application gives (`parley.Validator`, a pointer and its functions, as `std.mem.Allocator` is): `parley.validation.json_schema`, in the new module `parley.validation`, is strand_schema's (github.com/pedronaugusto/strand-schema 97cf747, a new lazy dependency, on strand main 7658e11, now parley's pin), every `format` asserted. The client checks a tool call's `structuredContent` against the `outputSchema` its `tools/list` gave (MCP: a client SHOULD): a result that is not valid, or has no structured content though the tool has an output schema, is `error.StructuredContentInvalid`, and an output schema that does not compile `error.OutputSchemaRefused`, each with why in `Diagnostics.schema`; a `pattern` strand_schema cannot run in linear time is left unchecked and named in `ToolOutcome.unchecked`; an error result is not checked. The server checks the arguments of a tool whose input schema it was given (`addDynamicTool`, or `ToolSpec.input_schema` stricter than a typed tool's type) before its handler runs, a refusal answered as an execution error (`invalid arguments: ...`), as an argument its type does not decode is; a given schema that does not compile is `AddError.InvalidSchema`. `Call.elicit` checks an accepted form's content against its `requestedSchema`: content it refuses is `InvalidInput`.
- DPoP (RFC 9449), MCP's `auth/dpop` and `auth/dpop-nonce`: `Authorizer.Options.dpop` asks for tokens bound to a key, with a proof on every token request and on every request a bound token goes on, and a nonce a token endpoint or MCP server asks for sent back. `oauth.Guard` takes DPoP tokens when its verifier does, answering with `DPoP-Nonce`.
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
