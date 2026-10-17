//! The Streamable HTTP transport's client side: each request a POST to the
//! server's MCP endpoint, its answer JSON or an event stream read to the
//! answer, on an uplink client.
//!
//! Every POST carries `MCP-Protocol-Version`, and under 2026-07-28
//! `Mcp-Method`, `Mcp-Name` and the `Mcp-Param-*` headers a tool's
//! `x-mcp-header` marks name, values outside plain ASCII in the Base64
//! sentinel. A session (2025-11-25 and before) is named in `Mcp-Session-Id`
//! once `initialize` gives one; a stream the server closes before its answer
//! is reopened with `Last-Event-ID` after the `retry` it set.
const Transport = @This();

const std = @import("std");
const parley = @import("parley");
const uplink = @import("uplink");
const strand = @import("strand");
const headers = @import("headers.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = parley.Client;
const wire = parley.wire;

gpa: Allocator,
http: *uplink.Client,
url: []const u8,
/// Private: the session's id, once `initialize` gave one.
session: ?[]u8 = null,
/// Private: the session's GET stream, and the client it answers for.
stream: ?Io.Future(Io.Cancelable!void) = null,
client: ?*Client = null,
/// Private: the tools' `x-mcp-header` marks, from the last `tools/list`.
marks_mutex: Io.Mutex = .init,
marks: std.ArrayList(Marked) = .empty,

const Marked = struct {
    tool: []u8,
    params: []const parley.registry.HeaderParam,
};

/// The endpoint at `url`, reached through `http`, which the caller keeps.
pub fn init(gpa: Allocator, http: *uplink.Client, url: []const u8) Transport {
    return .{ .gpa = gpa, .http = http, .url = url };
}

/// Ends the session's stream; `io` is the one the client connected with.
pub fn close(t: *Transport, io: Io) void {
    if (t.stream) |*task| {
        // glint-ignore: Z026 -- the stream ends with the client; how it ended says nothing more
        task.cancel(io) catch {};
        t.stream = null;
    }
}

pub fn deinit(t: *Transport) void {
    if (t.session) |s| t.gpa.free(s);
    for (t.marks.items) |m| t.free(m);
    t.marks.deinit(t.gpa);
}

fn free(t: *Transport, m: Marked) void {
    t.gpa.free(m.tool);
    parley.registry.freeHeaderParams(t.gpa, m.params);
}

pub fn transport(t: *Transport) Client.Transport {
    return .{ .context = t, .vtable = &.{ .request = request, .notify = notify, .opened = opened, .listed = listedFn } };
}

fn listedFn(context: *anyopaque, io: Io, client: *const Client, arena: Allocator, result: []const u8) Allocator.Error![]const u8 {
    const t: *Transport = @ptrCast(@alignCast(context)); // safe: the transport was made from this one
    return t.listed(io, client.jsonLimits(), arena, result);
}

/// Opens the session's GET stream, where a session server sends what
/// belongs to no request; a server that has none answers 405.
fn opened(context: *anyopaque, io: Io, client: *Client) void {
    const t: *Transport = @ptrCast(@alignCast(context)); // safe: the transport was made from this one
    t.client = client;
    t.stream = io.concurrent(sessionStream, .{ t, io }) catch null;
}

fn sessionStream(t: *Transport, io: Io) Io.Cancelable!void {
    var arena_state: std.heap.ArenaAllocator = .init(t.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const client = t.client orelse return;
    var fields: std.ArrayList(std.http.Header) = .empty;
    fields.appendSlice(arena, &.{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = headers.protocol_version, .value = client.revision.text() },
    }) catch return;
    if (t.session) |id| fields.append(arena, .{ .name = headers.session_id, .value = id }) catch return;
    var response = t.http.send(io, .{ .method = .GET, .url = t.url, .headers = fields.items }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return,
    };
    defer response.deinit(io);
    if (response.status != .ok) return;
    const data = arena.alloc(u8, client.options.limits.message.raw()) catch return;
    var reader: uplink.wire.sse.Reader = .init(response.reader(io), data);
    while (reader.next() catch return) |event| {
        var turn: std.heap.ArenaAllocator = .init(t.gpa);
        defer turn.deinit();
        const message = wire.decode(turn.allocator(), event.data, .{ .limits = client.jsonLimits() }) catch continue;
        switch (message) {
            .request => |r| switch (client.serveRequest(io, turn.allocator(), r)) {
                // glint-ignore: Z026 -- an answer the server cannot take leaves its request unanswered, which it times out
                .message => |answer| t.postAnswer(io, turn.allocator(), client.revision, answer) catch {},
                .none => {},
            },
            else => {},
        }
    }
}

/// Learns the marks of the tools a `tools/list` answer lists, and leaves
/// out a tool whose marks break the rules (2026-07-28: MUST): the answer
/// as the application sees it. `limits`: the client's (`Client.jsonLimits`).
pub fn listed(t: *Transport, io: Io, limits: strand.core.Limits, arena: Allocator, result: []const u8) Allocator.Error![]const u8 {
    const Listed = struct { tools: []const strand.json.Raw = &.{} };
    const l = strand.json.parseLeaky(Listed, arena, result, parley.types.readOptions(limits)) catch return result;
    var kept: std.ArrayList([]const u8) = .empty;
    var dropped = false;
    t.marks_mutex.lockUncancelable(io);
    defer t.marks_mutex.unlock(io);
    for (l.tools) |tool| {
        const Tool = struct { name: []const u8, inputSchema: strand.json.Raw = .{ .bytes = "{}" } };
        const parsed = strand.json.parseLeaky(Tool, arena, tool.bytes, parley.types.readOptions(limits)) catch continue;
        const marks = parley.registry.headerParams(t.gpa, parsed.inputSchema.bytes, limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSchema => {
                std.log.warn("tool {s} left out: its x-mcp-header marks break the rules", .{parsed.name});
                dropped = true;
                continue;
            },
        };
        for (t.marks.items, 0..) |m, i| if (std.mem.eql(u8, m.tool, parsed.name)) {
            t.free(t.marks.swapRemove(i));
            break;
        };
        try t.marks.append(t.gpa, .{ .tool = try t.gpa.dupe(u8, parsed.name), .params = marks });
        try kept.append(arena, tool.bytes);
    }
    if (!dropped) return result;
    // The answer again, with only the tools kept.
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    var members: strand.json.Members = undefined;
    members.init(result, .{ .limits = limits });
    var first = true;
    while (members.next() catch null) |m| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        if (m.is("tools")) {
            w.writeAll("\"tools\":[") catch return error.OutOfMemory;
            for (kept.items, 0..) |bytes, i| {
                if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
                w.writeAll(bytes) catch return error.OutOfMemory;
            }
            w.writeByte(']') catch return error.OutOfMemory;
        } else w.writeAll(result[m.start..m.valueEnd()]) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

fn request(context: *anyopaque, io: Io, arena: Allocator, exchange: *Client.Exchange) Client.RequestError![]const u8 {
    const t: *Transport = @ptrCast(@alignCast(context)); // safe: the transport was made from this one
    var fields: std.ArrayList(std.http.Header) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
        .{ .name = headers.protocol_version, .value = exchange.revision.text() },
    });
    if (exchange.revision.stateless()) {
        try fields.append(arena, .{ .name = headers.method, .value = exchange.method });
        if (exchange.name) |name| try fields.append(arena, .{ .name = headers.name, .value = try headers.encode(arena, name) });
        if (std.mem.eql(u8, exchange.method, "tools/call")) try t.mirror(io, arena, exchange, &fields);
    } else if (t.session) |id| try fields.append(arena, .{ .name = headers.session_id, .value = id });

    var response = t.http.send(io, .{
        .method = .POST,
        .url = t.url,
        .headers = fields.items,
        .body = .{ .bytes = exchange.message },
        .timeout = .{ .duration = .{ .raw = exchange.timeout, .clock = .awake } },
    }) catch |err| return sendError(err);
    defer response.deinit(io);

    if (std.mem.eql(u8, exchange.method, "initialize")) if (response.headers.get(headers.session_id)) |id| {
        if (t.session) |old| t.gpa.free(old);
        t.session = try t.gpa.dupe(u8, id);
    };
    const content_type = response.headers.get("Content-Type") orelse "";
    if (std.mem.startsWith(u8, content_type, "text/event-stream")) return t.events(io, arena, exchange, &response);
    const body = response.collect(arena, io, .limited(exchange.client.options.limits.message.raw())) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Closed,
    };
    const code = @backingInt(response.status);
    // An answer at the transport's level that is not JSON-RPC: a session
    // server refusing what it does not know, a proxy.
    if (code >= 400 and (body.len == 0 or body[0] != '{')) {
        exchange.status = @intCast(code);
        return error.Refused;
    }
    if (code == 202) return error.Refused;
    return body;
}

