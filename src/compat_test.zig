//! The session era over stdio: what Codex and Claude Code send (their own
//! captured lines), the methods only those revisions have, and input asked
//! of the client as requests of the server's, answered on stdin.
const std = @import("std");
const parley = @import("parley.zig");
const stdio = @import("stdio.zig");
const Pipe = @import("testing/Pipe.zig");
const shakedown = @import("shakedown");

const testing = std.testing;
const Call = parley.Call;

fn echo(_: *Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

fn greet(call: *Call) Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{
        .message = "Who are you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(answer.content.?.bytes);
}

fn chatty(call: *Call) Call.Error!parley.ToolResult {
    try call.log(.info, null, "hello");
    try call.log(.debug, null, "too fine");
    return .ofText("done");
}

fn newServer(io: std.Io) !parley.Server {
    var s = try parley.Server.init(testing.allocator, io, .{ .info = .{ .name = "legacy", .version = "0" } });
    errdefer s.deinit();
    try s.addTool(io, .{ .name = "echo", .description = "Echo text" }, echo);
    try s.addTool(io, .{ .name = "greet" }, greet);
    try s.addTool(io, .{ .name = "chatty" }, chatty);
    return s;
}

fn answerTo(lines: []const u8, id: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| if (std.mem.find(u8, line, id) != null) return line;
    return null;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("\n{s}\ndoes not contain\n{s}\n", .{ haystack, needle });
        return error.TestExpectedContains;
    }
}

test "Codex 0.160.0's session, as it sent it: initialize 2025-06-18, list, call" {
    var server = try newServer(testing.io);
    defer server.deinit();
    var in: std.Io.Reader = .fixed(@embedFile("testing/captures/codex-0.160.0.jsonl"));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const lines = out.written();
    const init = answerTo(lines, "\"id\":0,").?;
    try expectContains(init, "\"protocolVersion\":\"2025-06-18\",\"capabilities\":{");
    try expectContains(init, "\"serverInfo\":{\"name\":\"legacy\",\"version\":\"0\"}");
    try testing.expect(std.mem.find(u8, init, "resultType") == null);
    const listed = answerTo(lines, "\"id\":1,").?;
    try expectContains(listed, "\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text\"");
    try testing.expect(std.mem.find(u8, listed, "ttlMs") == null);
    try expectContains(answerTo(lines, "\"id\":2,").?, "\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]");
}

test "Claude Code 2.1.302's probe is answered modern, and it stays modern" {
    var server = try newServer(testing.io);
    defer server.deinit();
    // Its second session, against a modern server: the probe, then listen,
    // list and call, each with its `_meta`. Every request is answered.
    const capture = @embedFile("testing/captures/claude-code-2.1.302.jsonl");
    var it = std.mem.splitScalar(u8, capture, '\n');
    var modern: std.ArrayList(u8) = .empty;
    defer modern.deinit(testing.allocator);
    var after_first_probe = false;
    while (it.next()) |line| {
        if (std.mem.find(u8, line, "server-discover-probe-1") != null) {
            if (after_first_probe) try modern.appendSlice(testing.allocator, "");
            after_first_probe = true;
        }
        if (std.mem.find(u8, line, "\"method\":\"initialize\"") != null) break;
        if (line.len != 0) {
            try modern.appendSlice(testing.allocator, line);
            try modern.append(testing.allocator, '\n');
        }
    }
    var in: std.Io.Reader = .fixed(modern.items);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const discovered = answerTo(out.written(), "server-discover-probe-1").?;
    try expectContains(discovered, "\"supportedVersions\":[\"2026-07-28\"");
}

test "the session's own methods: ping, the log level, subscriptions; requests before initialize refused" {
    var server = try newServer(testing.io);
    defer server.deinit();
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
        \\{"jsonrpc":"2.0","id":4,"method":"logging/setLevel","params":{"level":"info"}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"chatty"}}
        \\{"jsonrpc":"2.0","id":6,"method":"resources/subscribe","params":{"uri":"test://x"}}
        \\{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
        \\{"jsonrpc":"2.0","id":8,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        \\
    ;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const lines = out.written();
    try expectContains(answerTo(lines, "\"id\":1,").?, "-32602");
    try expectContains(answerTo(lines, "\"id\":3,").?, "\"result\":{}");
    try expectContains(answerTo(lines, "\"id\":4,").?, "\"result\":{}");
    try expectContains(lines, "\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"hello\"}");
    try testing.expect(std.mem.find(u8, lines, "too fine") == null);
    try expectContains(answerTo(lines, "\"id\":6,").?, "\"result\":{}");
    try expectContains(answerTo(lines, "\"id\":7,").?, "-32600");
    try expectContains(answerTo(lines, "\"id\":8,").?, "\"resultType\":\"complete\"");
}

/// An `Io` with no task to spare.
const Serial = shakedown.Layer(u8, .{
    .concurrent = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    }.concurrent,
    .groupConcurrent = struct {
        fn groupConcurrent(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    }.groupConcurrent,
});

test "a session whose list changes have no task to go out on is refused, where its client would never hear of them" {
    var server = try newServer(testing.io);
    defer server.deinit();
    var serial: Serial = .init(testing.io, 0);
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        \\
    ;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.ConcurrencyUnavailable, stdio.serve(serial.io(), testing.allocator, &server, &in, &out.writer, .{}));
    // The handshake itself was answered, inline: requests need no task.
    try expectContains(answerTo(out.written(), "\"id\":1,").?, "\"protocolVersion\":\"2025-11-25\"");
}

fn serveTask(io: std.Io, server: *parley.Server, in: *Pipe, out: *Pipe) void {
    // glint-ignore: Z026 -- the test reads what was written; how the serving ended is not what it checks
    stdio.serve(io, testing.allocator, server, &in.reader, &out.writer, .{}) catch {};
    out.close();
}

fn readLine(p: *Pipe) ![]const u8 {
    return (try p.reader.takeDelimiter('\n')) orelse error.EndOfStream;
}

test "input the handler asks for goes to the client as the server's request, and its answer back to the handler" {
    const io = testing.io;
    var server = try newServer(io);
    defer server.deinit();
    var in_storage: [4096]u8 = undefined;
    var in_buffer: [4096]u8 = undefined;
    var in: Pipe = .init(io, &in_storage, &in_buffer, &.{});
    var out_storage: [4096]u8 = undefined;
    var out_read: [4096]u8 = undefined;
    var out_write: [4096]u8 = undefined;
    var out: Pipe = .init(io, &out_storage, &out_read, &out_write);
    var task = try io.concurrent(serveTask, .{ io, &server, &in, &out });
    defer task.cancel(io);

    try in.write("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"elicitation\":{}}}}\n");
    _ = try readLine(&out);
    try in.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\"}}\n");
    const asked = try readLine(&out);
    try expectContains(asked, "\"method\":\"elicitation/create\",\"params\":{\"message\":\"Who are you?\",\"requestedSchema\":");
    const id_start = std.mem.find(u8, asked, "\"id\":").? + 5;
    const id_end = std.mem.findScalarPos(u8, asked, id_start, ',').?;
    var answer_buffer: [256]u8 = undefined;
    const answer = try std.mem.print(&answer_buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"action\":\"accept\",\"content\":{{\"name\":\"ada\"}}}}}}\n", .{asked[id_start..id_end]});
    try in.write(answer);
    const done = try readLine(&out);
    try expectContains(done, "\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"name\\\":\\\"ada\\\"}\"}]}");
    in.close();
}
