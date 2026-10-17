//! The revisions before 2026-07-28, served above the stateless core: a
//! session opened by `initialize`, which holds what a 2026-07-28 request
//! carries in its `_meta` (the version, the client's capabilities and
//! identity, the log level), and the methods those revisions have that the
//! core does not (`initialize`, `ping`, `logging/setLevel`,
//! `resources/subscribe` and `unsubscribe`).
//!
//! Input a handler asks for is asked the way those revisions ask: as
//! requests from the server on the session's stream, whose answers the
//! session gathers and gives the handler on its next round. A handler is the
//! same in both eras.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const types = @import("types.zig");
const wire = @import("wire.zig");
const meta = @import("meta.zig");
const subscriptions = @import("subscriptions.zig");
const Server = @import("Server.zig");
const Revision = @import("revision.zig").Revision;
const Context = @import("context.zig").Context;
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Where a session stands.
pub const Lifecycle = aegis.state.Machine(enum { awaiting, initializing, ready, closed }, enum { initialize, initialized, close }, .{
    .initial = .awaiting,
    .terminal = &.{.closed},
    .edges = &.{
        .{ .from = .awaiting, .on = .initialize, .to = .initializing },
        .{ .from = .initializing, .on = .initialized, .to = .ready },
        .{ .from = .awaiting, .on = .close, .to = .closed },
        .{ .from = .initializing, .on = .close, .to = .closed },
        .{ .from = .ready, .on = .close, .to = .closed },
    },
});

pub const Options = struct {
    /// How long the session waits for the client to answer a request of
    /// the server's (an elicitation the user is filling in).
    input_timeout: Server.Duration = .literal("10m"),
    /// Rounds of input one request may ask for.
    max_rounds: u8 = 8,
};