/// The answer from an event stream, handing what comes before it to the
/// exchange; a stream closed before it is reopened with `Last-Event-ID`.
fn events(t: *Transport, io: Io, arena: Allocator, exchange: *Client.Exchange, first: *uplink.Response) Client.RequestError![]const u8 {
    var response = first;
    var reopened: ?uplink.Response = null;
    defer if (reopened) |*r| r.deinit(io);
    var last_id: []const u8 = "";
    var retry: ?u64 = null;
    var attempts: u8 = 0;
    while (true) {
        const data = try arena.alloc(u8, exchange.client.options.limits.message.raw());
        var reader: uplink.wire.sse.Reader = .init(response.reader(io), data);
        while (reader.next() catch return error.Closed) |event| {
            if (event.id.len != 0) last_id = try arena.dupe(u8, event.id);
            if (event.retry) |r| retry = r;
            if (event.data.len == 0) continue;
            const message = wire.decode(arena, event.data, .{ .limits = exchange.client.jsonLimits() }) catch continue;
            switch (message) {
                .result => |r| if (r.id.eql(exchange.id)) return arena.dupe(u8, event.data),
                .failure => |f| if (f.id) |id| if (id.eql(exchange.id)) return arena.dupe(u8, event.data),
                .request => switch (exchange.inbound(io, arena, message)) {
                    .message => |answer| try t.post(io, arena, exchange, answer),
                    .none => {},
                },
                .notification => {},
            }
        }
        // Closed before the answer: a session's stream is resumed after the
        // wait the server set (2025-11-25); a 2026-07-28 stream is not.
        if (exchange.revision.stateless() or last_id.len == 0 or attempts >= 8) return error.Closed;
        attempts += 1;
        io.sleep(.fromMilliseconds(@intCast(retry orelse 1000)), .awake) catch return error.Canceled;
        var fields: std.ArrayList(std.http.Header) = .empty;
        try fields.appendSlice(arena, &.{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = headers.protocol_version, .value = exchange.revision.text() },
            .{ .name = "Last-Event-ID", .value = last_id },
        });
        if (t.session) |id| try fields.append(arena, .{ .name = headers.session_id, .value = id });
        if (reopened) |*r| r.deinit(io);
        reopened = t.http.send(io, .{ .method = .GET, .url = t.url, .headers = fields.items, .timeout = .{ .duration = .{ .raw = exchange.timeout, .clock = .awake } } }) catch |err| return sendError(err);
        response = &reopened.?;
    }
}

