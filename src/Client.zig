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
    /// Whether a session server (2025-11-25 and before) is spoken to.
    sessions: bool = true,
    /// How long `server/discover` waits before the server is taken for a
    /// session server that stays silent before `initialize` (stdio).
    probe_timeout: Duration = .literal("5s"),
};

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
        /// The session was opened (`initialize` answered at `revision`): a
        /// transport that names its sessions keeps what it needs.
        opened: *const fn (context: *anyopaque, revision: Revision) void,
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
/// `status` names. `Closed`: the connection is gone. `TimedOut`: no answer
/// within the request's time.
pub const RequestError = error{ Refused, Closed, TimedOut, Canceled, OutOfMemory };

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

/// `Unsupported`: the server speaks no version this client does.
/// `Protocol`: the server's answer is not what the protocol says.
pub const ConnectError = RequestError || error{ Unsupported, Protocol };

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
    c.revision = Revision.latest;
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
                    const chosen = chooseVersion(arena, f.data) orelse return error.Unsupported;
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
fn chooseVersion(arena: Allocator, data: ?[]const u8) ?Revision {
    const Data = struct { supported: []const []const u8 = &.{} };
    const d = strand.json.parseLeaky(Data, arena, data orelse return null, types.read_options) catch return null;
    var best: ?Revision = null;
    for (d.supported) |name| if (Revision.named(name)) |r| {
        if (best == null or @backingInt(r) < @backingInt(best.?)) best = r;
    };
    return best;
}

fn keepDiscovery(c: *Client, result: []const u8) ConnectError!void {
    const Discovery = struct { capabilities: Raw = .null, instructions: ?[]const u8 = null, _meta: ?struct {
        @"io.modelcontextprotocol/serverInfo": ?types.Implementation = null,
    } = null };
    const kept = c.arena.allocator();
    const bytes = try kept.dupe(u8, result);
    const d = strand.json.parseLeaky(Discovery, kept, bytes, types.read_options) catch return error.Protocol;
    c.server_capabilities = d.capabilities.bytes;
    c.instructions = d.instructions;
    if (d._meta) |m| c.server_info = m.@"io.modelcontextprotocol/serverInfo";
}

/// `initialize`, then `notifications/initialized`: a session.
fn openSession(c: *Client, io: Io, arena: Allocator) ConnectError!void {
    if (!c.options.sessions) return error.Unsupported;
    c.era = .session;
    c.revision = Revision.latest_legacy;
    var params: Writer.Allocating = .init(arena);
    const w = &params.writer;
    w.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":", .{c.revision.text()}) catch return error.OutOfMemory;
    c.writeCapabilities(w) catch return error.OutOfMemory;
    w.writeAll(",\"clientInfo\":") catch return error.OutOfMemory;
    strand.json.write(w, c.options.info, types.write_options) catch return error.OutOfMemory;
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
    const r = strand.json.parseLeaky(Initialized, kept, bytes, types.read_options) catch return error.Protocol;
    const revision = Revision.named(r.protocolVersion) orelse return error.Unsupported;
    if (revision.stateless()) return error.Protocol;
    c.revision = revision;
    c.server_capabilities = r.capabilities.bytes;
    c.server_info = r.serverInfo;
    c.instructions = r.instructions;
    c.transport.vtable.opened(c.transport.context, revision);
    try c.transport.notify(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
}

fn writeCapabilities(c: *const Client, w: *Writer) Writer.Error!void {
    const h = c.options.handlers;
    var caps: types.ClientCapabilities = .{};
    if (h.roots != null) caps.roots = .{ .bytes = "{}" };
    if (h.sample != null) caps.sampling = .{};
    if (h.elicit != null) caps.elicitation = .{ .form = .{ .bytes = "{}" } };
    strand.json.write(w, caps, types.write_options) catch return error.WriteFailed;
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
    return wire.decode(arena, bytes, .{}) catch error.Refused;
}

/// `params` with the `_meta` of a 2026-07-28 request merged in.
fn writeWithMeta(c: *const Client, w: *Writer, params: []const u8) Writer.Error!void {
    try w.writeAll("{\"_meta\":{\"" ++ meta.protocol_version ++ "\":\"");
    try w.writeAll(c.revision.text());
    try w.writeAll("\",\"" ++ meta.client_info ++ "\":");
    strand.json.write(w, c.options.info, types.write_options) catch return error.WriteFailed;
    try w.writeAll(",\"" ++ meta.client_capabilities ++ "\":");
    try c.writeCapabilities(w);
    try w.writeByte('}');
    // The rest of the params' members, but a `_meta` of their own.
    var members: strand.json.Members = undefined;
    members.init(params, .{});
    while (members.next() catch null) |m| {
        if (m.is("_meta")) continue;
        try w.writeByte(',');
        try w.writeAll(params[m.start..m.valueEnd()]);
    }
    try w.writeByte('}');
}

