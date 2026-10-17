//! A client's side of MCP's authorization: the bearer token a request
//! carries, and what a server's refusal of it is answered with, for
//! `parley.http.Transport` (`authorization`).
//!
//! The first request goes without a token. A 401 (or a 403 asking for more
//! scope, `insufficient_scope`) starts the work MCP lays out: the protected
//! resource's metadata, from the challenge's `resource_metadata` or the
//! well-known locations (its `resource` held to the server's URL), then its
//! authorization server's metadata, the client as that server knows it, the
//! scope to ask for, and the tokens: kept ones, a refresh, or a sign-in
//! (the authorization code flow with PKCE, the resource named). The request
//! is then sent again, once.
//!
//! The client, in MCP's order of preference: one registered beforehand with
//! that server (`Options.registered`), a client ID metadata document's URL
//! where the server takes one (`Options.metadata_url`), else one registered
//! now (RFC 7591), as a native or web application. A server that changes
//! (the resource names another) is a new start: nothing the old one issued
//! is sent to it. The scope: what the challenge names, else everything the
//! resource lists, with what was granted before kept (a step-up never drops
//! a scope), and `offline_access` where the server lists it and refresh
//! tokens are wanted.
const Authorizer = @This();

const std = @import("std");
const uplink = @import("uplink");
const oauth = @import("clearance.oauth");
const http = @import("parley.http");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const TokenSet = oauth.TokenSet;
const Method = oauth.client_auth.Method;

gpa: Allocator,
web: *uplink.Client,
/// The MCP server's URL: the resource the tokens are for.
resource: []const u8,
options: Options,
/// Private: one renewal at a time; guards everything below.
mutex: Io.Mutex = .init,
/// Private: the tokens requests carry, once there are some.
active: ?TokenSet = null,
/// Private: the authorization server they came from, owned.
issuer: ?[]u8 = null,
/// Private: the client registered with it now, owned.
registered: ?Registered = null,
/// Private: where tokens are kept when the options name no store.
memory: oauth.store.Memory,
/// Why the last refusal stood (a server that cannot be discovered, a
/// sign-in refused); null once a renewal succeeds.
failure: ?anyerror = null,

pub const Options = struct {
    /// How the user signs in: open the authorization URL (in a browser),
    /// and return the URL the browser was sent back to (the redirect URI
    /// with the code). Needed for `.authorization_code`.
    sign_in: ?SignIn = null,
    /// Exactly as registered: for a native application, a loopback one
    /// (RFC 8252).
    redirect_uri: []const u8 = "http://127.0.0.1/callback",
    /// The client's name, sent when it registers.
    client_name: []const u8,
    application_type: oauth.registration.ApplicationType = .native,
    /// A client ID metadata document's URL: the client's id with a server
    /// that takes them, in place of registering. The document is the
    /// caller's to publish (`oauth.registration.writeDocument`).
    metadata_url: ?[]const u8 = null,
    /// Clients registered beforehand, each with its authorization server.
    registered: []const Credentials = &.{},
    grant: Grant = .authorization_code,
    /// Ask for refresh tokens where the server gives them.
    offline: bool = true,
    /// Where tokens are kept between runs, by the server and resource;
    /// null: in this process's memory.
    store: ?oauth.TokenStore = null,
    fetch: oauth.fetch.Options = .{},
};

pub const Grant = enum {
    /// A user signs in (`Options.sign_in`).
    authorization_code,
    /// The client on its own behalf, with credentials registered
    /// beforehand: a machine, no user.
    client_credentials,
};

/// A client registered beforehand with the authorization server `issuer`.
pub const Credentials = struct {
    /// Null: whichever server the resource names (a client that serves one
    /// resource, configured for it).
    issuer: ?[]const u8,
    client_id: []const u8,
    /// The secret, sent as the server's metadata prefers (`Basic`, or in
    /// the body).
    secret: ?[]const u8 = null,
    /// A key the client signs its assertions with (`private_key_jwt`).
    private_key_jwt: ?oauth.client_auth.PrivateKeyJwt = null,
};

pub const SignIn = struct {
    context: ?*anyopaque = null,
    /// Opens `url` for the user; returns where the browser was sent back
    /// to, on `arena`.
    open: *const fn (context: ?*anyopaque, io: Io, arena: Allocator, url: []const u8) SignInError![]const u8,
};

/// `Declined`: the user did not sign in.
pub const SignInError = error{ Declined, Canceled, OutOfMemory };

