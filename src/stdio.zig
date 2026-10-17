//! The stdio transport: one JSON-RPC message a line, over a process's
//! standard streams or any other byte stream (a Unix socket, a TCP
//! connection), as the stdio binding has it.
//!
//! The reader decodes each line and starts each request as a task of its
//! own, so a long tool never holds up a cancellation, or another request,
//! behind it. A request is canceled by `notifications/cancelled` naming it:
//! its task sees `error.Canceled` at its next `Io` call, and nothing more is
//! written for it. Messages go out whole, one at a time, each flushed.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const wire = @import("wire.zig");
const types = @import("types.zig");
const Server = @import("Server.zig");
const compat = @import("compat.zig");
const Client = @import("Client.zig");
const meta = @import("meta.zig");
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// The session an `initialize` opens (2025-11-25 and before).
    session: compat.Options = .{},
    /// Requests answered at once; one past it is refused as busy.
    max_in_flight: u32 = 64,
};

/// `ReadFailed`, `WriteFailed`: the stream broke. `Canceled`: the task
/// serving it was canceled.
pub const ServeError = error{ ReadFailed, WriteFailed, Canceled, OutOfMemory };

/// Serves `server` over `in` and `out` until `in` ends (the client closed
/// it: the server's cue to exit) or the task is canceled. Requests still
/// running then are canceled.
pub fn serve(io: Io, gpa: Allocator, server: *Server, in: *Io.Reader, out: *Io.Writer, options: Options) ServeError!void {
    var conn: Connection = .{ .io = io, .gpa = gpa, .server = server, .out = out, .options = options };
    defer conn.jobs.deinit(gpa);
    defer if (conn.session) |session| {
        session.deinit();
        gpa.destroy(session);
    };
    defer conn.group.cancel(io);
    defer conn.endSession();
    while (true) {
        const job = try Job.create(&conn);
        const read = conn.readLine(in, job) catch |err| {
            job.destroy();
            return err;
        };
        switch (read) {
            .end => {
                job.destroy();
                // The requests read are answered; the streams that would
                // never end are ended.
                conn.endStreams();
                conn.endSession();
                conn.group.await(io) catch |err| return err;
                return;
            },
            .empty => job.destroy(),
            .too_long => {
                job.destroy();
                try conn.writeFailure(null, .invalid_request, "the message is longer than the server reads");
            },
            .line => try conn.dispatch(job),
        }
    }
}

