//! parley's benchmarks. `bay bench` runs them in ReleaseFast and writes one
//! JSON line per row to stdout; `bay test` runs each row once with
//! `--smoke`. Timings are taken by hand, never in CI. `zig-out/bench/
//! parley-bench <row prefix>` runs the rows whose name starts with the prefix.
//!
//! The `wire/` and `server/` rows run parley in process. The `stdio/` and
//! `http/` rows drive a server process the way a client does, with requests
//! written as bytes, so the driver costs the same whatever it measures: the
//! fixture server (src/testing/server.zig, built in the benchmark's mode) by
//! default, or any server named after `--` that takes the fixture's
//! arguments (`--tools <n>`, `--port <port>`) and serves its tools (`echo`,
//! `sleep`): `parley-bench [rows] -- <program> <arguments>...`. The rival
//! SDKs are measured that way, in trials.
//!
//! Rows of single requests are latency rows: each request is timed alone,
//! and the row's median and p99 are its p50 and p99. Each era has its rows:
//! 2025-11-25 (a session opened by `initialize`) and 2026-07-28 (no session,
//! each request carrying its revision). `http/load/` is TM Dev Lab's MCP
//! workload with an echo tool in place of its Redis and HTTP backends: 50
//! clients at once, each opening a session per call (`initialize`,
//! `notifications/initialized`, the call, `DELETE`), without its 50 ms pause
//! between rounds, so the row is the server's capacity; under 2026-07-28 a
//! call is one request.
//!
//! `parley-bench memory [-- <server>]` prints the server's memory instead,
//! one JSON line each: at rest after a call, and after echoing one 64 MiB
//! message (`conduit.Child.memory`: the resident set on Linux, the physical
//! footprint on macOS).
const std = @import("std");
const parley = @import("parley");
const wire_limits = parley.wire.limitsFor(parley.wire.default_message);
const conduit = @import("conduit");
const uplink = @import("uplink");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");
const bench_options = @import("bench_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const WorkloadError = error{
    OutOfMemory,
    Malformed,
    Invalid,
    WriteFailed,
    ReadFailed,
    EndOfStream,
    StreamTooLong,
    Canceled,
    Duplicate,
    InvalidSchema,
    TasksNotServed,
    EntropyUnavailable,
    Unanswered,
    /// A server process would not start, answer, or listen.
    ServerFailed,
    /// An HTTP exchange failed below MCP.
    HttpFailed,
};
const Row = shakedown.bench.Row(Bench, WorkloadError);

/// What Claude Code sends to call a tool, `_meta` and all.
const call =
    \\{"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.302","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01TPoWJP87tokEt7hQxSLL7f","progressToken":1}},"jsonrpc":"2.0","id":1}
;

/// A tool whose schema is large: twenty described fields.
const Wide = struct {
    f0: []const u8,
    f1: i64,
    f2: bool,
    f3: ?f64 = null,
    f4: []const []const u8 = &.{},
    f5: []const u8,
    f6: i64,
    f7: bool,
    f8: ?f64 = null,
    f9: []const []const u8 = &.{},
    f10: []const u8,
    f11: i64,
    f12: bool,
    f13: ?f64 = null,
    f14: []const []const u8 = &.{},
    f15: []const u8,
    f16: i64,
    f17: bool,
    f18: ?f64 = null,
    f19: []const []const u8 = &.{},
};

fn wide(_: *parley.Call, _: Wide) error{}![]const u8 {
    return "ok";
}

fn echo(_: *parley.Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

/// The two eras a client can speak.
const Era = enum {
    /// 2025-11-25: `initialize` opens a session.
    session,
    /// 2026-07-28: no session; each request carries its revision in `_meta`.
    stateless,

    fn text(era: Era) []const u8 {
        return switch (era) {
            .session => "2025-11-25",
            .stateless => "2026-07-28",
        };
    }
};

/// How many tools the process rows' server lists: each with forty described
/// fields, about 6 KiB of schema.
const listed_tools = "100";
/// The long call the rows that must not wait on it run beside: longer than
/// any row.
const long_call_ms = 600_000;
/// TM Dev Lab's clients at once.
const load_clients = 50;
/// What the memory mode echoes.
const large_message = 64 << 20;

/// A request line: `{"jsonrpc":"2.0","id":<id>,"method":<method>,"params":{<params>}}`,
/// under 2026-07-28 with the revision in `params._meta`.
fn request(buffer: []u8, era: Era, id: u64, method: []const u8, params: []const u8) error{WriteFailed}![]const u8 {
    var w: Io.Writer = .fixed(buffer);
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}", .{ id, method, params });
    if (era == .stateless) try w.print("{s}{s}", .{ if (params.len == 0) "" else ",", meta });
    try w.writeAll("}}");
    return w.buffered();
}