/// A client registered with the server now, owned.
const Registered = struct {
    id: []u8,
    secret: ?[]u8,
    method: Method,

    fn deinit(r: *Registered, gpa: Allocator) void {
        gpa.free(r.id);
        if (r.secret) |s| {
            std.crypto.secureZero(u8, s);
            gpa.free(s);
        }
        r.* = undefined;
    }
};

/// An authorizer for the MCP server at `resource`, its exchanges with the
/// authorization server on `web`. It must not move once used.
pub fn init(gpa: Allocator, web: *uplink.Client, resource: []const u8, options: Options) Authorizer {
    return .{ .gpa = gpa, .web = web, .resource = resource, .options = options, .memory = .init(gpa) };
}

pub fn deinit(a: *Authorizer) void {
    if (a.active) |*set| set.deinit();
    if (a.issuer) |i| a.gpa.free(i);
    if (a.registered) |*r| r.deinit(a.gpa);
    a.memory.deinit();
    a.* = undefined;
}

/// The authorizer as the HTTP transport's `authorization`.
pub fn authorization(a: *Authorizer) http.Transport.Authorization {
    return .{ .context = a, .vtable = &.{ .credentials = credentials, .refused = refused } };
}

fn store(a: *Authorizer) oauth.TokenStore {
    return a.options.store orelse a.memory.store();
}

fn credentials(context: *anyopaque, io: Io, arena: Allocator) http.Transport.Authorization.Error!?[]const u8 {
    const a: *Authorizer = @ptrCast(@alignCast(context)); // safe: the authorization was made from an authorizer
    try a.mutex.lock(io);
    defer a.mutex.unlock(io);
    const set = a.active orelse return null;
    return try std.mem.concat(arena, u8, &.{ "Bearer ", set.access_token });
}

fn refused(context: *anyopaque, io: Io, sent: ?[]const u8, status: u16, challenges: []const []const u8) http.Transport.Authorization.Error!bool {
    const a: *Authorizer = @ptrCast(@alignCast(context)); // safe: the authorization was made from an authorizer
    try a.mutex.lock(io);
    defer a.mutex.unlock(io);
    // Another request renewed the tokens since this one was sent.
    if (a.active) |set| {
        const was = sent orelse return true;
        if (!std.mem.eql(u8, was["Bearer ".len..], set.access_token)) return true;
    }
    var arena_state: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena_state.deinit();
    a.renew(io, arena_state.allocator(), status, challenges) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            a.failure = err;
            std.log.scoped(.parley_oauth).warn("the server's refusal stands: {t}", .{err});
            return false;
        },
    };
    a.failure = null;
    return true;
}

const RenewError = oauth.DiscoverError || oauth.RefreshError || oauth.RegisterError || oauth.AuthorizationFlow.BeginError || oauth.AuthorizationFlow.FinishError ||
    oauth.challenge.ReadError || oauth.store.LoadError || oauth.store.SaveError || SignInError || error{
    /// No `WWW-Authenticate` challenge is Bearer.
    NotBearer,
    /// A 403 that is not for more scope: more credentials would not help.
    Forbidden,
    /// The resource's metadata names no authorization server.
    NoAuthorizationServer,
    /// No way to authenticate that the server takes.
    NoAuthMethod,
    /// A sign-in is needed, and the options give no way to have one.
    NoSignIn,
    /// The grant needs a client registered beforehand with this server.
    NotRegistered,
    /// The server refused to register the client, or registered it without
    /// the secret its method needs.
    RegistrationRefused,
    /// The token endpoint refused the grant.
    TokenRefused,
};

