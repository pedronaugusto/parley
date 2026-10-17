//! MCP's authorization end to end over loopback: an authorization server,
//! an MCP server whose endpoint a guard holds to its tokens, and a client
//! that signs in when the server asks, then steps up for a tool that needs
//! more.
const std = @import("std");
const uplink = @import("uplink");
const clearance = @import("clearance");
const oauth = @import("clearance.oauth");
const cloak = @import("cloak");
const parley = @import("parley");
const http = @import("parley.http");
const Authorizer = @import("Authorizer.zig");
const Guard = @import("Guard.zig");
const ResourceMetadata = @import("ResourceMetadata.zig");

const testing = std.testing;
const Io = std.Io;
const form = uplink.wire.form;

/// RFC 8037 A.1's Ed25519 key, PKCS#8, and its public JWK.
const ed25519_der_prefix = "302e020100300506032b657004220420";
const ed25519_d = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A";
const ed25519_x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";

/// An authorization server on 127.0.0.1, serving from a task of its own.
/// What it was asked is kept for the tests to check.
const Provider = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    http: uplink.Server,
    listener: Io.net.Server,
    serving: Io.Future(uplink.Server.ServeError!void),
    base_buffer: [64]u8 = undefined,
    base: []const u8 = "",

    // Guarded by `mutex`.
    challenge: [43]u8 = undefined,
    scope_buffer: [128]u8 = undefined,
    scope: []const u8 = "",
    resource_buffer: [128]u8 = undefined,
    resource: []const u8 = "",
    registrations: u32 = 0,
    application_type_named: bool = false,
    sign_ins: u32 = 0,
    refreshes: u32 = 0,

    fn start(p: *Provider, io: Io) !void {
        p.* = .{ .gpa = testing.allocator, .http = undefined, .listener = undefined, .serving = undefined };
        p.listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        p.base = try std.mem.print(&p.base_buffer, "http://127.0.0.1:{d}", .{p.listener.socket.address.getPort()});
        p.http = .init(testing.allocator, .{}, .init(p, handle));
        p.serving = io.concurrent(uplink.Server.serve, .{ &p.http, io, &p.listener }) catch return error.SkipZigTest;
    }

    fn stop(p: *Provider, io: Io) void {
        p.http.shutdown(io);
        // glint-ignore: Z026 -- serve ends with the shutdown; its result is not what the test checks
        p.serving.await(io) catch {};
        p.http.deinit(io);
        p.listener.deinit(io);
    }

    fn handle(p: *Provider, io: Io, request: *uplink.server.Request, response: *uplink.server.Response) anyerror!void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = request.path;
        try response.header("Content-Type", "application/json");
        if (std.mem.eql(u8, path, "/.well-known/oauth-authorization-server")) {
            return response.send(io, try arena.print(
                \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token","registration_endpoint":"{s}/register",
                \\"jwks_uri":"{s}/jwks","code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"],
                \\"scopes_supported":["mcp:read","mcp:write","offline_access"],"grant_types_supported":["authorization_code","refresh_token"],
                \\"authorization_response_iss_parameter_supported":true}}
            , .{ p.base, p.base, p.base, p.base, p.base }));
        }
        if (std.mem.eql(u8, path, "/register")) {
            const body = try request.collect(arena, io, .limited(8192));
            p.mutex.lockUncancelable(io);
            p.registrations += 1;
            p.application_type_named = std.mem.find(u8, body, "\"application_type\":\"native\"") != null;
            p.mutex.unlock(io);
            response.status = .created;
            return response.send(io, "{\"client_id\":\"registered-1\",\"token_endpoint_auth_method\":\"none\"}");
        }
        if (std.mem.eql(u8, path, "/authorize")) return p.authorize(io, arena, request, response);
        if (std.mem.eql(u8, path, "/token")) return p.token(io, arena, request, response);
        if (std.mem.eql(u8, path, "/jwks")) {
            return response.send(io, "{\"keys\":[{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"k1\",\"x\":\"" ++ ed25519_x ++ "\"}]}");
        }
        response.status = .not_found;
        return response.send(io, "{}");
    }

    /// What a browser would do: the request read, and the redirect back
    /// with a code, the state and `iss`.
    fn authorize(p: *Provider, io: Io, arena: std.mem.Allocator, request: *uplink.server.Request, response: *uplink.server.Response) !void {
        const query = request.query orelse "";
        const challenge = field(arena, query, "code_challenge") orelse return error.NoChallenge;
        const redirect = field(arena, query, "redirect_uri") orelse return error.NoRedirect;
        const state = field(arena, query, "state") orelse return error.NoState;
        const scope = field(arena, query, "scope") orelse "";
        const resource = field(arena, query, "resource") orelse "";
        p.mutex.lockUncancelable(io);
        p.sign_ins += 1;
        @memcpy(&p.challenge, challenge[0..43]);
        p.scope = p.scope_buffer[0..scope.len];
        @memcpy(p.scope_buffer[0..scope.len], scope);
        p.resource = p.resource_buffer[0..resource.len];
        @memcpy(p.resource_buffer[0..resource.len], resource);
        p.mutex.unlock(io);
        var location: std.Io.Writer.Allocating = .init(arena);
        try location.writer.print("{s}?", .{redirect});
        try form.encode(&location.writer, &.{
            .{ .name = "code", .value = "c0de" },
            .{ .name = "state", .value = state },
            .{ .name = "iss", .value = p.base },
        });
        response.status = .found;
        try response.header("Location", location.written());
        return response.send(io, "");
    }

    /// A JWT access token for the scope the sign-in asked, its audience the
    /// resource it named.
    fn token(p: *Provider, io: Io, arena: std.mem.Allocator, request: *uplink.server.Request, response: *uplink.server.Response) !void {
        const body = try request.collect(arena, io, .limited(8192));
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const grant = field(arena, body, "grant_type") orelse "";
        if (std.mem.eql(u8, grant, "refresh_token")) p.refreshes += 1 else {
            const verifier = field(arena, body, "code_verifier") orelse "";
            const expected = oauth.pkce.challengeOf(verifier);
            if (!std.mem.eql(u8, &expected, &p.challenge) or !std.mem.eql(u8, field(arena, body, "resource") orelse "", p.resource)) {
                response.status = .bad_request;
                return response.send(io, "{\"error\":\"invalid_grant\"}");
            }
        }
        const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        var jwt: std.Io.Writer.Allocating = .init(arena);
        try signClaims(p.gpa, io, &jwt.writer, .{ .iss = p.base, .aud = p.resource, .sub = "user-1", .client_id = "registered-1", .scope = p.scope, .exp = now + 600, .iat = now, .jti = "j" });
        return response.send(io, try arena.print("{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":600,\"refresh_token\":\"rt\",\"scope\":\"{s}\"}}", .{ jwt.written(), p.scope }));
    }
};

