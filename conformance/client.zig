//! The client the official conformance suite runs (`npx
//! @modelcontextprotocol/conformance client --command "<this program>"
//! --scenario <name>`): it connects to the server URL it is given last,
//! lists the tools, and calls them, with the arguments the scenario's
//! context gives (`MCP_CONFORMANCE_CONTEXT`) or with none. It answers what
//! a server asks: forms with their defaults, a model's answer, no roots.
//!
//! Every request goes through parley.oauth's authorizer: a server that asks
//! for a token gets one as MCP's authorization lays out. The suite's
//! authorization server redirects at once, so signing in is reading where
//! the authorization URL redirects to. A scenario that registered the
//! client beforehand gives its credentials in the context.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");
const oauth = @import("parley.oauth");
const clearance = @import("clearance");
const cloak = @import("cloak");
const uplink = @import("uplink");
const strand = @import("strand");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = parley.types;
const Raw = strand.json.Raw;
/// How the program reads what it is given: the client's limits, its message
/// limit the default.
const read_options = types.readOptions(parley.wire.limitsFor(parley.wire.default_message));

/// Accepts every form, filling each field the schema gives no default with
/// a value of its type (the client fills the defaults itself).
fn elicit(context: ?*anyopaque, _: Io, arena: Allocator, params: []const u8) parley.Client.HandlerError!types.ElicitResult {
    const scenario: *const []const u8 = @ptrCast(@alignCast(context.?)); // safe: main passes its scenario's name
    // Defaults are the client's to apply: the user answered nothing.
    if (std.mem.find(u8, scenario.*, "defaults") != null) return .{ .action = .accept, .content = .{ .bytes = "{}" } };
    const Form = struct { requestedSchema: struct { properties: ?Raw = null } = .{} };
    const form = strand.json.parseLeaky(Form, arena, params, read_options) catch return .{ .action = .accept, .content = .{ .bytes = "{}" } };
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    if (form.requestedSchema.properties) |properties| {
        var members: strand.json.Members = undefined;
        members.init(properties.bytes, .{});
        var first = true;
        while (members.next() catch null) |p| {
            const Field = struct { type: []const u8 = "string", default: ?Raw = null };
            const f = strand.json.parseLeaky(Field, arena, p.value, read_options) catch continue;
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

/// Signs in as the suite's authorization server lets a program: the
/// authorization URL answers with a redirect to the redirect URI, code and
/// all, which is read and not followed.
fn signIn(context: ?*anyopaque, io: Io, arena: Allocator, url: []const u8) oauth.Authorizer.SignInError![]const u8 {
    const web: *uplink.Client = @ptrCast(@alignCast(context.?)); // safe: main passes its uplink client
    var response = web.send(io, .{ .url = url, .redirects = .none }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Declined,
    };
    defer response.deinit(io);
    const location = response.headers.get("Location") orelse return error.Declined;
    return arena.dupe(u8, location);
}

/// The client ID metadata document's URL the suite expects of a client
/// that uses one.
const metadata_url = "https://conformance-test.local/client-metadata.json";

/// What a scenario that registered the client beforehand gives.
const Registration = struct {
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    private_key_pem: ?[]const u8 = null,
    signing_algorithm: ?[]const u8 = null,
};

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
    const raw_context = init.environ_map.get("MCP_CONFORMANCE_CONTEXT");
    const registration: Registration = if (raw_context) |raw| strand.json.parseLeaky(Registration, arena, raw, read_options) catch .{} else .{};
    var key: ?cloak.PrivateKey = null;
    defer if (key) |k| k.deinit();
    var registered: [1]oauth.Authorizer.Credentials = undefined;
    var credentials: []const oauth.Authorizer.Credentials = &.{};
    if (registration.client_id) |id| {
        registered[0] = .{ .issuer = registration.issuer, .client_id = id, .secret = registration.client_secret };
        if (registration.private_key_pem) |pem| {
            key = try cloak.PrivateKey.parse(gpa, pem, .{});
            const alg = clearance.Algorithm.parse(registration.signing_algorithm orelse "ES256") orelse return error.UnknownAlgorithm;
            registered[0].private_key_jwt = .{ .signer = .{ .private = .{ .alg = alg, .key = key.? } } };
        }
        credentials = &registered;
    }
    var authorizer: oauth.Authorizer = .init(gpa, &web, url, .{
        .sign_in = .{ .context = &web, .open = signIn },
        .redirect_uri = "http://localhost:3000/callback",
        .client_name = "parley-conformance-client",
        .metadata_url = metadata_url,
        .registered = credentials,
        // A scenario that registered the client without a user: the
        // client's own credentials.
        .grant = if (std.mem.startsWith(u8, scenario, "auth/client-credentials")) .client_credentials else .authorization_code,
    });
    defer authorizer.deinit();
    var remote: http.Transport = .init(gpa, &web, url, .{ .authorization = authorizer.authorization() });
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
    const context: Context = if (raw_context) |raw|
        strand.json.parseLeaky(Context, arena, raw, read_options) catch .{}
    else
        .{};
    if (context.toolCalls.len != 0) {
        for (context.toolCalls) |call| _ = client.callTool(io, arena, call.name, call.arguments, null) catch |err| std.log.warn("{s}: {t}", .{ call.name, err });
        return;
    }
    const Listed = struct { tools: []const struct { name: []const u8 } = &.{} };
    const tools = (strand.json.parseLeaky(Listed, arena, listed, read_options) catch Listed{}).tools;
    if (std.mem.eql(u8, scenario, "initialize") or std.mem.eql(u8, scenario, "tools_call") or std.mem.eql(u8, scenario, "tools-call")) {
        if (tools.len != 0) _ = try client.callTool(io, arena, tools[0].name, .{ .a = 2, .b = 3 }, null);
        return;
    }
    if (std.mem.eql(u8, scenario, "json-schema-ref-no-deref") or std.mem.eql(u8, scenario, "request-metadata")) return;
    if (std.mem.eql(u8, scenario, "json-schema-2020-12-preservation")) {
        // The focal tool's input schema goes back as the client received
        // it, byte for byte, as the echo tool's `schema` argument.
        const Schemas = struct { tools: []const struct { name: []const u8, inputSchema: ?Raw = null } = &.{} };
        const listed_schemas = (strand.json.parseLeaky(Schemas, arena, listed, read_options) catch Schemas{}).tools;
        for (listed_schemas) |tool| if (std.mem.eql(u8, tool.name, "json_schema_2020_12_tool")) {
            const schema = tool.inputSchema orelse return error.NoSchema;
            const arguments: Raw = .{ .bytes = try std.mem.concat(arena, u8, &.{ "{\"schema\":", schema.bytes, "}" }) };
            _ = try client.callTool(io, arena, "json_schema_echo", arguments, null);
        };
        return;
    }
    // Every other scenario: each tool, once, with no arguments.
    for (tools) |tool| _ = client.callTool(io, arena, tool.name, .{}, null) catch |err| std.log.warn("{s}: {t}", .{ tool.name, err });
}