/// One client's session: a stdio process, or an `Mcp-Session-Id`.
pub const Session = struct {
    gpa: Allocator,
    server: *Server,
    options: Options,
    /// Private: what the handshake gave, kept for the session's life.
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    lifecycle: Lifecycle.Runtime(void) = .init({}),
    revision: Revision = Revision.latest_legacy,
    client: types.ClientCapabilities = .{},
    client_info: ?types.Implementation = null,
    log_level: ?types.LoggingLevel = null,
    /// The session's change stream: every list, and the resources the
    /// client subscribed to.
    listener: subscriptions.Listener,
    /// Private: requests of the server's that wait for their answers.
    outgoing: std.ArrayList(*Outgoing) = .empty,
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn init(gpa: Allocator, server: *Server, options: Options) Session {
        var lists: std.EnumSet(subscriptions.Kind) = .empty;
        lists.insert(.tools);
        lists.insert(.prompts);
        lists.insert(.resources);
        return .{ .gpa = gpa, .server = server, .options = options, .arena = .init(gpa), .listener = .{ .id = null, .lists = lists } };
    }

    pub fn deinit(s: *Session) void {
        s.listener.deinit(s.gpa);
        s.outgoing.deinit(s.gpa);
        s.arena.deinit();
    }

    /// Whether `initialize` has been answered.
    pub fn open(s: *Session) bool {
        return switch (s.lifecycle.current()) {
            .initializing, .ready => true,
            .awaiting, .closed => false,
        };
    }

    /// Answers a request of the session's era. `sink` takes what belongs
    /// to the request: its notifications, and the server's requests for
    /// input, whose answers come back through `deliver`.
    pub fn handle(s: *Session, io: Io, arena: Allocator, request: wire.Request, sink: Sink) Server.HandleError!Server.Reply {
        const methods = [_][]const u8{ "initialize", "ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe" };
        const index = for (methods, 0..) |name, i| {
            if (std.mem.eql(u8, request.method, name)) break i;
        } else null;
        if (index) |i| return switch (i) {
            0 => s.initialize(io, arena, request),
            1 => .{ .result = "{}" },
            2 => s.setLevel(io, arena, request),
            3 => s.subscribe(io, arena, request, true),
            4 => s.subscribe(io, arena, request, false),
            else => unreachable,
        };
        if (!s.open()) return failure(.invalid_request, "the session is not initialized: send initialize first");
        if (std.mem.eql(u8, request.method, "server/discover") or std.mem.eql(u8, request.method, "subscriptions/listen"))
            return failure(.method_not_found, "Method not found");

        const m = meta.read(arena, request.params, s.server.jsonLimits()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => return failure(.invalid_params, "params or _meta are not what the schema says"),
        };
        const context: Context = blk: {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            break :blk .{
                .revision = s.revision,
                .client = s.client,
                .client_info = s.client_info,
                .log_level = s.log_level,
                .progress_token = m.progress_token,
                .meta = m.raw,
            };
        };
        var current = request;
        var rounds: u8 = 0;
        while (true) {
            const reply = try s.server.handle(io, arena, current, &context, sink);
            const ir = switch (reply) {
                .input_required => |ir| ir,
                else => return reply,
            };
            rounds += 1;
            if (rounds > s.options.max_rounds) return failure(.internal_error, "the handler asked for input more rounds than the server allows");
            const responses = s.ask(io, arena, ir.requests, sink) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.Refused => return failure(.internal_error, "the client did not give the input the request needs"),
            };
            current.params = try withInput(arena, s.server.jsonLimits(), current.params, responses, ir.state);
        }
    }

    /// An answer from the client to one of the server's requests.
    pub fn deliver(s: *Session, io: Io, message: wire.Message) void {
        const id: ?wire.Id, const outcome: Outcome = switch (message) {
            .result => |r| .{ r.id, .{ .result = r.result } },
            .failure => |f| .{ f.id, .{ .failure = f.message } },
            else => return,
        };
        const n = switch (id orelse return) {
            .integer => |n| n,
            .string => return,
        };
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        for (s.outgoing.items) |o| if (o.id == n and !o.done) {
            o.outcome = switch (outcome) {
                // Copied on the session's allocator: the asking task owns its
                // arena, and is waiting.
                .result => |bytes| .{ .result = s.gpa.dupe(u8, bytes) catch return },
                .failure => .{ .failure = "" },
            };
            o.done = true;
            o.event.set(io);
            return;
        };
    }

    /// Writes the session's list changes and resource updates to `sink`
    /// until canceled or the server closes.
    pub fn stream(s: *Session, io: Io, sink: Sink) Server.HandleError!void {
        s.server.hub.add(io, s.gpa, &s.listener, s.server.options.limits.listeners) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.TooMany => return error.Canceled,
        };
        defer s.server.hub.remove(io, &s.listener);
        var seen: u32 = 0;
        while (true) {
            seen = (s.listener.wait(io, &s.server.hub, seen, .none) catch return error.Canceled) orelse continue;
            if (s.server.hub.closed.load(.acquire)) return;
            var turn: std.heap.ArenaAllocator = .init(s.gpa);
            defer turn.deinit();
            const a = turn.allocator();
            const changed = s.listener.takeLists();
            if (changed.contains(.tools)) try s.server.notify(io, a, sink, "notifications/tools/list_changed", .{}, "");
            if (changed.contains(.prompts)) try s.server.notify(io, a, sink, "notifications/prompts/list_changed", .{}, "");
            if (changed.contains(.resources)) try s.server.notify(io, a, sink, "notifications/resources/list_changed", .{}, "");
            if (changed.contains(.resource)) {
                const uris = s.listener.takeChanged(io, a, .resource) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                };
                for (uris) |uri| try s.server.notify(io, a, sink, "notifications/resources/updated", .{ .uri = uri }, "");
            }
        }
    }

    /// `notifications/initialized`.
    pub fn initialized(s: *Session, io: Io) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        // glint-ignore: Z026 -- an initialized notice outside the handshake changes nothing; the session goes on as it is
        _ = s.lifecycle.step(.initialized) catch {};
    }

    fn initialize(s: *Session, io: Io, arena: Allocator, request: wire.Request) Server.HandleError!Server.Reply {
        const Params = struct {
            protocolVersion: []const u8,
            capabilities: types.ClientCapabilities = .{},
            clientInfo: ?types.Implementation = null,
        };
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.lifecycle.current() != .awaiting) return failure(.invalid_request, "the session is initialized already");
        const owned = s.arena.allocator();
        const params = try owned.dupe(u8, request.params orelse return failure(.invalid_params, "initialize has no params"));
        const p = strand.json.parseLeaky(Params, owned, params, types.readOptions(s.server.jsonLimits())) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(.invalid_params, "initialize's params are not what the schema says"),
        };
        // The client's version when this server speaks it; else the newest
        // of the session era, which the client may refuse.
        s.revision = if (Revision.named(p.protocolVersion)) |r| (if (r.stateless()) Revision.latest_legacy else r) else Revision.latest_legacy;
        s.client = p.capabilities;
        s.client_info = p.clientInfo;
        _ = s.lifecycle.step(.initialize) catch unreachable; // unreachable: awaiting was checked above
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":", .{s.revision.text()}) catch return error.OutOfMemory;
        w.writeAll(try s.server.capabilitiesJson(io, arena)) catch return error.OutOfMemory;
        w.writeAll(",\"serverInfo\":") catch return error.OutOfMemory;
        strand.json.write(w, s.server.options.info, types.writeOptions(s.server.jsonLimits())) catch return error.OutOfMemory;
        if (s.server.options.instructions) |text| {
            w.writeAll(",\"instructions\":") catch return error.OutOfMemory;
            wire.writeString(w, text) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        return .{ .result = out.written() };
    }

    fn setLevel(s: *Session, io: Io, arena: Allocator, request: wire.Request) Server.HandleError!Server.Reply {
        const p = strand.json.parseLeaky(struct { level: types.LoggingLevel }, arena, request.params orelse "{}", types.readOptions(s.server.jsonLimits())) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(.invalid_params, "level is not a logging level"),
        };
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.log_level = p.level;
        return .{ .result = "{}" };
    }

    fn subscribe(s: *Session, io: Io, arena: Allocator, request: wire.Request, on: bool) Server.HandleError!Server.Reply {
        const p = strand.json.parseLeaky(struct { uri: []const u8 }, arena, request.params orelse "{}", types.readOptions(s.server.jsonLimits())) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(.invalid_params, "uri is missing"),
        };
        if (on) {
            s.listener.watch(io, s.gpa, .resource, p.uri, s.server.options.limits.watched) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.TooMany => return failure(.invalid_params, "more resources than one session may watch"),
            };
        } else s.listener.unwatch(io, s.gpa, .resource, p.uri) catch return error.Canceled;
        return .{ .result = "{}" };
    }

    const AskError = error{ Canceled, OutOfMemory, Refused };

    /// Sends each input request to the client and waits for every answer:
    /// the `inputResponses` object, keyed as the handler asked.
    fn ask(s: *Session, io: Io, arena: Allocator, requests: []const @import("Call.zig").Pending, sink: Sink) AskError![]const u8 {
        var pending: std.ArrayList(*Outgoing) = .empty;
        defer for (pending.items) |o| s.retire(io, o);
        for (requests) |r| {
            const o = try arena.create(Outgoing);
            o.* = .{ .id = s.next_id.fetchAdd(1, .monotonic) };
            {
                s.mutex.lockUncancelable(io);
                defer s.mutex.unlock(io);
                try s.outgoing.append(s.gpa, o);
            }
            try pending.append(arena, o);
            var out: Writer.Allocating = .init(arena);
            const w = &out.writer;
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ o.id, r.request.method() }) catch return error.OutOfMemory;
            writeParams(w, r.request, s.server.jsonLimits()) catch return error.OutOfMemory;
            w.writeByte('}') catch return error.OutOfMemory;
            sink.send(io, out.written()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled, error.Closed => error.Canceled,
            };
        }
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeByte('{') catch return error.OutOfMemory;
        for (requests, pending.items, 0..) |r, o, i| {
            o.event.waitTimeout(io, .{ .duration = .{ .raw = s.options.input_timeout.toIoDuration(), .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => return error.Refused,
            };
            const answer = switch (o.outcome) {
                .result => |bytes| bytes,
                .failure => return error.Refused,
            };
            if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
            wire.writeString(w, r.key) catch return error.OutOfMemory;
            w.writeByte(':') catch return error.OutOfMemory;
            w.writeAll(answer) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        return out.written();
    }

    fn retire(s: *Session, io: Io, o: *Outgoing) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        switch (o.outcome) {
            .result => |bytes| s.gpa.free(bytes),
            .failure => {},
        }
        for (s.outgoing.items, 0..) |x, i| if (x == o) {
            _ = s.outgoing.swapRemove(i);
            return;
        };
    }
};

