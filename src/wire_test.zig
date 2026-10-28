//! The envelope read and written: what is a message, what is refused with
//! which code, and what the two clients that matter today send.
const std = @import("std");
const wire = @import("wire.zig");
const wire_limits = wire.limitsFor(wire.default_message);

const testing = std.testing;

fn decode(bytes: []const u8, fault: *wire.Fault) wire.DecodeError!wire.Message {
    return wire.decode(testing.allocator, bytes, .{ .fault = fault, .limits = wire_limits });
}

fn expectRefused(bytes: []const u8, code: wire.Code, id: ?wire.Id) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fault: wire.Fault = .{};
    if (wire.decode(arena.allocator(), bytes, .{ .fault = &fault, .limits = wire_limits })) |m| {
        std.debug.print("accepted {s} as {t}\n", .{ bytes, m });
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(if (code == .parse_error) error.Malformed else error.Invalid, err);
    }
    try testing.expectEqual(code, fault.code);
    if (id) |want| {
        try testing.expect(fault.id != null);
        try testing.expect(want.eql(fault.id.?));
    } else try testing.expect(fault.id == null);
}

test "a request with an integer id and params, as written" {
    var fault: wire.Fault = .{};
    const m = try decode("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{\"cursor\":\"a\"}}", &fault);
    try testing.expectEqual(wire.Id{ .integer = 7 }, m.request.id);
    try testing.expectEqualStrings("tools/list", m.request.method);
    try testing.expectEqualStrings("{\"cursor\":\"a\"}", m.request.params.?);
}

test "members in any order and any spacing; unknown members passed over" {
    var fault: wire.Fault = .{};
    const m = try decode(" { \"method\" : \"ping\" ,\"x\":[1,{\"y\":null}], \"id\" : \"a\",\n\"jsonrpc\":\"2.0\" } ", &fault);
    try testing.expectEqualStrings("a", m.request.id.string);
    try testing.expectEqualStrings("ping", m.request.method);
    try testing.expect(m.request.params == null);
}

test "an escaped method and string id are unescaped, and equal their plain spelling" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try wire.decode(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":\"l\\u0069sten:0\",\"method\":\"tools\\/call\"}", .{ .limits = wire_limits });
    try testing.expectEqualStrings("tools/call", m.request.method);
    try testing.expect(m.request.id.eql(.{ .string = "listen:0" }));
}

test "a notification has no id" {
    var fault: wire.Fault = .{};
    const m = try decode("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", &fault);
    try testing.expectEqualStrings("notifications/initialized", m.notification.method);
}

test "a result and an error, an error's id may be null" {
    var fault: wire.Fault = .{};
    const r = try decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}", &fault);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", r.result.result);
    const e = try decode("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\",\"data\":[1]}}", &fault);
    try testing.expect(e.failure.id == null);
    try testing.expectEqual(wire.Code.parse_error, e.failure.code);
    try testing.expectEqualStrings("Parse error", e.failure.message);
    try testing.expectEqualStrings("[1]", e.failure.data.?);
    const peer = try decode("{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"message\":\"x\",\"code\":-1}}", &fault);
    try testing.expectEqual(@as(i64, -1), @backingInt(peer.failure.code));
}

test "what is not JSON is a parse error; what is not a message is invalid, naming its id when it has one" {
    try expectRefused("", .parse_error, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",", .parse_error, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"} x", .parse_error, null);
    try expectRefused("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"}]", .invalid_request, null);
    try expectRefused("\"hello\"", .invalid_request, null);
    try expectRefused("{\"id\":1,\"method\":\"a\"}", .invalid_request, .{ .integer = 1 });
    try expectRefused("{\"jsonrpc\":\"1.0\",\"id\":\"q\",\"method\":\"a\"}", .invalid_request, .{ .string = "q" });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"a\"}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"a\"}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"a\"}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":7}", .invalid_request, .{ .integer = 3 });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"a\",\"params\":5}", .invalid_request, .{ .integer = 3 });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"a\",\"method\":\"b\"}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{},\"error\":{\"code\":1,\"message\":\"\"}}", .invalid_request, .{ .integer = 3 });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"result\":{}}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":\"x\",\"message\":\"\"}}", .invalid_request, .{ .integer = 4 });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":4}", .invalid_request, .{ .integer = 4 });
    try expectRefused("{\"jsonrpc\":\"2.0\",\"params\":{}}", .invalid_request, null);
    try expectRefused("{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"method\":\"a\"}", .invalid_request, null);
}

test "a batch's elements are read each on its own: messages, and refusals naming their ids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const batch =
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/list"},
        \\ {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":0}},
        \\ {"jsonrpc":"2.0","id":2,"result":{}},
        \\ {"jsonrpc":"1.0","id":"q","method":"ping"},
        \\ 7]
    ;
    const elements = try wire.decodeBatch(arena.allocator(), batch, .{ .limits = wire_limits });
    try testing.expectEqual(@as(usize, 5), elements.len);
    try testing.expectEqualStrings("tools/list", elements[0].read.message.request.method);
    try testing.expectEqualStrings("notifications/cancelled", elements[1].read.message.notification.method);
    try testing.expectEqual(wire.Id{ .integer = 2 }, elements[2].read.message.result.id);
    try testing.expectEqual(wire.Code.invalid_request, elements[3].read.refused.code);
    try testing.expect(elements[3].read.refused.id.?.eql(.{ .string = "q" }));
    try testing.expectEqual(wire.Code.invalid_request, elements[4].read.refused.code);
    try testing.expect(elements[4].read.refused.id == null);
    // Each element keeps the bytes it was written as.
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}", elements[2].bytes);
}

