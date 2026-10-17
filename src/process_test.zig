//! A real server process: the fixture server (src/testing/server.zig),
//! built by the tests' build and named by `test_options`.
const std = @import("std");
const parley = @import("parley");
const process = @import("process.zig");
const options = @import("test_options");

const testing = std.testing;
const Io = std.Io;

const client_options: parley.Client.Options = .{ .info = .{ .name = "c", .version = "1" } };

test "a server process answers its client, and ends when its input does" {
    const io = testing.io;
    const child = try process.Child.spawn(testing.allocator, io, .{
        .argv = &.{options.server},
        .client = client_options,
        .stderr = .{ .kept = .literal("4KiB") },
    });
    defer child.deinit(io);
    try child.client.connect(io);
    try testing.expectEqual(parley.Client.Era.modern, child.client.era);
    try testing.expectEqualStrings("parley-fixture", child.client.server_info.?.name);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const echoed = try child.client.callTool(io, arena.allocator(), "echo", .{ .text = "over a pipe" }, null);
    try testing.expectEqualStrings("over a pipe", echoed.content[0].text.text);
    const term = try child.close(io);
    try testing.expectEqual(@as(?u32, 0), process.exitCode(term));
    var tail: [64]u8 = undefined;
    try testing.expectEqualStrings("ready\n", child.stderrTail(io, &tail));
}

test "a server that stays after its input ends is asked to stop" {
    const io = testing.io;
    const child = try process.Child.spawn(testing.allocator, io, .{
        .argv = &.{ options.server, "--linger" },
        .client = client_options,
        .stderr = .ignore,
        .grace = .literal("100ms"),
    });
    defer child.deinit(io);
    try child.client.connect(io);
    const term = try child.close(io);
    try testing.expect(!process.succeeded(term));
}

test "a request to a server that has gone fails Closed" {
    const io = testing.io;
    const child = try process.Child.spawn(testing.allocator, io, .{
        .argv = &.{ options.server, "--exit" },
        .client = client_options,
        .stderr = .ignore,
    });
    defer child.deinit(io);
    try testing.expectError(error.Closed, child.client.connect(io));
}

test "a program that is not there is not spawned" {
    try testing.expectError(error.FileNotFound, process.Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{"parley-no-such-program-anywhere"},
        .client = client_options,
    }));
}
