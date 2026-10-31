//! Change notifications: the open `subscriptions/listen` streams (and a
//! legacy session's stream, which is one more listener), each with the kinds
//! it asked for, and the changes waiting for it.
//!
//! A change never queues: each listener keeps a flag per kind of list and
//! one bit per resource it watches, set by whoever changes something and
//! cleared by the listener's own task as it writes. Every one of these
//! notifications means "fetch again", so ten changes before a slow reader
//! catches up are rightly one notification, and a listener costs the same
//! however many changes it misses.
//!
//! A stream ends by an explicit act, never by canceling its task: the server
//! closing (`Hub.close`, answered `complete`), or the stream's owner ending it
//! (`Listener.end`, `End.end`: the client canceled the request, its input
//! ended, its session was deleted), each seen by the stream's next wait, after
//! which its task returns on its own.
const std = @import("std");
const aegis = @import("aegis");
const wire = @import("wire.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The kinds of change a listener can ask for.
pub const Kind = enum(u3) {
    tools,
    prompts,
    resources,
    /// A watched resource was updated (its bit says which).
    resource,
    /// A watched task's status changed (its bit says which).
    task,
};

/// What a listener watches one by one, by name: resources by URI, tasks by
/// id.
pub const Watch = enum { resource, task };

/// The locks here, in the order one is taken while another is held: a
/// stream's end, or the hub, before a listener.
const Locks = aegis.Order(&.{
    .{ .name = "end" },
    .{ .name = "hub" },
    .{ .name = "listener", .after = &.{ 0, 1 } },
});

/// The names a listener watches of one kind, and which changed.
const Watched = struct {
    names: std.ArrayList([]const u8) = .empty,
    /// One bit per name: changed and not yet written.
    changed: std.DynamicBitSetUnmanaged = .{},

    fn deinit(w: *Watched, gpa: Allocator) void {
        for (w.names.items) |n| gpa.free(n);
        w.names.deinit(gpa);
        w.changed.deinit(gpa);
    }
};

/// One open stream.
pub const Listener = struct {
    /// The `subscriptions/listen` request's id, which every notification on
    /// the stream carries; null for a legacy session's stream, whose
    /// notifications carry none.
    id: ?wire.Id,
    /// The kinds of list change asked for.
    lists: std.EnumSet(Kind),
    /// Private: what changed and is not yet written, and whether the
    /// stream is over.
    state: Locks.Ordered(aegis.BlockingGuarded(State), 2) = .init(.init(.{})),
    /// Private: signaled by every change, for the stream's task.
    changes: aegis.Condition = .init(),

    const State = struct {
        /// The resources and the tasks watched, as given. A legacy session
        /// adds to the resources.
        watched: std.EnumArray(Watch, Watched) = .initFill(.{}),
        /// Bumped by every change: what the stream's task waits past.
        version: u32 = 0,
        /// Kinds changed and not yet written.
        pending: std.EnumSet(Kind) = .empty,
        /// Set by `end`: the stream's task returns at its next wait.
        ended: bool = false,
        /// Set when the server closes (`Hub.close`).
        closed: bool = false,

        fn bump(st: *State) void {
            st.version +%= 1;
        }
    };

    /// Ends the stream: its task sees it at its next wait and returns,
    /// writing nothing more. Safe from any task, before the stream starts
    /// too, and more than once.
    pub fn end(l: *Listener, io: Io) void {
        var order: Locks.Context = .{};
        l.endIn(io, &order);
    }

    /// `end`, with the locks `order` holds.
    fn endIn(l: *Listener, io: Io, order: *Locks.Context) void {
        var held = l.state.acquireOrderedUncancelable(io, order);
        defer held.deinit(io);
        const st = held.value();
        st.ended = true;
        st.bump();
        l.changes.signal(io);
    }

    /// The server closed: the stream's task writes what is pending and
    /// returns.
    fn close(l: *Listener, io: Io, order: *Locks.Context) void {
        var held = l.state.acquireOrderedUncancelable(io, order);
        defer held.deinit(io);
        const st = held.value();
        st.closed = true;
        st.bump();
        l.changes.signal(io);
    }

    /// Whether the stream's owner ended it (`end`).
    pub fn ended(l: *Listener, io: Io) bool {
        var order: Locks.Context = .{};
        var held = l.state.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        return held.value().ended;
    }

    /// Whether the server closed (`Hub.close`).
    pub fn closed(l: *Listener, io: Io) bool {
        var order: Locks.Context = .{};
        var held = l.state.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        return held.value().closed;
    }

    /// Whether the stream is over: ended by its owner, or its server closed.
    pub fn over(l: *Listener, io: Io) bool {
        var order: Locks.Context = .{};
        var held = l.state.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const st = held.value();
        return st.ended or st.closed;
    }

    /// `kind` changed; `st` is the listener's state, held.
    fn mark(l: *Listener, io: Io, st: *State, kind: Kind) void {
        st.pending.insert(kind);
        st.bump();
        l.changes.signal(io);
    }

    /// Waits until something changed since `seen`, the stream is over
    /// (`over`), `timeout` passes (null), or the task is canceled. Returns
    /// the version seen, to wait past next time.
    pub fn wait(l: *Listener, io: Io, seen: u32, timeout: Io.Timeout) Io.Cancelable!?u32 {
        const deadline = timeout.toDeadline(io);
        var order: Locks.Context = .{};
        var held = try l.state.acquireOrdered(io, &order);
        defer held.deinit(io);
        while (true) {
            const st = held.value();
            if (st.version != seen or st.ended or st.closed) return st.version;
            l.changes.wait(io, &held, deadline) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => return null,
                error.WaiterLimit => unreachable, // unreachable: one task waits on a listener, its stream's
            };
        }
    }

    /// The kinds changed since the last call, cleared.
    pub fn takeLists(l: *Listener, io: Io) std.EnumSet(Kind) {
        var order: Locks.Context = .{};
        var held = l.state.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const st = held.value();
        const set = st.pending;
        st.pending = .empty;
        return set;
    }

    /// The watched names of `which` changed since the last call, cleared,
    /// as copies on `arena`.
    pub fn takeChanged(l: *Listener, io: Io, arena: Allocator, which: Watch) (Allocator.Error || Io.Cancelable)![]const []const u8 {
        var order: Locks.Context = .{};
        var held = try l.state.acquireOrdered(io, &order);
        defer held.deinit(io);
        const w = held.value().watched.getPtr(which);
        var out: std.ArrayList([]const u8) = .empty;
        var it = w.changed.iterator(.{});
        while (it.next()) |i| try out.append(arena, try arena.dupe(u8, w.names.items[i]));
        w.changed.unsetAll();
        return out.items;
    }

    /// Watches `name` too (for resources, also a legacy
    /// `resources/subscribe`), up to `max` of its kind.
    pub fn watch(l: *Listener, io: Io, gpa: Allocator, which: Watch, name: []const u8, max: usize) (Allocator.Error || Io.Cancelable || error{TooMany})!void {
        var order: Locks.Context = .{};
        var held = try l.state.acquireOrdered(io, &order);
        defer held.deinit(io);
        const w = held.value().watched.getPtr(which);
        for (w.names.items) |n| if (std.mem.eql(u8, n, name)) return;
        if (w.names.items.len >= max) return error.TooMany;
        try w.names.ensureUnusedCapacity(gpa, 1);
        try w.changed.resize(gpa, w.names.items.len + 1, false);
        const copy = gpa.dupe(u8, name) catch |err| {
            w.changed.resize(gpa, w.names.items.len, false) catch unreachable; // unreachable: shrinking never allocates
            return err;
        };
        w.names.appendAssumeCapacity(copy);
    }

    /// Stops watching `name` (a legacy `resources/unsubscribe`).
    pub fn unwatch(l: *Listener, io: Io, gpa: Allocator, which: Watch, name: []const u8) Io.Cancelable!void {
        var order: Locks.Context = .{};
        var held = try l.state.acquireOrdered(io, &order);
        defer held.deinit(io);
        const w = held.value().watched.getPtr(which);
        for (w.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            gpa.free(n);
            _ = w.names.orderedRemove(i);
            // The bits after `i` move down one.
            var k = i;
            while (k + 1 < w.changed.bit_length) : (k += 1) w.changed.setValue(k, w.changed.isSet(k + 1));
            w.changed.resize(gpa, w.names.items.len, false) catch unreachable; // unreachable: shrinking never allocates
            return;
        };
    }

    pub fn deinit(l: *Listener, gpa: Allocator) void {
        for (&l.state.teardown().watched.values) |*w| w.deinit(gpa);
    }
};

