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
/// Private: the open sessions, each named by its `Mcp-Session-Id`.
sessions_mutex: Io.Mutex = .init,
sessions: std.ArrayList(*Entry) = .empty,

/// A session, and who is using it: one ended while a request is under way
/// is freed when that request is done.
const Entry = struct {
    id: [32]u8,
    session: parley.compat.Session,
    refs: std.atomic.Value(u32) = .init(1),
    /// Whether its GET stream is open (one at a time).
    streaming: std.atomic.Value(bool) = .init(false),
    /// Milliseconds on the real clock when it was last used.
    used: std.atomic.Value(i64),

    fn release(entry: *Entry, gpa: Allocator) void {
        if (entry.refs.fetchSub(1, .acq_rel) != 1) return;
        entry.session.deinit();
        gpa.destroy(entry);
    }
};

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
    /// Sessions (2025-11-25 and before) open at once; the one idle longest
    /// is ended to make room.
    max_sessions: u32 = 1024,
    /// A session unused this long is ended.
    session_idle: parley.Server.Duration = .literal("10m"),
    session: parley.compat.Options = .{},
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

/// Ends every session. The server the endpoint is mounted on has stopped.
pub fn deinit(e: *Endpoint) void {
    for (e.sessions.items) |entry| entry.release(e.gpa);
    e.sessions.deinit(e.gpa);
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
    const session_id = request.headers.get(headers.session_id);
    if (std.mem.eql(u8, request.method.name, "GET")) return e.openStream(io, response, session_id, request.headers.get("Accept"));
    if (std.mem.eql(u8, request.method.name, "DELETE")) return e.endSession(io, response, session_id);
    if (!std.mem.eql(u8, request.method.name, "POST")) {
        try response.header("Allow", "GET, POST, DELETE");
        return refuse(io, response, .method_not_allowed, null, .invalid_request, "The MCP endpoint takes POST, and GET and DELETE for a session");
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

    // The session era: a request naming a session, or one opening it.
    if (session_id) |id| {
        const entry = e.lookup(io, id) orelse return refuse(io, response, .not_found, idOf(message), .invalid_request, "Session not found: initialize again");
        defer entry.release(e.gpa);
        return e.serveSession(io, arena, request, response, entry, message);
    }
    // `initialize` opens a session, unless it carries a 2026-07-28 `_meta`:
    // a modern request is served statelessly, and that revision has no
    // `initialize`.
    if (message == .request and std.mem.eql(u8, message.request.method, "initialize") and !try modern(arena, message.request))
        return e.openSession(io, arena, response, message.request);

    const req = switch (message) {
        .request => |r| r,
        // A notification or an answer: taken.
        .notification, .result, .failure => {
            response.status = .accepted;
            return response.end(io);
        },
    };

    if (try e.mismatch(io, arena, request, req)) |why|
        return refuse(io, response, .bad_request, req.id, .header_mismatch, why);

    const principal = if (e.options.principal) |p| p.of(p.context, request) else null;
    var stream: Stream = .{ .io = io, .response = response };
    const reply = e.server.serve(io, arena, req, principal, stream.sink(e)) catch |err| switch (err) {
        // The client left, or the server is going away: nothing to answer.
        error.Canceled => return,
        error.OutOfMemory => return err,
    };
    return e.answer(io, arena, response, &stream, req.id, reply);
}

/// Writes `reply`: as the last event of a stream the request began, or as
/// JSON with the status its refusal goes with.
fn answer(e: *Endpoint, io: Io, arena: Allocator, response: *Response, stream: *Stream, id: wire.Id, reply: parley.Server.Reply) anyerror!void {
    var out: Io.Writer.Allocating = .init(arena);
    var status: std.http.Status = .ok;
    switch (reply) {
        .result => |r| try wire.writeResult(&out.writer, id, r),
        .input_required => |ir| try wire.writeResult(&out.writer, id, try e.server.inputRequiredJson(arena, ir)),
        .failure => |f| {
            status = statusOf(f);
            try wire.writeFailure(&out.writer, id, f.code, f.message, f.data);
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

/// Whether a request carries the version a 2026-07-28 request carries in
/// its `_meta`.
fn modern(arena: Allocator, req: wire.Request) Allocator.Error!bool {
    const m = parley.meta.read(arena, req.params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return false,
    };
    return m.version != null;
}

fn idOf(message: wire.Message) ?wire.Id {
    return switch (message) {
        .request => |r| r.id,
        else => null,
    };
}

/// `initialize`: a new session, named in the answer's `Mcp-Session-Id`.
fn openSession(e: *Endpoint, io: Io, arena: Allocator, response: *Response, req: wire.Request) anyerror!void {
    const entry = try e.gpa.create(Entry);
    errdefer e.gpa.destroy(entry);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    entry.* = .{ .id = std.fmt.bytesToHex(random, .lower), .session = .init(e.gpa, e.server, e.options.session), .used = .init(now(io)) };
    var stream: Stream = .{ .io = io, .response = response };
    const reply = try entry.session.handle(io, arena, req, stream.sink(e));
    if (reply == .result) {
        try e.admit(io, entry);
        try response.header(headers.session_id, &entry.id);
    } else entry.release(e.gpa);
    return e.answer(io, arena, response, &stream, req.id, reply);
}

/// Adds `entry`, ending sessions idle too long, and the one idle longest
/// when there is no room.
fn admit(e: *Endpoint, io: Io, entry: *Entry) Io.Cancelable!void {
    try e.sessions_mutex.lock(io);
    defer e.sessions_mutex.unlock(io);
    const idle_ms: i64 = e.options.session_idle.raw();
    const t = now(io);
    var i: usize = 0;
    while (i < e.sessions.items.len) {
        const old = e.sessions.items[i];
        if (t - old.used.load(.monotonic) > idle_ms and !old.streaming.load(.acquire)) {
            _ = e.sessions.swapRemove(i);
            old.release(e.gpa);
        } else i += 1;
    }
    if (e.sessions.items.len >= e.options.max_sessions) {
        var oldest: usize = 0;
        for (e.sessions.items, 0..) |x, k| if (x.used.load(.monotonic) < e.sessions.items[oldest].used.load(.monotonic)) {
            oldest = k;
        };
        e.sessions.swapRemove(oldest).release(e.gpa);
    }
    e.sessions.append(e.gpa, entry) catch {
        entry.release(e.gpa);
        return;
    };
}

/// The session named `id`, held until `release`.
fn lookup(e: *Endpoint, io: Io, id: []const u8) ?*Entry {
    e.sessions_mutex.lockUncancelable(io);
    defer e.sessions_mutex.unlock(io);
    for (e.sessions.items) |entry| if (std.mem.eql(u8, &entry.id, id)) {
        _ = entry.refs.fetchAdd(1, .acq_rel);
        entry.used.store(now(io), .monotonic);
        return entry;
    };
    return null;
}

fn now(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

/// A message on a session: its requests answered as their revision
/// answers them, its notifications and answers to the server taken.
fn serveSession(e: *Endpoint, io: Io, arena: Allocator, request: *Request, response: *Response, entry: *Entry, message: wire.Message) anyerror!void {
    const session = &entry.session;
    switch (message) {
        .request => |req| {
            if (request.headers.get(headers.protocol_version)) |version| {
                if (!std.mem.eql(u8, version, session.revision.text()))
                    return refuse(io, response, .bad_request, req.id, .invalid_request, "MCP-Protocol-Version is not the session's version");
            }
            var stream: Stream = .{ .io = io, .response = response };
            const reply = session.handle(io, arena, req, stream.sink(e)) catch |err| switch (err) {
                error.Canceled => return,
                error.OutOfMemory => return err,
            };
            return e.answer(io, arena, response, &stream, req.id, reply);
        },
        .notification => |n| if (std.mem.eql(u8, n.method, "notifications/initialized")) session.initialized(io),
        .result, .failure => session.deliver(io, message),
    }
    response.status = .accepted;
    return response.end(io);
}

/// GET: the session's own stream, where its list changes and resource
/// updates go; one at a time.
fn openStream(e: *Endpoint, io: Io, response: *Response, session_id: ?[]const u8, accept: ?[]const u8) anyerror!void {
    const id = session_id orelse {
        try response.header("Allow", "POST, DELETE");
        return refuse(io, response, .method_not_allowed, null, .invalid_request, "GET opens a session's stream: there is no stream without a session");
    };
    if (accept == null or std.mem.find(u8, accept.?, "text/event-stream") == null)
        return refuse(io, response, .not_acceptable, null, .invalid_request, "Accept must list text/event-stream");
    const entry = e.lookup(io, id) orelse return refuse(io, response, .not_found, null, .invalid_request, "Session not found: initialize again");
    defer entry.release(e.gpa);
    if (entry.streaming.swap(true, .acq_rel)) return refuse(io, response, .conflict, null, .invalid_request, "The session's stream is open already");
    defer entry.streaming.store(false, .release);
    var stream: Stream = .{ .io = io, .response = response };
    // The head goes now: the client learns the stream is open.
    stream.keepAlive(io) catch return;
    // glint-ignore: Z026 -- the stream ends when its client leaves or the server closes; either way there is nothing to answer
    entry.session.stream(io, stream.sink(e)) catch {};
    // glint-ignore: Z026 -- the stream was the answer; a client gone before its end needs no more
    response.end(io) catch {};
}

/// DELETE: the session ends.
fn endSession(e: *Endpoint, io: Io, response: *Response, session_id: ?[]const u8) anyerror!void {
    const id = session_id orelse return refuse(io, response, .bad_request, null, .invalid_request, "DELETE ends a session: name it in Mcp-Session-Id");
    const gone = found: {
        e.sessions_mutex.lockUncancelable(io);
        defer e.sessions_mutex.unlock(io);
        for (e.sessions.items, 0..) |entry, i| if (std.mem.eql(u8, &entry.id, id)) break :found e.sessions.swapRemove(i);
        break :found null;
    } orelse return refuse(io, response, .not_found, null, .invalid_request, "Session not found");
    gone.release(e.gpa);
    response.status = .no_content;
    return response.end(io);
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
fn mismatch(e: *Endpoint, io: Io, arena: Allocator, request: *const Request, req: wire.Request) Allocator.Error!?[]const u8 {
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
        if (std.mem.eql(u8, req.method, "tools/call")) return e.paramMismatch(io, arena, request, req, expected);
    }
    return null;
}

/// Why the tool's `Mcp-Param-*` headers disagree with its arguments, or
/// null when they agree (2026-07-28 streamable-http, custom headers).
fn paramMismatch(e: *Endpoint, io: Io, arena: Allocator, request: *const Request, req: wire.Request, tool: []const u8) Allocator.Error!?[]const u8 {
    const params = e.server.toolHeaders(io, arena, tool) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return null,
    } orelse return null;
    const arguments = rawMember(req.params, "arguments");
    for (params) |p| {
        const header_name = try std.mem.concat(arena, u8, &.{ headers.param_prefix, p.name });
        const header = request.headers.get(header_name);
        const value = if (arguments) |a| at(a, p.path) else null;
        const present = if (value) |v| !std.mem.eql(u8, v, "null") else false;
        if (!present) continue;
        const raw = header orelse return try arena.print("{s} is missing", .{header_name});
        const given = headers.decode(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return try arena.print("{s} holds a value no header holds", .{header_name}),
        };
        const v = value.?;
        const same = switch (p.kind) {
            .string => if (@import("strand").json.parseLeaky([]const u8, arena, v, .{})) |text| std.mem.eql(u8, text, given) else |_| false,
            .boolean => std.mem.eql(u8, v, given),
            .integer => numericallyEqual(v, given),
        };
        if (!same) return try arena.print("{s} does not match the argument", .{header_name});
    }
    return null;
}

/// Whether two integers' spellings name one number (`42` and `42.0`).
fn numericallyEqual(a: []const u8, b: []const u8) bool {
    const x = std.fmt.parseFloat(f64, a) catch return false;
    const y = std.fmt.parseFloat(f64, b) catch return false;
    return x == y;
}

/// The value at `path` (property names) in the JSON object `object`.
fn at(object: []const u8, path: []const []const u8) ?[]const u8 {
    var current = object;
    for (path) |step| current = rawMember(current, step) orelse return null;
    return current;
}

fn rawMember(object: ?[]const u8, name: []const u8) ?[]const u8 {
    const bytes = object orelse return null;
    var members: @import("strand").json.Members = undefined;
    members.init(bytes, .{});
    while (members.next() catch return null) |m| if (m.is(name)) return m.value;
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
        try s.response.flush(s.io);
    }

    fn sink(s: *Stream, e: *const Endpoint) parley.Sink {
        return .{
            .context = s,
            .sendFn = send,
            .keep_alive = e.options.keep_alive.toIoDuration(),
            .keepAliveFn = keepAliveFn,
        };
    }

    fn keepAlive(s: *Stream, io: Io) parley.Sink.SendError!void {
        return keepAliveFn(s, io);
    }

    fn send(context: *anyopaque, io: Io, message: []const u8) parley.Sink.SendError!void {
        _ = io;
        const s: *Stream = @ptrCast(@alignCast(context)); // safe: the sink was made from this stream
        s.event(message) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Closed,
        };
    }

    fn keepAliveFn(context: *anyopaque, io: Io) parley.Sink.SendError!void {
        _ = io;
        const s: *Stream = @ptrCast(@alignCast(context)); // safe: the sink was made from this stream
        const w = s.begin() catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.Closed,
        };
        w.writeAll(":\n\n") catch return error.Closed;
        s.response.flush(s.io) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.Closed,
        };
    }
};
