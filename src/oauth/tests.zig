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
    /// JWT-bearer grants given.
    grants: u32 = 0,
    exchanges: u32 = 0,

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
        if (std.mem.eql(u8, path, "/idp/token")) return p.identityProvider(io, arena, request, response);
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

    /// The enterprise's identity provider (issuer `<base>/idp`): the ID
    /// token `id-token-u1` exchanged for an ID-JAG to the audience asked,
    /// for `ema-client`, the resource and scope asked.
    fn identityProvider(p: *Provider, io: Io, arena: std.mem.Allocator, request: *uplink.server.Request, response: *uplink.server.Response) !void {
        const body = try request.collect(arena, io, .limited(8192));
        p.mutex.lockUncancelable(io);
        p.exchanges += 1;
        p.mutex.unlock(io);
        if (!std.mem.eql(u8, field(arena, body, "subject_token") orelse "", "id-token-u1") or !std.mem.eql(u8, field(arena, body, "client_id") orelse "", "idp-app")) {
            response.status = .bad_request;
            return response.send(io, "{\"error\":\"invalid_grant\"}");
        }
        const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        var jag: std.Io.Writer.Allocating = .init(arena);
        try signTyped(p.gpa, io, &jag.writer, "oauth-id-jag+jwt", .{
            .iss = try std.mem.concat(arena, u8, &.{ p.base, "/idp" }),
            .sub = "u1",
            .aud = field(arena, body, "audience") orelse "",
            .client_id = "ema-client",
            .jti = "jag",
            .iat = now,
            .exp = now + 300,
            .resource = field(arena, body, "resource") orelse "",
            .scope = field(arena, body, "scope"),
        });
        return response.send(io, try arena.print("{{\"access_token\":\"{s}\",\"issued_token_type\":\"urn:ietf:params:oauth:token-type:id-jag\",\"token_type\":\"N_A\"}}", .{jag.written()}));
    }

    /// A JWT access token for the scope the sign-in asked, its audience the
    /// resource it named.
    fn token(p: *Provider, io: Io, arena: std.mem.Allocator, request: *uplink.server.Request, response: *uplink.server.Response) !void {
        const body = try request.collect(arena, io, .limited(8192));
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const grant = field(arena, body, "grant_type") orelse "";
        if (std.mem.eql(u8, grant, "urn:ietf:params:oauth:grant-type:jwt-bearer")) return jwtBearer(p, io, arena, request, body, response);
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

/// A JWT as the grant, verified with the provider's key: an ID-JAG for
/// this server from its identity provider (`/idp`), redeemed by
/// `ema-client`, or a workload's token for this server with no client. Either way a JWT access token for the resource the
/// assertion or the request names, with the scope it carries.
fn jwtBearer(p: *Provider, io: Io, arena: std.mem.Allocator, request: *uplink.server.Request, body: []const u8, response: *uplink.server.Response) !void {
    const assertion = field(arena, body, "assertion") orelse "";
    var keys = try clearance.jwk.KeySet.parse(arena, "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"k1\",\"x\":\"" ++ ed25519_x ++ "\"}", .{});
    defer keys.deinit();
    const scratch = try arena.alloc(u8, clearance.jws.scratchLength(assertion.len));
    const now = Io.Clock.real.now(io);
    const Claims = struct { resource: ?[]const u8 = null, scope: ?[]const u8 = null, client_id: ?[]const u8 = null };
    var resource: []const u8 = field(arena, body, "resource") orelse "";
    var scope: []const u8 = field(arena, body, "scope") orelse "";
    _ = request;
    if (field(arena, body, "client_id")) |client_id| {
        if (!std.mem.eql(u8, client_id, "ema-client")) {
            response.status = .unauthorized;
            return response.send(io, "{\"error\":\"invalid_client\"}");
        }
        const jag = clearance.jwt.verify(Claims, assertion, keys.keys, .{ .algorithms = &.{.eddsa}, .issuer = try std.mem.concat(arena, u8, &.{ p.base, "/idp" }), .audience = p.base, .typ = "oauth-id-jag+jwt" }, now, scratch) catch {
            response.status = .bad_request;
            return response.send(io, "{\"error\":\"invalid_grant\"}");
        };
        if (!std.mem.eql(u8, jag.claims.client_id orelse "", "ema-client")) return response.send(io, "{\"error\":\"invalid_grant\"}");
        resource = jag.claims.resource orelse "";
        scope = jag.claims.scope orelse "";
    } else {
        _ = clearance.jwt.verify(void, assertion, keys.keys, .{ .algorithms = &.{.eddsa}, .audience = p.base }, now, scratch) catch {
            response.status = .bad_request;
            return response.send(io, "{\"error\":\"invalid_grant\"}");
        };
    }
    p.grants += 1;
    const seconds: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    var jwt: std.Io.Writer.Allocating = .init(arena);
    try signClaims(p.gpa, io, &jwt.writer, .{ .iss = p.base, .aud = resource, .sub = "user-1", .client_id = "ema-client", .scope = scope, .exp = seconds + 600, .iat = seconds, .jti = "j" });
    return response.send(io, try arena.print("{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":600}}", .{jwt.written()}));
}

fn field(arena: std.mem.Allocator, query: []const u8, name: []const u8) ?[]const u8 {
    var it: form.Iterator = .init(query);
    while (it.next()) |pair| {
        const n = form.decode(arena.dupe(u8, pair.name) catch return null);
        if (std.mem.eql(u8, n, name)) return form.decode(arena.dupe(u8, pair.value) catch return null);
    }
    return null;
}

fn signClaims(gpa: std.mem.Allocator, io: Io, out: *std.Io.Writer, claims: anytype) !void {
    return signTyped(gpa, io, out, "at+jwt", claims);
}

fn signTyped(gpa: std.mem.Allocator, io: Io, out: *std.Io.Writer, typ: []const u8, claims: anytype) !void {
    var der: [48]u8 = undefined;
    _ = try std.fmt.hexToBytes(der[0..16], ed25519_der_prefix);
    _ = try std.base64.url_safe_no_pad.Decoder.decode(der[16..48], ed25519_d);
    const key = try cloak.PrivateKey.parse(gpa, &der, .{});
    defer key.deinit();
    try clearance.jwt.sign(gpa, io, out, .{ .kid = "k1", .typ = typ }, claims, .{ .private = .{ .alg = .eddsa, .key = key } });
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

/// An MCP server with the tools `read` and `write`, its endpoint behind a
/// guard holding requests to the provider's tokens (`mcp:read`, and
/// `mcp:write` for `write`), its resource metadata served.
const Guarded = struct {
    core: parley.Server,
    listener: Io.net.Server,
    url_buffer: [64]u8,
    url: []const u8,
    location_buffer: [128]u8,
    location: []const u8,
    metadata: ResourceMetadata,
    jwks_buffer: [96]u8,
    keys: oauth.RemoteKeySet,
    verifier: oauth.bearer.Verifier,
    guard: Guard,
    endpoint: http.Endpoint,
    router: uplink.server.Router,
    server: uplink.Server,
    serving: Io.Future(uplink.Server.ServeError!void),

    fn start(g: *Guarded, gpa: std.mem.Allocator, io: Io, web: *uplink.Client, issuer: []const u8) !void {
        g.core = try .init(gpa, io, .{ .info = .{ .name = "guarded", .version = "0" } });
        errdefer g.core.deinit();
        try g.core.addTool(io, .{ .name = "read" }, read);
        try g.core.addTool(io, .{ .name = "write" }, write);
        g.listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        errdefer g.listener.deinit(io);
        g.url = try std.mem.print(&g.url_buffer, "http://127.0.0.1:{d}/mcp", .{g.listener.socket.address.getPort()});
        var location: Io.Writer = .fixed(&g.location_buffer);
        try ResourceMetadata.location(&location, g.url);
        g.location = location.buffered();
        g.metadata = try .init(gpa, .{ .resource = g.url, .authorization_servers = &.{issuer}, .scopes_supported = &.{"mcp:read"} });
        errdefer g.metadata.deinit(gpa);
        g.keys = try oauth.RemoteKeySet.init(gpa, try std.mem.print(&g.jwks_buffer, "{s}/jwks", .{issuer}), .{});
        errdefer g.keys.deinit();
        g.verifier = .{
            .source = .{ .keys = .{ .set = &g.keys, .algorithms = &.{.eddsa} } },
            .issuer = issuer,
            .resource = g.url,
            .resource_metadata = g.location,
        };
        g.guard = .{ .verifier = &g.verifier, .web = web, .scopes = &.{"mcp:read"}, .needs = .{ .scopes = needs } };
        g.endpoint = .init(gpa, &g.core, .{ .access = g.guard.access() });
        errdefer g.endpoint.deinit();
        g.router = .init(gpa);
        errdefer g.router.deinit();
        try g.router.add("/mcp", g.endpoint.handler());
        try g.router.add(g.location[std.mem.find(u8, g.location, "/.well-known").?..], g.metadata.handler());
        g.server = .init(gpa, .{}, g.router.handler());
        errdefer g.server.deinit(io);
        g.serving = io.concurrent(uplink.Server.serve, .{ &g.server, io, &g.listener }) catch return error.SkipZigTest;
    }

    fn stop(g: *Guarded, io: Io) void {
        g.server.shutdown(io);
        // glint-ignore: Z026 -- serve ends with the shutdown; its result is not what the test checks
        g.serving.await(io) catch {};
        g.server.deinit(io);
        g.router.deinit();
        g.endpoint.deinit();
        g.keys.deinit();
        g.metadata.deinit(g.core.gpa);
        g.listener.deinit(io);
        g.core.deinit();
    }
};

test "a client signs in when the server asks, and steps up for a tool that needs more scope" {
    const gpa = testing.allocator;
    const io = testing.io;
    var provider: Provider = undefined;
    try provider.start(io);
    defer provider.stop(io);
    var web: uplink.Client = .init(gpa, .{});
    defer web.deinit(io);

    var mcp: Guarded = undefined;
    try mcp.start(gpa, io, &web, provider.base);
    defer mcp.stop(io);
    const url = mcp.url;

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

fn idToken(_: ?*anyopaque, _: Io, _: std.mem.Allocator) Authorizer.SourceError![]const u8 {
    return "id-token-u1";
}

fn workloadToken(context: ?*anyopaque, _: Io, _: std.mem.Allocator) Authorizer.SourceError![]const u8 {
    const token: *const []const u8 = @ptrCast(@alignCast(context.?)); // safe: the test passes its token
    return token.*;
}

test "enterprise-managed authorization: no sign-in; the identity provider's ID-JAG redeemed, again for a step-up" {
    const gpa = testing.allocator;
    const io = testing.io;
    var provider: Provider = undefined;
    try provider.start(io);
    defer provider.stop(io);
    var web: uplink.Client = .init(gpa, .{});
    defer web.deinit(io);
    var mcp: Guarded = undefined;
    try mcp.start(gpa, io, &web, provider.base);
    defer mcp.stop(io);

    var issuer_buffer: [96]u8 = undefined;
    const idp = try std.mem.print(&issuer_buffer, "{s}/idp", .{provider.base});
    var endpoint_buffer: [96]u8 = undefined;
    var authorizer: Authorizer = .init(gpa, &web, mcp.url, .{
        .client_name = "parley-test",
        .grant = .enterprise,
        .registered = &.{.{ .issuer = provider.base, .client_id = "ema-client" }},
        .enterprise = .{
            .issuer = idp,
            .token_endpoint = try std.mem.print(&endpoint_buffer, "{s}/token", .{idp}),
            .client = .{ .issuer = idp, .client_id = "idp-app" },
            .subject = .{ .get = idToken },
        },
    });
    defer authorizer.deinit();
    var remote: http.Transport = .init(gpa, &web, mcp.url, .{ .authorization = authorizer.authorization() });
    defer remote.deinit();
    defer remote.close(io);
    var client: parley.Client = .init(gpa, remote.transport(), .{ .info = .{ .name = "parley-test", .version = "0" } });
    defer client.deinit();
    try client.connect(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try client.callTool(io, arena, "read", .{}, null);
    _ = try client.callTool(io, arena, "write", .{}, null);
    provider.mutex.lockUncancelable(io);
    defer provider.mutex.unlock(io);
    try testing.expectEqual(@as(u32, 0), provider.sign_ins);
    try testing.expectEqual(@as(u32, 0), provider.registrations);
    // One for the first 401, one for the step-up.
    try testing.expectEqual(@as(u32, 2), provider.exchanges);
    try testing.expectEqual(@as(u32, 2), provider.grants);
}

test "a workload's token as the grant: no client, no sign-in" {
    const gpa = testing.allocator;
    const io = testing.io;
    var provider: Provider = undefined;
    try provider.start(io);
    defer provider.stop(io);
    var web: uplink.Client = .init(gpa, .{});
    defer web.deinit(io);
    var mcp: Guarded = undefined;
    try mcp.start(gpa, io, &web, provider.base);
    defer mcp.stop(io);

    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    var workload: std.Io.Writer.Allocating = .init(gpa);
    defer workload.deinit();
    try signTyped(gpa, io, &workload.writer, "JWT", .{ .iss = "https://platform.example", .sub = "agent", .aud = provider.base, .exp = now + 600 });
    const token = workload.written();
    var authorizer: Authorizer = .init(gpa, &web, mcp.url, .{
        .client_name = "parley-test",
        .grant = .jwt_bearer,
        .assertion = .{ .context = @ptrCast(@constCast(&token)), .get = workloadToken }, // safe: workloadToken casts it back to this type
    });
    defer authorizer.deinit();
    var remote: http.Transport = .init(gpa, &web, mcp.url, .{ .authorization = authorizer.authorization() });
    defer remote.deinit();
    defer remote.close(io);
    var client: parley.Client = .init(gpa, remote.transport(), .{ .info = .{ .name = "parley-test", .version = "0" } });
    defer client.deinit();
    try client.connect(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    _ = try client.callTool(io, arena_state.allocator(), "read", .{}, null);
    provider.mutex.lockUncancelable(io);
    defer provider.mutex.unlock(io);
    try testing.expectEqual(@as(u32, 0), provider.sign_ins);
    try testing.expectEqual(@as(u32, 1), provider.grants);
}
