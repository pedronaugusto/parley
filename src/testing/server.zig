//! The server `parley.process`'s tests and the benchmarks launch: `echo`,
//! `sleep` (a long call, canceled at once), and with `--tools <n>` that many
//! more tools with large input schemas. Over stdio by default; with
//! `--port <port>` over Streamable HTTP at `http://127.0.0.1:<port>/mcp`
//! instead, and 2024-11-05's HTTP+SSE at `/sse` beside it. It runs on a reactor runtime, the family's evented `Io`, or with
//! `--io threaded` on std's. It says `ready` on its standard error once it
//! serves; with `--linger` it stays after its input ends, until it is asked
//! to stop; with `--exit` it ends at once.
//!
//! The benchmarks' rivals implement the same arguments and tools, so the one
//! driver measures each the same way.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");
const uplink = @import("uplink");
const reactor = @import("reactor");

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

const Arguments = struct {
    tools: usize = 0,
    linger: bool = false,
    port: ?u16 = null,
    threaded: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var arguments: Arguments = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--linger")) arguments.linger = true;
        if (std.mem.eql(u8, args[i], "--exit")) return;
        if (i + 1 == args.len) continue;
        if (std.mem.eql(u8, args[i], "--tools")) {
            i += 1;
            arguments.tools = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            arguments.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--io")) {
            i += 1;
            arguments.threaded = std.mem.eql(u8, args[i], "threaded");
        }
    }
    if (arguments.threaded) return serve(init.gpa, init.io, arguments);
    // The runtime is large, so it lives on the heap; the server runs on the
    // home thread, as a program's would.
    const runtime = try init.gpa.create(reactor.Runtime);
    defer init.gpa.destroy(runtime);
    try runtime.init(init.gpa, .{ .environ = init.minimal.environ, .report_after = null });
    defer runtime.deinit();
    try runtime.start();
    try serve(init.gpa, runtime.io(), arguments);
}

fn serve(gpa: std.mem.Allocator, io: Io, arguments: Arguments) !void {
    var server = try parley.Server.init(gpa, io, .{ .info = .{ .name = "parley-fixture", .version = "1.0.0" }, .limits = .{ .message = .literal("128MiB") } });
    defer server.deinit();
    try server.addTool(io, .{ .name = "echo", .description = "Echoes the text it is given" }, echo);
    try server.addTool(io, .{ .name = "sleep", .description = "Answers after ms milliseconds" }, sleep);
    if (arguments.tools != 0) {
        const schema = try wideSchema(gpa, 40);
        defer gpa.free(schema);
        var name_buffer: [32]u8 = undefined;
        for (0..arguments.tools) |t| {
            const name = try std.mem.print(&name_buffer, "tool_{d}", .{t});
            try server.addDynamicTool(io, .{ .name = name, .description = "One of many tools with a large input schema", .input_schema = schema }, .{ .call = wideCall });
        }
    }
    var err_buffer: [64]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &err_buffer);
    if (arguments.port) |port| {
        var endpoint: http.Endpoint = .init(gpa, &server, .{});
        defer endpoint.deinit();
        var router: uplink.server.Router = .init(gpa);
        defer router.deinit();
        try router.add("/mcp", endpoint.handler());
        var sse: http.SseEndpoint = .init(gpa, &server, .{});
        defer sse.deinit();
        try router.add("/sse", sse.handler());
        var web: uplink.Server = .init(gpa, .{}, router.handler());
        defer web.deinit(io);
        var listener = try (try Io.net.IpAddress.parse("127.0.0.1", port)).listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);
        try stderr.interface.writeAll("ready\n");
        try stderr.interface.flush();
        return web.serve(io, &listener);
    }
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    try stderr.interface.writeAll("ready\n");
    try stderr.interface.flush();
    // The benchmarks echo a 64 MiB message.
    try parley.stdio.serve(io, gpa, &server, &stdin.interface, &stdout.interface, .{});
    if (arguments.linger) try io.sleep(.fromSeconds(3600), .awake);
}
