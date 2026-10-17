//! parley.process: an MCP server launched as a child process, a client on
//! its standard streams (conduit).
//!
//! `Child.spawn` starts the program on pipes and a `parley.Client` on them,
//! one message a line; `Child.close` (or `deinit`) ends it as stdio's
//! shutdown says: its input closed, a grace to exit, then asked to stop,
//! then killed, and what it started ended with it. Its standard error is the caller's to choose:
//! this process's own, the null device, a file, or the latest bytes kept
//! for a diagnosis.
const std = @import("std");
const aegis = @import("aegis");
const conduit = @import("conduit");
const parley = @import("parley");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How a server process ended.
pub const Term = conduit.Term;
/// A span given to a server process: conduit's, written `.literal("2s")`.
pub const Duration = conduit.Duration;
/// Whether a server ended as one that did its job does: exited, status 0.
pub const succeeded = conduit.succeeded;
/// The status a server exited with, or `null` if a signal ended it.
pub const exitCode = conduit.exitCode;
/// Whether what the server starts outlives it.
pub const Descendants = conduit.Child.Descendants;

/// Where the server's standard error goes. stdio leaves it to the client:
/// a server may write anything there, logs as a rule.
pub const Stderr = union(enum) {
    /// This process's own: what the server logs is seen where this
    /// program's own is.
    inherit,
    /// The null device.
    ignore,
    /// A file the caller opened and keeps open until `spawn` returns.
    file: Io.File,
    /// Read on a task of the child's own; the latest bytes up to this many
    /// are kept, for `Child.stderrTail` (a server that failed to start says
    /// why there).
    kept: aegis.units.Bytes(u32),
};

pub const Options = struct {
    /// The program and its arguments; a bare name is looked up in `PATH`.
    argv: []const []const u8,
    /// The server's working directory; `null` is this process's.
    cwd: ?[]const u8 = null,
    /// The server's environment; `null` is this process's. conduit's
    /// `environ.inherit` builds one with variables set or removed.
    environ: ?*const std.process.Environ.Map = null,
    stderr: Stderr = .inherit,
    /// The client on the server's streams.
    client: parley.Client.Options,
    /// How long the server has to exit once its input is closed, and again
    /// once it is asked to stop, before it is killed.
    grace: Duration = .literal("2s"),
    /// `.contain`: what the server started ends with it (a server run by a
    /// launcher, `npx` or `uvx`, is the launcher's child).
    descendants: Descendants = .contain,
};

