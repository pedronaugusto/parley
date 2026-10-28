//! The endpoint over a real loopback connection: uplink's server in front
//! of the core, uplink's client asking.
const std = @import("std");
const shakedown = @import("shakedown");
const parley = @import("parley");
const uplink = @import("uplink");
const Endpoint = @import("Endpoint.zig");
const SseEndpoint = @import("SseEndpoint.zig");

test {
    _ = @import("headers.zig");
}

const testing = std.testing;
const Io = std.Io;
const Call = parley.Call;

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

fn echo(_: *Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

fn counted(call: *Call) Call.Error!parley.ToolResult {
    try call.progress(1, 2, null);
    try call.progress(2, 2, null);
    return .ofText("counted");
}

/// Text larger than uplink's body buffer, to be written as it is made: in
/// lines, so an event stream splits nothing it must not.
const large_line = "line of the large answer\n";
const large_lines = 20_000;

fn large(call: *Call, args: struct { progress: bool }) Call.Error!parley.ToolResult {
    if (args.progress) try call.progress(1, 1, null);
    return .ofText(try repeated(call.arena, large_line, large_lines));
}

fn repeated(arena: std.mem.Allocator, line: []const u8, n: usize) error{OutOfMemory}![]const u8 {
    const text = try arena.alloc(u8, line.len * n);
    for (0..n) |i| @memcpy(text[i * line.len ..][0..line.len], line);
    return text;
}

/// A server and an endpoint in front of it, listening on loopback.
const Harness = struct {
    core: parley.Server,
    endpoint: Endpoint,
    sse: SseEndpoint,
    router: uplink.server.Router,
    http: uplink.Server,
    listener: Io.net.Server,
    serving: Io.Future(uplink.Server.ServeError!void),
    client: uplink.Client,
    port: u16,

    fn start(h: *Harness, io: Io) !void {
        h.core = try .init(testing.allocator, io, .{ .info = .{ .name = "http", .version = "0" } });
        try h.core.addTool(io, .{ .name = "echo" }, echo);
        try h.core.addTool(io, .{ .name = "counted" }, counted);
        try h.core.addTool(io, .{ .name = "large" }, large);
        try h.core.addTool(io, .{ .name = "stall" }, Stall.handle);
        h.endpoint = .init(testing.allocator, &h.core, .{ .keep_alive = .literal("100ms") });
        h.router = .init(testing.allocator);
        try h.router.add("/mcp", h.endpoint.handler());
        h.sse = .init(testing.allocator, &h.core, .{ .keep_alive = .literal("100ms") });
        try h.router.add("/sse", h.sse.handler());
        h.http = .init(testing.allocator, .{}, h.router.handler());
        h.listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        h.port = h.listener.socket.address.getPort();
        h.serving = try io.concurrent(uplink.Server.serve, .{ &h.http, io, &h.listener });
        h.client = .init(testing.allocator, .{});
    }

    fn stop(h: *Harness, io: Io) void {
        h.client.deinit(io);
        h.http.shutdown(io);
        // glint-ignore: Z026 -- serve ends with the shutdown; its result is not what the test checks
        h.serving.await(io) catch {};
        h.http.deinit(io);
        h.endpoint.deinit();
        h.sse.deinit();
        h.listener.deinit(io);
        h.router.deinit();
        h.core.deinit();
    }

    const Answer = struct { status: std.http.Status, content_type: []const u8, body: []const u8 };

    fn post(h: *Harness, io: Io, arena: std.mem.Allocator, body: []const u8, extra: []const uplink.Header) !Answer {
        var url_buffer: [64]u8 = undefined;
        const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{h.port});
        var fields: std.ArrayList(uplink.Header) = .empty;
        try fields.appendSlice(arena, &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json, text/event-stream" },
        });
        try fields.appendSlice(arena, extra);
        var response = try h.client.send(io, .{ .method = .POST, .url = url, .headers = fields.items, .body = .{ .bytes = body } });
        defer response.deinit(io);
        const content_type = try arena.dupe(u8, response.headers.get("Content-Type") orelse "");
        return .{ .status = response.status, .content_type = content_type, .body = try response.collect(arena, io, .limited(4 << 20)) };
    }
};

