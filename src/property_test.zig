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
