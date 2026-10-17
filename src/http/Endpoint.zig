//! The Streamable HTTP transport's server side: an uplink handler for the
//! MCP endpoint, mounted at a path of an uplink router or serving a whole
//! uplink server.
//!
//! Every request is a POST of one JSON-RPC message. Before the core sees a
//! request, the endpoint holds it to what 2026-07-28 asks of HTTP: a `Host`
//! and an `Origin` it serves (DNS rebinding), `MCP-Protocol-Version`,
//! `Mcp-Method` and `Mcp-Name` agreeing with the body (`-32020` otherwise).
//! An answer is JSON, or an event stream once the request has something to
//! say before its result (progress, a log line) and always for
//! `subscriptions/listen`, kept open by a comment every `keep_alive`.
const Endpoint = @This();

const std = @import("std");
const aegis = @import("aegis");
const parley = @import("parley");
const uplink = @import("uplink");
const headers = @import("headers.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = uplink.server.Request;
const Response = uplink.server.Response;
const wire = parley.wire;

gpa: Allocator,
server: *parley.Server,
options: Options,

pub const Options = struct {
    /// Serve requests whose `Host` and `Origin` are this machine's
    /// (`localhost`, `127.0.0.1`, `[::1]`, any port): what a local server
    /// asks, so a page that rebinds a name to it cannot reach it.
    loopback: bool = true,
    /// `Host` values served besides loopback ones, exactly (`example.com`,
    /// `example.com:8443`). Empty and `loopback` off: any host.
    hosts: []const []const u8 = &.{},
    /// `Origin` values served besides loopback ones (`https://app.example`).
    origins: []const []const u8 = &.{},
    /// The longest body read.
    max_body: aegis.units.Bytes(u32) = .literal("16MiB"),
    /// How often a quiet event stream is kept open with a comment.
    keep_alive: parley.Server.Duration = .literal("15s"),
    /// Who sent a request, from its headers (an authorization the caller
    /// verified); null: nobody is told apart.
    principal: ?Principal = null,
};

pub const Principal = struct {
    context: ?*anyopaque = null,
    /// The caller's identity for `request`, or null when it has none. What
    /// it returns lives as long as the request.
    of: *const fn (context: ?*anyopaque, request: *const Request) ?[]const u8,
};

pub fn init(gpa: Allocator, server: *parley.Server, options: Options) Endpoint {
    return .{ .gpa = gpa, .server = server, .options = options };
}

/// The endpoint as an uplink handler.
pub fn handler(e: *Endpoint) uplink.server.Handler {
    return .init(e, handle);
}

fn handle(e: *Endpoint, io: Io, request: *Request, response: *Response) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(e.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!e.hostServed(request.headers.get("Host") orelse request.host) or !e.originServed(request.headers.get("Origin")))
        return refuse(io, response, .forbidden, null, .invalid_request, "Origin or Host not served: a page another site serves may not reach this server");
    if (!std.mem.eql(u8, request.method.name, "POST")) {
        try response.header("Allow", "POST");
        return refuse(io, response, .method_not_allowed, null, .invalid_request, "The MCP endpoint takes POST");
    }
    if (!accepts(request.headers.get("Accept")))
        return refuse(io, response, .not_acceptable, null, .invalid_request, "Accept must list application/json and text/event-stream");
    if (!isJson(request.headers.get("Content-Type")))
        return refuse(io, response, .unsupported_media_type, null, .invalid_request, "The body is application/json");
    const body = request.collect(arena, io, .limited(e.options.max_body.raw())) catch |err| switch (err) {
        error.StreamTooLong, error.BodyTooLarge => return refuse(io, response, .payload_too_large, null, .invalid_request, "The message is longer than the server reads"),
        error.OutOfMemory => return err,
        else => return err,
    };

    var fault: wire.Fault = .{};
    const message = wire.decode(arena, body, .{ .fault = &fault }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Malformed, error.Invalid => return refuse(io, response, .bad_request, fault.id, fault.code, fault.reason),
    };
    const req = switch (message) {
        .request => |r| r,
        // A notification or an answer: taken.
        .notification, .result, .failure => {
            response.status = .accepted;
            return response.end(io);
        },
    };

    if (try e.mismatch(arena, request, req)) |why|
        return refuse(io, response, .bad_request, req.id, .header_mismatch, why);

    const principal = if (e.options.principal) |p| p.of(p.context, request) else null;
    var stream: Stream = .{ .io = io, .response = response };
    const sink: parley.Sink = .{
        .context = &stream,
        .sendFn = Stream.send,
        .keep_alive = e.options.keep_alive.toIoDuration(),
        .keepAliveFn = Stream.keepAlive,
    };
    const reply = e.server.serve(io, arena, req, principal, sink) catch |err| switch (err) {
        // The client left, or the server is going away: nothing to answer.
        error.Canceled => return,
        error.OutOfMemory => return err,
    };
    var out: Io.Writer.Allocating = .init(arena);
    var status: std.http.Status = .ok;
    switch (reply) {
        .result => |r| try wire.writeResult(&out.writer, req.id, r),
        .input_required => |ir| try wire.writeResult(&out.writer, req.id, try e.server.inputRequiredJson(arena, ir)),
        .failure => |f| {
            status = statusOf(f);
            try wire.writeFailure(&out.writer, req.id, f.code, f.message, f.data);
        },
    }
    if (stream.events) {
        try stream.event(out.written());
        return response.end(io);
    }
    response.status = status;
    try response.header("Content-Type", "application/json");
    return response.send(io, out.written());
}

