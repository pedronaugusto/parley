//! The client: requests built and answered the way the server speaks.
//!
//! `connect` learns which era the server is in: a 2026-07-28 server answers
//! `server/discover` (or names the versions it speaks), and every request
//! then carries the version, the client's identity and capabilities in its
//! `_meta`; any other answer means a session server, which is opened with
//! `initialize`. A tool call, a prompt or a read that comes back asking for
//! input (2026-07-28) is answered by the application's handlers and retried
//! with the answers and the server's state as they came; a session server
//! asks the same through its own requests, which the transport hands to the
//! same handlers.
const Client = @This();

const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const types = @import("types.zig");
const wire = @import("wire.zig");
const meta = @import("meta.zig");
const Revision = @import("revision.zig").Revision;

const tasks_extension = "io.modelcontextprotocol/tasks";

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Raw = strand.json.Raw;

/// A span as MCP writes one: whole milliseconds.
pub const Duration = aegis.units.Duration(.millisecond, u32);

gpa: Allocator,
options: Options,
transport: Transport,
/// Private: what `connect` learned, kept for the client's life.
arena: std.heap.ArenaAllocator,
era: Era = .unknown,
/// The version requests are in.
revision: Revision = Revision.latest,
/// The server's capabilities, as it gave them.
server_capabilities: ?[]const u8 = null,
server_info: ?types.Implementation = null,
instructions: ?[]const u8 = null,
next_id: std.atomic.Value(i64) = .init(1),

/// Which era the server is in, once `connect` has asked.
pub const Era = enum { unknown, modern, session };

pub const Options = struct {
    info: types.Implementation,
    /// What the client answers when a server asks for input. A capability
    /// is declared only for a handler given.
    handlers: Handlers = .{},
    /// How long a request may take before it is canceled.
    timeout: Duration = .literal("60s"),
    /// Rounds of input one request may ask for.
    max_rounds: u8 = 8,
    /// The revisions the client speaks, newest first. Without 2026-07-28
    /// it opens a session at once; without the session revisions it speaks
    /// to 2026-07-28 servers alone. A session server that answers
    /// `initialize` with 2025-03-26 or 2024-11-05 is served at it: a batch
    /// from it is taken, and the client sends none of its own.
    revisions: []const Revision = &.{ .@"2026-07-28", .@"2025-11-25", .@"2025-06-18", .@"2025-03-26", .@"2024-11-05" },
    /// How long `server/discover` waits before the server is taken for a
    /// session server that stays silent before `initialize` (stdio).
    probe_timeout: Duration = .literal("5s"),
    /// Declare the tasks extension (2026-07-28): a tool call the server
    /// runs as a task is polled to its end, its input given as it asks,
    /// and answers as if it had been answered at once.
    tasks: bool = true,
    limits: Limits = .{},
};

pub const Limits = struct {
    /// The longest message, either way: what the transport reads of the
    /// server (a longer one is passed over unread), and what every read of
    /// a message and of a value within it allows (`wire.limitsFor`).
    message: aegis.units.Bytes(u32) = wire.default_message,
};

/// strand's limits for every read and write of a message and of the values
/// within it: those of `options.limits.message`.
pub fn jsonLimits(c: *const Client) strand.core.Limits {
    return wire.limitsFor(c.options.limits.message);
}

/// The application's answers to a server's requests for input. Each takes
/// the request's params as JSON and returns its answer.
pub const Handlers = struct {
    context: ?*anyopaque = null,
    elicit: ?*const fn (context: ?*anyopaque, io: Io, arena: Allocator, params: []const u8) HandlerError!types.ElicitResult = null,
    sample: ?*const fn (context: ?*anyopaque, io: Io, arena: Allocator, params: []const u8) HandlerError!types.CreateMessageResult = null,
    roots: ?*const fn (context: ?*anyopaque, io: Io, arena: Allocator) HandlerError!types.ListRootsResult = null,
};

/// `Refused`: the application will not give what was asked.
pub const HandlerError = error{ Refused, Canceled, OutOfMemory };