/// The end of one request's stream, held by the transport that carries the
/// request (`Sink.end`): the client's cancellation, or its input ending,
/// ends the stream through it whether or not the stream has started. A
/// stream started after its end returns at once.
pub const End = struct {
    /// Private: whether it ended, and the stream's listener once started.
    held: Locks.Ordered(aegis.BlockingGuarded(Ending), 0) = .init(.init(.{})),

    const Ending = struct {
        ended: bool = false,
        listener: ?*Listener = null,
    };

    /// Ends the request's stream, now or as it starts: its task returns on
    /// its own, so the caller awaits it rather than canceling it.
    pub fn end(e: *End, io: Io) void {
        var order: Locks.Context = .{};
        var held = e.held.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const ending = held.value();
        ending.ended = true;
        if (ending.listener) |l| l.endIn(io, &order);
    }

    /// The stream's listener, from its start to `detach`; false, attaching
    /// nothing, when the request was ended before it started.
    pub fn attach(e: *End, io: Io, l: *Listener) bool {
        var order: Locks.Context = .{};
        var held = e.held.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const ending = held.value();
        if (ending.ended) return false;
        ending.listener = l;
        return true;
    }

    pub fn detach(e: *End, io: Io) void {
        var order: Locks.Context = .{};
        var held = e.held.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        held.value().listener = null;
    }
};