/// Posts an answer to the server's request, on the session.
fn post(t: *Transport, io: Io, arena: Allocator, exchange: *const Client.Exchange, message: []const u8) Client.RequestError!void {
    return t.postAnswer(io, arena, exchange.revision, message);
}

fn postAnswer(t: *Transport, io: Io, arena: Allocator, revision: parley.Revision, message: []const u8) Client.RequestError!void {
    var fields: std.ArrayList(std.http.Header) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
        .{ .name = headers.protocol_version, .value = revision.text() },
    });
    if (t.session) |id| try fields.append(arena, .{ .name = headers.session_id, .value = id });
    var response = t.http.send(io, .{ .method = .POST, .url = t.url, .headers = fields.items, .body = .{ .bytes = message } }) catch |err| return sendError(err);
    response.deinit(io);
}

fn notify(context: *anyopaque, io: Io, message: []const u8) Client.RequestError!void {
    const t: *Transport = @ptrCast(@alignCast(context)); // safe: the transport was made from this one
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    defer arena.deinit();
    var fields: std.ArrayList(std.http.Header) = .empty;
    try fields.appendSlice(arena.allocator(), &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
    });
    if (t.session) |id| try fields.append(arena.allocator(), .{ .name = headers.session_id, .value = id });
    var response = t.http.send(io, .{ .method = .POST, .url = t.url, .headers = fields.items, .body = .{ .bytes = message } }) catch |err| return sendError(err);
    response.deinit(io);
}

/// The `Mcp-Param-*` headers of a tool call: each marked argument the call
/// gives, as its header carries it.
fn mirror(t: *Transport, io: Io, arena: Allocator, exchange: *const Client.Exchange, fields: *std.ArrayList(std.http.Header)) Allocator.Error!void {
    const tool = exchange.name orelse return;
    const arguments = exchange.arguments orelse return;
    t.marks_mutex.lockUncancelable(io);
    defer t.marks_mutex.unlock(io);
    const marked = for (t.marks.items) |m| {
        if (std.mem.eql(u8, m.tool, tool)) break m;
    } else return;
    const limits = exchange.client.jsonLimits();
    for (marked.params) |p| {
        var value: []const u8 = arguments;
        for (p.path) |step| value = member(value, step, limits) orelse break else {
            if (std.mem.eql(u8, value, "null")) continue;
            const text = switch (p.kind) {
                .string => strand.json.parseLeaky([]const u8, arena, value, .{ .limits = limits }) catch continue,
                .integer, .boolean => value,
            };
            try fields.append(arena, .{
                .name = try std.mem.concat(arena, u8, &.{ headers.param_prefix, p.name }),
                .value = try headers.encode(arena, text),
            });
        }
    }
}

fn member(object: []const u8, name: []const u8, limits: strand.core.Limits) ?[]const u8 {
    var members: strand.json.Members = undefined;
    members.init(object, .{ .limits = limits });
    while (members.next() catch return null) |m| if (m.is(name)) return m.value;
    return null;
}

fn sendError(err: uplink.Client.SendError) Client.RequestError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.TimedOut => error.TimedOut,
        else => error.Closed,
    };
}
