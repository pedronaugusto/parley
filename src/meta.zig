//! A request's `_meta`: the protocol version, the client's identity and
//! capabilities, the log level and the progress token every 2026-07-28
//! request carries, read without touching the rest of its params.
const std = @import("std");
const strand = @import("strand");
const types = @import("types.zig");

const json = strand.json;
const Allocator = std.mem.Allocator;

pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
pub const client_info = "io.modelcontextprotocol/clientInfo";
pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
pub const log_level = "io.modelcontextprotocol/logLevel";
pub const subscription_id = "io.modelcontextprotocol/subscriptionId";
pub const server_info = "io.modelcontextprotocol/serverInfo";
pub const progress_token = "progressToken";

/// What `_meta` holds that a server acts on. A key that is absent is null.
pub const Meta = struct {
    /// The version the request is in, as written.
    version: ?[]const u8 = null,
    client_info: ?types.Implementation = null,
    client_capabilities: ?types.ClientCapabilities = null,
    log_level: ?types.LoggingLevel = null,
    progress_token: ?types.Token = null,
    /// The whole `_meta` object, vendor keys included, as written.
    raw: ?[]const u8 = null,
};

/// `Malformed`: `params` is not an object, or `_meta` or one of its reserved
/// keys is not what the schema says.
pub const ReadError = error{ Malformed, OutOfMemory };

/// The `_meta` of a request whose params are `params` (null when it has
/// none), read within `limits` (`wire.limitsFor` the message limit). Values
/// point into `params` or onto `arena`.
pub fn read(arena: Allocator, params: ?[]const u8, limits: strand.core.Limits) ReadError!Meta {
    const bytes = params orelse return .{};
    var members: json.Members = undefined;
    members.init(bytes, .{ .limits = limits });
    while (members.next() catch return error.Malformed) |m| {
        if (m.is("_meta")) return readObject(arena, m.value, limits);
    }
    return .{};
}

fn readObject(arena: Allocator, raw: []const u8, limits: strand.core.Limits) ReadError!Meta {
    var meta: Meta = .{ .raw = raw };
    var members: json.Members = undefined;
    members.init(raw, .{ .limits = limits });
    while (members.next() catch return error.Malformed) |m| {
        switch (m.which(&.{ protocol_version, client_info, client_capabilities, log_level, progress_token }) orelse continue) {
            0 => meta.version = try parse([]const u8, arena, m.value, limits),
            1 => meta.client_info = try parse(types.Implementation, arena, m.value, limits),
            2 => meta.client_capabilities = try parse(types.ClientCapabilities, arena, m.value, limits),
            3 => meta.log_level = try parse(types.LoggingLevel, arena, m.value, limits),
            4 => meta.progress_token = try parse(types.Token, arena, m.value, limits),
            else => unreachable,
        }
    }
    return meta;
}

fn parse(comptime T: type, arena: Allocator, bytes: []const u8, limits: strand.core.Limits) ReadError!T {
    return json.parseLeaky(T, arena, bytes, types.readOptions(limits)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
}
