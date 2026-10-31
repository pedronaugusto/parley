//! The stdio transport: one JSON-RPC message a line, over a process's
//! standard streams or any other byte stream (a Unix socket, a TCP
//! connection), as the stdio binding has it.
//!
//! The reader decodes each line and starts each request as a task of its
//! own, so a long tool never holds up a cancellation, or another request,
//! behind it. A request is canceled by `notifications/cancelled` naming it:
//! its task sees `error.Canceled` at its next `Io` call, and nothing more is
//! written for it. Messages go out whole, one at a time, each flushed.
//!
//! A `Connection` is that reader's other half, for a transport whose
//! messages come and go in other frames: HTTP+SSE (2024-11-05) hands it each
//! POST's body and writes its messages as events
//! (`parley.http.SseEndpoint`).
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const wire = @import("wire.zig");
const types = @import("types.zig");
const Server = @import("Server.zig");
const compat = @import("compat.zig");
const subscriptions = @import("subscriptions.zig");
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
/// serving it was canceled. `ConcurrencyUnavailable`: a session opened and
/// the `Io` gave no task to send its list changes on, which the client
/// would otherwise never be told of.
pub const ServeError = error{ ReadFailed, WriteFailed, Canceled, OutOfMemory, ConcurrencyUnavailable };

/// Serves `server` over `in` and `out` until `in` ends (the client closed
/// it: the server's cue to exit) or the task is canceled. Requests still
/// running then are canceled.
pub fn serve(io: Io, gpa: Allocator, server: *Server, in: *Io.Reader, out: *Io.Writer, options: Options) ServeError!void {
    var lines: Out.Lines = .{ .writer = out };
    var conn: Connection = .init(io, gpa, server, &lines.out, options);
    defer conn.deinit();
    while (true) {
        const job = try Job.create(&conn);
        const read = conn.readLine(in, job) catch |err| {
            job.destroy();
            return err;
        };
        switch (read) {
            .end => {
                job.destroy();
                return conn.finish();
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

/// Where a connection's messages go, one whole message at a time: a line
/// each on stdio (`Lines`), an event each on HTTP+SSE. A writer embeds one
/// and finds itself from it by `@fieldParentPtr`.
pub const Out = struct {
    /// A writer for the next message.
    beginFn: *const fn (o: *Out) Error!*Io.Writer,
    /// The message written to `beginFn`'s writer is whole: framed, and
    /// flushed.
    endFn: *const fn (o: *Out) Error!void,
    /// Keeps a quiet stream open (a comment, on HTTP+SSE); null where
    /// nothing needs it.
    keepAliveFn: ?*const fn (o: *Out) Error!void = null,

    pub const Error = error{WriteFailed};

    /// Each message a line on `writer`, flushed.
    pub const Lines = struct {
        writer: *Io.Writer,
        out: Out = .{ .beginFn = lineBegin, .endFn = lineEnd },

        fn lineBegin(o: *Out) Error!*Io.Writer {
            const l: *Lines = @fieldParentPtr("out", o);
            return l.writer;
        }

        fn lineEnd(o: *Out) Error!void {
            const l: *Lines = @fieldParentPtr("out", o);
            try l.writer.writeByte('\n');
            try l.writer.flush();
        }
    };
};

/// One client's messages, as they come, answered to `Out`: what `serve`
/// reads line by line, and what HTTP+SSE takes POST by POST. It must not
/// move once it takes a message.
pub const Connection = struct {
    io: Io,
    gpa: Allocator,
    server: *Server,
    /// Private: where messages go, one at a time.
    out: aegis.BlockingGuarded(*Out),
    options: Options,
    /// Private: one message taken at a time, in the order they come; once
    /// ended, no more are.
    taking: aegis.BlockingGuarded(Taking) = .init(.open),
    /// Private: the requests being answered.
    jobs: aegis.BlockingGuarded(std.ArrayList(*Job)) = .init(.empty),
    group: Io.Group = .init,
    /// The process's session, once a client opens one with `initialize`.
    session: ?*compat.Session = null,
    /// The task writing the session's list changes.
    session_stream: ?Io.Future(Io.Cancelable!void) = null,
    /// Private: where lines that belong to no request go.
    target: Sink.Target = .{ .sendFn = sendLine },

    const Taking = enum { open, ended };

    pub fn init(io: Io, gpa: Allocator, server: *Server, out: *Out, options: Options) Connection {
        return .{ .io = io, .gpa = gpa, .server = server, .out = .init(out), .options = options };
    }

    /// Takes no more messages; stops what is still answering, its streams
    /// first, each ended by its own act; and frees the session.
    pub fn deinit(c: *Connection) void {
        c.close();
        c.endStreams();
        c.endSession();
        c.group.cancel(c.io);
        if (c.session) |session| {
            session.deinit();
            c.gpa.destroy(session);
        }
        c.jobs.teardown().deinit(c.gpa);
    }

    /// The client is done sending: the requests taken are answered, and the
    /// streams that would never end are ended.
    pub fn finish(c: *Connection) ServeError!void {
        c.close();
        c.endStreams();
        c.endSession();
        return c.group.await(c.io);
    }

    fn close(c: *Connection) void {
        var held = c.taking.acquireUncancelable(c.io);
        defer held.deinit(c.io);
        held.value().* = .ended;
    }

    pub const TakeError = ServeError || error{
        /// `finish` or `deinit` came first.
        Ended,
    };

    /// One message from the client, as `serve` takes a line: decoded, then
    /// answered on `out` (a request), or taken (a notification, an answer).
    /// `bytes`, on the connection's allocator, is the connection's from
    /// here, whatever is returned. Messages are taken one at a time, in
    /// the order the calls come.
    pub fn take(c: *Connection, bytes: []u8) TakeError!void {
        const job = Job.create(c) catch |err| {
            c.gpa.free(bytes);
            return err;
        };
        job.bytes = .fromOwnedSlice(bytes);
        job.line = bytes;
        var held = c.taking.acquireUncancelable(c.io);
        defer held.deinit(c.io);
        if (held.value().* == .ended) {
            job.destroy();
            return error.Ended;
        }
        return c.dispatch(job);
    }

    /// Keeps a quiet stream open, where `out` has a way to.
    pub fn keepAlive(c: *Connection) error{ WriteFailed, Canceled }!void {
        var held = try c.out.acquire(c.io);
        defer held.deinit(c.io);
        const out = held.value().*;
        const keep = out.keepAliveFn orelse return;
        try keep(out);
    }

    const Read = enum { line, empty, too_long, end };

    /// The next line into `job`'s buffer, without its line break. The
    /// buffer is the job's own on `gpa`, not its arena: growing it frees what
    /// it outgrew, where an arena would keep every size it passed through.
    fn readLine(c: *Connection, in: *Io.Reader, job: *Job) ServeError!Read {
        var line: Io.Writer.Allocating = .fromArrayList(c.gpa, &job.bytes);
        defer job.bytes = line.toArrayList();
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
        // A batch, on a session whose revision has them (2025-03-26 and
        // 2024-11-05); anywhere else the decode refuses it.
        if (wire.isBatch(job.line)) if (c.session) |session| if (session.revision(c.io).batches()) return c.dispatchBatch(job, session);
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
                try c.notice(job.arena.allocator(), n);
            },
            // Answers to requests the session sent (2025-11-25 and before).
            .result, .failure => {
                defer job.destroy();
                if (c.session) |session| session.deliver(c.io, message);
            },
        }
    }

    /// A notification from the client: a request canceled, or the session
    /// begun.
    fn notice(c: *Connection, arena: Allocator, n: wire.Notification) ServeError!void {
        if (std.mem.eql(u8, n.method, "notifications/cancelled")) try c.cancel(arena, n.params);
        if (std.mem.eql(u8, n.method, "notifications/initialized")) if (c.session) |session| {
            if (session.initialized(c.io)) {
                // The session's list changes go out on stdout from here.
                c.session_stream = try c.io.concurrent(streamSession, .{ c, session });
            }
        };
    }

    /// A batch's elements, each as `dispatch` takes one message: its
    /// requests run as tasks whose answers go out together, one array on one
    /// line, once the last is answered (none when it held no request, or
    /// none was answered). `initialize` is refused inside one (2025-03-26).
    fn dispatchBatch(c: *Connection, job: *Job, session: *compat.Session) ServeError!void {
        var fault: wire.Fault = .{};
        const elements = wire.decodeBatch(job.arena.allocator(), job.line, .{ .fault = &fault, .limits = c.server.jsonLimits() }) catch |err| {
            job.destroy();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Malformed, error.Invalid => c.writeFailure(fault.id, fault.code, fault.reason),
            };
        };
        // The batch holds the line its messages point into until its last
        // answer is written.
        const batch = try c.gpa.create(Batch);
        batch.* = .{ .conn = c, .source = job };
        defer batch.release();
        for (elements) |element| {
            const message = switch (element.read) {
                .refused => |f| {
                    try batch.addFailure(f.id, f.code, f.reason);
                    continue;
                },
                .message => |m| m,
            };
            switch (message) {
                .request => |request| {
                    if (std.mem.eql(u8, request.method, "initialize")) {
                        try batch.addFailure(request.id, .invalid_request, "initialize is not sent in a batch");
                        continue;
                    }
                    const member = try Job.create(c);
                    member.request = request;
                    member.session = session;
                    member.batch = batch;
                    if (!try c.admit(member)) {
                        member.destroy();
                        try batch.addFailure(request.id, .internal_error, "the server is answering as many requests as it takes at once");
                        continue;
                    }
                    batch.hold();
                    if (setsSession(request.method)) {
                        Job.run(member);
                        continue;
                    }
                    c.group.concurrent(c.io, Job.run, .{member}) catch Job.run(member);
                },
                .notification => |n| try c.notice(job.arena.allocator(), n),
                .result, .failure => session.deliver(c.io, message),
            }
        }
    }

    /// Ends the session's stream and waits for it: ended, it returns on
    /// its own.
    fn endSession(c: *Connection) void {
        if (c.session_stream) |*task| {
            c.session.?.end(c.io);
            // glint-ignore: Z026 -- the session stream ends with the connection; its result says nothing more
            task.await(c.io) catch {};
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
        return .{ .target = &c.target };
    }

    fn sendLine(t: *Sink.Target, io: Io, message: []const u8) Sink.SendError!void {
        _ = io;
        const c: *Connection = @fieldParentPtr("target", t);
        c.send(message) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.WriteFailed => error.Closed,
        };
    }

    /// Adds `job` to the requests in flight, unless they are at the bound.
    fn admit(c: *Connection, job: *Job) Io.Cancelable!bool {
        var held = try c.jobs.acquire(c.io);
        defer held.deinit(c.io);
        const jobs = held.value();
        if (jobs.items.len >= c.options.max_in_flight) return false;
        jobs.append(c.gpa, job) catch return false;
        return true;
    }

    /// Ends every `subscriptions/listen` in flight, unanswered.
    fn endStreams(c: *Connection) void {
        var held = c.jobs.acquireUncancelable(c.io);
        defer held.deinit(c.io);
        for (held.value().items) |j| if (j.streams()) j.stop(c.io);
    }

    fn retire(c: *Connection, job: *Job) void {
        var held = c.jobs.acquireUncancelable(c.io);
        defer held.deinit(c.io);
        const jobs = held.value();
        for (jobs.items, 0..) |j, i| if (j == job) {
            _ = jobs.swapRemove(i);
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
        var held = try c.jobs.acquire(c.io);
        defer held.deinit(c.io);
        for (held.value().items) |j| if (j.request.id.eql(id)) j.stop(c.io);
    }

    /// Writes `message`, whole.
    fn send(c: *Connection, message: []const u8) error{ WriteFailed, Canceled }!void {
        var held = try c.out.acquire(c.io);
        defer held.deinit(c.io);
        const out = held.value().*;
        const w = try out.beginFn(out);
        try w.writeAll(message);
        try out.endFn(out);
    }

    /// Writes a request's answer, whole.
    fn sendAnswer(c: *Connection, id: wire.Id, answer: Answer) error{ WriteFailed, Canceled }!void {
        var held = try c.out.acquire(c.io);
        defer held.deinit(c.io);
        const out = held.value().*;
        const w = try out.beginFn(out);
        try answer.write(w, id);
        try out.endFn(out);
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

/// What a request is answered with, as `sendAnswer` writes it.
const Answer = union(enum) {
    result: Server.Body,
    failure: Server.Failure,

    fn write(answer: Answer, w: *Io.Writer, id: wire.Id) Io.Writer.Error!void {
        switch (answer) {
            .result => |body| {
                try wire.beginResult(w, id);
                try body.write(w);
                try wire.endResult(w);
            },
            .failure => |f| try wire.writeFailure(w, id, f.code, f.message, f.data),
        }
    }
};

/// A batch being answered: its answers gathered into one array, written
/// when the last request still running lets go of it.
const Batch = struct {
    conn: *Connection,
    /// The batch's line, which its requests point into.
    source: *Job,
    /// Its holders and its answers so far.
    held: aegis.BlockingGuarded(Answers) = .init(.{}),

    const Answers = struct {
        /// The reader while it reads the batch, and each request.
        holders: u32 = 1,
        /// `[` and the answers so far, comma separated.
        out: std.ArrayList(u8) = .empty,
    };

    fn hold(b: *Batch) void {
        var held = b.held.acquireUncancelable(b.conn.io);
        defer held.deinit(b.conn.io);
        held.value().holders += 1;
    }

    /// One answer into the array.
    fn add(b: *Batch, id: wire.Id, answer: Answer) Allocator.Error!void {
        var held = b.held.acquireUncancelable(b.conn.io);
        defer held.deinit(b.conn.io);
        const a = held.value();
        var w: Io.Writer.Allocating = .fromArrayList(b.conn.gpa, &a.out);
        defer a.out = w.toArrayList();
        w.writer.writeByte(if (a.out.items.len == 0) '[' else ',') catch return error.OutOfMemory;
        answer.write(&w.writer, id) catch return error.OutOfMemory;
    }

    fn addFailure(b: *Batch, id: ?wire.Id, code: wire.Code, message: []const u8) Allocator.Error!void {
        var held = b.held.acquireUncancelable(b.conn.io);
        defer held.deinit(b.conn.io);
        const a = held.value();
        var w: Io.Writer.Allocating = .fromArrayList(b.conn.gpa, &a.out);
        defer a.out = w.toArrayList();
        w.writer.writeByte(if (a.out.items.len == 0) '[' else ',') catch return error.OutOfMemory;
        wire.writeFailure(&w.writer, id, code, message, null) catch return error.OutOfMemory;
    }

    /// A holder is done: the last writes the array and frees the batch.
    fn release(b: *Batch) void {
        const c = b.conn;
        {
            var held = b.held.acquireUncancelable(c.io);
            defer held.deinit(c.io);
            const a = held.value();
            a.holders -= 1;
            if (a.holders != 0) return;
        }
        // The last holder: no other task reaches the batch.
        const out = &b.held.teardown().out;
        defer {
            out.deinit(c.gpa);
            b.source.destroy();
            c.gpa.destroy(b);
        }
        // No answer: nothing is written (JSON-RPC 2.0 §6, never an empty array).
        if (out.items.len == 0) return;
        out.append(c.gpa, ']') catch {
            // glint-ignore: Z026 -- the answers could not be closed and the refusal could not be written: the stream is gone
            c.writeFailure(null, .internal_error, "out of memory") catch {};
            return;
        };
        // glint-ignore: Z026 -- a stream that cannot be written is gone; the reader sees its end
        c.send(out.items) catch {};
    }
};

/// One request: its bytes, its arena, and its cancellation.
const Job = struct {
    conn: *Connection,
    arena: std.heap.ArenaAllocator,
    /// The line read, which the request's strings point into.
    bytes: std.ArrayList(u8) = .empty,
    line: []const u8 = "",
    request: wire.Request = undefined,
    /// Set by `notifications/cancelled`; the request's task waits on it.
    cancel: Io.Event = .unset,
    /// How a stream the request opens is ended (`subscriptions/listen`).
    end: subscriptions.End = .{},
    /// Once set, nothing more is written for the request.
    canceled: aegis.Atomic(Canceled) = .init(.running),
    /// The session that answers the request, or null for the core.
    session: ?*compat.Session = null,
    /// The batch the request came in, whose array its answer joins.
    batch: ?*Batch = null,
    target: Sink.Target = .{ .sendFn = sendFn },

    const Canceled = enum(u8) { running, canceled };

    fn create(conn: *Connection) Allocator.Error!*Job {
        const job = try conn.gpa.create(Job);
        job.* = .{ .conn = conn, .arena = .init(conn.gpa) };
        return job;
    }

    /// Whether the request is a stream, which ends by its own act.
    fn streams(job: *const Job) bool {
        return std.mem.eql(u8, job.request.method, "subscriptions/listen");
    }

    /// The client's cancellation, or its input's end: nothing more is
    /// written for the request. A stream is ended, and returns on its own;
    /// anything else is stopped where it is.
    fn stop(job: *Job, io: Io) void {
        job.canceled.store(.canceled, .release);
        if (job.streams()) job.end.end(io) else job.cancel.set(io);
    }

    fn destroy(job: *Job) void {
        const gpa = job.conn.gpa;
        job.arena.deinit();
        job.bytes.deinit(gpa);
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
            const batch = job.batch;
            job.destroy();
            if (batch) |b| b.release();
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
        if (job.canceled.load(.acquire) == .canceled) return;
        const c = job.conn;
        const reply = result catch |err| switch (err) {
            error.Canceled => return,
            error.OutOfMemory => {
                // glint-ignore: Z026 -- the answer could not be made and the refusal could not be written: the stream is gone
                c.writeFailure(job.request.id, .internal_error, "out of memory") catch {};
                return;
            },
        };
        // The answer goes to the stream as it is written: a result is never
        // copied into a message first.
        const out: Answer = switch (reply) {
            .result => |body| .{ .result = body },
            .input_required => |ir| .{
                .result = .{
                    .json = c.server.inputRequiredJson(job.arena.allocator(), ir) catch {
                        // glint-ignore: Z026 -- the answer could not be made and the refusal could not be written: the stream is gone
                        c.writeFailure(job.request.id, .internal_error, "out of memory") catch {};
                        return;
                    },
                },
            },
            .failure => |f| .{ .failure = f },
        };
        if (job.batch) |batch| {
            batch.add(job.request.id, out) catch {
                // glint-ignore: Z026 -- the answer could not be made and the refusal could not be written: the stream is gone
                c.writeFailure(job.request.id, .internal_error, "out of memory") catch {};
            };
            return;
        }
        // glint-ignore: Z026 -- a stream that cannot be written is gone; the reader sees its end
        c.sendAnswer(job.request.id, out) catch {};
    }

    fn sink(job: *Job) Sink {
        return .{ .target = &job.target, .end = &job.end };
    }

    fn sendFn(t: *Sink.Target, io: Io, message: []const u8) Sink.SendError!void {
        _ = io;
        const job: *Job = @fieldParentPtr("target", t);
        if (job.canceled.load(.acquire) == .canceled) return error.Canceled;
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
    /// Private: where messages go, one at a time.
    writing: aegis.BlockingGuarded(Writing),
    /// Private: the requests waiting for their answers.
    waiting: aegis.BlockingGuarded(Waiting) = .init(.{}),
    reading: ?Io.Future(void) = null,
    client: ?*Client = null,
    /// Private: the channel as a client's transport (`transport`).
    transporting: Client.Transport = .{ .vtable = &.{ .request = request, .notify = notify, .opened = opened } },

    const Writing = struct {
        out: *Io.Writer,
        /// Set by `end`: nothing more is written.
        ended: bool = false,
    };

    const Waiting = struct {
        list: std.ArrayList(*Waiter) = .empty,
        /// Set once the server's output ended: every wait fails at once.
        closed: bool = false,
    };

    const Waiter = struct {
        id: wire.Id,
        event: Io.Event = .unset,
        /// The answer, on the channel's allocator; null until it comes.
        answer: ?[]u8 = null,
    };

    pub fn init(gpa: Allocator, in: *Io.Reader, out: *Io.Writer) Channel {
        return .{ .gpa = gpa, .in = in, .writing = .init(.{ .out = out }) };
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
        ch.waiting.teardown().list.deinit(ch.gpa);
    }

    /// Writes nothing more: what is sent from now on fails `Closed`, so the
    /// caller may close what `out` writes to (the server's input, which is
    /// how a stdio server is told to end) while the answers already asked
    /// for are still read.
    pub fn end(ch: *Channel, io: Io) void {
        var held = ch.writing.acquireUncancelable(io);
        defer held.deinit(io);
        held.value().ended = true;
    }

    /// The channel as a client's transport, for as long as the channel
    /// stays where it is.
    pub fn transport(ch: *Channel) *Client.Transport {
        return &ch.transporting;
    }

    fn request(t: *Client.Transport, io: Io, arena: Allocator, exchange: *Client.Exchange) Client.RequestError![]const u8 {
        const ch: *Channel = @fieldParentPtr("transporting", t);
        var waiter: Waiter = .{ .id = exchange.id };
        {
            var held = try ch.waiting.acquire(io);
            defer held.deinit(io);
            const waiting = held.value();
            // Checked where the reader sets it, so no waiter comes after
            // the last are woken.
            if (waiting.closed) return error.Closed;
            try waiting.list.append(ch.gpa, &waiter);
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
        var held = ch.writing.acquireUncancelable(io);
        defer held.deinit(io);
        const w = held.value();
        if (w.ended) return error.Closed;
        w.out.writeAll(message) catch return error.Closed;
        w.out.writeByte('\n') catch return error.Closed;
        w.out.flush() catch return error.Closed;
    }

    fn notify(t: *Client.Transport, io: Io, message: []const u8) Client.RequestError!void {
        const ch: *Channel = @fieldParentPtr("transporting", t);
        return ch.write(io, message);
    }

    fn opened(_: *Client.Transport, _: Io, _: *Client) Io.ConcurrentError!void {}

    fn retire(ch: *Channel, io: Io, waiter: *Waiter) void {
        var held = ch.waiting.acquireUncancelable(io);
        defer held.deinit(io);
        const list = &held.value().list;
        for (list.items, 0..) |w, i| if (w == waiter) {
            _ = list.swapRemove(i);
            break;
        };
    }

    fn readLoop(ch: *Channel, io: Io) void {
        defer {
            var held = ch.waiting.acquireUncancelable(io);
            defer held.deinit(io);
            const waiting = held.value();
            waiting.closed = true;
            for (waiting.list.items) |w| w.event.set(io);
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

    /// One frame from the server: a message, or a batch where the
    /// session's revision has them. The answers to its requests go back
    /// together, as `Client.Replies` has them.
    fn handle(ch: *Channel, io: Io, bytes: []const u8) void {
        const client = ch.client.?;
        var arena: std.heap.ArenaAllocator = .init(ch.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const elements = wire.decodeFrame(a, bytes, client.revision.batches(), .{ .limits = client.jsonLimits() }) catch return;
        var replies: Client.Replies = .init(a, bytes);
        for (elements) |element| switch (element.read) {
            // An element the server got wrong is passed over, as a line is.
            .refused => {},
            .message => |message| switch (message) {
                .result => |r| ch.answered(io, element.bytes, r.id),
                .failure => |f| if (f.id) |id| ch.answered(io, element.bytes, id),
                // A session server's own request: answered by the client.
                .request => {
                    var exchange: Client.Exchange = .{ .id = .{ .integer = 0 }, .method = "", .message = "", .revision = client.revision, .timeout = .zero, .client = client };
                    replies.add(exchange.inbound(io, a, message)) catch return;
                },
                .notification => {},
            },
        };
        const answer = (replies.message() catch return) orelse return;
        ch.write(io, answer) catch return;
    }

    /// An answer to a request of the client's: handed to the request that
    /// waits for it, as `bytes`.
    fn answered(ch: *Channel, io: Io, bytes: []const u8, id: wire.Id) void {
        var held = ch.waiting.acquireUncancelable(io);
        defer held.deinit(io);
        for (held.value().list.items) |w| if (w.id.eql(id) and w.answer == null) {
            w.answer = ch.gpa.dupe(u8, bytes) catch return;
            w.event.set(io);
            return;
        };
    }
};