const initialize_params =
    \\"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"parley-bench","version":"1"}
;
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
const echo_params = "\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}";

/// Whether `line` is the answer to request `id`: it names the id and is no
/// request or notification of the server's own.
fn answers(line: []const u8, id: u64) bool {
    var buffer: [32]u8 = undefined;
    const key = std.mem.print(&buffer, "\"id\":{d}", .{id}) catch unreachable; // unreachable: a u64 prints in 32 bytes
    var at: usize = 0;
    while (std.mem.findPos(u8, line, at, key)) |found| {
        const after = found + key.len;
        if (after < line.len and (line[after] == ',' or line[after] == '}')) return std.mem.find(u8, line, "\"method\":") == null;
        at = after;
    }
    return false;
}

/// The answer's result, or `Unanswered` if it is an error.
fn result(line: []const u8) WorkloadError![]const u8 {
    if (std.mem.find(u8, line, "\"result\":") == null) return error.Unanswered;
    return line;
}

/// A listing's `nextCursor`, if it has one.
fn nextCursor(line: []const u8) ?[]const u8 {
    const key = "\"nextCursor\":\"";
    const start = (std.mem.find(u8, line, key) orelse return null) + key.len;
    const end = std.mem.findScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

/// A server process on its standard streams.
const Process = struct {
    child: conduit.Child,
    input: Io.File.Writer,
    output: Io.File.Reader,
    input_buffer: [64 << 10]u8,
    output_buffer: [4 << 20]u8,

    fn start(gpa: Allocator, io: Io, command: []const []const u8, extra: []const []const u8) WorkloadError!*Process {
        const argv = try std.mem.concat(gpa, []const u8, &.{ command, extra });
        defer gpa.free(argv);
        const p = try gpa.create(Process);
        errdefer gpa.destroy(p);
        p.child = conduit.Child.spawn(gpa, io, .{
            .argv = argv,
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
            .descendants = .contain,
        }) catch return error.ServerFailed;
        p.input = p.child.stdinWriter(io, &p.input_buffer).?;
        p.output = p.child.stdoutReader(io, &p.output_buffer).?;
        return p;
    }

    /// Input closed, a grace to end, then killed: stdio's shutdown. A server
    /// over HTTP, which reads no input, is killed at once.
    fn stop(p: *Process, gpa: Allocator, io: Io, grace: bool) void {
        p.child.closeStdin(io);
        const ended = if (grace) p.child.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }) catch null else null;
        // glint-ignore: Z026 -- the benchmark has its numbers; a server that outlives a kill is the system's
        if (ended == null) _ = p.child.killWait(io, .fromRaw(0)) catch {};
        p.child.deinit(io);
        gpa.destroy(p);
    }

    fn send(p: *Process, line: []const u8) WorkloadError!void {
        const w = &p.input.interface;
        try w.writeAll(line);
        try w.writeByte('\n');
        try w.flush();
    }

    /// The answer to `id`, skipping what comes before it: valid until the
    /// next read.
    fn answer(p: *Process, id: u64) WorkloadError![]const u8 {
        while (true) {
            const line = try p.output.interface.takeDelimiterExclusive('\n');
            p.output.interface.toss(1);
            if (answers(line, id)) return result(line);
        }
    }

    fn ask(p: *Process, line: []const u8, id: u64) WorkloadError![]const u8 {
        try p.send(line);
        return p.answer(id);
    }
};

