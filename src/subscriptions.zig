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
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The kinds of change a listener can ask for.
pub const Kind = enum(u3) {
    tools,
    prompts,
    resources,
    /// A watched resource was updated (its bit says which).
    resource,
};

/// One open stream.
pub const Listener = struct {
    /// The `subscriptions/listen` request's id, which every notification on
    /// the stream carries; null for a legacy session's stream, whose
    /// notifications carry none.
    id: ?wire.Id,
    /// The kinds of list change asked for.
    lists: std.EnumSet(Kind),
    /// The resources watched, as given. A legacy session adds to them.
    uris: std.ArrayList([]const u8) = .empty,
    /// Bumped by every change for this listener: the futex its task waits on.
    version: std.atomic.Value(u32) = .init(0),
    /// Lists changed and not yet written.
    pending: std.atomic.Value(u8) = .init(0),
    /// One bit per entry of `uris`: updated and not yet written.
    updated: std.DynamicBitSetUnmanaged = .{},
    /// Private: guards `uris` and `updated`.
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

    /// The lists changed since the last call, cleared.
    pub fn takeLists(l: *Listener) std.EnumSet(Kind) {
        const bits = l.pending.swap(0, .acquire);
        var set: std.EnumSet(Kind) = .empty;
        inline for (@typeInfo(Kind).@"enum".field_names) |name| {
            const k = @field(Kind, name);
            if (bits & (@as(u8, 1) << @backingInt(k)) != 0) set.insert(k);
        }
        return set;
    }

    /// The watched resources updated since the last call, cleared, as
    /// copies on `arena`.
    pub fn takeUpdated(l: *Listener, io: Io, arena: Allocator) (Allocator.Error || Io.Cancelable)![]const []const u8 {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        var out: std.ArrayList([]const u8) = .empty;
        var it = l.updated.iterator(.{});
        while (it.next()) |i| try out.append(arena, try arena.dupe(u8, l.uris.items[i]));
        l.updated.unsetAll();
        return out.items;
    }

    /// Watches `uri` too (a legacy `resources/subscribe`), up to `max`.
    pub fn watch(l: *Listener, io: Io, gpa: Allocator, uri: []const u8, max: usize) (Allocator.Error || Io.Cancelable || error{TooMany})!void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        for (l.uris.items) |u| if (std.mem.eql(u8, u, uri)) return;
        if (l.uris.items.len >= max) return error.TooMany;
        try l.updated.resize(gpa, l.uris.items.len + 1, false);
        const copy = try gpa.dupe(u8, uri);
        errdefer gpa.free(copy);
        try l.uris.append(gpa, copy);
    }

    /// Stops watching `uri` (a legacy `resources/unsubscribe`).
    pub fn unwatch(l: *Listener, io: Io, gpa: Allocator, uri: []const u8) Io.Cancelable!void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        for (l.uris.items, 0..) |u, i| if (std.mem.eql(u8, u, uri)) {
            gpa.free(u);
            _ = l.uris.orderedRemove(i);
            // The bits after `i` move down one.
            var k = i;
            while (k + 1 < l.updated.bit_length) : (k += 1) l.updated.setValue(k, l.updated.isSet(k + 1));
            l.updated.resize(gpa, l.uris.items.len, false) catch unreachable; // unreachable: shrinking never allocates
            return;
        };
    }

    pub fn deinit(l: *Listener, gpa: Allocator) void {
        for (l.uris.items) |u| gpa.free(u);
        l.uris.deinit(gpa);
        l.updated.deinit(gpa);
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
        aegis.assert.pre(kind != .resource, "a resource's update names the resource");
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items) |l| if (l.lists.contains(kind)) l.mark(io, kind);
    }

    /// The resource `uri` was updated: every listener watching it learns it.
    pub fn resourceUpdated(h: *Hub, io: Io, uri: []const u8) void {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.listeners.items) |l| {
            l.mutex.lockUncancelable(io);
            defer l.mutex.unlock(io);
            for (l.uris.items, 0..) |u, i| if (std.mem.eql(u8, u, uri)) {
                l.updated.set(i);
                l.mark(io, .resource);
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
