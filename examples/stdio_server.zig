//! A server a client launches: tools over stdin and stdout. `bay
//! stdio-server` puts it in zig-out/bin; a client such as Claude Code or
//! Codex runs it as an MCP server.
const std = @import("std");
const parley = @import("parley");

fn echo(_: *parley.Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

const Sum = struct { total: i64 };

fn add(call: *parley.Call, args: struct { numbers: []const i64 }) parley.Call.Error!Sum {
    var total: i64 = 0;
    for (args.numbers, 0..) |n, i| {
        total +|= n;
        try call.progress(@floatFromInt(i + 1), @floatFromInt(args.numbers.len), null);
    }
    return .{ .total = total };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var server = try parley.Server.init(init.gpa, io, .{ .info = .{ .name = "parley-example", .version = "0.1.0" } });
    defer server.deinit();
    try server.addTool(io, .{ .name = "echo", .description = "Echoes the text it is given" }, echo);
    try server.addTool(io, .{ .name = "add", .description = "Adds whole numbers" }, add);
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try parley.stdio.serve(io, init.gpa, &server, &stdin.interface, &stdout.interface, .{});
}
