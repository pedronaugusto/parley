//! The HTTP+SSE transport of 2024-11-05, server side: deprecated since
//! 2025-03-26, served for the clients that speak only it. Mount it beside
//! `Endpoint`, at a path of its own.
//!
//! A GET opens a session and its event stream, whose first event,
//! `endpoint`, names where the client POSTs (this path, its session named
//! in `?sessionId=`). Each POST carries one message, or a batch, and is
//! answered 202 at once; what answers it goes out on the stream, as does
//! everything else the server sends the session. The session ends with its
//! stream: the client leaving, or the server stopping.
//!
//! A session is stdio's `Connection`, its lines events and the client's
//! lines POSTs: one way of taking a client's messages, whichever transport
//! carries them. It is the session layer's (`parley.compat`), as stdio's
//! is: an `initialize` opens it, at any revision the session layer serves.
const SseEndpoint = @This();

const std = @import("std");
const parley = @import("parley");
const uplink = @import("uplink");
const guard = @import("guard.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = uplink.server.Request;
const Response = uplink.server.Response;
const wire = parley.wire;
const sse = uplink.wire.sse;
const refuse = guard.refuse;

gpa: Allocator,
server: *parley.Server,
options: Options,
/// Private: the endpoint as an uplink handler (`handler`), which finds the
/// endpoint by `@fieldParentPtr`.
handling: uplink.server.Handler = .{ .handleFn = handled },
/// Private: the open sessions; `refs` counts who holds each.
sessions_mutex: Io.Mutex = .init,
sessions: std.ArrayList(*Session) = .empty,

pub const Options = struct {
    /// As `Endpoint.Options.loopback`.
    loopback: bool = true,
    /// As `Endpoint.Options.hosts`.
    hosts: []const []const u8 = &.{},
    /// As `Endpoint.Options.origins`.
    origins: []const []const u8 = &.{},
    /// How often a quiet stream is kept open with a comment, and how soon
    /// a client gone from one is noticed.
    keep_alive: parley.Server.Duration = .literal("15s"),
    /// As `Endpoint.Options.access`: the GET is held to it, and each message
    /// POSTed.
    access: ?guard.Access = null,
    /// Sessions open at once: a GET past it is refused (503), as each holds
    /// a stream.
    max_sessions: u32 = 1024,
    /// Each session's in-flight bound, and the session layer's options.
    connection: parley.stdio.Options = .{},
};

/// The query parameter a POST names its session in.
pub const session_parameter = "sessionId";

pub fn init(gpa: Allocator, server: *parley.Server, options: Options) SseEndpoint {
    return .{ .gpa = gpa, .server = server, .options = options };
}

/// The server the endpoint is mounted on has stopped, and with it every
/// stream: no session is left.
pub fn deinit(e: *SseEndpoint) void {
    std.debug.assert(e.sessions.items.len == 0);
    e.sessions.deinit(e.gpa);
}

/// The endpoint as an uplink handler, for as long as the endpoint stays where
/// it is.
pub fn handler(e: *SseEndpoint) *uplink.server.Handler {
    return &e.handling;
}

fn handled(h: *uplink.server.Handler, io: Io, request: *Request, response: *Response) anyerror!void {
    const e: *SseEndpoint = @alignCast(@fieldParentPtr("handling", h));
    return e.handle(io, request, response);
}

/// One session: its stream's response, the connection that answers it,
/// and who holds it. Freed by the last `release`.
const Session = struct {
    id: [32]u8,
    io: Io,
    response: *Response,
    connection: parley.stdio.Connection,
    /// Private, under `sessions_mutex`.
    refs: u32 = 1,
    /// The event being written, between `begin` and `end`.
    event: sse.EventWriter = undefined,
    buffer: [256]u8 = undefined,

    fn out(s: *Session) parley.stdio.Out {
        return .{ .context = s, .beginFn = begin, .endFn = end, .keepAliveFn = keepAlive };
    }

    fn of(context: *anyopaque) *Session {
        return @ptrCast(@alignCast(context)); // safe: `out` made the context from this session
    }

    fn begin(context: *anyopaque) parley.stdio.Out.Error!*Io.Writer {
        const s = of(context);
        const w = s.response.writer(s.io) catch return error.WriteFailed;
        s.event = sse.EventWriter.begin(w, &s.buffer, .{ .type = "message" }) catch return error.WriteFailed;
        return &s.event.interface;
    }

    fn end(context: *anyopaque) parley.stdio.Out.Error!void {
        const s = of(context);
        s.event.end() catch return error.WriteFailed;
        s.response.flush(s.io) catch return error.WriteFailed;
    }

    fn keepAlive(context: *anyopaque) parley.stdio.Out.Error!void {
        const s = of(context);
        const w = s.response.writer(s.io) catch return error.WriteFailed;
        w.writeAll(":\n\n") catch return error.WriteFailed;
        s.response.flush(s.io) catch return error.WriteFailed;
    }
};

fn served(e: *const SseEndpoint) guard.Served {
    return .{ .loopback = e.options.loopback, .hosts = e.options.hosts, .origins = e.options.origins };
}

fn handle(e: *SseEndpoint, io: Io, request: *Request, response: *Response) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(e.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!guard.served(e.served(), request))
        return refuse(io, response, .forbidden, null, .invalid_request, guard.not_served);
    if (std.mem.eql(u8, request.method.name, "GET")) {
        _ = try guard.checkAccess(e.options.access, io, arena, request, response, null) orelse return;
        const accept = request.headers.get("Accept") orelse "";
        if (std.mem.find(u8, accept, "text/event-stream") == null and std.mem.find(u8, accept, "*/*") == null)
            return refuse(io, response, .not_acceptable, null, .invalid_request, "Accept must list text/event-stream");
        return e.open(io, request, response);
    }
    if (std.mem.eql(u8, request.method.name, "POST")) return e.post(io, arena, request, response);
    try response.header("Allow", "GET, POST");
    return refuse(io, response, .method_not_allowed, null, .invalid_request, "The HTTP+SSE endpoint takes GET for a session's stream and POST for its messages");
}