/// How a request reaches the server and its answer comes back: stdio's
/// lines, Streamable HTTP's posts. A transport hands every message that
/// arrives for a request before its answer (a notification, the server's
/// own request in a session) to `Exchange.inbound`.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sends `exchange.message` and returns the answer, one JSON-RPC
        /// message, on `arena`.
        request: *const fn (context: *anyopaque, io: Io, arena: Allocator, exchange: *Exchange) RequestError![]const u8,
        /// Sends a notification.
        notify: *const fn (context: *anyopaque, io: Io, message: []const u8) RequestError!void,
        /// The session was opened (`initialize` answered at
        /// `client.revision`): a transport with a stream of the session's
        /// own (an HTTP GET) opens it, for the server's requests and
        /// notifications that belong to no request. `ConcurrencyUnavailable`
        /// when the `Io` gives no task to read it on: `connect` returns it,
        /// where a session without it would miss what the server sends.
        opened: *const fn (context: *anyopaque, io: Io, client: *Client) Io.ConcurrentError!void,
        /// A `tools/list` answer, as the application should see it: a
        /// transport that mirrors arguments into headers learns the tools'
        /// marks, and leaves out a tool whose marks it cannot honour.
        listed: ?*const fn (context: *anyopaque, io: Io, client: *const Client, arena: Allocator, result: []const u8) Allocator.Error![]const u8 = null,
    };

    pub fn request(t: Transport, io: Io, arena: Allocator, exchange: *Exchange) RequestError![]const u8 {
        return t.vtable.request(t.context, io, arena, exchange);
    }

    pub fn notify(t: Transport, io: Io, message: []const u8) RequestError!void {
        return t.vtable.notify(t.context, io, message);
    }
};

/// `Refused`: the server answered at the transport's level with an error
/// that is not a JSON-RPC answer (an HTTP status with no message), which
/// `status` names. `Unauthorized`: the server refused the request's
/// credentials, and no better ones could be had (HTTP: a 401 or 403 the
/// transport's authorization could not answer). `Closed`: the connection is
/// gone. `TimedOut`: no answer within the request's time.
pub const RequestError = error{ Refused, Unauthorized, Closed, TimedOut, Canceled, OutOfMemory };

/// One request on its way: what is sent, what the transport learned of it.
pub const Exchange = struct {
    id: wire.Id,
    method: []const u8,
    /// The whole message.
    message: []const u8,
    /// `params.name` or `params.uri`, for a transport that mirrors it.
    name: ?[]const u8 = null,
    /// The tool's arguments, for a transport that mirrors marked ones.
    arguments: ?[]const u8 = null,
    revision: Revision,
    timeout: Io.Duration,
    client: *Client,
    /// Set by the transport when `Refused`: the status it got.
    status: u16 = 0,

    /// A message that arrived for the request before its answer.
    pub fn inbound(x: *Exchange, io: Io, arena: Allocator, message: wire.Message) Answer {
        return switch (message) {
            .request => |r| x.client.serveRequest(io, arena, r),
            else => .none,
        };
    }
};

/// What a transport sends back for an inbound message: nothing, or the
/// answer to a server's request.
pub const Answer = union(enum) { none, message: []const u8 };

/// The answers to what one frame from the server asked, as they go back:
/// the one answer as it is, or for a batch one array (JSON-RPC 2.0 §6), the
/// only batch the client sends.
pub const Replies = struct {
    batch: bool,
    out: Writer.Allocating,
    count: u32 = 0,

    /// For the answers to `frame`'s requests.
    pub fn init(arena: Allocator, frame: []const u8) Replies {
        return .{ .batch = wire.isBatch(frame), .out = .init(arena) };
    }

    pub fn add(r: *Replies, answer: Answer) Allocator.Error!void {
        const one = switch (answer) {
            .none => return,
            .message => |m| m,
        };
        const w = &r.out.writer;
        if (r.batch) w.writeByte(if (r.count == 0) '[' else ',') catch return error.OutOfMemory;
        w.writeAll(one) catch return error.OutOfMemory;
        r.count += 1;
    }

    /// What goes back, or null when nothing does.
    pub fn message(r: *Replies) Allocator.Error!?[]const u8 {
        if (r.count == 0) return null;
        if (r.batch) r.out.writer.writeByte(']') catch return error.OutOfMemory;
        return r.out.written();
    }
};

