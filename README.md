# parley

parley is the Model Context Protocol (MCP) for Zig: servers and clients. Its
core answers one request with one reply, statelessly, as the 2026-07-28
revision has it; the session revisions before it (2025-11-25 and 2025-06-18,
which Codex and Claude Code speak today, and 2025-03-26 and 2024-11-05 for the
clients that still do) are served above the core, from the same handlers.
Transports: stdio, Streamable HTTP, and 2024-11-05's HTTP+SSE on the server's
side, on [uplink](https://github.com/pedronaugusto/uplink).

Work in progress toward the public cut: the server, the client, the tasks
extension and authorization are built.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/parley`, then take the modules you use
through `b.dependency` and add them to your executable's imports: `parley`, on
std, strand (JSON), almanac (a task's times) and aegis (a std-only library of
checked types); `parley.http` for Streamable HTTP, on uplink; `parley.process`,
a client launching a server as a child process, on
[conduit](https://github.com/pedronaugusto/conduit); `parley.oauth`,
authorization over HTTP, on [clearance](https://github.com/pedronaugusto/clearance);
and `parley.validation`, JSON Schema validation through
[strand_schema](https://github.com/pedronaugusto/strand-schema). parley has no
build options: uplink, conduit, clearance and strand_schema are fetched with
it, and each compiles only in a program that imports the module over it.

Every client and server states whether it validates against JSON Schema:
`.validator = &validation.json_schema` (with
`const validation = @import("parley.validation");`), or `.validator = null`,
which gives up the checks (a client then hands on a server's structured
content whatever its output schema says; MCP asks a client to check it).

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
        .validator = &validation.json_schema,
        .cache = .{ .tools = .{ .ttl = .literal("5m") } },
    });
    errdefer server.deinit(io);
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
// both eras, until the client closes stdin. Each end is handed with
// what says why a read or write on it failed: a cancel is `Canceled`.
var in_buffer: [64 * 1024]u8 = undefined;
var out_buffer: [64 * 1024]u8 = undefined;
var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
try parley.stdio.serve(io, gpa, server, .fromFile(&stdin), .fromFile(&stdout), .{});
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
// Clients reach it at the listener's address until it is shut down;
// `serve` returns then, and its error says why it stopped before.
const asked = askOverHttp(io, gpa, listener.socket.address.getPort());
web.shutdown(io);
try serving.await(io);
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
var remote: http.Transport = .init(gpa, &web, url, .{});
defer remote.deinit();
defer remote.close(io);
var client: parley.Client = .init(gpa, remote.transport(), .{ .info = .{ .name = "weather-app", .version = "1.0.0" }, .validator = &validation.json_schema });
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
    .client = .{ .info = .{ .name = "weather-app", .version = "1.0.0" }, .validator = &validation.json_schema },
});
defer child.deinit(io);
try child.client.connect(io);
const outcome = try child.client.callTool(io, arena.allocator(), "forecast", .{ .city = "Porto" }, null);
```
<!-- END GENERATED -->

## Design

How parley serves each revision, its transports, the client, limits and authorization, and why:
[docs/design.md](docs/design.md).

## Scope

MCP as the specification has it: 2026-07-28, and 2025-11-25, 2025-06-18,
2025-03-26 and 2024-11-05 through a session, with batches where a revision has
them, and 2024-11-05's HTTP+SSE on the server's side. Not built: HTTP+SSE on the
client's side, a session's resumable streams (`Last-Event-ID`, removed in
2026-07-28), and dereferencing a schema's `$ref` over the network. No
conformance set covers 2025-03-26 or 2024-11-05: their proof is the handshake
at each revision, batches on each transport, and the TypeScript SDK's
2025-03-26 client (trials) over stdio, Streamable HTTP and HTTP+SSE.

## Built with

- [strand](https://github.com/pedronaugusto/strand): JSON and the JSON
  Schemas of Zig types.
- [strand_schema](https://github.com/pedronaugusto/strand-schema)
  (`parley.validation`): JSON Schema validation, a tool's structured content
  against its output schema on the client; given input schemas and
  elicitation answers on the server.
- [aegis](https://github.com/pedronaugusto/aegis): checked types.
- [almanac](https://github.com/pedronaugusto/almanac): civil time, for a
  task's times.
- [uplink](https://github.com/pedronaugusto/uplink) (`parley.http`): HTTP.
- [clearance](https://github.com/pedronaugusto/clearance) (`parley.oauth`):
  OAuth 2.1 and JOSE.
- [shakedown](https://github.com/pedronaugusto/shakedown) (tests only):
  properties, fuzzing and benchmarks.
- [preflight](https://github.com/pedronaugusto/preflight) (development only):
  the gate.

## Testing

`bay test` runs the modules' suites (authorization end to end against an
authorization server in the test), the example and each benchmark once;
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
| 2025-11-25 | client | 18 | 18, and the client credentials, enterprise-managed authorization and workload identity scenarios (not scored) |
| 2026-07-28 | client | 32 | 32, and the client credentials, enterprise-managed authorization and workload identity scenarios (not scored) |

## Licence

MIT
