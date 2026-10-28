//! JSON-RPC 2.0 as MCP speaks it, without I/O: a message read off its bytes
//! and told apart (request, notification, result, error), and a message
//! written around bytes its caller produces.
//!
//! Reading looks only at the envelope: `jsonrpc`, `id`, `method`, `params`,
//! `result` and `error`. Everything else stays the bytes it was written as,
//! checked as JSON and handed on: `params` and `result` are one JSON value
//! each, for the layer that knows their shape. Nothing is allocated for a
//! message whose method and string id have no escapes in them; one that has
//! them is unescaped onto the arena.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");

const json = strand.json;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// A request's id: a string or an integer, never null (MCP narrows JSON-RPC,
/// which also allows null and fractions). A string is held unescaped, so two
/// spellings of one id are one id.
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .integer => |x| b == .integer and b.integer == x,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        };
    }

    /// The id as JSON.
    pub fn write(id: Id, w: *Writer) Writer.Error!void {
        switch (id) {
            .integer => |n| try w.print("{d}", .{n}),
            .string => |s| try writeString(w, s),
        }
    }
};

/// The error codes MCP gives a meaning. Any other integer is the peer's own
/// and passes through as it came.
pub const Code = enum(i64) {
    /// The bytes are not JSON.
    parse_error = -32700,
    /// JSON, but not a JSON-RPC message MCP accepts.
    invalid_request = -32600,
    method_not_found = -32601,
    /// The params are wrong; also an unknown tool, a missing resource
    /// (2026-07-28) and a request without the `_meta` it must carry.
    invalid_params = -32602,
    internal_error = -32603,
    /// 2026-07-28: an HTTP header disagrees with the body, or a required one
    /// is missing or malformed.
    header_mismatch = -32020,
    /// 2026-07-28: serving the request needs a capability the client did
    /// not declare.
    missing_required_client_capability = -32021,
    /// 2026-07-28: the server does not serve the requested protocol version.
    unsupported_protocol_version = -32022,
    /// 2025-11-25 and earlier: the resource does not exist (now
    /// `invalid_params`). A client still accepts it.
    resource_not_found = -32002,
    _,
};

/// A request: it asks for exactly one response with its `id`.
pub const Request = struct {
    id: Id,
    method: []const u8,
    /// One JSON value, an object or an array, as written; null when absent.
    params: ?[]const u8,
};

/// A notification: no id, and no response.
pub const Notification = struct {
    method: []const u8,
    params: ?[]const u8,
};

/// A successful response.
pub const Result = struct {
    id: Id,
    /// One JSON value, as written.
    result: []const u8,
};

/// An error response. Its id is null when the request it answers could not
/// be read far enough to know one.
pub const Failure = struct {
    id: ?Id,
    code: Code,
    message: []const u8,
    /// One JSON value, as written; null when absent.
    data: ?[]const u8,
};

pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    result: Result,
    failure: Failure,
};

/// Why a message was refused, and what to answer it with: the code, the id
/// when one could be read (so the answer names the request it refuses), and
/// a reason for the answer's message.
pub const Fault = struct {
    code: Code = .parse_error,
    id: ?Id = null,
    reason: []const u8 = "",
};

/// The bytes one message may hold, by default: strand's own input limit.
pub const default_message: aegis.units.Bytes(u32) = .literal("16MiB");

/// strand's limits for a message of at most `message` bytes, and for every
/// read or write of a value within it: the message limit is the one a peer
/// sets, and no count inside it refuses what its bytes admit. Input, output
/// and strings are the message itself; items and a container's items are
/// as many as its bytes can hold (two bytes each, `1,`); what a decode may
/// allocate and the work it may do grow with it in strand's own
/// proportions (twice and eight times its input); depth and the sizes of
/// keys and numbers stay strand's, as no larger message needs more of them.
pub fn limitsFor(message: aegis.units.Bytes(u32)) strand.core.Limits {
    const m: usize = message.raw();
    const base: strand.core.Limits = .{};
    return .{
        .input_bytes = m,
        .output_bytes = m,
        .string_bytes = m,
        .items = @max(1, m / 2),
        .container_items = @max(1, m / 2),
        .allocation_bytes = std.math.mul(usize, m, base.allocation_bytes / base.input_bytes) catch std.math.maxInt(usize),
        .work = std.math.mul(usize, m, base.work / base.input_bytes) catch std.math.maxInt(usize),
        .depth = base.depth,
        .key_bytes = base.key_bytes,
        .numeric_bytes = base.numeric_bytes,
    };
}