fn standard(method: []const u8, name: ?[]const u8) [3]uplink.Header {
    return .{
        .{ .name = "MCP-Protocol-Version", .value = "2026-07-28" },
        .{ .name = "Mcp-Method", .value = method },
        .{ .name = "Mcp-Name", .value = name orelse "" },
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("\n{s}\ndoes not contain\n{s}\n", .{ haystack, needle });
        return error.TestExpectedContains;
    }
}

test "a request answered as JSON; one with progress as an event stream ending with its result" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listed = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}", standard("tools/list", null)[0..2]);
    try testing.expectEqual(std.http.Status.ok, listed.status);
    try testing.expectEqualStrings("application/json", listed.content_type);
    try expectContains(listed.body, "\"name\":\"echo\"");

    const progress = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"counted\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"progressToken\":7}}}", &standard("tools/call", "counted"));
    try testing.expectEqualStrings("text/event-stream", progress.content_type);
    const first = std.mem.find(u8, progress.body, "notifications/progress").?;
    const result = std.mem.find(u8, progress.body, "\"text\":\"counted\"").?;
    try testing.expect(first < result);
}

test "an answer larger than a buffer goes out as it is written: as JSON of its length, and as the last event" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"large\",\"arguments\":{\"progress\":false}," ++ meta ++ "}}", &standard("tools/call", "large"));
    try testing.expectEqual(std.http.Status.ok, json.status);
    try testing.expectEqualStrings("application/json", json.content_type);
    try testing.expect(std.mem.startsWith(u8, json.body, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{"));
    const text = try std.mem.concat(a, u8, &.{ "\"text\":\"", try repeated(a, "line of the large answer\\n", large_lines), "\"" });
    try expectContains(json.body, text);
    try testing.expect(std.mem.endsWith(u8, json.body, "}}"));

    const events = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"large\",\"arguments\":{\"progress\":true},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"progressToken\":7}}}", &standard("tools/call", "large"));
    try testing.expectEqualStrings("text/event-stream", events.content_type);
    // The last event is the answer, read back by uplink's own reader.
    var in: Io.Reader = .fixed(events.body);
    var data: [1 << 20]u8 = undefined;
    var reader: uplink.wire.sse.Reader = .init(&in, &data);
    var last: ?[]const u8 = null;
    while (try reader.next()) |event| last = try a.dupe(u8, event.data);
    const answer = last.?;
    try testing.expect(std.mem.startsWith(u8, answer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{"));
    try expectContains(answer, text);
}

test "headers that disagree with the body, or are missing, are -32020 with a 400" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"x\"}," ++ meta ++ "}}";

    const wrong_name = try h.post(io, a, call, &standard("tools/call", "other"));
    try testing.expectEqual(std.http.Status.bad_request, wrong_name.status);
    try expectContains(wrong_name.body, "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32020");
    const no_version = try h.post(io, a, call, standard("tools/call", "echo")[1..]);
    try testing.expectEqual(std.http.Status.bad_request, no_version.status);
    try expectContains(no_version.body, "-32020");
    const encoded = try h.post(io, a, call, &.{
        .{ .name = "MCP-Protocol-Version", .value = "2026-07-28" },
        .{ .name = "Mcp-Method", .value = "tools/call" },
        .{ .name = "Mcp-Name", .value = "=?base64?ZWNobw==?=" },
    });
    try testing.expectEqual(std.http.Status.ok, encoded.status);
    try expectContains(encoded.body, "\"text\":\"x\"");
}

test "what HTTP refuses: other origins, other methods, notifications taken, unknown methods a 404" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const discover = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{" ++ meta ++ "}}";

    const evil = try h.post(io, a, discover, &.{ standard("server/discover", null)[0], standard("server/discover", null)[1], .{ .name = "Origin", .value = "http://evil.example.com" } });
    try testing.expectEqual(std.http.Status.forbidden, evil.status);
    const local = try h.post(io, a, discover, &.{ standard("server/discover", null)[0], standard("server/discover", null)[1], .{ .name = "Origin", .value = "http://localhost:3000" } });
    try testing.expectEqual(std.http.Status.ok, local.status);
    const note = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}", &.{});
    try testing.expectEqual(std.http.Status.accepted, note.status);
    const unknown = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\",\"params\":{" ++ meta ++ "}}", standard("ping", null)[0..2]);
    try testing.expectEqual(std.http.Status.not_found, unknown.status);
    try expectContains(unknown.body, "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32601");
    const unsupported = try h.post(io, a, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}", &.{
        .{ .name = "MCP-Protocol-Version", .value = "1900-01-01" },
        .{ .name = "Mcp-Method", .value = "tools/list" },
    });
    try testing.expectEqual(std.http.Status.bad_request, unsupported.status);
    try expectContains(unsupported.body, "-32022");
}