/// New tokens, as MCP's authorization asks, for a request refused with
/// `status` and `challenges`.
fn renew(a: *Authorizer, io: Io, arena: Allocator, status: u16, challenges: []const []const u8) RenewError!void {
    const challenge = (try oauth.challenge.read(arena, challenges)) orelse return error.NotBearer;
    if (status == 403 and challenge.@"error" != .insufficient_scope) return error.Forbidden;
    var prm = try oauth.discoverResource(a.gpa, io, a.web, a.resource, challenge.resource_metadata, .ancestor, .{ .fetch = a.options.fetch });
    defer prm.deinit();
    const servers = prm.value.authorization_servers orelse return error.NoAuthorizationServer;
    if (servers.len == 0) return error.NoAuthorizationServer;
    var server = try oauth.discover(a.gpa, io, a.web, servers[0], .{ .fetch = a.options.fetch });
    defer server.deinit();
    const as = &server.value;
    // Another server: nothing the old one issued goes to it (SEP-2352).
    if (a.issuer) |old| if (!std.mem.eql(u8, old, as.issuer)) a.forgetServer(io, arena);
    if (a.issuer == null) a.issuer = try a.gpa.dupe(u8, as.issuer);
    const key = try a.storeKey(arena);
    const resource = prm.value.resource;

    // A first refusal: tokens kept from before (another run) are sent next,
    // unless they lack the scope the challenge asks for or have expired, in
    // which case they are what a refresh starts from.
    if (a.active == null) if (try a.store().load(io, a.gpa, key)) |kept| {
        a.active = kept;
        if (covers(kept.scope, challenge.scope) and !kept.expiresWithin(Io.Clock.real.now(io), .literal("0s"))) return;
    };
    const client = try a.clientFor(io, as);
    // Refused tokens that can be refreshed, and no more scope asked for:
    // a refresh first, a sign-in only if it is refused.
    if (a.active) |*set| if (set.refresh_token != null and covers(set.scope, challenge.scope)) {
        switch (try oauth.refresh(a.gpa, io, a.web, as, client, set, .{ .resources = &.{resource}, .fetch = a.options.fetch })) {
            .tokens => |renewed| return a.keep(io, key, renewed),
            .refused => {},
        }
    };
    const scope = try a.scopeFor(arena, challenge.scope, prm.value.scopes_supported, as);
    const response = switch (a.options.grant) {
        .authorization_code => try a.signIn(io, arena, as, client, scope, resource),
        .client_credentials => try oauth.clientCredentials(a.gpa, io, a.web, as, client, scope, .{ .resources = &.{resource}, .fetch = a.options.fetch }),
    };
    switch (response) {
        .tokens => |set| return a.keep(io, key, set),
        .refused => |e| {
            std.log.scoped(.parley_oauth).warn("the token endpoint refused: {f}", .{e});
            return error.TokenRefused;
        },
    }
}

/// The authorization code flow: the user signs in, and the code is spent.
fn signIn(a: *Authorizer, io: Io, arena: Allocator, as: *const oauth.metadata.AuthorizationServer, client: oauth.Client, scope: ?[]const u8, resource: []const u8) RenewError!oauth.token.Response {
    const sign_in = a.options.sign_in orelse return error.NoSignIn;
    var url: Io.Writer.Allocating = .init(arena);
    var flow = try oauth.AuthorizationFlow.begin(io, as, .{
        .client_id = client.id,
        .redirect_uri = a.options.redirect_uri,
        .scope = scope,
        .resources = &.{resource},
        // MCP: a server that does not list S256 is not one to sign in with.
        .require_pkce_listed = true,
    }, &url.writer);
    defer flow.deinit();
    const redirect = try sign_in.open(sign_in.context, io, arena, url.written());
    return flow.finish(a.gpa, io, a.web, as, client, redirect, .{ .fetch = a.options.fetch });
}

/// Keeps `set` as the tokens in use, and in the store.
fn keep(a: *Authorizer, io: Io, key: []const u8, set: TokenSet) RenewError!void {
    var owned = set;
    errdefer owned.deinit();
    try a.store().save(io, key, &owned);
    if (a.active) |*old| old.deinit();
    a.active = owned;
}

/// Forgets the server: its tokens, here and kept, and the client it
/// registered.
fn forgetServer(a: *Authorizer, io: Io, arena: Allocator) void {
    if (a.storeKey(arena)) |k| a.store().forget(io, k) else |_| {}
    if (a.active) |*set| set.deinit();
    a.active = null;
    if (a.registered) |*r| r.deinit(a.gpa);
    a.registered = null;
    if (a.issuer) |i| a.gpa.free(i);
    a.issuer = null;
}

/// Where tokens are kept: the server and the resource they are for.
fn storeKey(a: *const Authorizer, arena: Allocator) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ a.issuer orelse "", " ", a.resource });
}