const Connection = struct {
    io: Io,
    gpa: Allocator,
    server: *Server,
    out: *Io.Writer,
    options: Options,
    /// Private: one message at a time on `out`.
    write_mutex: Io.Mutex = .init,
    /// Private: the requests being answered.
    jobs_mutex: Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    group: Io.Group = .init,
    /// The process's session, once a client opens one with `initialize`.
    session: ?*compat.Session = null,
    /// The task writing the session's list changes.
    session_stream: ?Io.Future(Io.Cancelable!void) = null,

    const Read = enum { line, empty, too_long, end };

    /// The next line into `job`'s buffer, without its line break.
    fn readLine(c: *Connection, in: *Io.Reader, job: *Job) ServeError!Read {
        var line: Io.Writer.Allocating = .init(job.arena.allocator());
        // A longer line is refused and passed over; the line break is
        // looked for one byte past it.
        const limit = @as(usize, c.server.options.limits.message.raw()) + 1;
        const n = in.streamDelimiterLimit(&line.writer, '\n', .limited(limit)) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => {},
                };
                return .too_long;
            },
        };
        const at_end = blk: {
            const next = in.peekByte() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => break :blk true,
            };
            aegis.assert.post(next == '\n', "a line stops at its break");
            in.toss(1);
            break :blk false;
        };
        var bytes = line.written();
        if (bytes.len != 0 and bytes[bytes.len - 1] == '\r') bytes = bytes[0 .. bytes.len - 1];
        if (n == 0 and at_end) return .end;
        if (std.mem.trim(u8, bytes, " \t").len == 0) return .empty;
        job.line = bytes;
        return .line;
    }

    fn dispatch(c: *Connection, job: *Job) ServeError!void {
        var fault: wire.Fault = .{};
        const message = wire.decode(job.arena.allocator(), job.line, .{ .fault = &fault, .limits = c.server.jsonLimits() }) catch |err| {
            job.destroy();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Malformed, error.Invalid => c.writeFailure(fault.id, fault.code, fault.reason),
            };
        };
        switch (message) {
            .request => |request| {
                job.request = request;
                if (std.mem.eql(u8, request.method, "initialize") and c.session == null and sessionEra(job)) {
                    const session = try c.gpa.create(compat.Session);
                    session.* = .init(c.gpa, c.server, c.options.session);
                    c.session = session;
                }
                // Which era answers it is decided here, in reading order.
                job.session = if (c.session) |session| (if (sessionEra(job)) session else null) else null;
                if (!try c.admit(job)) {
                    job.destroy();
                    return c.writeFailure(request.id, .internal_error, "the server is answering as many requests as it takes at once");
                }
                // What sets the session's state (the handshake, the log
                // level, subscriptions) is answered before the next line is
                // read, so the requests after it find it set.
                if (job.session != null and setsSession(request.method)) return Job.run(job);
                c.group.concurrent(c.io, Job.run, .{job}) catch {
                    // No task to spare: answered here, before the next line
                    // is read (and it cannot be canceled).
                    Job.run(job);
                };
            },
            .notification => |n| {
                defer job.destroy();
                if (std.mem.eql(u8, n.method, "notifications/cancelled")) try c.cancel(job.arena.allocator(), n.params);
                if (std.mem.eql(u8, n.method, "notifications/initialized")) if (c.session) |session| {
                    if (session.lifecycle.current() == .initializing) {
                        session.initialized(c.io);
                        // The session's list changes go out on stdout from here.
                        c.session_stream = c.io.concurrent(streamSession, .{ c, session }) catch null;
                    }
                };
            },
            // Answers to requests the session sent (2025-11-25 and before).
            .result, .failure => {
                defer job.destroy();
                if (c.session) |session| session.deliver(c.io, message);
            },
        }
    }

    fn endSession(c: *Connection) void {
        if (c.session_stream) |*task| {
            // glint-ignore: Z026 -- the session stream ends with the connection; its result says nothing more
            _ = task.cancel(c.io) catch {};
            c.session_stream = null;
        }
    }

    fn setsSession(method: []const u8) bool {
        const methods = [_][]const u8{ "initialize", "logging/setLevel", "resources/subscribe", "resources/unsubscribe" };
        for (methods) |m| if (std.mem.eql(u8, method, m)) return true;
        return false;
    }

    /// Whether a request belongs to the session: its handshake, or one
    /// without the version a 2026-07-28 request carries in its `_meta`.
    fn sessionEra(job: *Job) bool {
        const m = meta.read(job.arena.allocator(), job.request.params, job.conn.server.jsonLimits()) catch return true;
        return m.version == null;
    }

    fn streamSession(c: *Connection, session: *compat.Session) Io.Cancelable!void {
        session.stream(c.io, c.sink()) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => {},
        };
    }

    /// Lines that belong to no request.
    fn sink(c: *Connection) Sink {
        return .{ .context = c, .sendFn = sendLine };
    }

    fn sendLine(context: *anyopaque, io: Io, message: []const u8) Sink.SendError!void {
        _ = io;
        const c: *Connection = @ptrCast(@alignCast(context)); // safe: the sink was made from this connection
        c.send(message) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.WriteFailed => error.Closed,
        };
    }

    /// Adds `job` to the requests in flight, unless they are at the bound.
    fn admit(c: *Connection, job: *Job) Io.Cancelable!bool {
        try c.jobs_mutex.lock(c.io);
        defer c.jobs_mutex.unlock(c.io);
        if (c.jobs.items.len >= c.options.max_in_flight) return false;
        c.jobs.append(c.gpa, job) catch return false;
        return true;
    }

    /// Cancels every `subscriptions/listen` in flight.
    fn endStreams(c: *Connection) void {
        c.jobs_mutex.lockUncancelable(c.io);
        defer c.jobs_mutex.unlock(c.io);
        for (c.jobs.items) |j| if (std.mem.eql(u8, j.request.method, "subscriptions/listen")) {
            j.canceled.store(true, .release);
            j.cancel.set(c.io);
        };
    }

    fn retire(c: *Connection, job: *Job) void {
        c.jobs_mutex.lockUncancelable(c.io);
        defer c.jobs_mutex.unlock(c.io);
        for (c.jobs.items, 0..) |j, i| if (j == job) {
            _ = c.jobs.swapRemove(i);
            return;
        };
    }

    /// `notifications/cancelled`: the request it names, if still running,
    /// is canceled. One it does not name, or one already answered, is
    /// passed over (cancellation §error handling).
    fn cancel(c: *Connection, arena: Allocator, params: ?[]const u8) ServeError!void {
        const limits = c.server.jsonLimits();
        const p = strand.json.parseLeaky(types.CancelledParams, arena, params orelse return, types.readOptions(limits)) catch return;
        const id = wire.idFrom(arena, p.request_id.bytes, limits) catch return;
        try c.jobs_mutex.lock(c.io);
        defer c.jobs_mutex.unlock(c.io);
        for (c.jobs.items) |j| if (j.request.id.eql(id)) {
            j.canceled.store(true, .release);
            j.cancel.set(c.io);
        };
    }

    /// Writes `message` and a line break, then flushes.
    fn send(c: *Connection, message: []const u8) error{ WriteFailed, Canceled }!void {
        try c.write_mutex.lock(c.io);
        defer c.write_mutex.unlock(c.io);
        try c.out.writeAll(message);
        try c.out.writeByte('\n');
        try c.out.flush();
    }

    fn writeFailure(c: *Connection, id: ?wire.Id, code: wire.Code, message: []const u8) ServeError!void {
        var buffer: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        wire.writeFailure(&w, id, code, message, null) catch {
            // An id too long for the buffer: answered without it.
            w = .fixed(&buffer);
            wire.writeFailure(&w, null, code, message, null) catch unreachable; // unreachable: a fixed message fits
        };
        c.send(w.buffered()) catch |err| return err;
    }
};

