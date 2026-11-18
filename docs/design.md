# parley's design

The design as built: how parley serves and speaks MCP, and why. The API and usage are in the README.

## Decisions

- **2026-07-28 is the core, stateless; the older revisions are a session layer above it.** 2025-11-25,
  2025-06-18, 2025-03-26 and 2024-11-05 are served by `compat.Session` (the `initialize` handshake); an
  `initialize` for another version is answered with 2025-11-25. Claude Code probes `server/discover` and falls
  back to `initialize`; Codex sends `initialize` 2025-06-18 only; SDK clients pinned to the two oldest still ship.
  A server that answered only the new revision would serve none of them.
- **No down-levelling.** Fields an older revision lacks (`structuredContent`, `outputSchema`, `title`,
  `resource_link`, `_meta`) go out as they are, as the TypeScript SDK does; elicitation stays gated on the
  client's declared capability. Batches exist only where the revision has them (2025-03-26, 2024-11-05), through
  one decoder bounded by the message limit and the in-flight cap.
- **One request, one response.** The core maps one decoded request to one response and the notifications that
  belong to it, and holds no connection state: the revision's own rule, and what makes the core testable without
  a transport and fast to fuzz.
- **One handler model for input: multi round-trip.** A handler that needs elicitation, sampling or roots returns
  "input required"; the 2026 core sends that as the result, and the session layer asks the client itself, gathers
  the answers and calls the handler again. Two ways of asking would be two code paths in every tool. The state a
  handler keeps across rounds is sealed by the server (keyed to the principal, the method, the request and an
  expiry), so a client can neither read nor change it; a bad one is `-32602`.
