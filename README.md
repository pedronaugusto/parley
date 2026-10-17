# parley

parley is the Model Context Protocol (MCP) for Zig: servers and clients. Its
core answers one request with one reply, statelessly, as the 2026-07-28
revision has it; the session revisions before it (2025-11-25 and 2025-06-18,
which Codex and Claude Code speak today) are served above the core, from the
same handlers. Transports: stdio, and Streamable HTTP on
[uplink](https://github.com/pedronaugusto/uplink).

Work in progress toward the public cut: the server, the client and the tasks
extension are built; authorization is not yet.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/parley`, then take the `parley` module,
and `parley.http` for Streamable HTTP, through `b.dependency` and add them to
your executable's imports. `parley` depends on std, strand (JSON) and aegis (a
std-only library of checked types); `parley.http` adds uplink, which is fetched
only when it is built: a server that speaks stdio alone passes `.http = false`
to `b.dependency` and fetches no uplink. `parley.process`, a client launching a
server as a child process, adds [conduit](https://github.com/pedronaugusto/conduit)
the same way (`.process = false` leaves it out).

## Usage

A server offers tools, resources and prompts. A tool's handler takes its
arguments as a Zig struct and returns a struct, text, or a `ToolResult`; the
input and output JSON Schemas `tools/list` gives are derived from those types
when the program is compiled, and a call's arguments are decoded into them,
a bad one answered as an error the model can correct:

<!-- BEGIN GENERATED zig build docs -- server -->
```zig
const parley = @import("parley");

/// A tool's arguments and result are Zig types: their JSON Schemas, in
/// `tools/list`, are derived from them when the program is compiled.
const Forecast = struct {
    city: []const u8,
    days: u8 = 1,

    pub const strand = .{ .fields = .{
        .city = .{ .description = "The city to forecast" },
        .days = .{ .range = .{ .min = 1, .max = 7 } },
    } };
};

const Weather = struct { city: []const u8, celsius: f64 };

fn forecast(call: *parley.Call, args: Forecast) parley.Call.Error!Weather {
    // Progress and log lines go on the request's own stream, when asked for.
    try call.progress(1, 1, "asked the sky");
    return .{ .city = args.city, .celsius = 21.5 };
}

/// Asks the user through the client, and continues once it is answered.
fn greet(call: *parley.Call) parley.Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{
        .message = "What should I call you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(if (answer.action == .accept) "hello" else "hello, stranger");
}

fn newServer(gpa: std.mem.Allocator, io: Io) !parley.Server {
    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "weather", .version = "1.0.0" },
        .cache = .{ .tools = .{ .ttl = .literal("5m") } },
    });
    errdefer server.deinit();
    try server.addTool(io, .{ .name = "forecast", .description = "The weather in a city" }, forecast);
    try server.addTool(io, .{ .name = "greet", .description = "Greets the user by name" }, greet);
    return server;
}
```
<!-- END GENERATED -->

Over stdio, as a client launches a server:

<!-- BEGIN GENERATED zig build docs -- stdio -->
```zig
const parley = @import("parley");

// A server a client launches: one message a line on stdin and stdout,
// both eras, until the client closes stdin.
try parley.stdio.serve(io, gpa, server, &in, &out.writer, .{});
```
<!-- END GENERATED -->

Over Streamable HTTP, mounted on an uplink router:

<!-- BEGIN GENERATED zig build docs -- http -->
```zig
const http = @import("parley.http");
const uplink = @import("uplink");

// Streamable HTTP: the endpoint is an uplink handler, mounted at a path.
var endpoint: http.Endpoint = .init(gpa, server, .{});
defer endpoint.deinit();
var router: uplink.server.Router = .init(gpa);
defer router.deinit();
try router.add("/mcp", endpoint.handler());
var web: uplink.Server = .init(gpa, .{}, router.handler());
defer web.deinit(io);
var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
defer listener.deinit(io);
var serving = try io.concurrent(uplink.Server.serve, .{ &web, io, &listener });
defer {
    web.shutdown(io);
    // glint-ignore: Z026 -- serve ends with the shutdown; the example only shows it starting
    serving.await(io) catch {};
}
```
<!-- END GENERATED -->

A client, over HTTP here (`stdio.Channel` is the same over any pair of
streams):

<!-- BEGIN GENERATED zig build docs -- client -->
```zig
const parley = @import("parley");
const http = @import("parley.http");
const uplink = @import("uplink");

