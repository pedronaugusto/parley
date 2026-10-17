//! A consumer imports the four modules and reaches every part with only
//! their runtime dependencies.
const std = @import("std");
const parley = @import("parley");
const wire_limits = parley.wire.limitsFor(parley.wire.default_message);
const http = @import("parley.http");
const process = @import("parley.process");
const oauth = @import("parley.oauth");

pub fn main() !void {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try parley.wire.writeResult(&w, .{ .integer = 1 }, "{}");
    const message = try parley.wire.decode(std.heap.page_allocator, w.buffered(), .{ .limits = wire_limits });
    std.debug.assert(message == .result);
    std.debug.assert(http.headers.plain("tools/call"));
    const options: process.Options = .{ .argv = &.{"server"}, .client = .{ .info = .{ .name = "c", .version = "1" } } };
    std.debug.assert(options.descendants == .contain);
    var location: [128]u8 = undefined;
    var l: std.Io.Writer = .fixed(&location);
    try oauth.ResourceMetadata.location(&l, "https://mcp.example/mcp");
    std.debug.assert(std.mem.endsWith(u8, l.buffered(), "/.well-known/oauth-protected-resource/mcp"));
}
