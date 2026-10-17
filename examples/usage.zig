//! README.md's Usage blocks, built and run by the tests.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");
const uplink = @import("uplink");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var server = try newServer(gpa, io);
    defer server.deinit();
    try overStdio(io, gpa, &server);
    try overHttp(io, gpa, &server);
}

// --- README:server ---
/// A tool's arguments and result are Zig types: their JSON Schemas, in
/// `tools/list`, are derived from them when the program is compiled.
const Forecast = struct {
    city: []const u8,
    days: u8 = 1,

    pub const strand = .{ .fields = .{
        .city = .{ .description = "The city to forecast" },
        .days = .{ .range = .{ .min = 1, .max = 7 } },
    } };
};

const Weather = struct { city: []const u8, celsius: f64 };

fn forecast(call: *parley.Call, args: Forecast) parley.Call.Error!Weather {
    // Progress and log lines go on the request's own stream, when asked for.
    try call.progress(1, 1, "asked the sky");
    return .{ .city = args.city, .celsius = 21.5 };
}

/// Asks the user through the client, and continues once it is answered.
fn greet(call: *parley.Call) parley.Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{
        .message = "What should I call you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(if (answer.action == .accept) "hello" else "hello, stranger");
}

fn newServer(gpa: std.mem.Allocator, io: Io) !parley.Server {
    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "weather", .version = "1.0.0" },
        .cache = .{ .tools = .{ .ttl = .literal("5m") } },
    });
    errdefer server.deinit();
    try server.addTool(io, .{ .name = "forecast", .description = "The weather in a city" }, forecast);
    try server.addTool(io, .{ .name = "greet", .description = "Greets the user by name" }, greet);
    return server;
}
// --- README:server ---

fn overStdio(io: Io, gpa: std.mem.Allocator, server: *parley.Server) !void {
    var in: Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}}}\n");
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // --- README:stdio ---
    // A server a client launches: one message a line on stdin and stdout,
    // both eras, until the client closes stdin.
    try parley.stdio.serve(io, gpa, server, &in, &out.writer, .{});
    // --- README:stdio ---
    std.debug.assert(std.mem.find(u8, out.written(), "\"protocolVersion\":\"2025-06-18\"") != null);
}

fn overHttp(io: Io, gpa: std.mem.Allocator, server: *parley.Server) !void {
    // --- README:http ---
    // Streamable HTTP: the endpoint is an uplink handler, mounted at a path.
    var endpoint: http.Endpoint = .init(gpa, server, .{});
    defer endpoint.deinit();
    var router: uplink.server.Router = .init(gpa);
    defer router.deinit();
    try router.add("/mcp", endpoint.handler());
    var web: uplink.Server = .init(gpa, .{}, router.handler());
    defer web.deinit(io);
    var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var serving = try io.concurrent(uplink.Server.serve, .{ &web, io, &listener });
    defer {
        web.shutdown(io);
        // glint-ignore: Z026 -- serve ends with the shutdown; the example only shows it starting
        serving.await(io) catch {};
    }
    // --- README:http ---
}