/// `Unsupported`: the server speaks no version this client does.
/// `Protocol`: the server's answer is not what the protocol says.
/// `ConcurrencyUnavailable`: the transport's session stream had no task
/// to run on (`Transport.VTable.opened`).
pub const ConnectError = RequestError || Io.ConcurrentError || error{ Unsupported, Protocol };

pub fn init(gpa: Allocator, transport: Transport, options: Options) Client {
    return .{ .gpa = gpa, .options = options, .transport = transport, .arena = .init(gpa) };
}

pub fn deinit(c: *Client) void {
    c.arena.deinit();
}

/// Learns the server's era and what it offers: `server/discover`, and when
/// it is not understood, `initialize` (when sessions are allowed).
pub fn connect(c: *Client, io: Io) ConnectError!void {
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    c.revision = for (c.options.revisions) |r| {
        if (r.stateless()) break r;
    } else return c.openSession(io, arena);
    var tries: u8 = 0;
    while (tries < 2) : (tries += 1) {
        const answer = c.send(io, arena, "server/discover", "{}", null, null, .modern, c.options.probe_timeout.toIoDuration()) catch |err| switch (err) {
            // No JSON-RPC answer at all: not a modern server.
            error.Refused, error.TimedOut => return c.openSession(io, arena),
            else => |e| return e,
        };
        switch (answer) {
            .result => |r| {
                c.era = .modern;
                return c.keepDiscovery(r.result);
            },
            .failure => |f| switch (f.code) {
                .unsupported_protocol_version => {
                    const chosen = chooseVersion(arena, c.jsonLimits(), c.options.revisions, f.data) orelse return error.Unsupported;
                    if (!chosen.stateless()) return c.openSession(io, arena);
                    c.revision = chosen;
                },
                // A modern refusal names a modern server.
                .header_mismatch, .missing_required_client_capability => return error.Protocol,
                else => return c.openSession(io, arena),
            },
            else => return error.Protocol,
        }
    }
    return error.Unsupported;
}

/// The newest version the server names that this client speaks.
fn chooseVersion(arena: Allocator, limits: strand.core.Limits, spoken: []const Revision, data: ?[]const u8) ?Revision {
    const Data = struct { supported: []const []const u8 = &.{} };
    const d = strand.json.parseLeaky(Data, arena, data orelse return null, types.readOptions(limits)) catch return null;
    var best: ?Revision = null;
    for (d.supported) |name| if (Revision.named(name)) |r| {
        for (spoken) |known| if (known == r) {
            if (best == null or @backingInt(r) < @backingInt(best.?)) best = r;
        };
    };
    return best;
}