- **Schemas come from Zig types**, at comptime, from the same type policy that encodes and decodes them
  (strand_schema), so a tool's schema is true of what it reads. A hand-written schema is kept byte for byte. A
  typed tool's arguments decode into its parameter type; a decode failure is a tool execution error the model can
  correct, not a protocol error. Validation against a schema is a `Validator` the caller gives
  (`parley.validation` has strand_schema's); a remote `$ref` is never followed.
- **Modules over lazy dependencies.** `parley` needs std, aegis, strand and almanac; `parley.http` adds uplink,
  `parley.process` conduit, `parley.oauth` clearance, `parley.validation` strand_schema. Every module is always
  declared and every lazy dependency asked for, so a stdio server compiles none of uplink, cloak, warp or
  reactor. A choice is the program's imports, never a build option.
- **Io is the caller's.** Every blocking call takes `io`; parley stores none and runs no loop of its own. A
  request runs as a task in its connection's group (`io.concurrent`), so a long tool never blocks a
  cancellation, a ping or another request; one writer lock per connection writes a message whole. No `io.async`.
- **One change channel.** `subscriptions/listen` fans out list changes and resource updates; the legacy
  notifications and `resources/subscribe` are listeners on it. Pending changes coalesce (a flag per kind, a
  bounded set of URIs per listener), which is correct because each one means "fetch again", and a slow reader
  costs no queue.
- **Authorization is clearance's.** parley holds MCP's binding (which resource, which scopes, the probe) over
  clearance's OAuth client; a server is a resource server with a verifier the caller supplies.
- **Every limit is finite**, an aegis quantity in `Options`, raised explicitly: one message limit that bounds
  every read, decode and answer either way (strand's limits derived from it), in-flight requests, listens, input
  requests, state size and lifetime, legacy sessions, timeouts, tasks.
- **Not built:** HTTP+SSE's client side, a legacy server's SSE resumability, 2025-11-25's experimental tasks
  (the tasks extension replaces them), network `$ref`, a WebSocket transport (no spec).

## How it behaves

**One request, one reply.** `Server.serve` answers a 2026-07-28 request from
what it carries: its `_meta` names the protocol version and the client's
capabilities (a request without them is refused, `-32602`; a version not
served, `-32022` with the versions that are), and nothing is kept between
requests. A request's notifications (progress, log lines when its `_meta` asks
for them) go to a sink the transport gives, the request's own stream. Every
result carries `resultType`; `server/discover`, the lists and `resources/read`
carry caching hints (`ttlMs`, `cacheScope`), set per list in `Server.Options`.
Lists are written in the order their items were added, a page at a time when
`page_size` is set, each item's JSON made once when it is added; a cursor into
a list that changed since is refused.

**Input across rounds.** A handler that needs the user (an elicitation), the
client's model (sampling) or its roots asks through its `Call` and returns
`error.InputRequired`; the client is asked for everything recorded at once and
retries with the answers. What the handler keeps between rounds
(`Call.setState`) travels with the client sealed with XChaCha20-Poly1305 under
the server's key, bound to who asked, the method and the tool, prompt or
resource, and an expiry: it can be neither read, changed nor replayed on
another request. Asking a client for what it did not declare is `-32021`,
naming the capability.

**Tasks.** A server given `Options.tasks` serves the tasks extension
(`io.modelcontextprotocol/tasks`). A tool registered with `.task = .optional`
or `.required` may run as a task: its handler calls `Call.runAsTask`, the call
is answered with the task at once, and the handler goes on as it; the client
polls `tasks/get` for its status and outcome, gives the input it asks for with
`tasks/update` (the handler runs again with the answers, as a retry would) and
stops it with `tasks/cancel`. A `subscriptions/listen` stream that names tasks
carries their statuses. Input asked before `runAsTask` is the call's own
rounds. A task's id is 128 random bits and only the principal that made it
sees it; tasks are held up to `max`, each for `ttl` from its creation. A
client that did not declare the extension gets the call answered as asked, or
`-32021` for a tool that must run as a task.

**The session revisions.** An `initialize` without a 2026-07-28 `_meta` opens a
session (`compat.Session`): the process on stdio, an `Mcp-Session-Id` over
HTTP. The session holds what a modern request would carry, and answers what
only those revisions have: `ping`, `logging/setLevel`, `resources/subscribe`.
Input a handler asks for goes to the client as the server's own requests
(`elicitation/create`, `sampling/createMessage`, `roots/list`), and the
handler is called again with the answers. A handler is the same in both eras.
An `initialize` for a version parley does not speak is answered with
2025-11-25. A session at 2025-03-26 or 2024-11-05 takes a JSON-RPC batch, read
by one decoder (`wire.decodeBatch`) and bounded as single messages are:
`initialize` inside one is refused, and the answers to its requests go back as
one array (one line on stdio; over Streamable HTTP a 202 when it holds no
request, else one JSON array or one event stream). Nothing is down-levelled
for the older revisions: fields they lack go out as they are, as the
TypeScript SDK sends them.

**Changes.** A tool, prompt or resource added or removed, or a resource
updated, is told to every open `subscriptions/listen` stream that asked for
it, and to every session's stream. A change never queues: each stream keeps a
flag per list and a bit per watched resource, so a slow reader costs the same
however many changes it misses.

**Limits.** One message limit, `Server.Options.limits.message` (16 MiB by
default; `Client.Options.limits.message` on the client), bounds every message
either way: what a transport reads (a longer line or body is refused unread),
every read of a value within it (strand's limits grow with it, so a raised
limit is never undercut by a default inside it), and every answer written (one
past it is answered as an internal error instead).

**stdio.** One message a line. Each request is a task of its own: a long tool
holds up nothing behind it, and `notifications/cancelled` cancels its task,
after which nothing more is written for it. A line past the message limit
is refused and the next one read. At the end of input the requests read are
answered and the streams ended.

**Streamable HTTP.** One endpoint, POST. A request's `Host` and `Origin` must
be this machine's (or listed): a page another site serves cannot reach a local
server. `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` are held to the
body (`-32020`, a 400), `Mcp-Name` read through the Base64 sentinel. An answer
is JSON, or an event stream once the request has something to say before its
result; a `subscriptions/listen` stream is kept open by a comment every
`keep_alive`. A client that closes its stream cancels the request at once:
its handler runs beside a wait for the client to leave, and sees
`error.Canceled`. A stream ends by an explicit act, never by canceling its
task: a `subscriptions/listen` stream when its client cancels it or leaves, or
stdio's input ends; a session's stream when the session is deleted or its
input ends; every stream when the server closes, answered `complete`. A
session's GET stream and DELETE are served for the session revisions, where a
disconnect is not a cancellation.

**HTTP+SSE (2024-11-05).** The transport 2025-03-26 deprecated, served for the
clients that speak only it: `parley.http.SseEndpoint`, mounted at a path of
its own beside the endpoint. A GET opens a session and its event stream, whose
first event, `endpoint`, names where to POST (`?sessionId=`); each POST is
answered 202 at once, and what answers it goes out on the stream. A session is
stdio's `Connection` with events for lines and POSTs for input, so it is
served, canceled (`notifications/cancelled`) and bounded as stdio's is, and it
ends with its stream. The host, origin and access checks are the endpoint's.

**The client.** `Client.connect` asks `server/discover` at 2026-07-28 (or the
versions `Options.revisions` names): an answer, or an error that names the
versions the server speaks, means a modern server, whose requests then carry
the version, the client's identity and capabilities in `_meta`; anything
else, or no answer within `probe_timeout`, means a session server, which is
opened with `initialize`. A call that comes back asking for input is answered
by the application's handlers (`Options.handlers`: forms, a model's answer,
roots) and retried with the answers and the server's state exactly as it came;
a session server's own requests reach the same handlers, and an accepted
form's fields the user left empty get the form's defaults. Over HTTP every
request carries the headers its revision asks for, a tool's `x-mcp-header`
arguments mirrored from its last `tools/list` (a tool whose marks break the
rules is left out of the list), a session's GET stream is read for what belongs
to no request, and a session stream the server closes is reopened with
`Last-Event-ID` after the `retry` it set. A session server that answers
`initialize` at 2025-03-26 or 2024-11-05 is spoken to at it: a batch it sends
is taken, its requests in one answered together as one array, and the client
sends no batch of its own; the client never speaks HTTP+SSE. A tool call a server runs as a task
is polled to its end, its input given as it asks, and returned as if answered
at once (`Options.tasks`).

**Authorization.** `parley.oauth.Authorizer` is a client's side, given to
the HTTP transport as its `authorization`. The first request goes without a
token; a 401 (or a 403 asking for more scope) starts what MCP lays out: the
resource's metadata from the challenge's `resource_metadata` or its
well-known locations (its `resource` held to the server's URL), its
authorization server's metadata, the client as that server knows it
(registered beforehand, a client ID metadata document's URL where the server
takes one, else registered now as a native or web application), the scope
(what the challenge names, else what the resource lists, what was granted
before kept, `offline_access` where the server lists it), then tokens: kept
ones, a refresh, or a sign-in with PKCE naming the resource, the application
opening the URL. Without a user at the keyboard: the client's own
credentials; MCP's enterprise-managed authorization, the user's token at the
enterprise's identity provider exchanged there for an ID-JAG that the
authorization server redeems; or a workload's identity token from its
platform as the grant. The request is sent again, once. A server that changes is a
new start: nothing the old one issued goes to it. `parley.oauth.Guard` is a
server's side, an endpoint's `access`: every request held to a bearer token
for this resource (a JWT checked against the authorization server's keys, or
introspection) with the scopes it needs, a 401 or 403 naming where the
resource's metadata is, which `ResourceMetadata` serves. The OAuth itself is
clearance's.
