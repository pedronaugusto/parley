//! The stdio transport: a line a message, answers whatever order requests
//! finish in, refusals that name the request they refuse, cancellation, and
//! a long request that holds up nothing behind it.
const std = @import("std");
const shakedown = @import("shakedown");
const aegis = @import("aegis");
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
    try stdio.serve(testing.io, testing.allocator, &server, .causeless(&in), .causeless(&out.writer), .{});
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
    try stdio.serve(testing.io, testing.allocator, &server, .causeless(&in), .causeless(&out.writer), .{});
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
    try stdio.serve(testing.io, testing.allocator, &server, .causeless(&in), .causeless(&out.writer), .{});
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
    try stdio.serve(testing.io, testing.allocator, &server, .causeless(&in), .causeless(&out.writer), .{});
    const answer = answerTo(out.written(), "\"id\":1,").?;
    try testing.expect(std.mem.find(u8, answer, "message limit") != null);
    try testing.expect(std.mem.find(u8, out.written(), "xxxx") == null);
}

fn serveTask(io: std.Io, server: *parley.Server, in: *Pipe, out: *Pipe) void {
    // the test reads what was written; how the serving ended is not what it checks
    stdio.serve(io, testing.allocator, server, .causeless(&in.reader), .causeless(&out.writer), .{}) catch {};
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
    try stdio.serve(testing.io, testing.allocator, &server, .causeless(&in), .causeless(&out.writer), .{});
    const answer = answerTo(out.written(), "\"id\":1,").?;
    try testing.expect(std.mem.find(u8, answer, "\"isError\"") == null);
    try testing.expect(std.mem.find(u8, answer, text) != null);
}

/// An `Io` with no task to spare: every request is answered on the task
/// that reads it.
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

/// Says it started, then sleeps until canceled.
const Stall = struct {
    var started: std.atomic.Value(bool) = .init(false);

    fn handle(call: *Call) Call.Error!parley.ToolResult {
        started.store(true, .release);
        call.io.sleep(.fromSeconds(60), .awake) catch return error.Canceled;
        return .ofText("woke");
    }
};

/// Waits (a while at most) until `flag` is set.
fn until(flag: *std.atomic.Value(bool)) !void {
    var waited: u32 = 0;
    while (!flag.load(.acquire) and waited < 1000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(10), .awake);
    try testing.expect(flag.load(.acquire));
}

fn serveOn(io: std.Io, server: *parley.Server, in: *std.Io.Reader, out: *std.Io.Writer) stdio.ServeError!void {
    return stdio.serve(io, testing.allocator, server, .causeless(in), .causeless(out), .{});
}

test "a request answered on serve's own task, canceled there, ends serve Canceled, unanswered" {
    var server = try newServer(testing.io);
    defer server.deinit();
    try server.addTool(testing.io, .{ .name = "stall" }, Stall.handle);
    Stall.started.store(false, .release);
    var serial: Serial = .init(testing.io, 0);
    var in: std.Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"stall\"," ++ meta ++ "}}\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var serving = try testing.io.concurrent(serveOn, .{ serial.io(), &server, &in, &out.writer });
    try until(&Stall.started);
    // Where the cancel was taken for the request's own and spent there,
    // serve read on to the end of its input and returned as if done.
    try testing.expectError(error.Canceled, serving.cancel(testing.io));
    try testing.expectEqualStrings("", out.written());
}

/// Messages a line each into `written`; `keepAliveFn` holds the stream
/// until `let_go`, so another message waits for its turn.
const Holding = struct {
    out: stdio.Out = .{ .beginFn = begin, .endFn = end, .keepAliveFn = hold },
    written: std.Io.Writer.Allocating,
    holding: std.atomic.Value(bool) = .init(false),
    let_go: std.Io.Event = .unset,

    fn begin(o: *stdio.Out) stdio.Out.Error!aegis.io.WriteEnd {
        const h: *Holding = @alignCast(@fieldParentPtr("out", o));
        return .causeless(&h.written.writer);
    }

    fn end(o: *stdio.Out) stdio.Out.Error!void {
        const h: *Holding = @alignCast(@fieldParentPtr("out", o));
        h.written.writer.writeByte('\n') catch return error.WriteFailed;
    }

    fn hold(o: *stdio.Out) stdio.Out.Error!void {
        const h: *Holding = @alignCast(@fieldParentPtr("out", o));
        h.holding.store(true, .release);
        h.let_go.waitUncancelable(testing.io);
        h.holding.store(false, .release);
    }
};

fn keepAlive(conn: *stdio.Connection) error{ WriteFailed, Canceled }!void {
    return conn.keepAlive();
}

fn take(conn: *stdio.Connection, bytes: []u8) stdio.Connection.TakeError!void {
    return conn.take(bytes);
}