fn greet(call: *Call) Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{
        .message = "Who are you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"default\":\"ada\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(answer.content.?.bytes);
}

fn acceptEmpty(_: ?*anyopaque, _: Io, _: std.mem.Allocator, _: []const u8) parley.Client.HandlerError!parley.types.ElicitResult {
    return .{ .action = .accept, .content = .{ .bytes = "{}" } };
}

const Transport = @import("Transport.zig");

fn clientRound(io: Io, h: *Harness, revisions: []const parley.Revision, expect: parley.Client.Era) !void {
    var url_buffer: [64]u8 = undefined;
    const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{h.port});
    var remote: Transport = .init(testing.allocator, &h.client, url, .{});
    defer remote.deinit();
    defer remote.close(io);
    var client: parley.Client = .init(testing.allocator, remote.transport(), .{
        .info = .{ .name = "c", .version = "1" },
        .handlers = .{ .elicit = acceptEmpty },
        .revisions = revisions,
    });
    defer client.deinit();
    try client.connect(io);
    try testing.expectEqual(expect, client.era);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try client.list(io, a, "tools/list", null, null);
    const echoed = try client.callTool(io, a, "echo", .{ .text = "over http" }, null);
    try testing.expectEqualStrings("over http", echoed.content[0].text.text);
    // The user filled nothing: the form's default is the client's to apply.
    const greeted = try client.callTool(io, a, "greet", .{}, null);
    try testing.expectEqualStrings("{\"name\":\"ada\"}", greeted.content[0].text.text);
}

test "the client over HTTP: modern, and a session whose input comes as the server's requests on the stream" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    try h.core.addTool(io, .{ .name = "greet" }, greet);
    try clientRound(io, &h, &.{.@"2026-07-28"}, .modern);
    try clientRound(io, &h, &.{.@"2025-11-25"}, .session);
}

/// An `Io` with no task to spare.
const Serial = shakedown.Layer(u8, .{
    .concurrent = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    }.concurrent,
    .groupConcurrent = struct {
        fn groupConcurrent(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    }.groupConcurrent,
});

test "a session client with no task for the session's stream is refused at connect, where it would miss what the server sends" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var serial: Serial = .init(io, 0);
    var url_buffer: [64]u8 = undefined;
    const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{h.port});
    var remote: Transport = .init(testing.allocator, &h.client, url, .{});
    defer remote.deinit();
    defer remote.close(io);
    var client: parley.Client = .init(testing.allocator, remote.transport(), .{
        .info = .{ .name = "c", .version = "1" },
        .revisions = &.{.@"2025-11-25"},
    });
    defer client.deinit();
    try testing.expectError(error.ConcurrencyUnavailable, client.connect(serial.io()));
}

test "a session's stream ends when the session is deleted" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{h.port});
    var opened = try h.client.send(io, .{ .method = .POST, .url = url, .headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
    }, .body = .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}" } });
    const session = try arena.allocator().dupe(u8, opened.headers.get("Mcp-Session-Id") orelse return error.TestNoSession);
    _ = try opened.collect(arena.allocator(), io, .limited(1 << 16));
    opened.deinit(io);
    stream_open.store(false, .release);
    var streaming = try io.concurrent(readStream, .{ &h, io, url, session });
    // glint-ignore: Z026 -- reached only when the test failed first; how the reader ends is not what it checks
    defer streaming.cancel(io) catch {};
    try Stall.until(&stream_open);
    var deleted = try h.client.send(io, .{ .method = .DELETE, .url = url, .headers = &.{
        .{ .name = "Mcp-Session-Id", .value = session },
        .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" },
    } });
    defer deleted.deinit(io);
    try testing.expectEqual(std.http.Status.no_content, deleted.status);
    // The stream ends with the session: its reader returns, the server still up.
    try streaming.await(io);
}

var stream_open: std.atomic.Value(bool) = .init(false);

