//! The tasks extension (`io.modelcontextprotocol/tasks`, 2026-07-28): a
//! `tools/call` answered with a task the client polls (`tasks/get`), gives
//! input to (`tasks/update`) and cancels (`tasks/cancel`), its status also
//! sent on `subscriptions/listen` streams that name it.
//!
//! This file keeps the tasks a server holds: each one's status (a state
//! machine: working, input required, then completed, failed or cancelled),
//! what it waits for, its outcome, and its life (a time to live from its
//! creation, a bound on how many are held). The server runs the handlers.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const wire = @import("wire.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The extension's name, in capabilities on both sides.
pub const extension = "io.modelcontextprotocol/tasks";

/// A span as the extension writes one: whole milliseconds.
pub const Duration = aegis.units.Duration(.millisecond, u32);

/// A task's times: milliseconds on the real clock, as its `createdAt` and
/// `lastUpdatedAt` are written.
pub const Instant = aegis.units.Instant(.real, .millisecond, i64);

/// Now, on the tasks' clock.
pub fn now(io: Io) Instant {
    return Instant.fromTimestamp(Io.Timestamp.now(io, .real), .down) catch .fromRaw(std.math.maxInt(i64));
}

pub const Options = struct {
    /// Tasks held at once, finished ones included until their time is up.
    max: u32 = 256,
    /// How long a task is kept from its creation.
    ttl: Duration = .literal("1h"),
    /// How often a client is asked to poll.
    poll_interval: Duration = .literal("1s"),
};

pub const Status = enum { working, input_required, completed, failed, cancelled };
pub const Step = enum { ask, @"resume", complete, fail, cancel };

/// A task's status: input is asked and given any number of times, and one
/// of the three ends is final.
pub const Lifecycle = aegis.state.Machine(Status, Step, .{
    .initial = .working,
    .terminal = &.{ .completed, .failed, .cancelled },
    .edges = &.{
        .{ .from = .working, .on = .ask, .to = .input_required },
        .{ .from = .input_required, .on = .@"resume", .to = .working },
        .{ .from = .working, .on = .complete, .to = .completed },
        .{ .from = .working, .on = .fail, .to = .failed },
        .{ .from = .working, .on = .cancel, .to = .cancelled },
        .{ .from = .input_required, .on = .fail, .to = .failed },
        .{ .from = .input_required, .on = .cancel, .to = .cancelled },
    },
});

/// A task's id: 128 random bits, in hex, so no one guesses another's.
pub const Id = [32]u8;

/// An input request outstanding: its key and the request, as JSON.
pub const Asked = struct { key: []const u8, request: []const u8 };

/// An answer given to an input request, as JSON.
pub const Answer = struct { key: []const u8, value: []const u8 };

pub const Task = struct {
    id: Id,
    /// Who created it, as the transport authenticated them: only they see it.
    principal: ?[]const u8,
    /// The `tools/call` params as sent: the tool, its arguments, `_meta`.
    params: []const u8,
    lifecycle: Lifecycle.Runtime(void) = .init({}),
    /// Why it failed or was cancelled.
    message: ?[]const u8 = null,
    /// Milliseconds since the epoch.
    created: Instant,
    updated: Instant,
    /// What it waits for, while its status is `input_required`.
    asked: std.ArrayList(Asked) = .empty,
    /// The answers given so far to what it waits for.
    answers: std.ArrayList(Answer) = .empty,
    /// The handler's own bytes, kept from one round to the next.
    state: ?[]const u8 = null,
    /// Completed: the tool's result object. Failed: the JSON-RPC error.
    outcome: ?[]const u8 = null,
    /// Set to stop the round running: `tasks/cancel`, its time running out,
    /// the server closing.
    cancel: Io.Event = .unset,
    /// A round of its handler is running.
    running: bool = false,
    /// Rounds run back to back without asking the client for anything.
    quiet_rounds: u8 = 0,

    pub fn status(t: *const Task) Status {
        return t.lifecycle.current();
    }

    fn deinit(t: *Task, gpa: Allocator) void {
        if (t.principal) |p| gpa.free(p);
        gpa.free(t.params);
        if (t.message) |m| gpa.free(m);
        t.clearAsked(gpa);
        t.asked.deinit(gpa);
        t.clearAnswers(gpa);
        t.answers.deinit(gpa);
        if (t.state) |s| gpa.free(s);
        if (t.outcome) |o| gpa.free(o);
    }

    fn clearAsked(t: *Task, gpa: Allocator) void {
        for (t.asked.items) |a| {
            gpa.free(a.key);
            gpa.free(a.request);
        }
        t.asked.clearRetainingCapacity();
    }

    fn clearAnswers(t: *Task, gpa: Allocator) void {
        for (t.answers.items) |a| {
            gpa.free(a.key);
            gpa.free(a.value);
        }
        t.answers.clearRetainingCapacity();
    }
};

