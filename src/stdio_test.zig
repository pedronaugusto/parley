//! The stdio transport: a line a message, answers whatever order requests
//! finish in, refusals that name the request they refuse, cancellation, and
//! a long request that holds up nothing behind it.
const std = @import("std");
const parley = @import("parley.zig");
const stdio = @import("stdio.zig");
const Pipe = @import("testing/Pipe.zig");

const testing = std.testing;
const Call = parley.Call;

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

fn echo(_: *Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

/// Sleeps until canceled.
fn slow(call: *Call) Call.Error!parley.ToolResult {
    call.io.sleep(.fromSeconds(60), .awake) catch return error.Canceled;
    return .ofText("woke");
}

/// A text larger than the limit the test sets.
const large_text: [8192]u8 = @splat('x');

fn large(_: *Call) error{}![]const u8 {
    return &large_text;
}

fn newServer(io: std.Io) !parley.Server {
    var s = try parley.Server.init(testing.allocator, io, .{ .info = .{ .name = "stdio", .version = "0" } });
    errdefer s.deinit();
    try s.addTool(io, .{ .name = "echo" }, echo);
    try s.addTool(io, .{ .name = "slow" }, slow);
    try s.addTool(io, .{ .name = "large" }, large);
    return s;
}

/// The answer to the request with id `id` among `lines`.
fn answerTo(lines: []const u8, id: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (std.mem.find(u8, line, id) != null) return line;
    }
    return null;
}

test "a line a message: answers, refusals naming their request, blank lines passed over, the end of input the end" {
    var server = try newServer(testing.io);
    defer server.deinit();
    const input =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"one\"}," ++ meta ++ "}}\r\n" ++
        "\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n" ++
        "not json\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\",\"params\":{" ++ meta ++ "}}\n" ++
        "{\"jsonrpc\":\"1.0\",\"id\":4,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":99}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}";
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const lines = out.written();
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, lines, "\n"));
    try testing.expect(std.mem.find(u8, answerTo(lines, "\"id\":1,").?, "\"text\":\"one\"") != null);
    try testing.expect(std.mem.find(u8, answerTo(lines, "\"id\":\"two\"").?, "\"tools\":[") != null);
    try testing.expect(answerTo(lines, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700") != null);
    try testing.expect(std.mem.find(u8, answerTo(lines, "\"id\":3,").?, "-32601") != null);
    try testing.expect(std.mem.find(u8, answerTo(lines, "\"id\":4,").?, "-32600") != null);
    try testing.expect(answerTo(lines, "\"id\":5,") != null);
}

test "a line past the limit is refused and the next one read" {
    var server = try newServer(testing.io);
    defer server.deinit();
    server.options.limits.message = .literal("1KiB");
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"padding\":\"" ++ @as([1100]u8, @splat('x')) ++ "\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n";
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const lines = out.written();
    try testing.expect(std.mem.find(u8, lines, "longer than the server reads") != null);
    try testing.expect(std.mem.find(u8, answerTo(lines, "\"id\":2,").?, "\"tools\":[") != null);
}

test "an answer past the limit is refused, not written" {
    var server = try newServer(testing.io);
    defer server.deinit();
    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}";
    server.options.limits.message = .fromRaw(request.len);
    var in: std.Io.Reader = .fixed(request ++ "\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const answer = answerTo(out.written(), "\"id\":1,").?;
    try testing.expect(std.mem.find(u8, answer, "-32603") != null);
    try testing.expect(std.mem.find(u8, answer, "message limit") != null);
    try testing.expect(std.mem.find(u8, answer, "\"tools\"") == null);
}

test "a tool's answer past the limit is refused, and nothing of it is written" {
    var server = try newServer(testing.io);
    defer server.deinit();
    server.options.limits.message = .literal("4KiB");
    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"large\"," ++ meta ++ "}}";
    var in: std.Io.Reader = .fixed(request ++ "\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const answer = answerTo(out.written(), "\"id\":1,").?;
    try testing.expect(std.mem.find(u8, answer, "message limit") != null);
    try testing.expect(std.mem.find(u8, out.written(), "xxxx") == null);
}

fn serveTask(io: std.Io, server: *parley.Server, in: *Pipe, out: *Pipe) void {
    // glint-ignore: Z026 -- the test reads what was written; how the serving ended is not what it checks
    stdio.serve(io, testing.allocator, server, &in.reader, &out.writer, .{}) catch {};
    out.close();
}

fn readLine(p: *Pipe) ![]const u8 {
    return (try p.reader.takeDelimiter('\n')) orelse error.EndOfStream;
}

test "a long request holds up nothing behind it, and is canceled without an answer" {
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

    try in.write("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"slow\"," ++ meta ++ "}}\n");
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"fast\"}," ++ meta ++ "}}\n");
    const fast = try readLine(&out);
    try testing.expect(std.mem.find(u8, fast, "\"id\":2,") != null);
    try in.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1,\"reason\":\"enough\"}}\n");
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n");
    const next = try readLine(&out);
    try testing.expect(std.mem.find(u8, next, "\"id\":3,") != null);
    in.close();
    // The end of input: the server returns, having written nothing for 1.
    if (out.reader.takeDelimiter('\n')) |line| {
        try testing.expect(line == null);
    } else |err| return err;
}

test "a stream ends by its client's cancellation, and by the end of input, unanswered" {
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

    const listen = "\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true}," ++ meta ++ "}}\n";
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":\"one\"," ++ listen);
    try testing.expect(std.mem.find(u8, try readLine(&out), "subscriptions/acknowledged") != null);
    try in.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"one\"}}\n");
    // Input is read in order: once the next request is answered, the
    // cancellation has been read, whichever task the change below runs on.
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n");
    try testing.expect(std.mem.find(u8, try readLine(&out), "\"id\":2,") != null);
    // Ended: a change goes to no stream, and the next answer is the next request's.
    try server.addTool(io, .{ .name = "another" }, echo);
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n");
    try testing.expect(std.mem.find(u8, try readLine(&out), "\"id\":3,") != null);
    try in.write("{\"jsonrpc\":\"2.0\",\"id\":\"two\"," ++ listen);
    try testing.expect(std.mem.find(u8, try readLine(&out), "subscriptions/acknowledged") != null);
    in.close();
    // The end of input ends the second: the server returns, having answered neither.
    if (out.reader.takeDelimiter('\n')) |line| {
        try testing.expect(line == null);
    } else |err| return err;
}

test "a message past strand's defaults, within the message limit, is read and answered" {
    var server = try newServer(testing.io);
    defer server.deinit();
    server.options.limits.message = .literal("48MiB");
    const text = try testing.allocator.alloc(u8, 20 << 20);
    defer testing.allocator.free(text);
    @memset(text, 'x');
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    try input.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"echo\",\"arguments\":{{\"text\":\"{s}\"}},{s}}}}}\n", .{ text, meta });
    var in: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try stdio.serve(testing.io, testing.allocator, &server, &in, &out.writer, .{});
    const answer = answerTo(out.written(), "\"id\":1,").?;
    try testing.expect(std.mem.find(u8, answer, "\"isError\"") == null);
    try testing.expect(std.mem.find(u8, answer, text) != null);
}