/// GET: a session, whose stream this response is until the client leaves.
fn open(e: *SseEndpoint, io: Io, request: *Request, response: *Response) anyerror!void {
    const session = try e.gpa.create(Session);
    var random: [16]u8 = undefined;
    io.randomSecure(&random) catch |err| {
        e.gpa.destroy(session);
        return err;
    };
    session.* = .{ .id = std.fmt.bytesToHex(random, .lower), .io = io, .response = response, .connection = undefined };
    session.connection = .init(io, e.gpa, e.server, session.out(), e.options.connection);
    if (!try e.admit(io, session)) {
        e.gpa.destroy(session);
        return refuse(io, response, .service_unavailable, null, .internal_error, "The server holds as many sessions as it takes");
    }
    // Last, the response ends: the connection, which writes to it, has
    // stopped first, and a POST still holding the session finds it ended.
    // glint-ignore: Z026 -- the stream was the answer; a client gone before its end needs no more
    defer response.end(io) catch {};
    defer e.release(io, session);
    defer {
        e.forget(io, session);
        session.connection.deinit();
    }

    try response.header("Content-Type", "text/event-stream");
    try response.header("Cache-Control", "no-cache");
    try response.header("X-Accel-Buffering", "no");
    {
        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = std.mem.print(&endpoint_buffer, "{s}?{s}={s}", .{ request.path, session_parameter, &session.id }) catch
            return refuse(io, response, .uri_too_long, null, .invalid_request, "The endpoint's path is longer than its stream names");
        // Nothing else writes yet: no POST names the session before this
        // event does.
        try sse.writeEvent(try response.writer(io), .{ .type = "endpoint", .data = endpoint });
        try response.flush(io);
    }
    // The stream is open until the client leaves or the server stops; a
    // quiet one is kept open with a comment.
    const keep_alive = e.options.keep_alive.toIoDuration();
    while (true) {
        const left = request.gone(io, .{ .duration = .{ .raw = keep_alive, .clock = .awake } }) catch break;
        if (left) break;
        session.connection.keepAlive() catch break;
    }
}