fn field(arena: std.mem.Allocator, query: []const u8, name: []const u8) ?[]const u8 {
    var it: form.Iterator = .init(query);
    while (it.next()) |pair| {
        const n = form.decode(arena.dupe(u8, pair.name) catch return null);
        if (std.mem.eql(u8, n, name)) return form.decode(arena.dupe(u8, pair.value) catch return null);
    }
    return null;
}

fn signClaims(gpa: std.mem.Allocator, io: Io, out: *std.Io.Writer, claims: anytype) !void {
    var der: [48]u8 = undefined;
    _ = try std.fmt.hexToBytes(der[0..16], ed25519_der_prefix);
    _ = try std.base64.url_safe_no_pad.Decoder.decode(der[16..48], ed25519_d);
    const key = try cloak.PrivateKey.parse(gpa, &der, .{});
    defer key.deinit();
    try clearance.jwt.sign(gpa, io, out, .{ .kid = "k1", .typ = "at+jwt" }, claims, .{ .private = .{ .alg = .eddsa, .key = key } });
}

fn read(_: *parley.Call) error{}![]const u8 {
    return "read";
}

fn write(_: *parley.Call) error{}![]const u8 {
    return "written";
}

/// `write` needs `mcp:write` beyond what every request needs.
fn needs(_: ?*anyopaque, _: std.mem.Allocator, message: ?parley.wire.Message) std.mem.Allocator.Error![]const []const u8 {
    const m = message orelse return &.{};
    if (m != .request or !std.mem.eql(u8, m.request.method, "tools/call")) return &.{};
    if (std.mem.find(u8, m.request.params orelse "", "\"name\":\"write\"") == null) return &.{};
    return &.{"mcp:write"};
}