/// One client of a server over HTTP: its own connection, and its session
/// under 2025-11-25.
const Client = struct {
    http: uplink.Client,
    url: []const u8,
    arena: std.heap.ArenaAllocator,
    session: ?[]u8 = null,
    session_buffer: [256]u8 = undefined,
    line: [1024]u8 = undefined,
    next: u64 = 1,
    failed: ?WorkloadError = null,

    fn init(gpa: Allocator, url: []const u8) Client {
        return .{ .http = .init(gpa, .{}), .url = url, .arena = .init(gpa) };
    }

    fn deinit(c: *Client, io: Io) void {
        c.http.deinit(io);
        c.arena.deinit();
    }

    /// POSTs `body` and returns the answer to `id` (null for a
    /// notification), from a JSON body or an event stream.
    fn post(c: *Client, io: Io, era: Era, method: []const u8, name: ?[]const u8, body: []const u8, id: ?u64) WorkloadError!?[]const u8 {
        _ = c.arena.reset(.retain_capacity);
        var fields: [6]std.http.Header = undefined;
        var count: usize = 0;
        fields[count] = .{ .name = "Content-Type", .value = "application/json" };
        count += 1;
        fields[count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
        count += 1;
        fields[count] = .{ .name = "MCP-Protocol-Version", .value = era.text() };
        count += 1;
        if (era == .stateless) {
            fields[count] = .{ .name = "Mcp-Method", .value = method };
            count += 1;
            if (name) |n| {
                fields[count] = .{ .name = "Mcp-Name", .value = n };
                count += 1;
            }
        } else if (c.session) |s| {
            fields[count] = .{ .name = "Mcp-Session-Id", .value = s };
            count += 1;
        }
        var response = c.http.send(io, .{ .method = .POST, .url = c.url, .headers = fields[0..count], .body = .{ .bytes = body } }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.HttpFailed,
        };
        defer response.deinit(io);
        // A server may serve 2025-11-25 without sessions.
        if (std.mem.eql(u8, method, "initialize")) if (response.headers.get("Mcp-Session-Id")) |s| {
            if (s.len > c.session_buffer.len) return error.Unanswered;
            @memcpy(c.session_buffer[0..s.len], s);
            c.session = c.session_buffer[0..s.len];
        };
        const text = response.collect(c.arena.allocator(), io, .limited(128 << 20)) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.HttpFailed,
        };
        const expected = id orelse {
            if (@backingInt(response.status) >= 300) return error.Unanswered;
            return null;
        };
        // A JSON body, or the event stream's data lines.
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const json = if (std.mem.startsWith(u8, line, "data:")) std.mem.trimStart(u8, line[5..], " ") else line;
            if (answers(json, expected)) return try result(json);
        }
        return error.Unanswered;
    }

    fn ask(c: *Client, io: Io, era: Era, method: []const u8, name: ?[]const u8, params: []const u8) WorkloadError![]const u8 {
        const id = c.next;
        c.next += 1;
        const line = try request(&c.line, era, id, method, params);
        return (try c.post(io, era, method, name, line, id)).?;
    }

    /// `initialize` and `notifications/initialized`: a session.
    fn open(c: *Client, io: Io) WorkloadError!void {
        c.session = null;
        _ = try c.ask(io, .session, "initialize", null, initialize_params);
        _ = try c.post(io, .session, "notifications/initialized", null, initialized, null);
    }

    /// `DELETE`: the session ended.
    fn close(c: *Client, io: Io) WorkloadError!void {
        const s = c.session orelse return;
        c.session = null;
        const fields = [_]std.http.Header{ .{ .name = "Mcp-Session-Id", .value = s }, .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" } };
        var response = c.http.send(io, .{ .method = .DELETE, .url = c.url, .headers = &fields }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.HttpFailed,
        };
        defer response.deinit(io);
        _ = c.arena.reset(.retain_capacity);
        // glint-ignore: Z026 -- the answer to a DELETE has no body worth reading; a failure here is the next request's
        _ = response.collect(c.arena.allocator(), io, .limited(1 << 20)) catch {};
    }

    fn echoCall(c: *Client, io: Io, era: Era) WorkloadError!void {
        _ = try c.ask(io, era, "tools/call", "echo", echo_params);
    }

    /// One unit of TM Dev Lab's workload: a session per call under
    /// 2025-11-25, the call alone under 2026-07-28.
    fn round(c: *Client, io: Io, era: Era) WorkloadError!void {
        if (era == .stateless) return c.echoCall(io, era);
        try c.open(io);
        try c.echoCall(io, era);
        try c.close(io);
    }
};

