//! The request headers 2026-07-28 Streamable HTTP mirrors from the body
//! (`Mcp-Method`, `Mcp-Name`, `Mcp-Param-{name}`), and the Base64 sentinel
//! a value that is not plain ASCII travels in: `=?base64?{value}?=`.
const std = @import("std");

const base64 = std.base64.standard;
const Allocator = std.mem.Allocator;

pub const protocol_version = "MCP-Protocol-Version";
pub const method = "Mcp-Method";
pub const name = "Mcp-Name";
pub const param_prefix = "Mcp-Param-";
pub const session_id = "Mcp-Session-Id";

const prefix = "=?base64?";
const suffix = "?=";

/// Whether `value` may travel as a header value as it is: visible ASCII,
/// space and tab, no space or tab at either end, and not spelling the
/// sentinel itself.
pub fn plain(value: []const u8) bool {
    if (value.len != 0 and (isSpace(value[0]) or isSpace(value[value.len - 1]))) return false;
    for (value) |c| if (!(c == '\t' or (c >= 0x20 and c <= 0x7e))) return false;
    return !sentinel(value);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn sentinel(value: []const u8) bool {
    return value.len >= prefix.len + suffix.len and std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix);
}

/// `value` as a header carries it: as it is when plain, else in the
/// sentinel, on `arena`.
pub fn encode(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    if (plain(value)) return value;
    const out = try arena.alloc(u8, prefix.len + base64.Encoder.calcSize(value.len) + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    _ = base64.Encoder.encode(out[prefix.len .. out.len - suffix.len], value);
    @memcpy(out[out.len - suffix.len ..], suffix);
    return out;
}

/// `Invalid`: a value with a byte no header value holds, or a sentinel
/// whose content is not Base64.
pub const DecodeError = error{ Invalid, OutOfMemory };

/// What a header's value stands for: the value itself, or what its
/// sentinel holds, on `arena`.
pub fn decode(arena: Allocator, value: []const u8) DecodeError![]const u8 {
    for (value) |c| if (!(c == '\t' or (c >= 0x20 and c <= 0x7e))) return error.Invalid;
    if (!sentinel(value)) return value;
    const body = value[prefix.len .. value.len - suffix.len];
    const len = base64.Decoder.calcSizeForSlice(body) catch return error.Invalid;
    const out = try arena.alloc(u8, len);
    base64.Decoder.decode(out, body) catch return error.Invalid;
    return out;
}

test "plain values travel as they are; others in the sentinel, which reads back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("us-west1", try encode(a, "us-west1"));
    // The spec's own examples (2026-07-28 streamable-http, value encoding).
    try std.testing.expectEqualStrings("=?base64?SGVsbG8sIOS4lueVjA==?=", try encode(a, "Hello, 世界"));
    try std.testing.expectEqualStrings("=?base64?IHBhZGRlZCA=?=", try encode(a, " padded "));
    try std.testing.expectEqualStrings("=?base64?bGluZTEKbGluZTI=?=", try encode(a, "line1\nline2"));
    try std.testing.expectEqualStrings("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", try encode(a, "=?base64?literal?="));
    for ([_][]const u8{ "us-west1", "Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?=", "" }) |v| {
        try std.testing.expectEqualStrings(v, try decode(a, try encode(a, v)));
    }
    try std.testing.expectError(error.Invalid, decode(a, "=?base64?!!!?="));
    try std.testing.expectError(error.Invalid, decode(a, "a\x01b"));
}