fn keepDiscovery(c: *Client, result: []const u8) ConnectError!void {
    const Discovery = struct { capabilities: Raw = .null, instructions: ?[]const u8 = null, _meta: ?struct {
        @"io.modelcontextprotocol/serverInfo": ?types.Implementation = null,
    } = null };
    const kept = c.arena.allocator();
    const bytes = try kept.dupe(u8, result);
    const d = strand.json.parseLeaky(Discovery, kept, bytes, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    c.server_capabilities = d.capabilities.bytes;
    c.instructions = d.instructions;
    if (d._meta) |m| c.server_info = m.@"io.modelcontextprotocol/serverInfo";
}

/// `initialize`, then `notifications/initialized`: a session.
fn openSession(c: *Client, io: Io, arena: Allocator) ConnectError!void {
    c.era = .session;
    c.revision = for (c.options.revisions) |r| {
        if (!r.stateless()) break r;
    } else return error.Unsupported;
    var params: Writer.Allocating = .init(arena);
    const w = &params.writer;
    w.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":", .{c.revision.text()}) catch return error.OutOfMemory;
    c.writeCapabilities(w) catch return error.OutOfMemory;
    w.writeAll(",\"clientInfo\":") catch return error.OutOfMemory;
    strand.json.write(w, c.options.info, types.writeOptions(c.jsonLimits())) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    const answer = try c.send(io, arena, "initialize", params.written(), null, null, .session, c.options.timeout.toIoDuration());
    const result = switch (answer) {
        .result => |r| r.result,
        .failure => return error.Unsupported,
        else => return error.Protocol,
    };
    const Initialized = struct {
        protocolVersion: []const u8,
        capabilities: Raw = .null,
        serverInfo: ?types.Implementation = null,
        instructions: ?[]const u8 = null,
    };
    const kept = c.arena.allocator();
    const bytes = try kept.dupe(u8, result);
    const r = strand.json.parseLeaky(Initialized, kept, bytes, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    const revision = Revision.named(r.protocolVersion) orelse return error.Unsupported;
    if (revision.stateless()) return error.Protocol;
    for (c.options.revisions) |spoken| {
        if (spoken == revision) break;
    } else return error.Unsupported;
    c.revision = revision;
    c.server_capabilities = r.capabilities.bytes;
    c.server_info = r.serverInfo;
    c.instructions = r.instructions;
    try c.transport.vtable.opened(c.transport.context, io, c);
    try c.transport.notify(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
}

fn writeCapabilities(c: *const Client, w: *Writer) Writer.Error!void {
    const h = c.options.handlers;
    var caps: types.ClientCapabilities = .{};
    if (h.roots != null) caps.roots = .{ .bytes = "{}" };
    if (h.sample != null) caps.sampling = .{};
    if (h.elicit != null) caps.elicitation = .{ .form = .{ .bytes = "{}" } };
    if (c.options.tasks and c.revision.stateless()) caps.extensions = .{ .bytes = "{\"" ++ tasks_extension ++ "\":{}}" };
    strand.json.write(w, caps, types.writeOptions(c.jsonLimits())) catch return error.WriteFailed;
}

/// Sends `method` with `params` (one JSON object) and returns the answer.
/// Under 2026-07-28 the params gain the `_meta` every request carries.
fn send(c: *Client, io: Io, arena: Allocator, method: []const u8, params: []const u8, name: ?[]const u8, arguments: ?[]const u8, era: Era, timeout: Io.Duration) RequestError!wire.Message {
    const id: wire.Id = .{ .integer = c.next_id.fetchAdd(1, .monotonic) };
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
    id.write(w) catch return error.OutOfMemory;
    w.writeAll(",\"method\":") catch return error.OutOfMemory;
    wire.writeString(w, method) catch return error.OutOfMemory;
    w.writeAll(",\"params\":") catch return error.OutOfMemory;
    if (era == .modern) {
        c.writeWithMeta(w, params) catch return error.OutOfMemory;
    } else w.writeAll(params) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    var exchange: Exchange = .{
        .id = id,
        .method = method,
        .message = out.written(),
        .name = name,
        .arguments = arguments,
        .revision = c.revision,
        .timeout = timeout,
        .client = c,
    };
    const bytes = try c.transport.request(io, arena, &exchange);
    return wire.decode(arena, bytes, .{ .limits = c.jsonLimits() }) catch error.Refused;
}

/// `params` with the `_meta` of a 2026-07-28 request merged in.
fn writeWithMeta(c: *const Client, w: *Writer, params: []const u8) Writer.Error!void {
    try w.writeAll("{\"_meta\":{\"" ++ meta.protocol_version ++ "\":\"");
    try w.writeAll(c.revision.text());
    try w.writeAll("\",\"" ++ meta.client_info ++ "\":");
    strand.json.write(w, c.options.info, types.writeOptions(c.jsonLimits())) catch return error.WriteFailed;
    try w.writeAll(",\"" ++ meta.client_capabilities ++ "\":");
    try c.writeCapabilities(w);
    try w.writeByte('}');
    // The rest of the params' members, but a `_meta` of their own.
    var members: strand.json.Members = undefined;
    members.init(params, .{ .limits = c.jsonLimits() });
    while (members.next() catch null) |m| {
        if (m.is("_meta")) continue;
        try w.writeByte(',');
        try w.writeAll(params[m.start..m.valueEnd()]);
    }
    try w.writeByte('}');
}

/// A server's request in a session, answered by the application.
pub fn serveRequest(c: *Client, io: Io, arena: Allocator, request: wire.Request) Answer {
    const params = request.params orelse "{}";
    var out: Writer.Allocating = .init(arena);
    const result: (HandlerError || error{ MethodNotFound, WriteFailed })![]const u8 = blk: {
        if (std.mem.eql(u8, request.method, "ping")) break :blk "{}";
        if (std.mem.eql(u8, request.method, "elicitation/create")) {
            const f = c.options.handlers.elicit orelse break :blk error.MethodNotFound;
            var answer = f(c.options.handlers.context, io, arena, params) catch |err| break :blk err;
            if (answer.action == .accept) answer.content = .{ .bytes = withDefaults(arena, c.jsonLimits(), params, if (answer.content) |r| r.bytes else "{}") catch |err| break :blk err };
            break :blk encode(arena, c.jsonLimits(), answer);
        }
        if (std.mem.eql(u8, request.method, "sampling/createMessage")) {
            const f = c.options.handlers.sample orelse break :blk error.MethodNotFound;
            break :blk encode(arena, c.jsonLimits(), f(c.options.handlers.context, io, arena, params) catch |err| break :blk err);
        }
        if (std.mem.eql(u8, request.method, "roots/list")) {
            const f = c.options.handlers.roots orelse break :blk error.MethodNotFound;
            break :blk encode(arena, c.jsonLimits(), f(c.options.handlers.context, io, arena) catch |err| break :blk err);
        }
        break :blk error.MethodNotFound;
    };
    if (result) |bytes| {
        wire.writeResult(&out.writer, request.id, bytes) catch return .none;
    } else |err| {
        const code: wire.Code = if (err == error.MethodNotFound) .method_not_found else .internal_error;
        wire.writeFailure(&out.writer, request.id, code, if (err == error.Refused) "the user declined" else @errorName(err), null) catch return .none;
    }
    return .{ .message = out.written() };
}

/// An accepted form's content, with each field the user left out that the
/// form's schema gives a default for set to that default (2025-11-25,
/// SEP-1034).
fn withDefaults(arena: Allocator, limits: strand.core.Limits, params: []const u8, content: []const u8) error{OutOfMemory}![]const u8 {
    const Form = struct { requestedSchema: struct { properties: ?Raw = null } = .{} };
    const form = strand.json.parseLeaky(Form, arena, params, types.readOptions(limits)) catch return content;
    const properties = form.requestedSchema.properties orelse return content;
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    const body = std.mem.trim(u8, content, " \t\r\n");
    if (body.len < 2 or body[0] != '{') return content;
    w.writeAll(body[0 .. body.len - 1]) catch return error.OutOfMemory;
    var first = std.mem.trim(u8, body[1 .. body.len - 1], " \t\r\n").len == 0;
    var each: strand.json.Members = undefined;
    each.init(properties.bytes, .{ .limits = limits });
    while (each.next() catch null) |p| {
        var name_buffer: [256]u8 = undefined;
        const name = p.nameInto(&name_buffer) catch continue;
        if (hasMember(content, limits, name)) continue;
        var fields: strand.json.Members = undefined;
        fields.init(p.value, .{ .limits = limits });
        while (fields.next() catch null) |f| if (f.is("default")) {
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            wire.writeString(w, name) catch return error.OutOfMemory;
            w.writeByte(':') catch return error.OutOfMemory;
            w.writeAll(f.value) catch return error.OutOfMemory;
        };
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

fn hasMember(object: []const u8, limits: strand.core.Limits, name: []const u8) bool {
    var members: strand.json.Members = undefined;
    members.init(object, .{ .limits = limits });
    while (members.next() catch return false) |m| if (m.is(name)) return true;
    return false;
}

fn encode(arena: Allocator, limits: strand.core.Limits, value: anytype) error{WriteFailed}![]const u8 {
    var out: Writer.Allocating = .init(arena);
    strand.json.write(&out.writer, value, types.writeOptions(limits)) catch return error.WriteFailed;
    return out.written();
}

/// `Failed`: the server answered with a JSON-RPC error, which `failure`
/// holds after the call.
pub const CallError = RequestError || error{ Protocol, Failed, TooManyRounds };

/// The error a call's answer carried.
pub const Failure = struct {
    code: wire.Code,
    message: []const u8,
    data: ?[]const u8,
};

pub const Diagnostics = struct {
    failure: ?Failure = null,
};

/// A result, as JSON, after any rounds of input it took.
fn call(c: *Client, io: Io, arena: Allocator, method: []const u8, params: []const u8, name: ?[]const u8, arguments: ?[]const u8, diagnostics: ?*Diagnostics) CallError![]const u8 {
    var current = params;
    var rounds: u8 = 0;
    while (true) {
        const answer = try c.send(io, arena, method, current, name, arguments, c.era, c.options.timeout.toIoDuration());
        switch (answer) {
            .result => |r| {
                const kind = resultType(r.result, c.jsonLimits());
                if (std.mem.eql(u8, kind, "complete")) return r.result;
                if (std.mem.eql(u8, kind, "task") and std.mem.eql(u8, method, "tools/call") and c.options.tasks) return c.followTask(io, arena, r.result, diagnostics);
                if (!std.mem.eql(u8, kind, "input_required")) return error.Protocol;
                rounds += 1;
                if (rounds > c.options.max_rounds) return error.TooManyRounds;
                current = try c.answerInput(io, arena, params, r.result);
            },
            .failure => |f| {
                if (diagnostics) |d| d.failure = .{ .code = f.code, .message = f.message, .data = f.data };
                return error.Failed;
            },
            else => return error.Protocol,
        }
    }
}

/// A result's `resultType`, `complete` when it has none (2025-11-25 and
/// before).
fn resultType(result: []const u8, limits: strand.core.Limits) []const u8 {
    var members: strand.json.Members = undefined;
    members.init(result, .{ .limits = limits });
    while (members.next() catch null) |m| if (m.is("resultType")) {
        if (m.value.len >= 2 and m.value[0] == '"') return m.value[1 .. m.value.len - 1];
    };
    return "complete";
}

/// The retry's params: the request's own, with the answers to every input
/// request and the server's state exactly as it came.
fn answerInput(c: *Client, io: Io, arena: Allocator, params: []const u8, result: []const u8) CallError![]const u8 {
    var requests: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var members: strand.json.Members = undefined;
    members.init(result, .{ .limits = c.jsonLimits() });
    while (members.next() catch return error.Protocol) |m| {
        if (m.is("inputRequests")) requests = m.value;
        if (m.is("requestState")) state = m.value;
    }
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    var first = true;
    var own: strand.json.Members = undefined;
    own.init(params, .{ .limits = c.jsonLimits() });
    while (own.next() catch return error.Protocol) |m| {
        if (m.is("inputResponses") or m.is("requestState")) continue;
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll(params[m.start..m.valueEnd()]) catch return error.OutOfMemory;
    }
    if (requests) |object| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll("\"inputResponses\":") catch return error.OutOfMemory;
        w.writeAll(try c.inputResponses(io, arena, object, null)) catch return error.OutOfMemory;
    }
    if (state) |s| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("\"requestState\":") catch return error.OutOfMemory;
        w.writeAll(s) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

/// The answers to an `inputRequests` object, as an `inputResponses` one;
/// with `given`, the keys answered before are passed over and the ones
/// answered now added to it.
fn inputResponses(c: *Client, io: Io, arena: Allocator, object: []const u8, given: ?*std.ArrayList([]const u8)) CallError![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    var each: strand.json.Members = undefined;
    each.init(object, .{ .limits = c.jsonLimits() });
    var n: usize = 0;
    while (each.next() catch return error.Protocol) |m| {
        if (given) |keys| {
            const key = strand.json.parseLeaky([]const u8, arena, object[m.start .. m.value_start - 1], .{ .limits = c.jsonLimits() }) catch return error.Protocol;
            const seen = for (keys.items) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (seen) continue;
            try keys.append(c.gpa, try c.gpa.dupe(u8, key));
        }
        const Request = struct { method: []const u8, params: Raw = .{ .bytes = "{}" } };
        const r = strand.json.parseLeaky(Request, arena, m.value, types.readOptions(c.jsonLimits())) catch return error.Protocol;
        const message = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"{s}\",\"params\":{s}}}", .{ r.method, r.params.bytes });
        const asked = wire.decode(arena, message, .{ .limits = c.jsonLimits() }) catch return error.Protocol;
        const answer = c.serveRequest(io, arena, asked.request);
        const bytes = switch (answer) {
            .message => |b| b,
            .none => return error.Protocol,
        };
        const reply = wire.decode(arena, bytes, .{ .limits = c.jsonLimits() }) catch return error.Protocol;
        const value = switch (reply) {
            .result => |x| x.result,
            // The application did not answer: the server learns it
            // when the answer is missing, and may ask again.
            else => continue,
        };
        if (n != 0) w.writeByte(',') catch return error.OutOfMemory;
        n += 1;
        // The key as the server wrote it, then the answer.
        w.writeAll(object[m.start..m.value_start]) catch return error.OutOfMemory;
        w.writeAll(value) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

/// Polls the task a tool call became until it ends, giving the input it
/// asks for along the way: the call's result, as JSON on `arena`.
fn followTask(c: *Client, io: Io, arena: Allocator, created: []const u8, diagnostics: ?*Diagnostics) CallError![]const u8 {
    const Created = struct { taskId: []const u8, pollIntervalMs: ?u32 = null };
    const task = strand.json.parseLeaky(Created, arena, created, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    var interval: u32 = task.pollIntervalMs orelse 1000;
    var id_out: Writer.Allocating = .init(arena);
    wire.writeString(&id_out.writer, task.taskId) catch return error.OutOfMemory;
    const quoted = id_out.written();
    const params = try arena.print("{{\"taskId\":{s}}}", .{quoted});
    // The keys answered, so a request seen on two polls is answered once.
    var given: std.ArrayList([]const u8) = .empty;
    defer {
        for (given.items) |k| c.gpa.free(k);
        given.deinit(c.gpa);
    }
    const timeout = c.options.timeout.toIoDuration();
    while (true) {
        io.sleep(.fromMilliseconds(interval), .awake) catch return error.Canceled;
        // Each poll on its own arena: a long task is polled many times.
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const polled = switch (try c.send(io, a, "tasks/get", params, task.taskId, null, c.era, timeout)) {
            .result => |r| r.result,
            .failure => |f| return failed(arena, diagnostics, f.code, f.message, f.data),
            else => return error.Protocol,
        };
        const Polled = struct {
            status: TaskStatus,
            statusMessage: ?[]const u8 = null,
            pollIntervalMs: ?u32 = null,
            inputRequests: ?Raw = null,
            result: ?Raw = null,
            @"error": ?Raw = null,
        };
        const p = strand.json.parseLeaky(Polled, a, polled, types.readOptions(c.jsonLimits())) catch return error.Protocol;
        if (p.pollIntervalMs) |next| interval = next;
        switch (p.status) {
            .working => {},
            .input_required => {
                const requests = p.inputRequests orelse return error.Protocol;
                const responses = try c.inputResponses(io, a, requests.bytes, &given);
                if (responses.len <= 2) continue;
                var update: Writer.Allocating = .init(a);
                update.writer.print("{{\"taskId\":{s},\"inputResponses\":{s}}}", .{ quoted, responses }) catch return error.OutOfMemory;
                switch (try c.send(io, a, "tasks/update", update.written(), task.taskId, null, c.era, timeout)) {
                    .result => {},
                    .failure => |f| return failed(arena, diagnostics, f.code, f.message, f.data),
                    else => return error.Protocol,
                }
            },
            .completed => return try arena.dupe(u8, (p.result orelse return error.Protocol).bytes),
            .failed => {
                const Fault = struct { code: i64, message: []const u8 = "", data: ?Raw = null };
                const f = strand.json.parseLeaky(Fault, a, (p.@"error" orelse return error.Protocol).bytes, types.readOptions(c.jsonLimits())) catch return error.Protocol;
                const code: wire.Code = @fromBackingInt(@intCast(f.code)); // safe: the codes are open, any integer is one
                return failed(arena, diagnostics, code, f.message, if (f.data) |d| d.bytes else null);
            },
            .cancelled => return failed(arena, diagnostics, .internal_error, p.statusMessage orelse "the task was cancelled", null),
        }
    }
}

const TaskStatus = enum { working, input_required, completed, failed, cancelled };

/// Records a failure (copied onto `arena`) for the caller and fails.
fn failed(arena: Allocator, diagnostics: ?*Diagnostics, code: wire.Code, message: []const u8, data: ?[]const u8) CallError {
    if (diagnostics) |d| d.failure = .{
        .code = code,
        .message = arena.dupe(u8, message) catch return error.OutOfMemory,
        .data = if (data) |x| arena.dupe(u8, x) catch return error.OutOfMemory else null,
    };
    return error.Failed;
}

// What applications call.

/// One page of a list: `tools/list`, `prompts/list`, `resources/list` or
/// `resources/templates/list`. The result as JSON.
pub fn list(c: *Client, io: Io, arena: Allocator, method: []const u8, cursor: ?[]const u8, diagnostics: ?*Diagnostics) CallError![]const u8 {
    var out: Writer.Allocating = .init(arena);
    out.writer.writeByte('{') catch return error.OutOfMemory;
    if (cursor) |text| {
        out.writer.writeAll("\"cursor\":") catch return error.OutOfMemory;
        wire.writeString(&out.writer, text) catch return error.OutOfMemory;
    }
    out.writer.writeByte('}') catch return error.OutOfMemory;
    const result = try c.call(io, arena, method, out.written(), null, null, diagnostics);
    if (std.mem.eql(u8, method, "tools/list")) if (c.transport.vtable.listed) |f| return f(c.transport.context, io, c, arena, result);
    return result;
}

/// Arguments as the object a request carries: a `Raw` as it is, an empty
/// literal (`.{}`) as `{}`, anything else as strand writes it.
fn argumentsJson(arena: Allocator, limits: strand.core.Limits, arguments: anytype) error{OutOfMemory}![]const u8 {
    const T = @TypeOf(arguments);
    if (T == Raw) return arguments.bytes;
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".field_names.len == 0) return "{}";
    return encode(arena, limits, arguments) catch error.OutOfMemory;
}

/// What a tool call returned.
pub const ToolOutcome = struct {
    content: []const types.ContentBlock = &.{},
    structured: ?Raw = null,
    is_error: bool = false,
};

/// Calls the tool `name` with `arguments` (any value strand writes, or a
/// `strand.json.Raw` object), after as many rounds of input as it asks for.
pub fn callTool(c: *Client, io: Io, arena: Allocator, name: []const u8, arguments: anytype, diagnostics: ?*Diagnostics) CallError!ToolOutcome {
    const args = try argumentsJson(arena, c.jsonLimits(), arguments);
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"name\":") catch return error.OutOfMemory;
    wire.writeString(w, name) catch return error.OutOfMemory;
    w.writeAll(",\"arguments\":") catch return error.OutOfMemory;
    w.writeAll(args) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    const result = try c.call(io, arena, "tools/call", out.written(), name, args, diagnostics);
    const Outcome = struct {
        content: []const types.ContentBlock = &.{},
        structuredContent: ?Raw = null,
        isError: bool = false,
    };
    const o = strand.json.parseLeaky(Outcome, arena, result, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    return .{ .content = o.content, .structured = o.structuredContent, .is_error = o.isError };
}

/// Reads the resource `uri`: its contents.
pub fn readResource(c: *Client, io: Io, arena: Allocator, uri: []const u8, diagnostics: ?*Diagnostics) CallError![]const types.ResourceContents {
    var out: Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"uri\":") catch return error.OutOfMemory;
    wire.writeString(&out.writer, uri) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    const result = try c.call(io, arena, "resources/read", out.written(), uri, null, diagnostics);
    const Read = struct { contents: []const types.ResourceContents = &.{} };
    const r = strand.json.parseLeaky(Read, arena, result, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    return r.contents;
}

/// Gets the prompt `name` with `arguments` (names to strings, as a struct
/// strand writes, or a `Raw` object): its messages.
pub fn getPrompt(c: *Client, io: Io, arena: Allocator, name: []const u8, arguments: anytype, diagnostics: ?*Diagnostics) CallError![]const types.PromptMessage {
    const args = try argumentsJson(arena, c.jsonLimits(), arguments);
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"name\":") catch return error.OutOfMemory;
    wire.writeString(w, name) catch return error.OutOfMemory;
    w.writeAll(",\"arguments\":") catch return error.OutOfMemory;
    w.writeAll(args) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    const result = try c.call(io, arena, "prompts/get", out.written(), name, null, diagnostics);
    const Got = struct { messages: []const types.PromptMessage = &.{} };
    const g = strand.json.parseLeaky(Got, arena, result, types.readOptions(c.jsonLimits())) catch return error.Protocol;
    return g.messages;
}