const Bench = struct {
    gpa: Allocator,
    io: Io = undefined,
    server: parley.Server = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    out: [256]u8 = undefined,
    sink: usize = 0,

    /// The server the process rows launch.
    command: []const []const u8 = &.{},
    process: ?*Process = null,
    line: [1024]u8 = undefined,
    next: u64 = 1,
    /// The id of the long call a row runs beside, or of the call a unit
    /// cancels.
    pending: u64 = 0,
    url_buffer: [64]u8 = undefined,
    url: []const u8 = "",
    http: ?*Client = null,
    clients: []Client = &.{},
    /// The clients loading the server while a latency row measures: they run
    /// until `stopping`.
    loaders: Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    fn setup(b: *Bench) WorkloadError!void {
        b.arena = .init(b.gpa);
    }

    fn teardown(b: *Bench) WorkloadError!void {
        b.arena.deinit();
    }

    fn serverSetup(b: *Bench) WorkloadError!void {
        b.arena = .init(b.gpa);
        b.server = try parley.Server.init(b.gpa, b.io, .{ .info = .{ .name = "bench", .version = "0" } });
        var name_buffer: [16]u8 = undefined;
        for (0..100) |i| {
            const name = std.mem.print(&name_buffer, "wide_{d}", .{i}) catch unreachable; // unreachable: the name fits
            try b.server.addTool(b.io, .{ .name = name, .description = "A tool with twenty arguments" }, wide);
        }
        try b.server.addTool(b.io, .{ .name = "echo" }, echo);
    }

    fn serverTeardown(b: *Bench) WorkloadError!void {
        b.server.deinit();
        b.arena.deinit();
    }

    fn ask(b: *Bench, method: []const u8, params: []const u8) WorkloadError!void {
        const r: parley.wire.Request = .{ .id = .{ .integer = 1 }, .method = method, .params = params };
        const reply = try b.server.serve(b.io, b.arena.allocator(), r, null, .none);
        switch (reply) {
            .result => |text| b.sink +%= text.len,
            else => return error.Unanswered,
        }
        _ = b.arena.reset(.retain_capacity);
    }

    fn listTools(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| try b.ask("tools/list", "{" ++ meta ++ "}");
    }

    fn callEcho(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| try b.ask("tools/call", "{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}," ++ meta ++ "}");
    }

    fn decodeCall(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            const message = try parley.wire.decode(b.arena.allocator(), call, .{ .limits = wire_limits });
            b.sink +%= message.request.method.len;
        }
    }

    fn writeResult(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var w: Io.Writer = .fixed(&b.out);
            try parley.wire.writeResult(&w, .{ .integer = 1 }, "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}");
            b.sink +%= w.end;
        }
    }

    // The server over stdio.

    /// Asks the process `method` and returns its answer.
    fn askProcess(b: *Bench, era: Era, method: []const u8, params: []const u8) WorkloadError![]const u8 {
        const id = b.next;
        b.next += 1;
        return b.process.?.ask(try request(&b.line, era, id, method, params), id);
    }

    fn launch(b: *Bench, era: Era) WorkloadError!void {
        b.process = try Process.start(b.gpa, b.io, b.command, &.{ "--tools", listed_tools });
        errdefer b.stopProcess();
        if (era == .session) {
            _ = try b.askProcess(.session, "initialize", initialize_params);
            try b.process.?.send(initialized);
        }
    }

    fn stopProcess(b: *Bench) void {
        const p = b.process orelse return;
        b.process = null;
        p.stop(b.gpa, b.io, b.url.len == 0);
    }

    fn startStdio(comptime era: Era) Row.Hook {
        return struct {
            fn hook(b: *Bench) WorkloadError!void {
                return b.launch(era);
            }
        }.hook;
    }

    fn endStdio(b: *Bench) WorkloadError!void {
        b.stopProcess();
    }

    /// The server started and its first answer: `server/discover` under
    /// 2026-07-28, `initialize` under 2025-11-25.
    fn coldStart(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    b.process = try Process.start(b.gpa, b.io, b.command, &.{});
                    _ = switch (era) {
                        .stateless => try b.askProcess(era, "server/discover", ""),
                        .session => try b.askProcess(era, "initialize", initialize_params),
                    };
                    b.stopProcess();
                }
            }
        }.run;
    }

    /// Every page of `tools/list`.
    fn listProcess(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var answer = try b.askProcess(era, "tools/list", "");
                    while (nextCursor(answer)) |cursor| {
                        var params: [256]u8 = undefined;
                        answer = try b.askProcess(era, "tools/list", std.mem.print(&params, "\"cursor\":\"{s}\"", .{cursor}) catch return error.Malformed);
                    }
                    b.sink +%= answer.len;
                }
            }
        }.run;
    }

    fn echoProcess(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                for (0..units) |_| b.sink +%= (try b.askProcess(era, "tools/call", echo_params)).len;
            }
        }.run;
    }

    /// The server started with a long call running, which every unit of the
    /// row meets.
    fn startBesideLongCall(comptime era: Era) Row.Hook {
        return struct {
            fn hook(b: *Bench) WorkloadError!void {
                try b.launch(era);
                errdefer b.stopProcess();
                try b.startLongCall(era);
            }
        }.hook;
    }

    /// Sends a long call and waits until the server has read it: an answer
    /// to a request sent after it.
    fn startLongCall(b: *Bench, era: Era) WorkloadError!void {
        b.pending = b.next;
        b.next += 1;
        var params: [128]u8 = undefined;
        const sleep_params = std.mem.print(&params, "\"name\":\"sleep\",\"arguments\":{{\"ms\":{d}}}", .{long_call_ms}) catch unreachable; // unreachable: it fits
        try b.process.?.send(try request(&b.line, era, b.pending, "tools/call", sleep_params));
        _ = switch (era) {
            .session => try b.askProcess(era, "ping", ""),
            .stateless => try b.askProcess(era, "tools/call", echo_params),
        };
    }

    /// A request answered while the long call runs: `ping` under
    /// 2025-11-25, which has it, an echo under 2026-07-28, which does not.
    fn besideLongCall(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                for (0..units) |_| b.sink +%= switch (era) {
                    .session => (try b.askProcess(era, "ping", "")).len,
                    .stateless => (try b.askProcess(era, "tools/call", echo_params)).len,
                };
            }
        }.run;
    }

    /// Untimed: a long call the unit cancels, read by the server.
    fn stageCancel(b: *Bench, units: u64) WorkloadError!void {
        std.debug.assert(units == 1);
        try b.startLongCall(.session);
    }

    /// `notifications/cancelled` for the long call, then a `ping`: timed to
    /// the ping's answer, which the long call must not hold up.
    fn cancelThenPing(b: *Bench, units: u64) WorkloadError!void {
        std.debug.assert(units == 1);
        var w: Io.Writer = .fixed(&b.line);
        try w.print("{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"bench\"}}}}", .{b.pending});
        try b.process.?.send(w.buffered());
        b.sink +%= (try b.askProcess(.session, "ping", "")).len;
    }

    // The server over HTTP.

    fn listen(b: *Bench) WorkloadError!void {
        // A port the system gave and took back, for the server to take.
        var probe = (Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable).listen(b.io, .{}) catch return error.ServerFailed; // unreachable: the address is literal
        const port = probe.socket.address.getPort();
        probe.deinit(b.io);
        var port_text: [8]u8 = undefined;
        b.url = std.mem.print(&b.url_buffer, "http://127.0.0.1:{d}/mcp", .{port}) catch unreachable; // unreachable: it fits
        b.process = try Process.start(b.gpa, b.io, b.command, &.{ "--tools", listed_tools, "--port", std.mem.print(&port_text, "{d}", .{port}) catch unreachable }); // unreachable: a port fits
        errdefer b.stopProcess();
        // Ready once it accepts a connection.
        const address = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable; // unreachable: the address is literal
        for (0..1000) |_| {
            if (address.connect(b.io, .{ .mode = .stream })) |stream| {
                stream.close(b.io);
                return;
            } else |_| b.io.sleep(.fromMilliseconds(10), .awake) catch return error.Canceled;
        }
        return error.ServerFailed;
    }

    fn startHttp(comptime era: Era) Row.Hook {
        return struct {
            fn hook(b: *Bench) WorkloadError!void {
                try b.listen();
                errdefer b.stopProcess();
                const c = try b.gpa.create(Client);
                c.* = .init(b.gpa, b.url);
                b.http = c;
                if (era == .session) try c.open(b.io);
            }
        }.hook;
    }

    fn endHttp(b: *Bench) WorkloadError!void {
        if (b.http) |c| {
            // glint-ignore: Z026 -- the session's end is the server's to answer; the row has its numbers
            c.close(b.io) catch {};
            c.deinit(b.io);
            b.gpa.destroy(c);
            b.http = null;
        }
        b.stopProcess();
        b.url = "";
    }

    fn listHttp(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                const c = b.http.?;
                for (0..units) |_| {
                    var answer = try c.ask(b.io, era, "tools/list", null, "");
                    while (nextCursor(answer)) |cursor| {
                        var params: [256]u8 = undefined;
                        answer = try c.ask(b.io, era, "tools/list", null, std.mem.print(&params, "\"cursor\":\"{s}\"", .{cursor}) catch return error.Malformed);
                    }
                    b.sink +%= answer.len;
                }
            }
        }.run;
    }

    fn echoHttp(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                for (0..units) |_| try b.http.?.echoCall(b.io, era);
            }
        }.run;
    }

    /// The server and TM Dev Lab's fifty clients.
    fn startLoad(b: *Bench) WorkloadError!void {
        try b.listen();
        errdefer b.stopProcess();
        b.clients = try b.gpa.alloc(Client, load_clients);
        for (b.clients) |*c| c.* = .init(b.gpa, b.url);
    }

    fn endLoad(b: *Bench) WorkloadError!void {
        b.finishLoad();
    }

    fn finishLoad(b: *Bench) void {
        for (b.clients) |*c| c.deinit(b.io);
        b.gpa.free(b.clients);
        b.clients = &.{};
        b.stopProcess();
        b.url = "";
    }

    fn rounds(c: *Client, io: Io, era: Era, count: u64) void {
        for (0..count) |_| c.round(io, era) catch |err| {
            c.failed = err;
            return;
        };
    }

    /// `units` rounds over the fifty clients at once: the throughput row.
    fn load(comptime era: Era) Row.Step {
        return struct {
            fn run(b: *Bench, units: u64) WorkloadError!void {
                var group: Io.Group = .init;
                defer group.cancel(b.io);
                for (b.clients, 0..) |*c, i| {
                    const share = units / load_clients + @intFromBool(i < units % load_clients);
                    if (share == 0) continue;
                    group.concurrent(b.io, rounds, .{ c, b.io, era, share }) catch return error.ServerFailed;
                }
                try group.await(b.io);
                for (b.clients) |*c| if (c.failed) |err| return err;
            }
        }.run;
    }

    fn keepLoading(b: *Bench, c: *Client, era: Era) void {
        while (!b.stopping.load(.acquire)) c.round(b.io, era) catch |err| {
            c.failed = err;
            return;
        };
    }

    /// The server under load from all clients but one, which the row times.
    fn startUnderLoad(comptime era: Era) Row.Hook {
        return struct {
            fn hook(b: *Bench) WorkloadError!void {
                try b.startLoad();
                errdefer b.finishLoad();
                b.stopping.store(false, .release);
                b.loaders = .init;
                errdefer {
                    b.stopping.store(true, .release);
                    b.loaders.cancel(b.io);
                }
                for (b.clients[1..]) |*c| b.loaders.concurrent(b.io, keepLoading, .{ b, c, era }) catch return error.ServerFailed;
                b.http = &b.clients[0];
            }
        }.hook;
    }

    fn endUnderLoad(b: *Bench) WorkloadError!void {
        b.stopping.store(true, .release);
        // glint-ignore: Z026 -- the loaders end on the flag; canceled, they end as well
        b.loaders.await(b.io) catch {};
        b.http = null;
        var failed: ?WorkloadError = null;
        for (b.clients[1..]) |c| if (c.failed) |err| {
            failed = err;
        };
        try b.endLoad();
        if (failed) |err| return err;
    }

    /// Untimed: a session opened for the unit's call under 2025-11-25.
    fn stageRound(comptime era: Era) Row.Step {
        return struct {
            fn stage(b: *Bench, _: u64) WorkloadError!void {
                if (era == .session) try b.http.?.open(b.io);
            }
        }.stage;
    }

    fn settleRound(b: *Bench, _: u64) WorkloadError!void {
        try b.http.?.close(b.io);
    }

    // Memory.

    /// The server's memory at rest after a call, then after echoing one
    /// `size`-byte message: one JSON line each, unless `write` is off.
    fn memory(b: *Bench, out: *Io.Writer, size: usize, write: bool) !void {
        b.process = try Process.start(b.gpa, b.io, b.command, &.{});
        defer b.stopProcess();
        const p = b.process.?;
        _ = try b.askProcess(.session, "initialize", initialize_params);
        try p.send(initialized);
        _ = try b.askProcess(.session, "tools/call", echo_params);
        try b.io.sleep(.fromSeconds(if (write) 1 else 0), .awake);
        const rest = try p.child.memory();
        if (write) {
            try out.print("{{\"row\":\"stdio/memory/at-rest\",\"current\":{d},\"peak\":{d},\"commit\":\"{s}\",\"cpu\":\"{s}\",\"os\":\"{s}\"}}\n", .{ rest.current, rest.peak, provenance.commit, provenance.cpu, provenance.os });
            try out.flush();
        }
        // A server that cannot take the message is a row too: what failed.
        b.echoLarge(p, size) catch |err| {
            if (!write) return err;
            try out.print("{{\"row\":\"stdio/memory/message\",\"message\":{d},\"failed\":\"{t}\",\"commit\":\"{s}\",\"cpu\":\"{s}\",\"os\":\"{s}\"}}\n", .{ size, err, provenance.commit, provenance.cpu, provenance.os });
            return;
        };
        const large = try p.child.memory();
        if (!write) return;
        try out.print("{{\"row\":\"stdio/memory/message\",\"message\":{d},\"current\":{d},\"peak\":{d},\"commit\":\"{s}\",\"cpu\":\"{s}\",\"os\":\"{s}\"}}\n", .{ size, large.current, large.peak, provenance.commit, provenance.cpu, provenance.os });
    }

    /// One echo of `size` bytes of text, its answer read and passed over.
    fn echoLarge(b: *Bench, p: *Process, size: usize) !void {
        const id = b.next;
        b.next += 1;
        const w = &p.input.interface;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"echo\",\"arguments\":{{\"text\":\"", .{id});
        try w.splatByteAll('a', size);
        try w.writeAll("\"}}}\n");
        try w.flush();
        // The answer holds the message: discarded as it comes, never kept. A
        // short one is the message refused.
        while (true) {
            if (p.output.interface.takeDelimiterInclusive('\n')) |line| {
                if (answers(line, id)) {
                    if (line.len < size) return error.Unanswered;
                    return;
                }
            } else |err| switch (err) {
                error.StreamTooLong => if (try p.output.interface.discardDelimiterInclusive('\n') >= size) return,
                else => |e| return e,
            }
        }
    }
};

