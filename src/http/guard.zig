//! What both server endpoints (`Endpoint`, `SseEndpoint`) hold a request to
//! before they read it, and how they refuse one: a `Host` and an `Origin`
//! they serve (DNS rebinding), and their `Access`.
const std = @import("std");
const parley = @import("parley");
const uplink = @import("uplink");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = uplink.server.Request;
const Response = uplink.server.Response;
const wire = parley.wire;

pub const Access = struct {
    context: ?*anyopaque = null,
    /// Whether `request` may be served, and for whom. `message` is what its
    /// body holds (null for a GET or a DELETE), for an access whose needs
    /// depend on the method or the tool. What it returns lives in `arena`.
    check: *const fn (context: ?*anyopaque, io: Io, arena: Allocator, request: *const Request, message: ?wire.Message) Error!Verdict,

    /// `Unavailable`: what checks credentials could not answer (an
    /// authorization server down): a 503.
    pub const Error = error{ Unavailable, Canceled, OutOfMemory };
};

pub const Verdict = union(enum) {
    /// Served, for the principal named (null: nobody told apart).
    admitted: ?[]const u8,
    refused: Refusal,
};

pub const Refusal = struct {
    /// 400, 401 or 403.
    status: std.http.Status,
    /// The `WWW-Authenticate` value: why, and where to get credentials.
    challenge: []const u8,
    /// The body, JSON (an OAuth error object), or empty.
    body: []const u8 = "",
};

/// The hosts and origins an endpoint serves.
pub const Served = struct {
    loopback: bool,
    hosts: []const []const u8,
    origins: []const []const u8,
};

/// Why a request `served` refuses is refused.
pub const not_served = "Origin or Host not served: a page another site serves may not reach this server";

/// Whether `request`'s `Host` and `Origin` are ones `s` serves.
pub fn served(s: Served, request: *const Request) bool {
    return hostServed(s, request.headers.get("Host") orelse request.host) and originServed(s, request.headers.get("Origin"));
}

fn hostServed(s: Served, host: []const u8) bool {
    for (s.hosts) |h| if (std.ascii.eqlIgnoreCase(h, host)) return true;
    if (s.loopback) return loopbackHost(host);
    return s.hosts.len == 0;
}

fn originServed(s: Served, origin: ?[]const u8) bool {
    const o = origin orelse return true;
    for (s.origins) |allowed| if (std.ascii.eqlIgnoreCase(allowed, o)) return true;
    if (!s.loopback) return false;
    const scheme_end = std.mem.find(u8, o, "://") orelse return false;
    const scheme = o[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return false;
    return loopbackHost(o[scheme_end + 3 ..]);
}

/// Whether `authority` (`host[:port]`) names this machine.
fn loopbackHost(authority: []const u8) bool {
    const host = if (std.mem.startsWith(u8, authority, "[")) blk: {
        const close = std.mem.findScalar(u8, authority, ']') orelse return false;
        break :blk authority[0 .. close + 1];
    } else if (std.mem.findScalar(u8, authority, ':')) |colon| authority[0..colon] else authority;
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}

pub const Admitted = struct { principal: ?[]const u8 };

/// Holds `request` to `access`: who sent it, or null when it is refused
/// (the refusal written).
pub fn checkAccess(access_: ?Access, io: Io, arena: Allocator, request: *const Request, response: *Response, message: ?wire.Message) anyerror!?Admitted {
    const access = access_ orelse return .{ .principal = null };
    const verdict = access.check(access.context, io, arena, request, message) catch |err| switch (err) {
        error.Unavailable => {
            try refuse(io, response, .service_unavailable, null, .internal_error, "The server cannot check credentials now");
            return null;
        },
        error.Canceled, error.OutOfMemory => |x| return x,
    };
    switch (verdict) {
        .admitted => |principal| return .{ .principal = principal },
        .refused => |r| {
            response.status = r.status;
            try response.header("WWW-Authenticate", r.challenge);
            if (r.body.len != 0) try response.header("Content-Type", "application/json");
            try response.send(io, r.body);
            return null;
        },
    }
}

/// Answers with `status` and a JSON-RPC error.
pub fn refuse(io: Io, response: *Response, status: std.http.Status, id: ?wire.Id, code: wire.Code, message: []const u8) anyerror!void {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    wire.writeFailure(&w, id, code, message, null) catch {
        w = .fixed(&buffer);
        try wire.writeFailure(&w, null, code, message, null);
    };
    response.status = status;
    try response.header("Content-Type", "application/json");
    return response.send(io, w.buffered());
}

/// Whether `Content-Type` is JSON.
pub fn isJson(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const media = std.mem.trim(u8, value[0 .. std.mem.findScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.eqlIgnoreCase(media, "application/json");
}
