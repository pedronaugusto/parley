//! Properties of every parser of what a peer sends, held to a model. Run
//! seeded in every test run, and by the fuzzer under `bay properties --fuzz`.
const std = @import("std");
const shake = @import("shakedown");
const wire = @import("wire.zig");

const examples = [_][]const u8{
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"},\"_meta\":{\"progressToken\":4}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"listen:0\",\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true}}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"123\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"resultType\":\"complete\",\"tools\":[]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
};

/// Any bytes: decoding never fails but by refusing, a refusal carries the
/// code its error says, and what is accepted is one of the four shapes with
/// its parts inside the input or on the arena.
fn anyBytes(_: void, c: *shake.Case) !void {
    var buffer: [512]u8 = undefined;
    const input = shake.gen.mutated(c.source, &buffer, &examples);
    var fault: wire.Fault = .{};
    const message = wire.decode(c.gpa, input, .{ .fault = &fault }) catch |err| {
        switch (err) {
            error.Malformed => if (fault.code != .parse_error) return error.FaultDisagrees,
            error.Invalid => if (fault.code != .invalid_request) return error.FaultDisagrees,
            error.OutOfMemory => return err,
        }
        return;
    };
    switch (message) {
        .request => |r| if (r.method.len > input.len) return error.MethodPastInput,
        .notification => |n| if (n.params) |p| if (p[0] != '{' and p[0] != '[') return error.ParamsNotStructured,
        .result => |r| if (r.result.len == 0) return error.EmptyResult,
        .failure => |f| if (f.message.len > input.len) return error.MessagePastInput,
    }
}

test "any bytes are read as a message or refused with the code their error says" {
    try shake.check(std.testing.allocator, {}, anyBytes, .{ .cases = 2000 });
}

/// A message written from any id, method and params reads back as itself.
fn roundTrip(_: void, c: *shake.Case) !void {
    const id: wire.Id = if (shake.gen.boolean(c.source))
        .{ .integer = shake.gen.int(c.source, i64) }
    else
        .{ .string = try shake.gen.string(c.source, c.gpa, .{ .kind = .utf8 }) };
    const method = try shake.gen.string(c.source, c.gpa, .{ .kind = .utf8, .min_len = 1 });
    const params: ?[]const u8 = switch (shake.gen.intRange(c.source, u8, 0, 2)) {
        0 => null,
        1 => "{\"a\":[1,2,{\"b\":null}]}",
        else => "[]",
    };
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    const notification = shake.gen.boolean(c.source);
    if (notification) try wire.writeNotification(&out.writer, method, params) else try wire.writeRequest(&out.writer, id, method, params);
    const message = try wire.decode(c.gpa, out.written(), .{});
    if (notification) {
        if (!std.mem.eql(u8, message.notification.method, method)) return error.MethodChanged;
        if ((message.notification.params == null) != (params == null)) return error.ParamsChanged;
    } else {
        if (!message.request.id.eql(id)) return error.IdChanged;
        if (!std.mem.eql(u8, message.request.method, method)) return error.MethodChanged;
        if (params) |p| if (!std.mem.eql(u8, message.request.params.?, p)) return error.ParamsChanged;
    }
}

test "a message written reads back as what was written" {
    try shake.check(std.testing.allocator, {}, roundTrip, .{ .cases = 500 });
}

const Server = @import("Server.zig");
const stdio = @import("stdio.zig");
const state = @import("state.zig");
const Call = @import("Call.zig");

fn echo(_: *Call, args: struct { text: []const u8, times: u8 = 1 }) error{}![]const u8 {
    return args.text;
}

fn asks(call: *Call) Call.Error!@import("registry.zig").ToolResult {
    _ = try call.elicit("x", .{ .form = .{ .message = "?", .requested_schema = .{ .bytes = "{\"type\":\"object\"}" } } }) orelse {
        try call.setState("kept");
        return error.InputRequired;
    };
    return .ofText("ok");
}

const line_examples = [_][]const u8{
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}},\"progressToken\":1}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"asks\",\"inputResponses\":{\"x\":{\"action\":\"accept\"}},\"requestState\":\"AQ\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}}}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"elicitation\":{}},\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"test://x\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{\"cursor\":\"0.1\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"p\"},\"argument\":{\"name\":\"a\",\"value\":\"b\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}",
};

/// What a client sends, mutated, a few lines at a time: the server answers
/// or refuses every line and never fails while doing it.
fn anyLines(_: void, c: *shake.Case) !void {
    // The server answers on tasks of its own: it allocates from a
    // thread-safe allocator (the case's arena is not), and the Io and the
    // server live for the case, so what they hold is taken back with it
    // (under the fuzzer the leak check runs after each input).
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var owned = try Server.init(gpa, io, .{ .info = .{ .name = "fuzz", .version = "0" } });
    defer owned.deinit();
    const server = &owned;
    try server.addTool(io, .{ .name = "echo" }, echo);
    try server.addTool(io, .{ .name = "asks" }, asks);
    var input: std.ArrayList(u8) = .empty;
    var lines = shake.gen.intRange(c.source, u8, 1, 4);
    while (lines > 0) : (lines -= 1) {
        var buffer: [600]u8 = undefined;
        const line = shake.gen.mutated(c.source, &buffer, &line_examples);
        for (line) |b| try input.append(c.gpa, if (b == '\n') ' ' else b);
        try input.append(c.gpa, '\n');
    }
    var in: std.Io.Reader = .fixed(input.items);
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    try stdio.serve(io, gpa, server, &in, &out.writer, .{});
    // Every line out is one JSON-RPC message.
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        _ = wire.decode(c.gpa, line, .{}) catch return error.ServerWroteWhatIsNotAMessage;
    }
}

test "any lines a client sends are answered or refused, each answer a message" {
    try shake.check(std.testing.allocator, {}, anyLines, .{ .cases = 300 });
}

/// A sealed state with any byte changed, cut or grown never opens; the
/// sealed state itself opens to what was sealed, for its own request only.
fn sealedState(sealer: *const state.Sealer, c: *shake.Case) !void {
    const io = std.testing.io;
    const payload = try shake.gen.string(c.source, c.gpa, .{ .kind = .bytes, .max_len = 64 });
    const binding: state.Binding = .{ .principal = null, .method = "tools/call", .subject = "t" };
    const sealed = try sealer.seal(io, c.gpa, binding, payload);
    const opened = try sealer.open(io, c.gpa, binding, sealed);
    if (!std.mem.eql(u8, opened, payload)) return error.OpenedOtherBytes;
    if (sealer.open(io, c.gpa, .{ .principal = "someone", .method = "tools/call", .subject = "t" }, sealed)) |_| return error.OpenedForAnotherPrincipal else |_| {}
    var buffer: [256]u8 = undefined;
    const changed = shake.gen.mutated(c.source, &buffer, &.{sealed});
    if (std.mem.eql(u8, changed, sealed)) return;
    if (sealer.open(io, c.gpa, binding, changed)) |bytes| {
        // A different spelling of the same Base64 is the same seal.
        if (!std.mem.eql(u8, bytes, payload)) return error.OpenedAChangedSeal;
    } else |err| switch (err) {
        error.Tampered, error.Expired => {},
        error.OutOfMemory => return err,
    }
}

test "sealed state opens only unchanged, for its own request" {
    var sealer = try state.Sealer.init(std.testing.io, .fromSeconds(60));
    defer sealer.deinit();
    try shake.check(std.testing.allocator, &sealer, sealedState, .{ .cases = 300 });
}