const rows = [_]Row{
    .{ .name = "wire/decode-call", .unit = "message", .run = Bench.decodeCall, .fixture = .{ .lifetime = .row, .setup = Bench.setup, .teardown = Bench.teardown } },
    .{ .name = "wire/write-result", .unit = "message", .run = Bench.writeResult },
    .{ .name = "server/tools-list-100-wide", .unit = "request", .run = Bench.listTools, .fixture = .{ .lifetime = .row, .setup = Bench.serverSetup, .teardown = Bench.serverTeardown } },
    .{ .name = "server/call-echo", .unit = "request", .run = Bench.callEcho, .fixture = .{ .lifetime = .row, .setup = Bench.serverSetup, .teardown = Bench.serverTeardown } },
} ++ stdioRows(.stateless) ++ stdioRows(.session) ++ [_]Row{
    .{ .name = "stdio/2025-11-25/ping-beside-long-call", .unit = "request", .latency = 2000, .run = Bench.besideLongCall(.session), .fixture = .{ .lifetime = .row, .setup = Bench.startBesideLongCall(.session), .teardown = Bench.endStdio } },
    .{ .name = "stdio/2026-07-28/echo-beside-long-call", .unit = "request", .latency = 2000, .run = Bench.besideLongCall(.stateless), .fixture = .{ .lifetime = .row, .setup = Bench.startBesideLongCall(.stateless), .teardown = Bench.endStdio } },
    .{ .name = "stdio/2025-11-25/cancel-then-ping", .unit = "request", .latency = 500, .run = Bench.cancelThenPing, .stage = Bench.stageCancel, .fixture = .{ .lifetime = .row, .setup = Bench.startStdio(.session), .teardown = Bench.endStdio } },
} ++ httpRows(.stateless) ++ httpRows(.session);

