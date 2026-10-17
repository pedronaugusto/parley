//! README.md's Usage blocks, built and run by the tests.
const std = @import("std");
const parley = @import("parley");

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try envelope(arena);
}

// --- README:usage ---
fn envelope(arena: std.mem.Allocator) !void {
    // A message as a peer sent it, told apart without reading what it carries.
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}";
    var fault: parley.wire.Fault = .{};
    const message = parley.wire.decode(arena, line, .{ .fault = &fault }) catch {
        // Refused: answer with the code and the id the fault names.
        var buffer: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try parley.wire.writeFailure(&w, fault.id, fault.code, fault.reason, null);
        return;
    };
    const request = message.request;
    std.debug.assert(std.mem.eql(u8, request.method, "tools/call"));

    // The answer, around a result its caller writes.
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try parley.wire.writeResult(&w, request.id, "{\"resultType\":\"complete\",\"content\":[]}");
}
// --- README:usage ---
