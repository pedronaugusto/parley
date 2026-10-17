//! The endpoint over a real loopback connection: uplink's server in front
//! of the core, uplink's client asking.
const std = @import("std");
const parley = @import("parley");
const uplink = @import("uplink");
const Endpoint = @import("Endpoint.zig");

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

/// A server and an endpoint in front of it, listening on loopback.
const Harness = struct {
    core: parley.Server,
    endpoint: Endpoint,
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
        try h.core.addTool(io, .{ .name = "stall" }, Stall.handle);
        h.endpoint = .init(testing.allocator, &h.core, .{ .keep_alive = .literal("100ms") });
        h.router = .init(testing.allocator);
        try h.router.add("/mcp", h.endpoint.handler());
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
        return .{ .status = response.status, .content_type = content_type, .body = try response.collect(arena, io, .limited(1 << 20)) };
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
    var remote: Transport = .init(testing.allocator, &h.client, url);
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