test "a batch that is not JSON, empty, or not an array is refused whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { []const u8, wire.DecodeError, wire.Code }{
        .{ "[{\"jsonrpc\":\"2.0\",", error.Malformed, .parse_error },
        .{ "[]", error.Invalid, .invalid_request },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", error.Invalid, .invalid_request },
    };
    for (cases) |case| {
        var fault: wire.Fault = .{};
        try testing.expectError(case[1], wire.decodeBatch(arena.allocator(), case[0], .{ .fault = &fault, .limits = wire_limits }));
        try testing.expectEqual(case[2], fault.code);
    }
    // One message alone is no batch, and a batch is not one message.
    try testing.expect(wire.isBatch(" \n[{}]"));
    try testing.expect(!wire.isBatch("{}"));
}

test "what Claude Code 2.1.302 and Codex 0.160.0 send is read" {
    const lines = [_][]const u8{
        @embedFile("testing/captures/claude-code-2.1.302.jsonl"),
        @embedFile("testing/captures/codex-0.160.0.jsonl"),
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var read: usize = 0;
    for (lines) |file| {
        var it = std.mem.splitScalar(u8, file, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const m = try wire.decode(arena.allocator(), line, .{ .limits = wire_limits });
            switch (m) {
                .request, .notification => read += 1,
                else => return error.TestUnexpectedMessage,
            }
        }
    }
    try testing.expect(read >= 10);
}

test "written messages read back as what was written" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try wire.writeRequest(&w, .{ .string = "a\"b" }, "tools/call", "{\"name\":\"x\"}");
    var fault: wire.Fault = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request = try wire.decode(arena.allocator(), w.buffered(), .{ .fault = &fault, .limits = wire_limits });
    try testing.expectEqualStrings("a\"b", request.request.id.string);
    try testing.expectEqualStrings("{\"name\":\"x\"}", request.request.params.?);

    w = .fixed(&buffer);
    try wire.writeFailure(&w, null, .invalid_request, "bad\nline", null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"bad\\nline\"}}", w.buffered());
    const failure = try wire.decode(arena.allocator(), w.buffered(), .{ .limits = wire_limits });
    try testing.expectEqualStrings("bad\nline", failure.failure.message);

    w = .fixed(&buffer);
    try wire.writeResult(&w, .{ .integer = -3 }, "{}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":-3,\"result\":{}}", w.buffered());

    w = .fixed(&buffer);
    try wire.writeNotification(&w, "notifications/progress", "{\"progress\":1}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}", w.buffered());
}

test "a string written is JSON whatever its bytes: controls escaped, broken UTF-8 replaced" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try wire.writeString(&w, "a\x01\tz\xffé\xe2\x82");
    try testing.expectEqualStrings("\"a\\u0001\\tz\u{FFFD}é\u{FFFD}\u{FFFD}\"", w.buffered());
}

test "every limit grows with the message limit: a value past strand's defaults is read within a larger one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.alloc(u8, 20 << 20);
    @memset(text, 'x');
    const bytes = try a.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"text\":\"{s}\"}}}}", .{text});
    var fault: wire.Fault = .{};
    try testing.expectError(error.Invalid, wire.decode(a, bytes, .{ .fault = &fault, .limits = wire_limits }));
    try testing.expectEqualStrings("the message is past a limit", fault.reason);
    const m = try wire.decode(a, bytes, .{ .limits = wire.limitsFor(.literal("32MiB")) });
    try testing.expectEqual(bytes.len - 2 - "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":".len + 1, m.request.params.?.len);
}

test "the limits of a small message bound nothing its bytes admit" {
    const l = wire.limitsFor(.fromRaw(64));
    try testing.expectEqual(@as(usize, 64), l.input_bytes);
    try testing.expectEqual(@as(usize, 32), l.items);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dense = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":[1,2,3,4,5,6,7]}";
    _ = try wire.decode(arena.allocator(), dense, .{ .limits = wire.limitsFor(.fromRaw(dense.len)) });
}

test "a frame is one message, or a batch's elements where the revision has batches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const one = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const single = try wire.decodeFrame(arena.allocator(), one, false, .{ .limits = wire_limits });
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqualStrings(one, single[0].bytes);
    const batch = "[" ++ one ++ ",{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}]";
    const elements = try wire.decodeFrame(arena.allocator(), batch, true, .{ .limits = wire_limits });
    try testing.expectEqual(@as(usize, 2), elements.len);
    try testing.expectEqualStrings("notifications/progress", elements[1].read.message.notification.method);
    // Where the revision has none, a batch is refused as any non-message.
    try testing.expectError(error.Invalid, wire.decodeFrame(arena.allocator(), batch, false, .{ .limits = wire_limits }));
}
