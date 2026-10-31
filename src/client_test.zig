//! The client over stdio: against parley's own server (2026-07-28, with
//! input asked across rounds), and against a session server that does not
//! know `server/discover`.
const std = @import("std");
const parley = @import("parley.zig");
const stdio = @import("stdio.zig");
const Pipe = @import("testing/Pipe.zig");

const testing = std.testing;
const Io = std.Io;
const Call = parley.Call;
const Client = parley.Client;

fn echo(_: *Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

fn greet(call: *Call) Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{
        .message = "Who are you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}" },
    } }) orelse {
        try call.setState("asked");
        return error.InputRequired;
    };
    if (!std.mem.eql(u8, call.state() orelse "", "asked")) return error.InvalidInput;
    return .ofText(answer.content.?.bytes);
}

fn answerName(_: *Client.Handlers, _: Io, _: std.mem.Allocator, params: []const u8) Client.HandlerError!parley.types.ElicitResult {
    if (std.mem.find(u8, params, "Who are you?") == null) return error.Refused;
    return .{ .action = .accept, .content = .{ .bytes = "{\"name\":\"ada\"}" } };
}

/// Two pipes, a server reading one and writing the other.
const Wiring = struct {
    to_server: Pipe,
    from_server: Pipe,
    storage: [4][8192]u8 = undefined,

    fn init(w: *Wiring, io: Io) void {
        w.to_server = .init(io, &w.storage[0], &w.storage[1], &.{});
        w.from_server = .init(io, &w.storage[2], &w.storage[3], &.{});
    }
};

fn serveTask(io: Io, server: *parley.Server, in: *Pipe, out: *Pipe) void {
    // glint-ignore: Z026 -- the test reads what the client got; how the serving ended is not what it checks
    stdio.serve(io, testing.allocator, server, &in.reader, &out.writer, .{}) catch {};
    out.close();
}

test "a 2026-07-28 server: discovered, listed, called, input given across rounds" {
    const io = testing.io;
    var server = try parley.Server.init(testing.allocator, io, .{ .info = .{ .name = "s", .version = "1" }, .instructions = "be kind" });
    defer server.deinit();
    try server.addTool(io, .{ .name = "echo" }, echo);
    try server.addTool(io, .{ .name = "greet" }, greet);

    var wiring: Wiring = .{ .to_server = undefined, .from_server = undefined };
    wiring.init(io);
    var task = try io.concurrent(serveTask, .{ io, &server, &wiring.to_server, &wiring.from_server });
    defer task.cancel(io);

    var writer_buffer: [4096]u8 = undefined;
    var out = PipeWriter.init(&wiring.to_server, &writer_buffer);
    var channel: stdio.Channel = .init(testing.allocator, &wiring.from_server.reader, &out.writer);
    var answers: Client.Handlers = .{ .elicit = answerName };
    var client: Client = .init(testing.allocator, channel.transport(), .{
        .info = .{ .name = "c", .version = "1" },
        .handlers = &answers,
    });
    defer client.deinit();
    try channel.start(io, &client);
    defer channel.deinit(io);

    try client.connect(io);
    try testing.expectEqual(Client.Era.modern, client.era);
    try testing.expectEqualStrings("be kind", client.instructions.?);
    try testing.expectEqualStrings("s", client.server_info.?.name);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try client.list(io, a, "tools/list", null, null);
    try testing.expect(std.mem.find(u8, listed, "\"name\":\"greet\"") != null);
    const echoed = try client.callTool(io, a, "echo", .{ .text = "hello" }, null);
    try testing.expectEqualStrings("hello", echoed.content[0].text.text);
    var why: Client.Diagnostics = .{};
    const greeted = client.callTool(io, a, "greet", .{}, &why) catch |err| {
        if (why.failure) |f| std.debug.print("greet: {t} {s}\n", .{ f.code, f.message });
        return err;
    };
    try testing.expectEqualStrings("{\"name\":\"ada\"}", greeted.content[0].text.text);
    var diagnostics: Client.Diagnostics = .{};
    try testing.expectError(error.Failed, client.callTool(io, a, "nope", .{}, &diagnostics));
    try testing.expectEqual(parley.wire.Code.invalid_params, diagnostics.failure.?.code);
    wiring.to_server.close();
}