const Outcome = union(enum) { result: []const u8, failure: []const u8 };

/// A request of the server's, waiting for the client's answer.
const Outgoing = struct {
    id: u64,
    event: Io.Event = .unset,
    done: bool = false,
    outcome: Outcome = .{ .failure = "" },
};

/// A request's params as the session sends them: what was asked, without
/// the method that 2026-07-28 wraps around it.
fn writeParams(w: *Writer, request: types.InputRequest, limits: strand.core.Limits) !void {
    switch (request) {
        .elicit => |e| switch (e) {
            // The form mode is the only one before 2025-11-25, which also
            // reads one without a mode.
            .form => |f| try strand.json.write(w, f, types.writeOptions(limits)),
            .url => |u| {
                try w.writeAll("{\"mode\":\"url\",\"message\":");
                try wire.writeString(w, u.message);
                try w.writeAll(",\"url\":");
                try wire.writeString(w, u.url);
                try w.writeByte('}');
            },
        },
        .sample => |p| try strand.json.write(w, p, types.writeOptions(limits)),
        .roots => try w.writeAll("{}"),
    }
}

/// `params` with `inputResponses` and `requestState` (when there is one)
/// set, as a 2026-07-28 client's retry carries them.
fn withInput(arena: Allocator, limits: strand.core.Limits, params: ?[]const u8, responses: []const u8, state: ?[]const u8) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    var first = true;
    if (params) |object| {
        var members: strand.json.Members = undefined;
        members.init(object, .{ .limits = limits });
        while (members.next() catch null) |m| {
            if (m.is("inputResponses") or m.is("requestState")) continue;
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            w.writeAll(object[m.start..m.valueEnd()]) catch return error.OutOfMemory;
        }
    }
    if (!first) w.writeByte(',') catch return error.OutOfMemory;
    w.writeAll("\"inputResponses\":") catch return error.OutOfMemory;
    w.writeAll(responses) catch return error.OutOfMemory;
    if (state) |sealed| {
        w.writeAll(",\"requestState\":") catch return error.OutOfMemory;
        wire.writeString(w, sealed) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

fn failure(code: wire.Code, message: []const u8) Server.Reply {
    return .{ .failure = .{ .code = code, .message = message } };
}