pub const DecodeOptions = struct {
    /// Filled when decoding fails.
    fault: ?*Fault = null,
    /// strand's limits for the envelope and every value passed over: those
    /// of the message limit the reader set (`limitsFor`).
    limits: strand.core.Limits,
};

/// `Malformed`: the bytes are not one JSON value (answered `parse_error`).
/// `Invalid`: JSON, but not a message (answered `invalid_request`).
pub const DecodeError = error{ Malformed, Invalid, OutOfMemory };

/// The message `bytes` holds. Strings and values point into `bytes`, which
/// must outlive the message, unless they were unescaped onto `arena`.
pub fn decode(arena: Allocator, bytes: []const u8, options: DecodeOptions) DecodeError!Message {
    var scratch: Fault = .{};
    const fault = options.fault orelse &scratch;
    fault.* = .{};
    return decodeInto(arena, bytes, options.limits, fault);
}

/// One element of a batch: the bytes it was written as, and the message
/// they are or why they are refused.
pub const Element = struct {
    /// The element as written, inside the batch's bytes.
    bytes: []const u8,
    read: Read,

    pub const Read = union(enum) {
        message: Message,
        refused: Fault,
    };
};

/// A JSON-RPC batch, which 2025-03-26 and 2024-11-05 have and the later
/// revisions removed: the elements of a non-empty array, each read as
/// `decode` reads one message and each refused on its own (JSON-RPC 2.0
/// §6). `Malformed`: the bytes are not JSON. `Invalid`: JSON, but not a
/// non-empty array. Messages point into `bytes`, as `decode`'s do.
pub fn decodeBatch(arena: Allocator, bytes: []const u8, options: DecodeOptions) DecodeError![]const Element {
    var scratch: Fault = .{};
    const fault = options.fault orelse &scratch;
    fault.* = .{};
    if (!isBatch(bytes)) return refuse(fault, .invalid_request, "a batch is a JSON array");
    const raws = json.parseLeaky([]const json.Raw, arena, bytes, .{ .limits = options.limits }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError, error.InvalidUtf8 => return refuse(fault, .parse_error, "the batch is not JSON"),
        error.InputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.AllocationLimit, error.WorkLimit => return refuse(fault, .invalid_request, "the batch is past a limit"),
        else => return refuse(fault, .invalid_request, "the batch is not an array of messages"),
    };
    if (raws.len == 0) return refuse(fault, .invalid_request, "the batch is empty");
    const elements = try arena.alloc(Element, raws.len);
    for (raws, elements) |raw, *element| {
        var refused: Fault = .{};
        element.* = .{ .bytes = raw.bytes, .read = if (decodeInto(arena, raw.bytes, options.limits, &refused)) |message| .{ .message = message } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed, error.Invalid => .{ .refused = refused },
        } };
    }
    return elements;
}

/// What one frame of a connection holds (a line, an event, a body): one
/// message, as `decode` reads it, or, where `batches` (the revision has
/// them), a batch's elements, as `decodeBatch` reads them. One message is
/// one element.
pub fn decodeFrame(arena: Allocator, bytes: []const u8, batches: bool, options: DecodeOptions) DecodeError![]const Element {
    if (batches and isBatch(bytes)) return decodeBatch(arena, bytes, options);
    const one = try arena.alloc(Element, 1);
    one[0] = .{ .bytes = bytes, .read = .{ .message = try decode(arena, bytes, options) } };
    return one;
}