/// Runs as a task and asks who is there, as the task's input.
fn knock(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    const answer = try call.elicit("who", .{ .form = .{
        .message = "Who are you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(answer.content.?.bytes);
}

fn refuseTask(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    return error.HandlerFailed;
}

test "a call the server runs as a task: polled, its input given, answered as if at once" {
    const io = testing.io;
    var server = try parley.Server.init(testing.allocator, io, .{ .info = .{ .name = "s", .version = "1" }, .tasks = .{ .poll_interval = .literal("5ms") } });
    defer server.deinit();
    try server.addTool(io, .{ .name = "knock", .task = .required }, knock);
    try server.addTool(io, .{ .name = "refuse", .task = .optional }, refuseTask);

    var wiring: Wiring = .{ .to_server = undefined, .from_server = undefined };
    wiring.init(io);
    var task = try io.concurrent(serveTask, .{ io, &server, &wiring.to_server, &wiring.from_server });
    defer task.cancel(io);
    var writer_buffer: [4096]u8 = undefined;
    var out = PipeWriter.init(&wiring.to_server, &writer_buffer);
    var channel: stdio.Channel = .init(testing.allocator, &wiring.from_server.reader, &out.writer);
    var answers: Client.Handlers = .{ .elicit = answerName };
    var client: Client = .init(testing.allocator, channel.transport(), .{
        .info = .{ .name = "c", .version = "1" },
        .handlers = &answers,
    });
    defer client.deinit();
    try channel.start(io, &client);
    defer channel.deinit(io);
    try client.connect(io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const knocked = try client.callTool(io, a, "knock", .{}, null);
    try testing.expectEqualStrings("{\"name\":\"ada\"}", knocked.content[0].text.text);
    var why: Client.Diagnostics = .{};
    try testing.expectError(error.Failed, client.callTool(io, a, "refuse", .{}, &why));
    try testing.expectEqual(parley.wire.Code.internal_error, why.failure.?.code);
    wiring.to_server.close();
}

/// A writer into a pipe, flushed a line at a time by the channel.
const PipeWriter = struct {
    pipe: *Pipe,
    writer: Io.Writer,

    fn init(pipe: *Pipe, buffer: []u8) PipeWriter {
        return .{ .pipe = pipe, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *PipeWriter = @alignCast(@fieldParentPtr("writer", w));
        self.pipe.write(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.pipe.write(d) catch return error.WriteFailed;
            n += d.len;
        }
        for (0..splat) |_| self.pipe.write(data[data.len - 1]) catch return error.WriteFailed;
        return n + data[data.len - 1].len * splat;
    }
};

/// A session server as the ones that predate 2026-07-28 are: it knows no
/// `server/discover`, and serves after `initialize`.
fn sessionServer(io: Io, in: *Pipe, out: *Pipe) void {
    defer out.close();
    var seen_initialized = false;
    while (in.reader.takeDelimiter('\n') catch null) |line| {
        const id_at = std.mem.find(u8, line, "\"id\":") orelse {
            if (std.mem.find(u8, line, "notifications/initialized") != null) seen_initialized = true;
            continue;
        };
        const id_end = std.mem.findAnyPos(u8, line, id_at + 5, ",}").?;
        const id = line[id_at + 5 .. id_end];
        var buffer: [512]u8 = undefined;
        const answer = if (std.mem.find(u8, line, "server/discover") != null)
            std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}\n", .{id}) catch unreachable
        else if (std.mem.find(u8, line, "\"initialize\"") != null)
            std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"old\",\"version\":\"1\"}}}}}}\n", .{id}) catch unreachable
        else if (seen_initialized and std.mem.find(u8, line, "\"_meta\"") == null)
            std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"old school\"}}]}}}}\n", .{id}) catch unreachable
        else
            std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32600,\"message\":\"not initialized\"}}}}\n", .{id}) catch unreachable;
        out.queue.putAll(io, answer) catch return;
    }
}

test "a session server: discover not understood, so initialize, then requests without _meta" {
    const io = testing.io;
    var wiring: Wiring = .{ .to_server = undefined, .from_server = undefined };
    wiring.init(io);
    var task = try io.concurrent(sessionServer, .{ io, &wiring.to_server, &wiring.from_server });
    defer task.cancel(io);
    var writer_buffer: [4096]u8 = undefined;
    var out = PipeWriter.init(&wiring.to_server, &writer_buffer);
    var channel: stdio.Channel = .init(testing.allocator, &wiring.from_server.reader, &out.writer);
    var client: Client = .init(testing.allocator, channel.transport(), .{ .info = .{ .name = "c", .version = "1" } });
    defer client.deinit();
    try channel.start(io, &client);
    defer channel.deinit(io);

    try client.connect(io);
    try testing.expectEqual(Client.Era.session, client.era);
    try testing.expectEqual(parley.Revision.@"2025-06-18", client.revision);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const called = try client.callTool(io, arena.allocator(), "anything", .{}, null);
    try testing.expectEqualStrings("old school", called.content[0].text.text);
    wiring.to_server.close();
}

/// A 2024-11-05 server, scripted: it answers `initialize` at its own
/// revision whatever the client offers, and a call with a batch holding a
/// request of its own beside the call's answer.
const BatchingServer = struct {
    /// The line the client answered the batch with.
    answer: [256]u8 = undefined,
    answer_len: usize = 0,

    fn run(s: *BatchingServer, io: Io, in: *Pipe, out: *Pipe) void {
        defer out.close();
        while (in.reader.takeDelimiter('\n') catch null) |line| {
            if (line.len != 0 and line[0] == '[') {
                @memcpy(s.answer[0..line.len], line);
                s.answer_len = line.len;
                continue;
            }
            const id_at = std.mem.find(u8, line, "\"id\":") orelse continue;
            const id_end = std.mem.findAnyPos(u8, line, id_at + 5, ",}").?;
            const id = line[id_at + 5 .. id_end];
            var buffer: [512]u8 = undefined;
            const answer = if (std.mem.find(u8, line, "server/discover") != null)
                std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}\n", .{id}) catch unreachable
            else if (std.mem.find(u8, line, "\"initialize\"") != null)
                std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"older\",\"version\":\"1\"}}}}}}\n", .{id}) catch unreachable
            else
                std.mem.print(&buffer, "[{{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"ping\"}},{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"batched\"}}]}}}}]\n", .{id}) catch unreachable;
            out.queue.putAll(io, answer) catch return;
        }
    }
};