/// One request: its bytes, its arena, and its cancellation.
const Job = struct {
    conn: *Connection,
    arena: std.heap.ArenaAllocator,
    line: []const u8 = "",
    request: wire.Request = undefined,
    /// Set by `notifications/cancelled`; the request's task waits on it.
    cancel: Io.Event = .unset,
    /// Once set, nothing more is written for the request.
    canceled: std.atomic.Value(bool) = .init(false),
    /// The session that answers the request, or null for the core.
    session: ?*compat.Session = null,

    fn create(conn: *Connection) Allocator.Error!*Job {
        const job = try conn.gpa.create(Job);
        job.* = .{ .conn = conn, .arena = .init(conn.gpa) };
        return job;
    }

    fn destroy(job: *Job) void {
        const gpa = job.conn.gpa;
        job.arena.deinit();
        gpa.destroy(job);
    }

    const Outcome = union(enum) {
        done: Server.HandleError!Server.Reply,
        canceled: Io.Cancelable!void,
    };

    /// Answers the request, or stops at its cancellation.
    fn run(job: *Job) void {
        const c = job.conn;
        const io = c.io;
        defer {
            c.retire(job);
            job.destroy();
        }
        var buffer: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(io, &buffer);
        // Every task of the select has ended before the job's memory goes:
        // a task still finishing would write into what is freed. What they
        // return lives in the job's arena.
        defer select.cancelDiscard();
        select.concurrent(.done, answer, .{job}) catch {
            // No task to spare for watching: answered, never canceled.
            job.finish(answer(job));
            return;
        };
        select.concurrent(.canceled, waitCancel, .{ &job.cancel, io }) catch {
            const result = select.await() catch return;
            job.finish(result.done);
            return;
        };
        switch (select.await() catch return) {
            .done => |result| job.finish(result),
            // Canceled: the request's task ends; nothing is answered.
            .canceled => {},
        }
    }

    fn answer(job: *Job) Server.HandleError!Server.Reply {
        const c = job.conn;
        if (job.session) |session| return session.handle(c.io, job.arena.allocator(), job.request, job.sink());
        return c.server.serve(c.io, job.arena.allocator(), job.request, null, job.sink());
    }

    fn waitCancel(event: *Io.Event, io: Io) Io.Cancelable!void {
        try event.wait(io);
    }

    fn finish(job: *Job, result: Server.HandleError!Server.Reply) void {
        if (job.canceled.load(.acquire)) return;
        const c = job.conn;
        const reply = result catch |err| switch (err) {
            error.Canceled => return,
            error.OutOfMemory => {
                // glint-ignore: Z026 -- the answer could not be made and the refusal could not be written: the stream is gone
                c.writeFailure(job.request.id, .internal_error, "out of memory") catch {};
                return;
            },
        };
        var out: Io.Writer.Allocating = .init(job.arena.allocator());
        const written = switch (reply) {
            .result => |r| wire.writeResult(&out.writer, job.request.id, r),
            .input_required => |ir| blk: {
                const json = c.server.inputRequiredJson(job.arena.allocator(), ir) catch break :blk error.WriteFailed;
                break :blk wire.writeResult(&out.writer, job.request.id, json);
            },
            .failure => |f| wire.writeFailure(&out.writer, job.request.id, f.code, f.message, f.data),
        };
        written catch {
            // glint-ignore: Z026 -- the answer could not be made and the refusal could not be written: the stream is gone
            c.writeFailure(job.request.id, .internal_error, "out of memory") catch {};
            return;
        };
        // glint-ignore: Z026 -- a stream that cannot be written is gone; the reader sees its end
        c.send(out.written()) catch {};
    }

    fn sink(job: *Job) Sink {
        return .{ .context = job, .sendFn = sendFn };
    }

    fn sendFn(context: *anyopaque, io: Io, message: []const u8) Sink.SendError!void {
        _ = io;
        const job: *Job = @ptrCast(@alignCast(context)); // safe: the sink was made from this job
        if (job.canceled.load(.acquire)) return error.Canceled;
        job.conn.send(message) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.WriteFailed => error.Closed,
        };
    }
};

