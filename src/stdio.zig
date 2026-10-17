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
const meta = @import("meta.zig");
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// The session an `initialize` opens (2025-11-25 and before).
    session: compat.Options = .{},
    /// The longest message read; a longer line is refused and passed over.
    max_message: aegis.units.Bytes(u32) = .literal("16MiB"),
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
        const limit = c.options.max_message.raw();
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
        const message = wire.decode(job.arena.allocator(), job.line, .{ .fault = &fault }) catch |err| {
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
                // The handshake is answered before the next line is read, so
                // the requests after it find the session open.
                if (job.session != null and std.mem.eql(u8, request.method, "initialize")) return Job.run(job);
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

    /// Whether a request belongs to the session: its handshake, or one
    /// without the version a 2026-07-28 request carries in its `_meta`.
    fn sessionEra(job: *Job) bool {
        const m = meta.read(job.arena.allocator(), job.request.params) catch return true;
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
        const p = strand.json.parseLeaky(types.CancelledParams, arena, params orelse return, types.read_options) catch return;
        const id = wire.idFrom(arena, p.request_id.bytes) catch return;
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
        select.concurrent(.done, answer, .{job}) catch {
            // No task to spare for watching: answered, never canceled.
            job.finish(answer(job));
            return;
        };
        select.concurrent(.canceled, waitCancel, .{ &job.cancel, io }) catch {
            const result = select.await() catch {
                _ = select.cancel();
                return;
            };
            job.finish(result.done);
            return;
        };
        const first = select.await() catch {
            _ = select.cancel();
            return;
        };
        switch (first) {
            .done => |result| {
                _ = select.cancel();
                job.finish(result);
            },
            // Canceled: the request's task ends; nothing is answered.
            .canceled => _ = select.cancel(),
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