/// Signs in as a browser would, without one: the authorization URL's
/// redirect read, not followed.
fn signIn(context: ?*anyopaque, io: Io, arena: std.mem.Allocator, url: []const u8) Authorizer.SignInError![]const u8 {
    const web: *uplink.Client = @ptrCast(@alignCast(context.?)); // safe: the test passes its client
    var response = web.send(io, .{ .url = url, .redirects = .none }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Declined,
    };
    defer response.deinit(io);
    return arena.dupe(u8, response.headers.get("Location") orelse return error.Declined);
}

test "a client signs in when the server asks, and steps up for a tool that needs more scope" {
    const gpa = testing.allocator;
    const io = testing.io;
    var provider: Provider = undefined;
    try provider.start(io);
    defer provider.stop(io);
    var web: uplink.Client = .init(gpa, .{});
    defer web.deinit(io);

    // The MCP server, its endpoint behind the guard, its metadata served.
    var core: parley.Server = try .init(gpa, io, .{ .info = .{ .name = "guarded", .version = "0" } });
    defer core.deinit();
    try core.addTool(io, .{ .name = "read" }, read);
    try core.addTool(io, .{ .name = "write" }, write);
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var url_buffer: [64]u8 = undefined;
    const url = try std.mem.print(&url_buffer, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
    var location_buffer: [128]u8 = undefined;
    var location: Io.Writer = .fixed(&location_buffer);
    try ResourceMetadata.location(&location, url);
    var metadata: ResourceMetadata = try .init(gpa, .{ .resource = url, .authorization_servers = &.{provider.base}, .scopes_supported = &.{"mcp:read"} });
    defer metadata.deinit(gpa);
    var jwks_buffer: [96]u8 = undefined;
    var keys = try oauth.RemoteKeySet.init(gpa, try std.mem.print(&jwks_buffer, "{s}/jwks", .{provider.base}), .{});
    defer keys.deinit();
    const verifier: oauth.bearer.Verifier = .{
        .source = .{ .keys = .{ .set = &keys, .algorithms = &.{.eddsa} } },
        .issuer = provider.base,
        .resource = url,
        .resource_metadata = location.buffered(),
    };
    var guard: Guard = .{ .verifier = &verifier, .web = &web, .scopes = &.{"mcp:read"}, .needs = .{ .scopes = needs } };
    var endpoint: http.Endpoint = .init(gpa, &core, .{ .access = guard.access() });
    defer endpoint.deinit();
    var router: uplink.server.Router = .init(gpa);
    defer router.deinit();
    try router.add("/mcp", endpoint.handler());
    const metadata_path = location.buffered()[std.mem.find(u8, location.buffered(), "/.well-known").?..];
    try router.add(metadata_path, metadata.handler());
    var server: uplink.Server = .init(gpa, .{}, router.handler());
    defer server.deinit(io);
    var serving = io.concurrent(uplink.Server.serve, .{ &server, io, &listener }) catch return error.SkipZigTest;
    defer {
        server.shutdown(io);
        // glint-ignore: Z026 -- serve ends with the shutdown; its result is not what the test checks
        serving.await(io) catch {};
    }

    // The client: no token at first, a sign-in on the first 401.
    var authorizer: Authorizer = .init(gpa, &web, url, .{
        .sign_in = .{ .context = &web, .open = signIn },
        .client_name = "parley-test",
    });
    defer authorizer.deinit();
    var remote: http.Transport = .init(gpa, &web, url, .{ .authorization = authorizer.authorization() });
    defer remote.deinit();
    defer remote.close(io);
    var client: parley.Client = .init(gpa, remote.transport(), .{ .info = .{ .name = "parley-test", .version = "0" } });
    defer client.deinit();
    try client.connect(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try client.list(io, arena, "tools/list", null, null);
    _ = try client.callTool(io, arena, "read", .{}, null);
    provider.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(u32, 1), provider.sign_ins);
    try testing.expectEqual(@as(u32, 1), provider.registrations);
    try testing.expect(provider.application_type_named);
    // Everything the resource lists, and a refresh token where the server
    // gives them; the resource named as its metadata names it.
    try testing.expectEqualStrings("mcp:read offline_access", provider.scope);
    try testing.expectEqualStrings(url, provider.resource);
    provider.mutex.unlock(io);

    // A tool that needs a scope the token lacks: a 403, and a step-up that
    // keeps what was granted.
    _ = try client.callTool(io, arena, "write", .{}, null);
    provider.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(u32, 2), provider.sign_ins);
    try testing.expectEqual(@as(u32, 1), provider.registrations);
    try testing.expectEqualStrings("mcp:read offline_access mcp:write", provider.scope);
    provider.mutex.unlock(io);
}