/// The HTTP status a refusal goes with: 400 for what the request lacks or
/// gets wrong at the protocol's level, 404 for a method not served.
fn statusOf(f: parley.Server.Failure) std.http.Status {
    if (f.malformed) return .bad_request;
    return switch (f.code) {
        .header_mismatch, .missing_required_client_capability, .unsupported_protocol_version => .bad_request,
        .method_not_found => .not_found,
        else => .ok,
    };
}

/// Why the headers disagree with the body, or null when they agree.
fn mismatch(e: *Endpoint, arena: Allocator, request: *const Request, req: wire.Request) Allocator.Error!?[]const u8 {
    _ = e;
    const m = parley.meta.read(arena, req.params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The core refuses params that are not what the schema says.
        error.Malformed => return null,
    };
    const version = request.headers.get(headers.protocol_version) orelse return "MCP-Protocol-Version is missing";
    if (m.version) |v| if (!std.mem.eql(u8, v, version)) return "MCP-Protocol-Version does not match _meta's protocol version";
    const method = request.headers.get(headers.method) orelse return "Mcp-Method is missing";
    if (!std.mem.eql(u8, method, req.method)) return "Mcp-Method does not match the body's method";
    const subject: ?[]const u8 = if (std.mem.eql(u8, req.method, "tools/call") or std.mem.eql(u8, req.method, "prompts/get"))
        member(arena, req.params, "name")
    else if (std.mem.eql(u8, req.method, "resources/read"))
        member(arena, req.params, "uri")
    else
        null;
    if (subject) |expected| {
        const raw = request.headers.get(headers.name) orelse return "Mcp-Name is missing";
        const given = headers.decode(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return "Mcp-Name holds a value no header holds",
        };
        if (!std.mem.eql(u8, given, expected)) return "Mcp-Name does not match the body";
    }
    return null;
}

/// A string member of `params`, or null.
fn member(arena: Allocator, params: ?[]const u8, name: []const u8) ?[]const u8 {
    const bytes = params orelse return null;
    var members: @import("strand").json.Members = undefined;
    members.init(bytes, .{});
    while (members.next() catch return null) |m| if (m.is(name)) {
        return @import("strand").json.parseLeaky([]const u8, arena, m.value, .{}) catch null;
    };
    return null;
}

fn refuse(io: Io, response: *Response, status: std.http.Status, id: ?wire.Id, code: wire.Code, message: []const u8) anyerror!void {
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

fn hostServed(e: *const Endpoint, host: []const u8) bool {
    for (e.options.hosts) |h| if (std.ascii.eqlIgnoreCase(h, host)) return true;
    if (e.options.loopback) return loopbackHost(host);
    return e.options.hosts.len == 0;
}

fn originServed(e: *const Endpoint, origin: ?[]const u8) bool {
    const o = origin orelse return true;
    for (e.options.origins) |allowed| if (std.ascii.eqlIgnoreCase(allowed, o)) return true;
    if (!e.options.loopback) return false;
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

/// Whether `Accept` lists both types an answer may be (or a wildcard that
/// covers them).
fn accepts(accept: ?[]const u8) bool {
    const value = accept orelse return false;
    var json = false;
    var events = false;
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |part| {
        const media = std.mem.trim(u8, part[0 .. std.mem.findScalar(u8, part, ';') orelse part.len], " \t");
        if (std.mem.eql(u8, media, "*/*")) return true;
        if (std.ascii.eqlIgnoreCase(media, "application/json") or std.ascii.eqlIgnoreCase(media, "application/*")) json = true;
        if (std.ascii.eqlIgnoreCase(media, "text/event-stream") or std.ascii.eqlIgnoreCase(media, "text/*")) events = true;
    }
    return json and events;
}

fn isJson(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const media = std.mem.trim(u8, value[0 .. std.mem.findScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.eqlIgnoreCase(media, "application/json");
}

/// A response that becomes an event stream at the first notification.
const Stream = struct {
    io: Io,
    response: *Response,
    events: bool = false,

    fn begin(s: *Stream) Response.Error!*Io.Writer {
        if (!s.events) {
            s.events = true;
            try s.response.header("Content-Type", "text/event-stream");
            try s.response.header("Cache-Control", "no-cache");
            try s.response.header("X-Accel-Buffering", "no");
        }
        return s.response.writer(s.io);
    }

    fn event(s: *Stream, message: []const u8) anyerror!void {
        const w = try s.begin();
        try uplink.wire.sse.writeEvent(w, .{ .type = "message", .data = message });
        try w.flush();
    }

    fn send(context: *anyopaque, io: Io, message: []const u8) parley.Sink.SendError!void {
        _ = io;
        const s: *Stream = @ptrCast(@alignCast(context));
        s.event(message) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Closed,
        };
    }

    fn keepAlive(context: *anyopaque, io: Io) parley.Sink.SendError!void {
        _ = io;
        const s: *Stream = @ptrCast(@alignCast(context));
        const w = s.begin() catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.Closed,
        };
        w.writeAll(":\n\n") catch return error.Closed;
        w.flush() catch return error.Closed;
    }
};
