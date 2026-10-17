//! A consumer imports the one module and reaches every part with only its
//! runtime dependencies.
const std = @import("std");
const parley = @import("parley");

pub fn main() !void {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try parley.wire.writeResult(&w, .{ .integer = 1 }, "{}");
    const message = try parley.wire.decode(std.heap.page_allocator, w.buffered(), .{});
    std.debug.assert(message == .result);
}
