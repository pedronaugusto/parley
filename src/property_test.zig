//! Properties of every parser of what a peer sends, held to a model. Run
//! seeded in every test run, and by the fuzzer under `bay properties --fuzz`.
const std = @import("std");
const shake = @import("shakedown");
const wire = @import("wire.zig");
const wire_limits = wire.limitsFor(wire.default_message);

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
    const message = wire.decode(c.gpa, input, .{ .fault = &fault, .limits = wire_limits }) catch |err| {
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
    const message = try wire.decode(c.gpa, out.written(), .{ .limits = wire_limits });
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
    try stdio.serve(io, gpa, server, .causeless(&in), .causeless(&out.writer), .{});
    // Every line out is one JSON-RPC message.
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        _ = wire.decode(c.gpa, line, .{ .limits = wire_limits }) catch return error.ServerWroteWhatIsNotAMessage;
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

const registry = @import("registry.zig");

const schema_examples = [_][]const u8{
    "{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"},\"n\":{\"type\":\"integer\",\"x-mcp-header\":\"N\"}}}",
    "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"boolean\",\"x-mcp-header\":\"B\"}}}}}",
    "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"x\"},\"y\":{\"type\":\"string\",\"x-mcp-header\":\"X\"}}}",
    "{\"type\":\"object\",\"items\":{\"x-mcp-header\":\"I\"},\"properties\":{}}",
};

/// The `x-mcp-header` marks of any input schema (a client reads them from
/// any server): found or refused, never more than once a name, each a
/// token naming a property's place; nothing kept when refused.
fn anySchema(_: void, c: *shake.Case) !void {
    var buffer: [600]u8 = undefined;
    const schema = shake.gen.mutated(c.source, &buffer, &schema_examples);
    const gpa = std.testing.allocator;
    const params = registry.headerParams(gpa, schema, wire_limits) catch |err| switch (err) {
        error.InvalidSchema => return,
        error.OutOfMemory => return err,
    };
    defer registry.freeHeaderParams(gpa, params);
    for (params, 0..) |p, i| {
        if (p.name.len == 0 or p.path.len == 0) return error.EmptyMark;
        for (params[0..i]) |q| if (std.ascii.eqlIgnoreCase(p.name, q.name)) return error.NameTwice;
    }
}

test "any input schema's header marks are found or refused" {
    try shake.check(std.testing.allocator, {}, anySchema, .{ .cases = 2000 });
}

const meta = @import("meta.zig");
const types = @import("types.zig");