/// How a task is written: as the result that creates it, as `tasks/get`
/// answers it (with what it waits for or its outcome), or as the params of
/// a `notifications/tasks`.
pub const Form = enum { created, polled, notified };

/// The tasks a server holds. What is done to a task takes the table's
/// lock (`held`), whose value each of those calls is given.
pub const Table = struct {
    gpa: Allocator,
    io: Io,
    options: Options,
    /// The tasks held, and every task's fields with them.
    held: aegis.BlockingGuarded(Held) = .init(.{}),
    /// The rounds running, each in a task of its own.
    group: Io.Group = .init,

    pub const Held = struct {
        tasks: std.ArrayList(*Task) = .empty,
    };

    /// The table's lock, until the guard's `deinit`.
    pub fn lock(t: *Table) aegis.BlockingGuarded(Held).Guard {
        return t.held.acquireUncancelable(t.io);
    }

    pub fn init(gpa: Allocator, io: Io, options: Options) Table {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    /// Stops every round, then frees every task.
    pub fn deinit(t: *Table) void {
        t.group.cancel(t.io);
        const h = t.held.teardown();
        for (h.tasks.items) |task| t.destroy(task);
        h.tasks.deinit(t.gpa);
    }

    /// A task not yet held: the call it is made for may still answer
    /// without it.
    pub fn create(t: *Table, principal: ?[]const u8, params: []const u8, at: Instant) (Allocator.Error || Io.RandomSecureError)!*Task {
        const task = try t.gpa.create(Task);
        errdefer t.gpa.destroy(task);
        var bytes: [16]u8 = undefined;
        try t.io.randomSecure(&bytes);
        const owned_params = try t.gpa.dupe(u8, params);
        errdefer t.gpa.free(owned_params);
        const owned_principal = if (principal) |p| try t.gpa.dupe(u8, p) else null;
        task.* = .{ .id = std.fmt.bytesToHex(bytes, .lower), .principal = owned_principal, .params = owned_params, .created = at, .updated = at };
        return task;
    }

    pub fn destroy(t: *Table, task: *Task) void {
        task.deinit(t.gpa);
        t.gpa.destroy(task);
    }

    /// Holds `task`, unless as many are held as allowed (after the ones
    /// whose time is up are let go).
    pub fn hold(t: *Table, h: *Held, task: *Task, at: Instant) Allocator.Error!bool {
        t.sweep(h, at);
        if (h.tasks.items.len >= t.options.max) return false;
        try h.tasks.append(t.gpa, task);
        return true;
    }

    /// The task `id` held for `principal`, or null.
    pub fn find(t: *Table, h: *Held, id: []const u8, principal: ?[]const u8, at: Instant) ?*Task {
        t.sweep(h, at);
        for (h.tasks.items) |task| if (std.mem.eql(u8, &task.id, id)) {
            const same = if (task.principal) |p| (if (principal) |q| std.mem.eql(u8, p, q) else false) else principal == null;
            return if (same) task else null;
        };
        return null;
    }

    /// Lets go of the tasks whose time is up; one still running is told to
    /// stop, and goes once it has.
    pub fn sweep(t: *Table, h: *Held, at: Instant) void {
        var i: usize = 0;
        while (i < h.tasks.items.len) {
            const task = h.tasks.items[i];
            if (at.compare(task.created.saturatingAdd(t.options.ttl.convert(.millisecond, i64, .exact))) == .lt) {
                i += 1;
                continue;
            }
            if (task.running) {
                task.cancel.set(t.io);
                i += 1;
                continue;
            }
            _ = h.tasks.swapRemove(i);
            t.destroy(task);
        }
    }

    // What happens to a task, under the table's lock (`h`); each takes
    // copies.

    /// The handler asks for `asked` (keys and requests as JSON), keeping
    /// `state`.
    pub fn ask(t: *Table, h: *Held, task: *Task, at: Instant, asked: []const Asked, state: ?[]const u8) Allocator.Error!void {
        task.clearAsked(t.gpa);
        task.clearAnswers(t.gpa);
        for (asked) |a| {
            try task.asked.ensureUnusedCapacity(t.gpa, 1);
            const key = try t.gpa.dupe(u8, a.key);
            errdefer t.gpa.free(key);
            task.asked.appendAssumeCapacity(.{ .key = key, .request = try t.gpa.dupe(u8, a.request) });
        }
        try t.keepState(h, task, state);
        _ = task.lifecycle.step(.ask) catch unreachable; // unreachable: a round runs only while the task is working
        task.updated = at;
    }

    /// Keeps `state` for the next round, replacing the one before.
    pub fn keepState(t: *Table, _: *Held, task: *Task, state: ?[]const u8) Allocator.Error!void {
        const copy = if (state) |s| try t.gpa.dupe(u8, s) else null;
        if (task.state) |old| t.gpa.free(old);
        task.state = copy;
    }

    /// Takes the answers in `responses` (an `inputResponses` object) to
    /// what the task waits for; others are passed over. Once every request
    /// is answered the task works again, and the answers are returned as
    /// one `inputResponses` object for its next round, on `arena`; `responses`
    /// is read within `limits` (the server's).
    pub fn answer(t: *Table, _: *Held, task: *Task, at: Instant, arena: Allocator, responses: []const u8, limits: strand.core.Limits) error{ OutOfMemory, Invalid }!?[]const u8 {
        if (task.status() != .input_required) return null;
        var members: strand.json.Members = undefined;
        members.init(responses, .{ .limits = limits });
        while (members.next() catch return error.Invalid) |m| {
            const index = for (task.asked.items, 0..) |a, i| {
                if (m.is(a.key)) break i;
            } else continue;
            try task.answers.ensureUnusedCapacity(t.gpa, 1);
            const value = try t.gpa.dupe(u8, m.value);
            const asked = task.asked.orderedRemove(index);
            t.gpa.free(asked.request);
            task.answers.appendAssumeCapacity(.{ .key = asked.key, .value = value });
        }
        if (task.asked.items.len != 0) return null;
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeByte('{') catch return error.OutOfMemory;
        for (task.answers.items, 0..) |a, i| {
            if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
            wire.writeString(w, a.key) catch return error.OutOfMemory;
            w.writeByte(':') catch return error.OutOfMemory;
            w.writeAll(a.value) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        task.clearAnswers(t.gpa);
        _ = task.lifecycle.step(.@"resume") catch unreachable; // unreachable: the status was checked above
        task.updated = at;
        return out.written();
    }

    pub fn complete(t: *Table, _: *Held, task: *Task, at: Instant, result: []const u8) Allocator.Error!void {
        task.outcome = try t.gpa.dupe(u8, result);
        _ = task.lifecycle.step(.complete) catch unreachable; // unreachable: a round runs only while the task is working
        task.updated = at;
    }

    /// Fails with `failure`, a JSON-RPC error object, and its message.
    pub fn fail(t: *Table, _: *Held, task: *Task, at: Instant, failure: []const u8, message: []const u8) Allocator.Error!void {
        if (task.lifecycle.isTerminal()) return;
        const owned = try t.gpa.dupe(u8, failure);
        errdefer t.gpa.free(owned);
        const text = try t.gpa.dupe(u8, message);
        if (task.message) |old| t.gpa.free(old);
        task.message = text;
        task.outcome = owned;
        _ = task.lifecycle.step(.fail) catch unreachable; // unreachable: not terminal, checked above
        task.updated = at;
    }

    pub fn cancelled(t: *Table, _: *Held, task: *Task, at: Instant, message: []const u8) Allocator.Error!void {
        if (task.lifecycle.isTerminal()) return;
        const owned = try t.gpa.dupe(u8, message);
        if (task.message) |old| t.gpa.free(old);
        task.message = owned;
        _ = task.lifecycle.step(.cancel) catch unreachable; // unreachable: not terminal, checked above
        task.updated = at;
    }
};

/// Writes `task` as `form` asks: `identity` (the server's `_meta` members)
/// goes into the results.
pub fn write(w: *Writer, task: *const Task, form: Form, ttl: Duration, poll: Duration, identity: ?[]const u8) Writer.Error!void {
    try w.writeByte('{');
    switch (form) {
        .created => try w.writeAll("\"resultType\":\"task\","),
        .polled => try w.writeAll("\"resultType\":\"complete\","),
        .notified => {},
    }
    try w.writeAll("\"taskId\":");
    try wire.writeString(w, &task.id);
    try w.print(",\"status\":\"{t}\"", .{task.status()});
    if (task.message) |m| {
        try w.writeAll(",\"statusMessage\":");
        try wire.writeString(w, m);
    }
    try w.writeAll(",\"createdAt\":");
    try writeTime(w, task.created);
    try w.writeAll(",\"lastUpdatedAt\":");
    try writeTime(w, task.updated);
    try w.print(",\"ttlMs\":{d},\"pollIntervalMs\":{d}", .{ ttl.raw(), poll.raw() });
    if (form != .created) switch (task.status()) {
        .input_required => {
            try w.writeAll(",\"inputRequests\":{");
            for (task.asked.items, 0..) |a, i| {
                if (i != 0) try w.writeByte(',');
                try wire.writeString(w, a.key);
                try w.writeByte(':');
                try w.writeAll(a.request);
            }
            try w.writeByte('}');
        },
        .completed => try w.print(",\"result\":{s}", .{task.outcome.?}),
        .failed => try w.print(",\"error\":{s}", .{task.outcome.?}),
        .working, .cancelled => {},
    };
    if (form != .notified) if (identity) |members| try w.print(",\"_meta\":{{{s}}}", .{members});
    try w.writeByte('}');
}

/// `at` as ISO 8601 in UTC, to the millisecond, quoted.
pub fn writeTime(w: *Writer, at: Instant) Writer.Error!void {
    const clamped: u64 = @intCast(@max(at.raw(), 0)); // safe: clamped to zero and up
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = clamped / 1000 };
    const day = seconds.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const in_day = seconds.getDaySeconds();
    try w.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\"", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        in_day.getHoursIntoDay(),
        in_day.getMinutesIntoHour(),
        in_day.getSecondsIntoMinute(),
        clamped % 1000,
    });
}

test "a time is written as ISO 8601 to the millisecond" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeTime(&w, .fromRaw(1_791_206_906_669));
    try std.testing.expectEqualStrings("\"2026-10-05T13:28:26.669Z\"", w.buffered());
    w = .fixed(&buffer);
    try writeTime(&w, .fromRaw(0));
    try std.testing.expectEqualStrings("\"1970-01-01T00:00:00.000Z\"", w.buffered());
}

test "a task's status: input asked and given, then one end, final" {
    var l: Lifecycle.Runtime(void) = .init({});
    _ = try l.step(.ask);
    _ = try l.step(.@"resume");
    _ = try l.step(.complete);
    try std.testing.expect(l.isTerminal());
    try std.testing.expectError(error.IllegalEvent, l.step(.cancel));
}
