//! The client the official conformance suite runs (`npx
//! @modelcontextprotocol/conformance client --command "<this program>"
//! --scenario <name>`): it connects to the server URL it is given last,
//! lists the tools, and calls them, with the arguments the scenario's
//! context gives (`MCP_CONFORMANCE_CONTEXT`) or with none. It answers what
//! a server asks: forms with their defaults, a model's answer, no roots.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");
const uplink = @import("uplink");
const strand = @import("strand");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = parley.types;
const Raw = strand.json.Raw;

/// Accepts every form, filling each field the schema gives no default with
/// a value of its type (the client fills the defaults itself).
fn elicit(context: ?*anyopaque, _: Io, arena: Allocator, params: []const u8) parley.Client.HandlerError!types.ElicitResult {
    const scenario: *const []const u8 = @ptrCast(@alignCast(context.?)); // safe: main passes its scenario's name
    // Defaults are the client's to apply: the user answered nothing.
    if (std.mem.find(u8, scenario.*, "defaults") != null) return .{ .action = .accept, .content = .{ .bytes = "{}" } };
    const Form = struct { requestedSchema: struct { properties: ?Raw = null } = .{} };
    const form = strand.json.parseLeaky(Form, arena, params, types.read_options) catch return .{ .action = .accept, .content = .{ .bytes = "{}" } };
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    if (form.requestedSchema.properties) |properties| {
        var members: strand.json.Members = undefined;
        members.init(properties.bytes, .{});
        var first = true;
        while (members.next() catch null) |p| {
            const Field = struct { type: []const u8 = "string", default: ?Raw = null };
            const f = strand.json.parseLeaky(Field, arena, p.value, types.read_options) catch continue;
            if (f.default != null) continue;
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            w.writeAll(properties.bytes[p.start..p.value_start]) catch return error.OutOfMemory;
            const value = if (std.mem.eql(u8, f.type, "boolean")) "true" else if (std.mem.eql(u8, f.type, "integer") or std.mem.eql(u8, f.type, "number")) "1" else if (std.mem.eql(u8, f.type, "array")) "[]" else "\"parley\"";
            w.writeAll(value) catch return error.OutOfMemory;
        }
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return .{ .action = .accept, .content = .{ .bytes = out.written() } };
}

fn sample(_: ?*anyopaque, _: Io, _: Allocator, _: []const u8) parley.Client.HandlerError!types.CreateMessageResult {
    return .{ .role = .assistant, .content = .{ .bytes = "{\"type\":\"text\",\"text\":\"Paris\"}" }, .model = "parley-conformance", .stop_reason = "endTurn" };
}

fn roots(_: ?*anyopaque, _: Io, _: Allocator) parley.Client.HandlerError!types.ListRootsResult {
    return .{ .roots = &.{} };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const url = args[args.len - 1];
    const scenario: []const u8 = init.environ_map.get("MCP_CONFORMANCE_SCENARIO") orelse "";

    var web: uplink.Client = .init(gpa, .{});
    defer web.deinit(io);
    var remote: http.Transport = .init(gpa, &web, url);
    defer remote.deinit();
    defer remote.close(io);
    // The suite names the revision a scenario runs at: the client speaks it
    // alone, as the suite asks.
    const asked: ?parley.Revision = if (init.environ_map.get("MCP_CONFORMANCE_PROTOCOL_VERSION")) |v| parley.Revision.named(v) else null;
    const only = [1]parley.Revision{asked orelse .@"2026-07-28"};
    var client: parley.Client = .init(gpa, remote.transport(), .{
        .info = .{ .name = "parley-conformance-client", .version = "1.0.0" },
        .revisions = if (asked != null) &only else &.{ .@"2026-07-28", .@"2025-11-25", .@"2025-06-18" },
        .handlers = .{ .context = @ptrCast(@constCast(&scenario)), .elicit = elicit, .sample = sample, .roots = roots }, // safe: elicit casts it back to this type
    });
    defer client.deinit();
    try client.connect(io);

    const listed = try client.list(io, arena, "tools/list", null, null);
    const Context = struct { toolCalls: []const struct { name: []const u8, arguments: Raw = .{ .bytes = "{}" } } = &.{} };
    const context: Context = if (init.environ_map.get("MCP_CONFORMANCE_CONTEXT")) |raw|
        strand.json.parseLeaky(Context, arena, raw, types.read_options) catch .{}
    else
        .{};
    if (context.toolCalls.len != 0) {
        for (context.toolCalls) |call| _ = client.callTool(io, arena, call.name, call.arguments, null) catch |err| std.log.warn("{s}: {t}", .{ call.name, err });
        return;
    }
    const Listed = struct { tools: []const struct { name: []const u8 } = &.{} };
    const tools = (strand.json.parseLeaky(Listed, arena, listed, types.read_options) catch Listed{}).tools;
    if (std.mem.eql(u8, scenario, "initialize") or std.mem.eql(u8, scenario, "tools_call") or std.mem.eql(u8, scenario, "tools-call")) {
        if (tools.len != 0) _ = try client.callTool(io, arena, tools[0].name, .{ .a = 2, .b = 3 }, null);
        return;
    }
    if (std.mem.eql(u8, scenario, "json-schema-ref-no-deref") or std.mem.eql(u8, scenario, "request-metadata")) return;
    // Every other scenario: each tool, once, with no arguments.
    for (tools) |tool| _ = client.callTool(io, arena, tool.name, .{}, null) catch |err| std.log.warn("{s}: {t}", .{ tool.name, err });
}
