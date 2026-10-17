//! A byte stream between two tasks, for the tests: one writes lines into
//! it, the other reads them through an `Io.Reader` that waits for bytes, so
//! a server under test reads as it would from a process's stdin.
const Pipe = @This();

const std = @import("std");
const Io = std.Io;

io: Io,
queue: Io.Queue(u8),
reader: Io.Reader,
/// What is written here goes into the pipe when flushed.
writer: Io.Writer,

pub fn init(io: Io, storage: []u8, read_buffer: []u8, write_buffer: []u8) Pipe {
    return .{
        .io = io,
        .queue = .init(storage),
        .reader = .{ .vtable = &.{ .stream = stream }, .buffer = read_buffer, .seek = 0, .end = 0 },
        .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buffer },
    };
}

/// Writes `bytes`, waiting for room.
pub fn write(p: *Pipe, bytes: []const u8) !void {
    try p.queue.putAll(p.io, bytes);
}

/// The reader sees the end of the stream once what was written is read.
pub fn close(p: *Pipe) void {
    p.queue.close(p.io);
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const p: *Pipe = @fieldParentPtr("reader", r);
    const dest = limit.slice(try w.writableSliceGreedy(1));
    const n = p.queue.get(p.io, dest, 1) catch |err| switch (err) {
        error.Closed => return error.EndOfStream,
        error.Canceled => return error.ReadFailed,
    };
    w.advance(n);
    return n;
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const p: *Pipe = @fieldParentPtr("writer", w);
    p.queue.putAll(p.io, w.buffered()) catch return error.WriteFailed;
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        p.queue.putAll(p.io, d) catch return error.WriteFailed;
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| p.queue.putAll(p.io, last) catch return error.WriteFailed;
    return n + last.len * splat;
}
