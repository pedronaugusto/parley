//! Properties of the header values a peer sends: any value is read back or
//! refused, and any value a client sends reads back as what it was. Run
//! seeded in every test run, and by the fuzzer under `bay properties --fuzz`.
const std = @import("std");
const shake = @import("shakedown");
const headers = @import("headers.zig");

const values = [_][]const u8{
    "us-west1",
    "=?base64?SGVsbG8sIOS4lueVjA==?=",
    "=?base64?IHBhZGRlZCA=?=",
    "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=",
    "tools/call",
    "",
};

/// Any header value: read as itself, or as what its sentinel holds, or
/// refused; one that reads is a value a client could have sent.
fn anyValue(_: void, c: *shake.Case) !void {
    var buffer: [256]u8 = undefined;
    const value = shake.gen.mutated(c.source, &buffer, &values);
    const read = headers.decode(c.gpa, value) catch |err| switch (err) {
        error.Invalid => return,
        error.OutOfMemory => return err,
    };
    if (headers.plain(value) and !std.mem.eql(u8, read, value)) return error.PlainValueChanged;
    // What reads back travels again, and reads back the same.
    if (!std.mem.eql(u8, try headers.decode(c.gpa, try headers.encode(c.gpa, read)), read)) return error.NoRoundTrip;
}

test "any header value is read back or refused" {
    try shake.check(std.testing.allocator, {}, anyValue, .{ .cases = 2000 });
}

/// Any bytes a value holds travel as a header value (visible ASCII, no
/// space at either end) and read back as they were.
fn anyBytes(_: void, c: *shake.Case) !void {
    var buffer: [256]u8 = undefined;
    const value = shake.gen.mutated(c.source, &buffer, &values);
    const sent = try headers.encode(c.gpa, value);
    for (sent) |b| if (!(b == '\t' or (b >= 0x20 and b <= 0x7e))) return error.NotAHeaderValue;
    if (sent.len != 0 and (sent[0] == ' ' or sent[0] == '\t' or sent[sent.len - 1] == ' ' or sent[sent.len - 1] == '\t')) return error.SpaceAtAnEnd;
    if (!std.mem.eql(u8, try headers.decode(c.gpa, sent), value)) return error.NoRoundTrip;
}

test "any value travels as a header value and reads back" {
    try shake.check(std.testing.allocator, {}, anyBytes, .{ .cases = 2000 });
}