/// Every open listener of a server. Its lock comes before a listener's.
pub const Hub = struct {
    listeners: Locks.Ordered(aegis.BlockingGuarded(Listeners), 1) = .init(.init(.{})),

    const Listeners = struct {
        list: std.ArrayList(*Listener) = .empty,
        /// Set when the server closes: every listener's task ends its
        /// stream, one added after too.
        closed: bool = false,
    };

    pub const AddError = Allocator.Error || Io.Cancelable || error{TooMany};

    /// Registers `l`, which the caller keeps until `remove`.
    pub fn add(h: *Hub, io: Io, gpa: Allocator, l: *Listener, max: usize) AddError!void {
        var order: Locks.Context = .{};
        var held = try h.listeners.acquireOrdered(io, &order);
        defer held.deinit(io);
        const ls = held.value();
        if (ls.list.items.len >= max) return error.TooMany;
        try ls.list.append(gpa, l);
        if (ls.closed) l.close(io, &order);
    }

    pub fn remove(h: *Hub, io: Io, l: *Listener) void {
        var order: Locks.Context = .{};
        var held = h.listeners.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const list = &held.value().list;
        for (list.items, 0..) |x, i| if (x == l) {
            _ = list.swapRemove(i);
            return;
        };
    }

    /// A list changed: every listener that asked for `kind` learns it.
    pub fn listChanged(h: *Hub, io: Io, kind: Kind) void {
        aegis.assert.pre(kind != .resource and kind != .task, "a resource's update and a task's change name what changed");
        var order: Locks.Context = .{};
        var held = h.listeners.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        for (held.value().list.items) |l| if (l.lists.contains(kind)) {
            var state = l.state.acquireOrderedUncancelable(io, &order);
            defer state.deinit(io);
            l.mark(io, state.value(), kind);
        };
    }

    /// The resource or task `name` changed: every listener watching it
    /// learns it.
    pub fn changed(h: *Hub, io: Io, which: Watch, name: []const u8) void {
        const kind: Kind = switch (which) {
            .resource => .resource,
            .task => .task,
        };
        var order: Locks.Context = .{};
        var held = h.listeners.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        for (held.value().list.items) |l| {
            var state = l.state.acquireOrderedUncancelable(io, &order);
            defer state.deinit(io);
            const st = state.value();
            const w = st.watched.getPtr(which);
            for (w.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
                w.changed.set(i);
                l.mark(io, st, kind);
            };
        }
    }

    /// Ends every stream: each listener's task sees it closed and returns.
    pub fn close(h: *Hub, io: Io) void {
        var order: Locks.Context = .{};
        var held = h.listeners.acquireOrderedUncancelable(io, &order);
        defer held.deinit(io);
        const ls = held.value();
        ls.closed = true;
        for (ls.list.items) |l| l.close(io, &order);
    }

    pub fn deinit(h: *Hub, gpa: Allocator) void {
        h.listeners.teardown().list.deinit(gpa);
    }
};

test "a stream's end, before or after it starts, ends its wait" {
    const io = std.testing.io;
    var early: End = .{};
    early.end(io);
    var unstarted: Listener = .{ .id = null, .lists = .empty };
    try std.testing.expect(!early.attach(io, &unstarted));

    var end: End = .{};
    var listener: Listener = .{ .id = null, .lists = .empty };
    try std.testing.expect(end.attach(io, &listener));
    try std.testing.expectEqual(@as(?u32, null), try listener.wait(io, 0, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }));
    end.end(io);
    try std.testing.expect(listener.over(io));
    try std.testing.expect(try listener.wait(io, 0, .none) != null);
    end.detach(io);
}