/// The client as `as` knows it.
fn clientFor(a: *Authorizer, io: Io, as: *const oauth.metadata.AuthorizationServer) RenewError!oauth.Client {
    for (a.options.registered) |r| if (r.issuer == null or std.mem.eql(u8, r.issuer.?, as.issuer)) {
        if (r.private_key_jwt) |key_jwt| {
            if (oauth.client_auth.choose(as.token_endpoint_auth_methods_supported, &.{.private_key_jwt}) == null) return error.NoAuthMethod;
            return .{ .id = r.client_id, .credentials = .{ .private_key_jwt = key_jwt } };
        }
        const secret = r.secret orelse return .{ .id = r.client_id };
        return .{ .id = r.client_id, .credentials = withSecret(oauth.client_auth.choose(as.token_endpoint_auth_methods_supported, &.{ .client_secret_basic, .client_secret_post }) orelse return error.NoAuthMethod, secret) };
    };
    if (a.options.grant == .client_credentials) return error.NotRegistered;
    if (a.options.metadata_url) |url| if (as.client_id_metadata_document_supported) return .{ .id = url };
    if (a.registered == null) a.registered = try a.register(io, as);
    const r = a.registered.?;
    return .{ .id = r.id, .credentials = withSecret(r.method, r.secret orelse "") };
}

fn withSecret(method: Method, secret: []const u8) oauth.client_auth.Credentials {
    return switch (method) {
        .none => .none,
        .client_secret_basic => .{ .client_secret_basic = secret },
        .client_secret_post => .{ .client_secret_post = secret },
        // unreachable: a secret's methods are the two above, and none
        .private_key_jwt => unreachable,
    };
}

/// Registers the client with `as` (RFC 7591): a public client where the
/// server takes one, else one with a secret, as the server's metadata says.
fn register(a: *Authorizer, io: Io, as: *const oauth.metadata.AuthorizationServer) RenewError!Registered {
    const asked = oauth.client_auth.choose(as.token_endpoint_auth_methods_supported, &.{ .none, .client_secret_basic, .client_secret_post }) orelse return error.NoAuthMethod;
    const grants: []const []const u8 = if (a.options.offline) &.{ "authorization_code", "refresh_token" } else &.{"authorization_code"};
    var response = try oauth.register(a.gpa, io, a.web, as, .{
        .client_name = a.options.client_name,
        .redirect_uris = &.{a.options.redirect_uri},
        .grant_types = grants,
        .response_types = &.{"code"},
        .token_endpoint_auth_method = asked.name(),
        .application_type = a.options.application_type,
    }, .{ .fetch = a.options.fetch });
    switch (response) {
        .refused => |e| {
            std.log.scoped(.parley_oauth).warn("registration refused: {f}", .{e});
            return error.RegistrationRefused;
        },
        .registered => |*r| {
            defer r.deinit();
            // What the server registered, which may differ from what was
            // asked.
            const method = if (r.token_endpoint_auth_method) |m| Method.parse(m) orelse return error.NoAuthMethod else asked;
            if (method == .private_key_jwt) return error.NoAuthMethod;
            if (method != .none and r.client_secret == null) return error.RegistrationRefused;
            const id = try a.gpa.dupe(u8, r.client_id);
            errdefer a.gpa.free(id);
            const secret = if (method == .none) null else try a.gpa.dupe(u8, r.client_secret.?);
            return .{ .id = id, .secret = secret, .method = method };
        },
    }
}

/// The scope to ask for: what was granted before, and what the challenge
/// names (else what the resource lists), each once; `offline_access` added
/// where the server lists it and refresh tokens are wanted. Null: none.
fn scopeFor(a: *const Authorizer, arena: Allocator, challenged: ?[]const u8, listed: ?[]const []const u8, as: *const oauth.metadata.AuthorizationServer) Allocator.Error!?[]const u8 {
    const needed = challenged orelse if (listed) |l| try std.mem.join(arena, " ", l) else "";
    const granted = if (a.active) |set| set.scope else null;
    var out: Io.Writer.Allocating = .init(arena);
    oauth.challenge.writeStepUp(&out.writer, granted, needed) catch return error.OutOfMemory;
    if (a.options.offline and a.options.grant == .authorization_code and as.supportsScope("offline_access") and !oauth.challenge.contains(out.written(), "offline_access")) {
        if (out.written().len != 0) out.writer.writeByte(' ') catch return error.OutOfMemory;
        out.writer.writeAll("offline_access") catch return error.OutOfMemory;
    }
    return if (out.written().len == 0) null else out.written();
}

/// Whether `granted` holds every scope of `needed` (none needed: yes).
fn covers(granted: ?[]const u8, needed: ?[]const u8) bool {
    var it = std.mem.tokenizeScalar(u8, needed orelse return true, ' ');
    while (it.next()) |s| if (!oauth.challenge.contains(granted orelse "", s)) return false;
    return true;
}