/// A server running as a child process, and the client that talks to it.
pub const Child = struct {
    gpa: Allocator,
    /// The client on the server's streams: `client.connect` first.
    client: parley.Client,
    /// Private: the process, its streams, and the channel over them.
    process: conduit.Child,
    channel: parley.stdio.Channel,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buffer: [64 * 1024]u8,
    write_buffer: [64 * 1024]u8,
    grace: Duration,
    descendants: Descendants,
    closed: bool = false,
    /// Private: the server's standard error, when kept.
    kept: ?Kept,

    pub const SpawnError = conduit.Child.SpawnError || Io.ConcurrentError;

    /// Starts the server, and the client's reading of its output. The
    /// client is not connected: `client.connect` learns the server's era.
    pub fn spawn(gpa: Allocator, io: Io, options: Options) SpawnError!*Child {
        const c = try gpa.create(Child);
        errdefer gpa.destroy(c);
        c.process = try conduit.Child.spawn(gpa, io, .{
            .argv = options.argv,
            .cwd = options.cwd,
            .environ = options.environ,
            .descendants = options.descendants,
            .stdio = .{ .streams = .{
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = switch (options.stderr) {
                    .inherit => .inherit,
                    .ignore => .ignore,
                    .file => |f| .{ .file = f },
                    .kept => .pipe,
                },
            } },
        });
        errdefer {
            // glint-ignore: Z026 -- a child that could not be given its client is ended however that goes
            _ = c.process.killWait(io, .fromRaw(0)) catch {};
            c.process.deinit(io);
        }
        c.gpa = gpa;
        c.grace = options.grace;
        c.descendants = options.descendants;
        c.closed = false;
        // unreachable: both pipes were asked for, and spawn made them
        c.reader = c.process.stdoutReader(io, &c.read_buffer) orelse unreachable;
        c.writer = c.process.stdinWriter(io, &c.write_buffer) orelse unreachable;
        c.channel = .init(gpa, &c.reader.interface, &c.writer.interface);
        c.client = .init(gpa, c.channel.transport(), options.client);
        errdefer c.client.deinit();
        c.kept = switch (options.stderr) {
            .kept => |limit| try Kept.init(gpa, limit.raw()),
            else => null,
        };
        errdefer if (c.kept) |*k| k.deinit(gpa);
        try c.channel.start(io, &c.client);
        errdefer c.channel.deinit(io);
        if (c.kept) |*k| k.task = try io.concurrent(drain, .{ c, io });
        return c;
    }

    pub const CloseError = conduit.Child.KillWaitError;

    /// Ends the server: its input closed (what is sent from now on fails
    /// `Closed`), `grace` for it to exit, then asked to stop and `grace`
    /// again, then killed. Not a cancelation point: it finishes within
    /// twice the grace. Once is enough; `deinit` frees the child after.
    pub fn close(c: *Child, io: Io) CloseError!Term {
        std.debug.assert(!c.closed);
        c.closed = true;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        c.channel.end(io);
        c.process.closeStdin(io);
        const exited = try c.process.waitTimeout(io, .{ .duration = .{ .raw = c.grace.toIoDuration(), .clock = .awake } });
        const term = exited orelse try c.process.killWait(io, c.grace);
        try c.process.finish(io);
        // What it started ended with it: its standard error is at its end,
        // and what it wrote last is all kept.
        if (c.kept) |*k| if (c.descendants == .contain) if (k.task) |*task| {
            task.await(io);
            k.task = null;
        };
        return term;
    }

    /// Frees the child, ending the server first if `close` did not.
    pub fn deinit(c: *Child, io: Io) void {
        // glint-ignore: Z026 -- the end of a child nobody closed reports nothing; `close` is the call that does
        if (!c.closed) _ = c.close(io) catch {};
        // The server has ended: its output is at its end, or the reading is
        // stopped; then nothing borrows the streams the process closes.
        c.channel.deinit(io);
        if (c.kept) |*k| {
            if (k.task) |*task| task.cancel(io);
            k.deinit(c.gpa);
        }
        c.process.deinit(io);
        c.client.deinit();
        c.gpa.destroy(c);
    }

    /// The latest bytes the server wrote to its standard error, up to
    /// `buffer.len`, when `Options.stderr` keeps them; empty otherwise.
    /// After `close`, all it wrote to its end.
    pub fn stderrTail(c: *Child, io: Io, buffer: []u8) []u8 {
        const k = &(c.kept orelse return buffer[0..0]);
        return k.tail(io, buffer);
    }

    /// The server's process id while it runs.
    pub fn processId(c: *const Child) ?conduit.Child.Id {
        return c.process.processId();
    }

    fn drain(c: *Child, io: Io) void {
        const k = &c.kept.?;
        // unreachable: `.kept` asked for the pipe
        const file = c.process.stderrFile() orelse unreachable;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&buffer}) catch return;
            if (n == 0) return;
            k.append(io, buffer[0..n]);
        }
    }
};

/// The latest bytes of a stream, up to a limit: a ring.
const Kept = struct {
    mutex: Io.Mutex = .init,
    ring: []u8,
    /// Bytes ever written; the ring holds the last `ring.len` of them.
    written: u64 = 0,
    task: ?Io.Future(void) = null,

    fn init(gpa: Allocator, limit: u32) Allocator.Error!Kept {
        return .{ .ring = try gpa.alloc(u8, limit) };
    }

    fn deinit(k: *Kept, gpa: Allocator) void {
        gpa.free(k.ring);
    }

    fn append(k: *Kept, io: Io, bytes: []const u8) void {
        if (k.ring.len == 0) return;
        k.mutex.lockUncancelable(io);
        defer k.mutex.unlock(io);
        const keep = bytes[bytes.len -| k.ring.len..];
        k.written += bytes.len - keep.len;
        for (keep) |b| {
            k.ring[@intCast(k.written % k.ring.len)] = b;
            k.written += 1;
        }
    }

    fn tail(k: *Kept, io: Io, buffer: []u8) []u8 {
        k.mutex.lockUncancelable(io);
        defer k.mutex.unlock(io);
        const held: usize = @intCast(@min(k.written, k.ring.len));
        const n = @min(held, buffer.len);
        for (buffer[0..n], 0..) |*b, i| {
            const at = k.written - n + i;
            b.* = k.ring[@intCast(at % k.ring.len)];
        }
        return buffer[0..n];
    }
};

test "the latest bytes are kept" {
    const io = std.testing.io;
    var kept: Kept = try .init(std.testing.allocator, 4);
    defer kept.deinit(std.testing.allocator);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", kept.tail(io, &buffer));
    kept.append(io, "ab");
    try std.testing.expectEqualStrings("ab", kept.tail(io, &buffer));
    kept.append(io, "cdef");
    try std.testing.expectEqualStrings("cdef", kept.tail(io, &buffer));
    kept.append(io, "g");
    try std.testing.expectEqualStrings("defg", kept.tail(io, &buffer));
    kept.append(io, "0123456789");
    try std.testing.expectEqualStrings("6789", kept.tail(io, &buffer));
    try std.testing.expectEqualStrings("89", kept.tail(io, buffer[0..2]));
}

test {
    _ = @import("process_test.zig");
}