fn stdioRows(comptime era: Era) [4]Row {
    const prefix = "stdio/" ++ comptime era.text();
    const fixture: Row.Fixture = .{ .lifetime = .row, .setup = Bench.startStdio(era), .teardown = Bench.endStdio };
    return .{
        .{ .name = prefix ++ "/cold-start", .unit = "start", .latency = 30, .run = Bench.coldStart(era) },
        .{ .name = prefix ++ "/tools-list-" ++ listed_tools, .unit = "request", .latency = 1000, .run = Bench.listProcess(era), .fixture = fixture },
        .{ .name = prefix ++ "/echo", .unit = "request", .latency = 5000, .run = Bench.echoProcess(era), .fixture = fixture },
        .{ .name = prefix ++ "/echo-batched", .unit = "request", .run = Bench.echoProcess(era), .fixture = fixture },
    };
}

fn httpRows(comptime era: Era) [4]Row {
    const prefix = "http/" ++ comptime era.text();
    const fixture: Row.Fixture = .{ .lifetime = .row, .setup = Bench.startHttp(era), .teardown = Bench.endHttp };
    const load_unit = if (era == .session) "session" else "request";
    return .{
        .{ .name = prefix ++ "/tools-list-" ++ listed_tools, .unit = "request", .latency = 1000, .run = Bench.listHttp(era), .fixture = fixture },
        .{ .name = prefix ++ "/echo", .unit = "request", .latency = 5000, .run = Bench.echoHttp(era), .fixture = fixture },
        .{ .name = prefix ++ "/load-50", .unit = load_unit, .initial = load_clients, .smoke = load_clients, .run = Bench.load(era), .fixture = .{ .lifetime = .row, .setup = Bench.startLoad, .teardown = Bench.endLoad } },
        .{ .name = prefix ++ "/load-50/echo", .unit = "request", .latency = 2000, .run = Bench.echoHttp(era), .stage = Bench.stageRound(era), .settle = if (era == .session) Bench.settleRound else null, .fixture = .{ .lifetime = .row, .setup = Bench.startUnderLoad(era), .teardown = Bench.endUnderLoad } },
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The server after `--`; the fixture's without one.
    const split = for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else args.len;
    // The build names the fixture from where it ran, the package's root; a
    // benchmark runs from a directory of its own.
    const fixture = try std.fs.path.resolveAlloc(init.arena.allocator(), &.{ provenance.root, bench_options.server });
    const command: []const []const u8 = if (split + 1 < args.len) args[split + 1 ..] else &.{fixture};
    var own = args[1..split];
    const memory_mode = own.len != 0 and std.mem.eql(u8, own[0], "memory");
    if (memory_mode) own = own[1..];
    const options = try shakedown.bench.Options.fromArguments(own);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var b: Bench = .{ .gpa = init.gpa, .io = init.io, .command = command };
    if (memory_mode) {
        try b.memory(&stdout.interface, large_message, true);
    } else {
        try shakedown.bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &b, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
        // A smoke run reads the memory too, of a small message, and says
        // nothing of it.
        if (options.smoke) try b.memory(&stdout.interface, 1 << 20, false);
    }
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(b.sink);
}