// A client: the transport reaches the server (here over HTTP), and
// `connect` learns which revision it speaks.
var web: uplink.Client = .init(gpa, .{});
defer web.deinit(io);
var remote: http.Transport = .init(gpa, &web, url);
defer remote.deinit();
defer remote.close(io);
var client: parley.Client = .init(gpa, remote.transport(), .{ .info = .{ .name = "weather-app", .version = "1.0.0" } });
defer client.deinit();
try client.connect(io);

var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const outcome = try client.callTool(io, arena.allocator(), "forecast", .{ .city = "Lisbon" }, null);
std.debug.assert(std.mem.find(u8, outcome.structured.?.bytes, "Lisbon") != null);
```
<!-- END GENERATED -->

A server launched as a child process, as Claude Code and Codex launch theirs,
the client on its standard streams; its standard error is this process's, the
null device, a file, or its latest bytes kept for a diagnosis:

<!-- BEGIN GENERATED zig build docs -- process -->
```zig
const process = @import("parley.process");

// A server launched as a child process, the client on its streams.
// `deinit` ends it as stdio's shutdown says: its input closed, then a
// grace to exit before it is asked to stop.
const child = try process.Child.spawn(gpa, io, .{
    .argv = &.{ self, "--serve" },
    .client = .{ .info = .{ .name = "weather-app", .version = "1.0.0" } },
});
defer child.deinit(io);
try child.client.connect(io);
const outcome = try child.client.callTool(io, arena.allocator(), "forecast", .{ .city = "Porto" }, null);
```
<!-- END GENERATED -->

## Design

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
`error.Canceled`. A session's GET stream and DELETE are served for the
session revisions, where a disconnect is not a cancellation.

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
`Last-Event-ID` after the `retry` it set. A tool call a server runs as a task
is polled to its end, its input given as it asks, and returned as if answered
at once (`Options.tasks`).

## Scope

MCP as the specification has it, in the revisions in use: 2026-07-28, and
2025-11-25 and 2025-06-18 through a session. Not built: the HTTP+SSE transport
(deprecated since 2025-03-26), a session's resumable streams (`Last-Event-ID`,
removed in 2026-07-28), JSON-RPC batches (removed in 2025-06-18), and
dereferencing a schema's `$ref` over the network.

## Built with

- [strand](https://github.com/pedronaugusto/strand): JSON, and the JSON
  Schemas of Zig types.
- [aegis](https://github.com/pedronaugusto/aegis): checked types.
- [uplink](https://github.com/pedronaugusto/uplink) (`parley.http`): HTTP.
- [shakedown](https://github.com/pedronaugusto/shakedown) (tests only):
  properties, fuzzing and benchmarks.
- [preflight](https://github.com/pedronaugusto/preflight) (development only):
  the gate.

## Testing

`bay test` runs both modules' suites, the example and each benchmark once;
`bay properties` the properties alone (any bytes a client sends over stdio,
every sealed state changed), which the fuzzer runs. The suite reads what
Claude Code 2.1.302 and Codex 0.160.0 send to a stdio server, captured from
both, and answers it.

The official conformance suite
([@modelcontextprotocol/conformance](https://github.com/modelcontextprotocol/conformance)
0.2.0-alpha.12) drives `conformance/server.zig` and runs `conformance/client.zig`
over HTTP, by hand (`bay conformance-server -- --port 3000`, then `npx
@modelcontextprotocol/conformance server --url http://127.0.0.1:3000/mcp
--requirements <revision>`; `bay conformance-client`, then `npx
@modelcontextprotocol/conformance client --command zig-out/bin/conformance-client
--scenario <name>`):

| Revision | Leg | Scenarios required | Passed |
|---|---|---|---|
| 2025-11-25 | server | 30 | 30 |
| 2026-07-28 | server | 37 | 37, and the 10 tasks scenarios (not scored) |
| 2025-11-25 | client | 18 | the 4 without authorization; the 14 `auth/*` wait on OAuth |
| 2026-07-28 | client | 32 | the 7 without authorization; the 25 `auth/*` wait on OAuth |

## Licence

MIT