/// Opens the session's stream and reads it to its end.
fn readStream(h: *Harness, io: Io, url: []const u8, session: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stream = try h.client.send(io, .{ .method = .GET, .url = url, .headers = &.{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = "Mcp-Session-Id", .value = session },
        .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" },
    } });
    defer stream.deinit(io);
    try testing.expectEqual(std.http.Status.ok, stream.status);
    stream_open.store(true, .release);
    _ = try stream.collect(arena.allocator(), io, .limited(1 << 16));
}

/// A tool that runs until it is stopped, and says how it ended.
const Stall = struct {
    var started: std.atomic.Value(bool) = .init(false);
    var canceled: std.atomic.Value(bool) = .init(false);

    fn handle(call: *Call) Call.Error!parley.ToolResult {
        started.store(true, .release);
        call.io.sleep(.fromSeconds(60), .awake) catch {
            canceled.store(true, .release);
            return error.Canceled;
        };
        return .ofText("woke");
    }

    fn until(flag: *std.atomic.Value(bool)) !void {
        var waited: u32 = 0;
        while (!flag.load(.acquire) and waited < 1000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(10), .awake);
        try testing.expect(flag.load(.acquire));
    }
};

fn postStall(h: *Harness, io: Io) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try h.post(io, arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"stall\"," ++ meta ++ "}}", &standard("tools/call", "stall"));
}

test "a client that closes its stream stops the call: the handler is canceled" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    Stall.started.store(false, .release);
    Stall.canceled.store(false, .release);
    var calling = try io.concurrent(postStall, .{ &h, io });
    try Stall.until(&Stall.started);
    // glint-ignore: Z026 -- the client gives up; how its own call ends is not what the test checks
    calling.cancel(io) catch {};
    try Stall.until(&Stall.canceled);
}

/// Opens a session at `version` and returns its id.
fn openSession(h: *Harness, io: Io, arena: std.mem.Allocator, version: []const u8) ![]const u8 {
    var url_buffer: [64]u8 = undefined;
    const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{h.port});
    const body = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"t\",\"version\":\"0\"}}}}}}", .{version});
    var opened = try h.client.send(io, .{ .method = .POST, .url = url, .headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
    }, .body = .{ .bytes = body } });
    defer opened.deinit(io);
    const session = try arena.dupe(u8, opened.headers.get("Mcp-Session-Id") orelse return error.TestNoSession);
    const answer = try opened.collect(arena, io, .limited(1 << 16));
    try expectContains(answer, try arena.print("\"protocolVersion\":\"{s}\"", .{version}));
    return session;
}

test "a 2025-03-26 session over HTTP takes a batch: one array of answers, 202 for one with no request, initialize refused inside" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const session = try openSession(&h, io, a, "2025-03-26");
    // A 2025-03-26 client sends no MCP-Protocol-Version: the session's is taken.
    const by_session = [_]uplink.Header{.{ .name = "Mcp-Session-Id", .value = session }};
    const notices = try h.post(io, a, "[{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}]", &by_session);
    try testing.expectEqual(std.http.Status.accepted, notices.status);
    const batch = try h.post(io, a,
        \\[{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"in a batch"}}},{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}},{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":0}}]
    , &by_session);
    try testing.expectEqual(std.http.Status.ok, batch.status);
    try expectContains(batch.content_type, "application/json");
    try testing.expect(batch.body[0] == '[' and batch.body[batch.body.len - 1] == ']');
    try expectContains(batch.body, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}");
    try expectContains(batch.body, "\"in a batch\"");
    try expectContains(batch.body, "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32600");
    // A request whose answer has progress before it: the batch's answers
    // go out as events.
    const streamed = try h.post(io, a,
        \\[{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"counted","_meta":{"progressToken":"p"}}},{"jsonrpc":"2.0","id":6,"method":"ping"}]
    , &by_session);
    try expectContains(streamed.content_type, "text/event-stream");
    try expectContains(streamed.body, "notifications/progress");
    try expectContains(streamed.body, "\"id\":5,\"result\"");
    try expectContains(streamed.body, "\"id\":6,\"result\":{}");
}