/// The client's side of stdio: requests written a line each, answers read
/// by a task of the channel's own and handed to the request that waits for
/// each, the server's own requests (a session's) answered by the client.
pub const Channel = struct {
    gpa: Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    /// Private: one message at a time on `out`.
    write_mutex: Io.Mutex = .init,
    /// Private: the requests waiting for their answers.
    mutex: Io.Mutex = .init,
    waiting: std.ArrayList(*Waiter) = .empty,
    reading: ?Io.Future(void) = null,
    client: ?*Client = null,
    /// Set once the server's output ended: every wait fails at once.
    closed: std.atomic.Value(bool) = .init(false),
    /// Private, under `write_mutex`: set by `end`, nothing more is written.
    ended: bool = false,

    const Waiter = struct {
        id: wire.Id,
        event: Io.Event = .unset,
        /// The answer, on the channel's allocator; null until it comes.
        answer: ?[]u8 = null,
    };

    pub fn init(gpa: Allocator, in: *Io.Reader, out: *Io.Writer) Channel {
        return .{ .gpa = gpa, .in = in, .out = out };
    }

    /// Starts reading the server's output, for `client`'s requests, each
    /// message within the client's message limit.
    pub fn start(ch: *Channel, io: Io, client: *Client) Io.ConcurrentError!void {
        ch.client = client;
        ch.reading = try io.concurrent(readLoop, .{ ch, io });
    }

    /// Stops reading; the requests still waiting fail.
    pub fn deinit(ch: *Channel, io: Io) void {
        if (ch.reading) |*task| task.cancel(io);
        ch.waiting.deinit(ch.gpa);
    }

    /// Writes nothing more: what is sent from now on fails `Closed`, so the
    /// caller may close what `out` writes to (the server's input, which is
    /// how a stdio server is told to end) while the answers already asked
    /// for are still read.
    pub fn end(ch: *Channel, io: Io) void {
        ch.write_mutex.lockUncancelable(io);
        defer ch.write_mutex.unlock(io);
        ch.ended = true;
    }

    pub fn transport(ch: *Channel) Client.Transport {
        return .{ .context = ch, .vtable = &.{ .request = request, .notify = notify, .opened = opened } };
    }

    fn request(context: *anyopaque, io: Io, arena: Allocator, exchange: *Client.Exchange) Client.RequestError![]const u8 {
        const ch: *Channel = @ptrCast(@alignCast(context)); // safe: the transport was made from this channel
        if (ch.closed.load(.acquire)) return error.Closed;
        var waiter: Waiter = .{ .id = exchange.id };
        {
            try ch.mutex.lock(io);
            defer ch.mutex.unlock(io);
            try ch.waiting.append(ch.gpa, &waiter);
        }
        defer {
            ch.retire(io, &waiter);
            if (waiter.answer) |a| ch.gpa.free(a);
        }
        try ch.write(io, exchange.message);
        waiter.event.waitTimeout(io, .{ .duration = .{ .raw = exchange.timeout, .clock = .awake } }) catch |err| {
            // Canceled or out of time: the server is told, and stops.
            var buffer: [128]u8 = undefined;
            var w: Io.Writer = .fixed(&buffer);
            w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":") catch unreachable; // unreachable: the buffer holds it
            if (exchange.id.write(&w)) |_| {
                w.writeAll("}}") catch unreachable; // unreachable: an integer id fits the buffer
                // glint-ignore: Z026 -- the request ends either way; a notice the server cannot take changes nothing
                ch.write(io, w.buffered()) catch {};
            } else |_| {}
            return switch (err) {
                error.Canceled => error.Canceled,
                error.Timeout => error.TimedOut,
            };
        };
        const answer = waiter.answer orelse return error.Closed;
        defer ch.gpa.free(answer);
        waiter.answer = null;
        return arena.dupe(u8, answer);
    }

    fn write(ch: *Channel, io: Io, message: []const u8) Client.RequestError!void {
        ch.write_mutex.lockUncancelable(io);
        defer ch.write_mutex.unlock(io);
        if (ch.ended) return error.Closed;
        ch.out.writeAll(message) catch return error.Closed;
        ch.out.writeByte('\n') catch return error.Closed;
        ch.out.flush() catch return error.Closed;
    }

    fn notify(context: *anyopaque, io: Io, message: []const u8) Client.RequestError!void {
        const ch: *Channel = @ptrCast(@alignCast(context)); // safe: the transport was made from this channel
        return ch.write(io, message);
    }

    fn opened(_: *anyopaque, _: Io, _: *Client) void {}

    fn retire(ch: *Channel, io: Io, waiter: *Waiter) void {
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        for (ch.waiting.items, 0..) |w, i| if (w == waiter) {
            _ = ch.waiting.swapRemove(i);
            break;
        };
    }

    fn readLoop(ch: *Channel, io: Io) void {
        defer {
            ch.closed.store(true, .release);
            ch.mutex.lockUncancelable(io);
            defer ch.mutex.unlock(io);
            for (ch.waiting.items) |w| w.event.set(io);
        }
        var line_buffer: Io.Writer.Allocating = .init(ch.gpa);
        defer line_buffer.deinit();
        while (true) {
            line_buffer.clearRetainingCapacity();
            _ = ch.in.streamDelimiterLimit(&line_buffer.writer, '\n', .limited(@as(usize, ch.client.?.options.limits.message.raw()) + 1)) catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = ch.in.discardDelimiterInclusive('\n') catch return;
                    continue;
                },
                else => return,
            };
            const at_end = if (ch.in.peekByte()) |_| blk: {
                ch.in.toss(1);
                break :blk false;
            } else |_| true;
            const bytes = std.mem.trimEnd(u8, line_buffer.written(), "\r");
            if (bytes.len != 0) ch.handle(io, bytes);
            if (at_end) return;
        }
    }

    /// One message from the server.
    fn handle(ch: *Channel, io: Io, bytes: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(ch.gpa);
        defer arena.deinit();
        const message = wire.decode(arena.allocator(), bytes, .{ .limits = ch.client.?.jsonLimits() }) catch return;
        switch (message) {
            .result, .failure => {
                const id = switch (message) {
                    .result => |r| r.id,
                    .failure => |f| f.id orelse return,
                    else => unreachable,
                };
                ch.mutex.lockUncancelable(io);
                defer ch.mutex.unlock(io);
                for (ch.waiting.items) |w| if (w.id.eql(id) and w.answer == null) {
                    w.answer = ch.gpa.dupe(u8, bytes) catch return;
                    w.event.set(io);
                    return;
                };
            },
            // A session server's own request: answered by the client.
            .request => {
                const client = ch.client orelse return;
                var exchange: Client.Exchange = .{ .id = .{ .integer = 0 }, .method = "", .message = "", .revision = client.revision, .timeout = .zero, .client = client };
                switch (exchange.inbound(io, arena.allocator(), message)) {
                    .message => |answer| ch.write(io, answer) catch return,
                    .none => {},
                }
            },
            .notification => {},
        }
    }
};