/// A server's request in a session, answered by the application.
fn serveRequest(c: *Client, io: Io, arena: Allocator, request: wire.Request) Answer {
    const params = request.params orelse "{}";
    var out: Writer.Allocating = .init(arena);
    const result: (HandlerError || error{ MethodNotFound, WriteFailed })![]const u8 = blk: {
        if (std.mem.eql(u8, request.method, "ping")) break :blk "{}";
        if (std.mem.eql(u8, request.method, "elicitation/create")) {
            const f = c.options.handlers.elicit orelse break :blk error.MethodNotFound;
            break :blk encode(arena, f(c.options.handlers.context, io, arena, params) catch |err| break :blk err);
        }
        if (std.mem.eql(u8, request.method, "sampling/createMessage")) {
            const f = c.options.handlers.sample orelse break :blk error.MethodNotFound;
            break :blk encode(arena, f(c.options.handlers.context, io, arena, params) catch |err| break :blk err);
        }
        if (std.mem.eql(u8, request.method, "roots/list")) {
            const f = c.options.handlers.roots orelse break :blk error.MethodNotFound;
            break :blk encode(arena, f(c.options.handlers.context, io, arena) catch |err| break :blk err);
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

fn encode(arena: Allocator, value: anytype) error{WriteFailed}![]const u8 {
    var out: Writer.Allocating = .init(arena);
    strand.json.write(&out.writer, value, types.write_options) catch return error.WriteFailed;
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
                const kind = resultType(r.result);
                if (std.mem.eql(u8, kind, "complete")) return r.result;
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
fn resultType(result: []const u8) []const u8 {
    var members: strand.json.Members = undefined;
    members.init(result, .{});
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
    members.init(result, .{});
    while (members.next() catch return error.Protocol) |m| {
        if (m.is("inputRequests")) requests = m.value;
        if (m.is("requestState")) state = m.value;
    }
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    var first = true;
    var own: strand.json.Members = undefined;
    own.init(params, .{});
    while (own.next() catch return error.Protocol) |m| {
        if (m.is("inputResponses") or m.is("requestState")) continue;
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll(params[m.start..m.valueEnd()]) catch return error.OutOfMemory;
    }
    if (requests) |object| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll("\"inputResponses\":{") catch return error.OutOfMemory;
        var each: strand.json.Members = undefined;
        each.init(object, .{});
        var n: usize = 0;
        while (each.next() catch return error.Protocol) |m| {
            const Request = struct { method: []const u8, params: Raw = .{ .bytes = "{}" } };
            const r = strand.json.parseLeaky(Request, arena, m.value, types.read_options) catch return error.Protocol;
            const message = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"{s}\",\"params\":{s}}}", .{ r.method, r.params.bytes });
            const asked = wire.decode(arena, message, .{}) catch return error.Protocol;
            const answer = c.serveRequest(io, arena, asked.request);
            const bytes = switch (answer) {
                .message => |b| b,
                .none => return error.Protocol,
            };
            const reply = wire.decode(arena, bytes, .{}) catch return error.Protocol;
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
    }
    if (state) |s| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("\"requestState\":") catch return error.OutOfMemory;
        w.writeAll(s) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
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
    return c.call(io, arena, method, out.written(), null, null, diagnostics);
}

/// Arguments as the object a request carries: a `Raw` as it is, an empty
/// literal (`.{}`) as `{}`, anything else as strand writes it.
fn argumentsJson(arena: Allocator, arguments: anytype) error{OutOfMemory}![]const u8 {
    const T = @TypeOf(arguments);
    if (T == Raw) return arguments.bytes;
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".field_names.len == 0) return "{}";
    return encode(arena, arguments) catch error.OutOfMemory;
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
    const args = try argumentsJson(arena, arguments);
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
    const o = strand.json.parseLeaky(Outcome, arena, result, types.read_options) catch return error.Protocol;
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
    const r = strand.json.parseLeaky(Read, arena, result, types.read_options) catch return error.Protocol;
    return r.contents;
}

/// Gets the prompt `name` with `arguments` (names to strings, as a struct
/// strand writes, or a `Raw` object): its messages.
pub fn getPrompt(c: *Client, io: Io, arena: Allocator, name: []const u8, arguments: anytype, diagnostics: ?*Diagnostics) CallError![]const types.PromptMessage {
    const args = try argumentsJson(arena, arguments);
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"name\":") catch return error.OutOfMemory;
    wire.writeString(w, name) catch return error.OutOfMemory;
    w.writeAll(",\"arguments\":") catch return error.OutOfMemory;
    w.writeAll(args) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    const result = try c.call(io, arena, "prompts/get", out.written(), name, null, diagnostics);
    const Got = struct { messages: []const types.PromptMessage = &.{} };
    const g = strand.json.parseLeaky(Got, arena, result, types.read_options) catch return error.Protocol;
    return g.messages;
}