test "a batch over HTTP is refused whole on a 2025-11-25 session and without one" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ping = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]";
    const alone = try h.post(io, a, ping, &.{});
    try testing.expectEqual(std.http.Status.bad_request, alone.status);
    try expectContains(alone.body, "a batch is taken only on a session at 2025-03-26 or 2024-11-05");
    const session = try openSession(&h, io, a, "2025-11-25");
    const later = try h.post(io, a, ping, &.{ .{ .name = "Mcp-Session-Id", .value = session }, .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" } });
    try testing.expectEqual(std.http.Status.bad_request, later.status);
    try expectContains(later.body, "a batch is taken only on a session at 2025-03-26 or 2024-11-05");
}

/// A 2024-11-05 client's stream on the HTTP+SSE endpoint, and where it
/// POSTs.
const SseClient = struct {
    h: *Harness,
    stream: uplink.Response,
    events: uplink.wire.sse.Reader,
    data: [1 << 16]u8,
    url_buffer: [256]u8,
    url: []const u8,

    fn open(c: *SseClient, h: *Harness, io: Io) !void {
        c.h = h;
        var url_buffer: [64]u8 = undefined;
        const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/sse", .{h.port});
        // The stream is left open, never read to an end: its connection is
        // not one to keep.
        c.stream = try h.client.send(io, .{ .method = .GET, .url = url, .headers = &.{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "Connection", .value = "close" },
        } });
        errdefer c.stream.deinit(io);
        try testing.expectEqual(std.http.Status.ok, c.stream.status);
        c.events = .init(c.stream.reader(io), &c.data);
        const first = (try c.events.next()).?;
        try testing.expectEqualStrings("endpoint", first.type);
        try testing.expect(std.mem.startsWith(u8, first.data, "/sse?sessionId="));
        c.url = try std.mem.print(&c.url_buffer, "http://127.0.0.1:{d}{s}", .{ h.port, first.data });
    }

    fn close(c: *SseClient, io: Io) void {
        c.stream.deinit(io);
    }

    fn post(c: *SseClient, io: Io, body: []const u8) !std.http.Status {
        var response = try c.h.client.send(io, .{ .method = .POST, .url = c.url, .headers = &.{.{ .name = "Content-Type", .value = "application/json" }}, .body = .{ .bytes = body } });
        defer response.deinit(io);
        return response.status;
    }

    /// The next message event's data.
    fn next(c: *SseClient) ![]const u8 {
        while (try c.events.next()) |event| if (std.mem.eql(u8, event.type, "message")) return event.data;
        return error.EndOfStream;
    }
};

const initialize_2024 =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
;

test "HTTP+SSE: the stream names where to POST; each POST is taken with 202 and answered on the stream" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var c: SseClient = undefined;
    try c.open(&h, io);
    defer c.close(io);

    try testing.expectEqual(std.http.Status.accepted, try c.post(io, initialize_2024));
    try expectContains(try c.next(), "\"protocolVersion\":\"2024-11-05\"");
    try testing.expectEqual(std.http.Status.accepted, try c.post(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
    try testing.expectEqual(std.http.Status.accepted, try c.post(io, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"over sse\"}}}"));
    const answer = try c.next();
    try expectContains(answer, "\"id\":2");
    try expectContains(answer, "over sse");

    // A batch, as 2024-11-05 has them: its answers one array, one event.
    try testing.expectEqual(std.http.Status.accepted, try c.post(io, "[{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"batched\"}}}]"));
    const array = try c.next();
    try testing.expect(array[0] == '[');
    try expectContains(array, "\"id\":3");
    try expectContains(array, "batched");

    // What does not decode is refused on the stream, as stdio refuses a line.
    try testing.expectEqual(std.http.Status.accepted, try c.post(io, "{not json"));
    try expectContains(try c.next(), "\"code\":-32700");
}

test "HTTP+SSE: a POST naming no session, or one whose stream has ended, is refused" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.start(io);
    defer h.stop(io);
    var url_buffer: [96]u8 = undefined;
    const unknown = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/sse?sessionId=00", .{h.port});
    var refused = try h.client.send(io, .{ .method = .POST, .url = unknown, .headers = &.{.{ .name = "Content-Type", .value = "application/json" }}, .body = .{ .bytes = initialize_2024 } });
    defer refused.deinit(io);
    try testing.expectEqual(std.http.Status.not_found, refused.status);

    var c: SseClient = undefined;
    try c.open(&h, io);
    c.close(io);
    // The server notices the client gone within a keep-alive.
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        if (try c.post(io, initialize_2024) == .not_found) break;
        try io.sleep(.fromMilliseconds(20), .awake);
    } else return error.TestExpectedNotFound;
}