test "a 2024-11-05 server: its revision taken, a batch from it taken, its requests in one answered as an array" {
    const io = testing.io;
    var wiring: Wiring = .{ .to_server = undefined, .from_server = undefined };
    wiring.init(io);
    var server: BatchingServer = .{};
    var task = try io.concurrent(BatchingServer.run, .{ &server, io, &wiring.to_server, &wiring.from_server });
    defer task.cancel(io);
    var writer_buffer: [4096]u8 = undefined;
    var out = PipeWriter.init(&wiring.to_server, &writer_buffer);
    var channel: stdio.Channel = .init(testing.allocator, &wiring.from_server.reader, &out.writer);
    var client: Client = .init(testing.allocator, channel.transport(), .{ .info = .{ .name = "c", .version = "1" } });
    defer client.deinit();
    try channel.start(io, &client);
    defer channel.deinit(io);

    try client.connect(io);
    try testing.expectEqual(Client.Era.session, client.era);
    try testing.expectEqual(parley.Revision.@"2024-11-05", client.revision);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const called = try client.callTool(io, arena.allocator(), "anything", .{}, null);
    try testing.expectEqualStrings("batched", called.content[0].text.text);
    wiring.to_server.close();
    task.await(io);
    try testing.expectEqualStrings("[{\"jsonrpc\":\"2.0\",\"id\":900,\"result\":{}}]", server.answer[0..server.answer_len]);
}