/// POST: a message for the session it names, answered on its stream.
fn post(e: *SseEndpoint, io: Io, arena: Allocator, request: *Request, response: *Response) anyerror!void {
    const id = sessionOf(request.query) orelse
        return refuse(io, response, .bad_request, null, .invalid_request, "A POST names its session: the endpoint event's sessionId");
    if (!guard.isJson(request.headers.get("Content-Type")))
        return refuse(io, response, .unsupported_media_type, null, .invalid_request, "The body is application/json");
    const session = e.lookup(io, id) orelse
        return refuse(io, response, .not_found, null, .invalid_request, "Session not found: open a stream again");
    defer e.release(io, session);
    // The server's message limit bounds the body, read onto `gpa`: the
    // connection keeps it while it is answered.
    const body = request.collect(e.gpa, io, .limited(e.server.options.limits.message.raw())) catch |err| switch (err) {
        error.StreamTooLong, error.BodyTooLarge => return refuse(io, response, .payload_too_large, null, .invalid_request, "The message is longer than the server reads"),
        else => return err,
    };
    if (e.options.access != null) {
        if (!try e.admitted(io, arena, request, response, body)) {
            e.gpa.free(body);
            return;
        }
    }
    session.connection.take(body) catch |err| switch (err) {
        error.Ended => return refuse(io, response, .not_found, null, .invalid_request, "Session not found: its stream has ended"),
        // The stream broke: the session ends with its GET.
        error.WriteFailed, error.ReadFailed => return refuse(io, response, .not_found, null, .invalid_request, "Session not found: its stream has ended"),
        error.Canceled => return,
        error.OutOfMemory, error.ConcurrencyUnavailable => |x| return x,
    };
    response.status = .accepted;
    return response.end(io);
}

/// Whether each message `body` holds passes the endpoint's access; a
/// refusal is written. A body that does not decode is the connection's to
/// refuse, on the stream, as any other.
fn admitted(e: *SseEndpoint, io: Io, arena: Allocator, request: *const Request, response: *Response, body: []const u8) anyerror!bool {
    const limits = e.server.jsonLimits();
    if (wire.isBatch(body)) {
        const elements = wire.decodeBatch(arena, body, .{ .limits = limits }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Malformed, error.Invalid => return true,
        };
        for (elements) |element| if (element.read == .message) {
            _ = try guard.checkAccess(e.options.access, io, arena, request, response, element.read.message) orelse return false;
        };
        return true;
    }
    const message = wire.decode(arena, body, .{ .limits = limits }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Malformed, error.Invalid => return true,
    };
    _ = try guard.checkAccess(e.options.access, io, arena, request, response, message) orelse return false;
    return true;
}

/// The session a query names.
fn sessionOf(query: ?[]const u8) ?[]const u8 {
    var pairs: uplink.wire.form.Iterator = .init(query orelse return null);
    while (pairs.next()) |pair| if (std.mem.eql(u8, pair.name, session_parameter)) return pair.value;
    return null;
}

/// Adds `session`, unless the endpoint holds as many as it takes.
fn admit(e: *SseEndpoint, io: Io, session: *Session) Io.Cancelable!bool {
    try e.sessions_mutex.lock(io);
    defer e.sessions_mutex.unlock(io);
    if (e.sessions.items.len >= e.options.max_sessions) return false;
    e.sessions.append(e.gpa, session) catch return false;
    return true;
}

/// Takes `session` out of the open ones: no POST finds it again.
fn forget(e: *SseEndpoint, io: Io, session: *Session) void {
    e.sessions_mutex.lockUncancelable(io);
    defer e.sessions_mutex.unlock(io);
    for (e.sessions.items, 0..) |s, i| if (s == session) {
        _ = e.sessions.swapRemove(i);
        return;
    };
}

/// The session named `id`, held until `release`.
fn lookup(e: *SseEndpoint, io: Io, id: []const u8) ?*Session {
    e.sessions_mutex.lockUncancelable(io);
    defer e.sessions_mutex.unlock(io);
    for (e.sessions.items) |s| if (std.mem.eql(u8, &s.id, id)) {
        s.refs += 1;
        return s;
    };
    return null;
}

fn release(e: *SseEndpoint, io: Io, session: *Session) void {
    const last = blk: {
        e.sessions_mutex.lockUncancelable(io);
        defer e.sessions_mutex.unlock(io);
        session.refs -= 1;
        break :blk session.refs == 0;
    };
    if (last) e.gpa.destroy(session);
}
