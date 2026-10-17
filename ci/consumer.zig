//! A consumer imports both modules and reaches every part with only their
//! runtime dependencies.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");

pub fn main() !void {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try parley.wire.writeResult(&w, .{ .integer = 1 }, "{}");
    const message = try parley.wire.decode(std.heap.page_allocator, w.buffered(), .{});
    std.debug.assert(message == .result);
    std.debug.assert(http.headers.plain("tools/call"));
}