/// Whether `bytes` is written as a batch: a JSON array, the one shape no
/// single message has.
pub fn isBatch(bytes: []const u8) bool {
    return firstByte(bytes) == '[';
}

/// One envelope member at most once each.
const envelope = [_][]const u8{ "jsonrpc", "id", "method", "params", "result", "error" };

fn decodeInto(arena: Allocator, bytes: []const u8, limits: strand.core.Limits, fault: *Fault) DecodeError!Message {
    var seen: [envelope.len]?[]const u8 = @splat(null);
    var members: json.Members = undefined;
    members.init(bytes, .{ .limits = limits });
    while (true) {
        const member = members.next() catch |err| return refuseMembers(fault, err, bytes);
        const m = member orelse break;
        const index = m.which(&envelope) orelse continue;
        if (seen[index] != null) return refuse(fault, .invalid_request, "a member is given twice");
        seen[index] = m.value;
    }
    _ = members.finish() catch |err| return refuseMembers(fault, err, bytes);

    // The id first, so that any refusal after it names the request.
    var id: ?Id = null;
    const null_id = if (seen[1]) |raw| std.mem.eql(u8, raw, "null") else false;
    if (seen[1]) |raw| {
        if (!null_id) {
            id = idFrom(arena, raw, limits) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return refuse(fault, .invalid_request, "the id is not a string or an integer"),
            };
            fault.id = id;
        }
    }
    const version = seen[0] orelse return refuse(fault, .invalid_request, "jsonrpc is missing");
    if (!std.mem.eql(u8, version, "\"2.0\"")) return refuse(fault, .invalid_request, "jsonrpc is not \"2.0\"");

    if (seen[2]) |raw_method| {
        if (seen[4] != null or seen[5] != null) return refuse(fault, .invalid_request, "a request has a result or an error");
        const method = readString(arena, raw_method, limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return refuse(fault, .invalid_request, "the method is not a string"),
        };
        const params = seen[3];
        if (params) |p| if (p[0] != '{' and p[0] != '[') return refuse(fault, .invalid_request, "params is not an object or an array");
        if (seen[1] == null) return .{ .notification = .{ .method = method, .params = params } };
        if (null_id) return refuse(fault, .invalid_request, "a request's id is null");
        return .{ .request = .{ .id = id.?, .method = method, .params = params } };
    }
    if (seen[3] != null) return refuse(fault, .invalid_request, "params without a method");
    if (seen[4]) |result| {
        if (seen[5] != null) return refuse(fault, .invalid_request, "both a result and an error");
        return .{ .result = .{ .id = id orelse return refuse(fault, .invalid_request, "a result without a string or integer id"), .result = result } };
    }
    if (seen[5]) |raw_error| {
        // An error may answer a request whose id could not be read: null.
        if (seen[1] == null) return refuse(fault, .invalid_request, "an error without an id");
        return .{ .failure = readFailure(arena, id, raw_error, limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return refuse(fault, .invalid_request, "the error is not an object with a code and a message"),
        } };
    }
    return refuse(fault, .invalid_request, "neither a method, a result nor an error");
}

fn refuse(fault: *Fault, code: Code, reason: []const u8) DecodeError {
    fault.code = code;
    fault.reason = reason;
    return if (code == .parse_error) error.Malformed else error.Invalid;
}

fn refuseMembers(fault: *Fault, err: json.MembersError, bytes: []const u8) DecodeError {
    return switch (err) {
        // JSON, but not an object: a batch, a scalar.
        error.UnexpectedType => refuse(fault, .invalid_request, if (firstByte(bytes) == '[') "a batch is taken only on a session at 2025-03-26 or 2024-11-05" else "the message is not an object"),
        error.SyntaxError => refuse(fault, .parse_error, "the message is not JSON"),
        error.InputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.WorkLimit => refuse(fault, .invalid_request, "the message is past a limit"),
    };
}

