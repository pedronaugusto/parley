//! The server `parley.process`'s tests and the benchmarks launch, over
//! stdio: `echo`, `sleep` (a long call, canceled at once), and with
//! `--tools <n>` that many more tools with large input schemas. It says
//! `ready` on its standard error once it serves; with `--linger` it stays
//! after its input ends, until it is asked to stop; with `--exit` it ends
//! at once.
const std = @import("std");
const parley = @import("parley");

const Io = std.Io;

fn echo(_: *parley.Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

fn sleep(call: *parley.Call, args: struct { ms: u32 }) parley.Call.Error![]const u8 {
    call.io.sleep(.fromMilliseconds(args.ms), .awake) catch return error.Canceled;
    return "slept";
}

fn wideCall(_: ?*anyopaque, _: *parley.Call, _: ?[]const u8) parley.Call.Error!parley.ToolResult {
    return .ofText("ok");
}

/// An input schema of `fields` string properties, each described, the
/// shape of a large real tool's.
fn wideSchema(gpa: std.mem.Allocator, fields: usize) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (0..fields) |i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"field_{d}\":{{\"type\":\"string\",\"description\":\"The {d}th setting of the operation, which the server reads as a plain string and checks against its own rules before use.\"}}", .{ i, i });
    }
    try w.writeAll("},\"required\":[\"field_0\"]}");
    return out.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var tools: usize = 0;
    var linger = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--linger")) linger = true;
        if (std.mem.eql(u8, args[i], "--exit")) return;
        if (std.mem.eql(u8, args[i], "--tools") and i + 1 < args.len) {
            i += 1;
            tools = try std.fmt.parseInt(usize, args[i], 10);
        }
    }
    var server = try parley.Server.init(gpa, io, .{ .info = .{ .name = "parley-fixture", .version = "1.0.0" } });
    defer server.deinit();
    try server.addTool(io, .{ .name = "echo", .description = "Echoes the text it is given" }, echo);
    try server.addTool(io, .{ .name = "sleep", .description = "Answers after ms milliseconds" }, sleep);
    if (tools != 0) {
        const schema = try wideSchema(gpa, 40);
        defer gpa.free(schema);
        var name_buffer: [32]u8 = undefined;
        for (0..tools) |t| {
            const name = try std.mem.print(&name_buffer, "tool_{d}", .{t});
            try server.addDynamicTool(io, .{ .name = name, .description = "One of many tools with a large input schema", .input_schema = schema }, .{ .call = wideCall });
        }
    }
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    var err_buffer: [64]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &err_buffer);
    try stderr.interface.writeAll("ready\n");
    try stderr.interface.flush();
    try parley.stdio.serve(io, gpa, &server, &stdin.interface, &stdout.interface, .{});
    if (linger) try io.sleep(.fromSeconds(3600), .awake);
}
