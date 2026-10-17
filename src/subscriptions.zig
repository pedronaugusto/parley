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
    /// The resources and the tasks watched, as given. A legacy session adds
    /// to the resources.
    watched: std.EnumArray(Watch, Watched) = .initFill(.{}),
    /// Bumped by every change for this listener: the futex its task waits on.
    version: std.atomic.Value(u32) = .init(0),
    /// Kinds changed and not yet written.
    pending: std.atomic.Value(u8) = .init(0),
    /// Private: guards `watched`.
    mutex: Io.Mutex = .init,

    fn mark(l: *Listener, io: Io, kind: Kind) void {
        _ = l.pending.fetchOr(@as(u8, 1) << @backingInt(kind), .release);
        _ = l.version.fetchAdd(1, .release);
        io.futexWake(u32, &l.version.raw, 1);
    }

    /// Waits until something is pending, the hub closes, `timeout` passes
    /// (null), or the task is canceled. Returns the version seen, to wait
    /// past next time.
    pub fn wait(l: *Listener, io: Io, hub: *const Hub, seen: u32, timeout: Io.Timeout) Io.Cancelable!?u32 {
        const now = l.version.load(.acquire);
        if (now != seen or hub.closed.load(.acquire)) return now;
        try io.futexWaitTimeout(u32, &l.version.raw, seen, timeout);
        const after = l.version.load(.acquire);
        if (after != seen or hub.closed.load(.acquire)) return after;
        return null;
    }

    /// The kinds changed since the last call, cleared.
    pub fn takeLists(l: *Listener) std.EnumSet(Kind) {
        const bits = l.pending.swap(0, .acquire);
        var set: std.EnumSet(Kind) = .empty;
        inline for (@typeInfo(Kind).@"enum".field_names) |name| {
            const k = @field(Kind, name);
            if (bits & (@as(u8, 1) << @backingInt(k)) != 0) set.insert(k);
        }
        return set;
    }

    /// The watched names of `which` changed since the last call, cleared,
    /// as copies on `arena`.
    pub fn takeChanged(l: *Listener, io: Io, arena: Allocator, which: Watch) (Allocator.Error || Io.Cancelable)![]const []const u8 {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const w = l.watched.getPtr(which);
        var out: std.ArrayList([]const u8) = .empty;
        var it = w.changed.iterator(.{});
        while (it.next()) |i| try out.append(arena, try arena.dupe(u8, w.names.items[i]));
        w.changed.unsetAll();
        return out.items;
    }

    /// Watches `name` too (for resources, also a legacy
    /// `resources/subscribe`), up to `max` of its kind.
    pub fn watch(l: *Listener, io: Io, gpa: Allocator, which: Watch, name: []const u8, max: usize) (Allocator.Error || Io.Cancelable || error{TooMany})!void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const w = l.watched.getPtr(which);
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
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const w = l.watched.getPtr(which);
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
        for (&l.watched.values) |*w| w.deinit(gpa);
    }
};

/// Every open listener of a server.
pub const Hub = struct {
    mutex: Io.Mutex = .init,
    listeners: std.ArrayList(*Listener) = .empty,
    /// Set when the server closes: every listener's task ends its stream.
    closed: std.atomic.Value(bool) = .init(false),

    pub const AddError = Allocator.Error || Io.Cancelable || error{TooMany};

    /// Registers `l`, which the caller keeps until `remove`.
    pub fn add(h: *Hub, io: Io, gpa: Allocator, l: *Listener, max: usize) AddError!void {
        try h.mutex.lock(io);
        defer h.mutex.unlock(io);
        if (h.listeners.items.len >= max) return error.TooMany;
        try h.listeners.append(gpa, l);
    }

    pub fn remove(h: *Hub, io: Io, l: *Listener) void {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items, 0..) |x, i| if (x == l) {
            _ = h.listeners.swapRemove(i);
            return;
        };
    }

    /// A list changed: every listener that asked for `kind` learns it.
    pub fn listChanged(h: *Hub, io: Io, kind: Kind) void {
        aegis.assert.pre(kind != .resource and kind != .task, "a resource's update and a task's change name what changed");
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items) |l| if (l.lists.contains(kind)) l.mark(io, kind);
    }

    /// The resource or task `name` changed: every listener watching it
    /// learns it.
    pub fn changed(h: *Hub, io: Io, which: Watch, name: []const u8) void {
        const kind: Kind = switch (which) {
            .resource => .resource,
            .task => .task,
        };
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items) |l| {
            l.mutex.lockUncancelable(io);
            defer l.mutex.unlock(io);
            const w = l.watched.getPtr(which);
            for (w.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
                w.changed.set(i);
                l.mark(io, kind);
            };
        }
    }

    /// Ends every stream: each listener's task sees `closed` and returns.
    pub fn close(h: *Hub, io: Io) void {
        h.closed.store(true, .release);
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items) |l| {
            _ = l.version.fetchAdd(1, .release);
            io.futexWake(u32, &l.version.raw, 1);
        }
    }

    pub fn deinit(h: *Hub, gpa: Allocator) void {
        h.listeners.deinit(gpa);
    }
};