/// Takes `message` on a task of its own while another holds the stream,
/// cancels it, and returns what the take returned.
fn takeWhileHeld(conn: *stdio.Connection, holding: *Holding, message: []const u8) stdio.Connection.TakeError!void {
    holding.let_go.reset();
    var keeping = try testing.io.concurrent(keepAlive, .{conn});
    defer {
        holding.let_go.set(testing.io);
        // the holder only holds; how it ends is not what the test checks
        keeping.await(testing.io) catch {};
    }
    var waited: u32 = 0;
    while (!holding.holding.load(.acquire) and waited < 1000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    var taking = try testing.io.concurrent(take, .{ conn, try testing.allocator.dupe(u8, message) });
    return taking.cancel(testing.io);
}

test "an answer canceled while it waits for its turn on the stream returns Canceled: a request's, and a batch's" {
    var server = try newServer(testing.io);
    defer server.deinit();
    var serial: Serial = .init(testing.io, 0);
    var holding: Holding = .{ .written = .init(testing.allocator) };
    defer holding.written.deinit();
    var conn: stdio.Connection = .init(serial.io(), testing.allocator, &server, &holding.out, .{});
    defer conn.deinit();
    // A request answered on the task that takes it: its answer waits for
    // the stream, and the cancel lands there. Where it was dropped, the
    // take returned as if answered.
    try testing.expectError(error.Canceled, takeWhileHeld(&conn, &holding, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}"));
    // A batch's array, written once its last request is answered.
    try conn.take(try testing.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}"));
    try testing.expectError(error.Canceled, takeWhileHeld(&conn, &holding, "[{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}]"));
    // Neither went out; the handshake's answer did.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, holding.written.written(), "\n"));
    try testing.expect(answerTo(holding.written.written(), "\"id\":2,") != null);
}

/// Cancels the first streaming write to a file: what a cancel of the task
/// writing stdout does to its `File.Writer`, which says `WriteFailed` and
/// keeps `Canceled` in its `err`.
const cancel_first_write = [_]shakedown.IoPlan.Entry{
    .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .cancel },
};

test "an answer on serve's own task whose flush is canceled ends serve Canceled" {
    var server = try newServer(testing.io);
    defer server.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "out", .{});
    defer file.close(testing.io);
    // No task to spare: the answer is written on serve's task.
    var serial: Serial = .init(testing.io, 0);
    const fio = try shakedown.FaultIo.init(testing.allocator, serial.io(), .{ .plan = &cancel_first_write });
    defer fio.deinit();
    var in: std.Io.Reader = .fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n",
    );
    var buffer: [256]u8 = undefined;
    var out = file.writerStreaming(fio.io(), &buffer);
    // Where the end could not say why the write failed, the stream was
    // taken for broken, the cancel spent, and serve read on to its end.
    try testing.expectError(error.Canceled, stdio.serve(fio.io(), testing.allocator, &server, .causeless(&in), .fromFile(&out), .{}));
    try testing.expectEqual(@as(usize, 1), fio.fired().len);
}

test "a channel's write canceled returns Canceled, not Closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "in", .{});
    defer file.close(testing.io);
    const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{ .plan = &cancel_first_write });
    defer fio.deinit();
    var from_server: std.Io.Reader = .fixed("");
    var buffer: [256]u8 = undefined;
    var to_server = file.writerStreaming(fio.io(), &buffer);
    var channel: stdio.Channel = .init(testing.allocator, .causeless(&from_server), .fromFile(&to_server));
    defer channel.deinit(testing.io);
    // Where the end could not say why, a canceled write was the server's
    // input gone.
    try testing.expectError(error.Canceled, channel.transport().notify(testing.io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
    try testing.expectEqual(@as(usize, 1), fio.fired().len);
}

/// Reports progress before it answers: a stream that cannot take the
/// report is gone, and the handler returns what the report said.
fn reporting(call: *Call) Call.Error!parley.ToolResult {
    try call.progress(1, null, null);
    return .ofText("reported");
}

/// Says it ran.
const Ran = struct {
    var ran: std.atomic.Value(bool) = .init(false);

    fn handle(_: *Call) Call.Error!parley.ToolResult {
        ran.store(true, .release);
        return .ofText("ran");
    }
};

test "a handler with nothing to answer, its stream gone, does not end serve" {
    var server = try newServer(testing.io);
    defer server.deinit();
    try server.addTool(testing.io, .{ .name = "reporting" }, reporting);
    try server.addTool(testing.io, .{ .name = "ran" }, Ran.handle);
    Ran.ran.store(false, .release);
    // No task to spare: each request is answered on serve's task.
    var serial: Serial = .init(testing.io, 0);
    const with_token =
        \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":1}
    ;
    var in: std.Io.Reader = .fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"reporting\"," ++ with_token ++ "}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ran\"," ++ meta ++ "}}\n",
    );
    var out: std.Io.Writer = .failing;
    // Where the handler said its stream was gone with `Canceled`, serve
    // took it for its own task's cancel and returned at the first request.
    try stdio.serve(serial.io(), testing.allocator, &server, .causeless(&in), .causeless(&out), .{});
    try testing.expect(Ran.ran.load(.acquire));
}