/// A request's `_meta`, as `meta.read` promises it: each reserved key it
/// reads comes back as written, one absent is null, `raw` is the `_meta`
/// object as written, the params' other members and `_meta`'s vendor keys
/// change nothing, and params that are not an object, or a reserved key of
/// the wrong shape, are `Malformed`.
fn requestMeta(_: void, c: *shake.Case) !void {
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    const w = &out.writer;
    // What is written, and so what reading must give.
    var version: ?[]const u8 = null;
    var level: ?types.LoggingLevel = null;
    var token: ?types.Token = null;
    var malformed = false;
    var raw: ?[]const u8 = null;

    if (shake.gen.intRange(c.source, u8, 0, 15) == 0) {
        // Params that are not an object.
        try w.writeAll(if (shake.gen.boolean(c.source)) "[{\"_meta\":{}}]" else "7");
        malformed = true;
    } else {
        try w.writeAll("{");
        var members: usize = 0;
        if (shake.gen.boolean(c.source)) {
            try w.writeAll("\"name\":\"echo\"");
            members += 1;
        }
        if (shake.gen.boolean(c.source)) {
            if (members > 0) try w.writeAll(",");
            try w.writeAll("\"_meta\":");
            const start = out.written().len;
            try w.writeAll("{");
            var keys: usize = 0;
            if (shake.gen.boolean(c.source)) {
                const text = try shake.gen.string(c.source, c.gpa, .{ .kind = .utf8, .max_len = 16 });
                try w.print("\"{s}\":{f}", .{ meta.protocol_version, std.json.fmt(text, .{}) });
                version = text;
                keys += 1;
            }
            if (shake.gen.boolean(c.source)) {
                if (keys > 0) try w.writeAll(",");
                try w.writeAll("\"com.example/vendor\":[1,{\"logLevel\":null}]");
                keys += 1;
            }
            switch (shake.gen.intRange(c.source, u8, 0, 3)) {
                0 => {},
                1, 2 => {
                    if (keys > 0) try w.writeAll(",");
                    const all = std.enums.values(types.LoggingLevel);
                    const chosen = all[shake.gen.intRange(c.source, usize, 0, all.len - 1)];
                    try w.print("\"{s}\":\"{s}\"", .{ meta.log_level, @tagName(chosen) });
                    level = chosen;
                    keys += 1;
                },
                else => {
                    if (keys > 0) try w.writeAll(",");
                    try w.print("\"{s}\":{s}", .{ meta.log_level, if (shake.gen.boolean(c.source)) "\"loud\"" else "3" });
                    malformed = true;
                    keys += 1;
                },
            }
            switch (shake.gen.intRange(c.source, u8, 0, 4)) {
                0 => {},
                1 => {
                    if (keys > 0) try w.writeAll(",");
                    const n = shake.gen.int(c.source, i64);
                    try w.print("\"{s}\":{d}", .{ meta.progress_token, n });
                    token = .{ .integer = n };
                    keys += 1;
                },
                2 => {
                    if (keys > 0) try w.writeAll(",");
                    const text = try shake.gen.string(c.source, c.gpa, .{ .kind = .utf8, .max_len = 16 });
                    try w.print("\"{s}\":{f}", .{ meta.progress_token, std.json.fmt(text, .{}) });
                    token = .{ .string = text };
                    keys += 1;
                },
                3 => {
                    if (keys > 0) try w.writeAll(",");
                    try w.print("\"{s}\":{s}", .{ meta.progress_token, if (shake.gen.boolean(c.source)) "true" else "{}" });
                    malformed = true;
                    keys += 1;
                },
                else => {
                    if (keys > 0) try w.writeAll(",");
                    try w.print("\"{s}\":{s}", .{ meta.client_info, if (shake.gen.boolean(c.source)) "5" else "[]" });
                    malformed = true;
                    keys += 1;
                },
            }
            try w.writeAll("}");
            raw = out.written()[start..];
            members += 1;
        }
        if (shake.gen.boolean(c.source)) {
            if (members > 0) try w.writeAll(",");
            try w.writeAll("\"arguments\":{\"_meta\":{\"progressToken\":\"not this one\"}}");
        }
        try w.writeAll("}");
    }
    const params = out.written();
    const got = meta.read(c.gpa, params, wire_limits) catch |err| switch (err) {
        error.Malformed => return if (malformed) {} else error.RefusedWellFormed,
        error.OutOfMemory => return err,
    };
    if (malformed) return error.TookMalformed;
    if ((got.raw == null) != (raw == null)) return error.RawChanged;
    if (raw) |r| if (!std.mem.eql(u8, got.raw.?, r)) return error.RawChanged;
    if ((got.version == null) != (version == null)) return error.VersionChanged;
    if (version) |v| if (!std.mem.eql(u8, got.version.?, v)) return error.VersionChanged;
    if (got.log_level != level) return error.LevelChanged;
    if ((got.progress_token == null) != (token == null)) return error.TokenChanged;
    if (token) |t| switch (t) {
        .integer => |n| if (got.progress_token.? != .integer or got.progress_token.?.integer != n) return error.TokenChanged,
        .string => |s| if (got.progress_token.? != .string or !std.mem.eql(u8, got.progress_token.?.string, s)) return error.TokenChanged,
    };
}

test "a request's _meta reads back as written, or is refused exactly where it is malformed" {
    try shake.check(std.testing.allocator, {}, requestMeta, .{ .cases = 2000 });
}