fn firstByte(bytes: []const u8) u8 {
    for (bytes) |b| switch (b) {
        ' ', '\t', '\r', '\n' => continue,
        else => return b,
    };
    return 0;
}

/// The id `raw` (one JSON value) is: a string or an integer.
pub fn idFrom(arena: Allocator, raw: []const u8, json_limits: strand.core.Limits) error{ Invalid, OutOfMemory }!Id {
    if (raw[0] == '"') return .{ .string = try readString(arena, raw, json_limits) };
    return .{ .integer = json.intOf(i64, raw) orelse return error.Invalid };
}

/// A JSON string value, unescaped: a view into `raw` when it has no escape.
fn readString(arena: Allocator, raw: []const u8, json_limits: strand.core.Limits) error{ Invalid, OutOfMemory }![]const u8 {
    if (raw.len < 2 or raw[0] != '"') return error.Invalid;
    const body = raw[1 .. raw.len - 1];
    if (std.mem.findScalar(u8, body, '\\') == null) return body;
    return json.parseLeaky([]const u8, arena, raw, .{ .limits = json_limits }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn readFailure(arena: Allocator, id: ?Id, raw: []const u8, json_limits: strand.core.Limits) error{ Invalid, OutOfMemory }!Failure {
    var code: ?i64 = null;
    var message: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var members: json.Members = undefined;
    members.init(raw, .{ .limits = json_limits });
    while (members.next() catch return error.Invalid) |m| {
        switch (m.which(&.{ "code", "message", "data" }) orelse continue) {
            0 => code = json.intOf(i64, m.value) orelse return error.Invalid,
            1 => message = try readString(arena, m.value, json_limits),
            2 => data = m.value,
            else => unreachable,
        }
    }
    return .{ .id = id, .code = @fromBackingInt(@intCast(code orelse return error.Invalid)), .message = message orelse return error.Invalid, .data = data };
}

// Writing. Each writes one whole message and nothing after it: framing (a
// line, an SSE event) is the transport's.

/// `{"jsonrpc":"2.0","id":…,"result":` — the caller writes the result value,
/// then `endResult`.
pub fn beginResult(w: *Writer, id: Id) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.write(w);
    try w.writeAll(",\"result\":");
}

pub fn endResult(w: *Writer) Writer.Error!void {
    try w.writeByte('}');
}

/// A result whose value is `result`, one JSON value.
pub fn writeResult(w: *Writer, id: Id, result: []const u8) Writer.Error!void {
    try beginResult(w, id);
    try w.writeAll(result);
    try endResult(w);
}

/// An error response. `data` is one JSON value or null.
pub fn writeFailure(w: *Writer, id: ?Id, code: Code, message: []const u8, data: ?[]const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| try i.write(w) else try w.writeAll("null");
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{@backingInt(code)});
    try writeString(w, message);
    if (data) |d| {
        try w.writeAll(",\"data\":");
        try w.writeAll(d);
    }
    try w.writeAll("}}");
}

/// A request; `params` is one JSON value or null.
pub fn writeRequest(w: *Writer, id: Id, method: []const u8, params: ?[]const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.write(w);
    try w.writeAll(",\"method\":");
    try writeString(w, method);
    if (params) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeByte('}');
}

/// A notification; `params` is one JSON value or null.
pub fn writeNotification(w: *Writer, method: []const u8, params: ?[]const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeString(w, method);
    if (params) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeByte('}');
}

/// `s` as a JSON string. Text that is not UTF-8 is written with each bad
/// byte as U+FFFD, so the message stays JSON whatever a caller passes.
pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b >= 0x20 and b != '"' and b != '\\' and b < 0x80) {
            i += 1;
            continue;
        }
        if (b >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
            if (n != 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
                i += n;
                continue;
            }
            try w.writeAll(s[start..i]);
            try w.writeAll("\u{FFFD}");
            i += 1;
            start = i;
            continue;
        }
        try w.writeAll(s[start..i]);
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.print("\\u{x:0>4}", .{b}),
        }
        i += 1;
        start = i;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}
