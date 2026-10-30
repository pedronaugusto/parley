//! A server's side of MCP's authorization: every request to an endpoint
//! held to a bearer token valid for this resource, as `parley.http.Endpoint`'s
//! `access`. The check is clearance's (`oauth.bearer.Verifier`): a JWT
//! access token verified against the authorization server's keys, or a
//! token of any form introspected, its audience this resource, its scopes
//! the ones the request needs. A request without one is answered 401, with
//! the challenge naming where this resource's metadata is; one whose token
//! lacks a scope, 403 `insufficient_scope` naming it. A request it admits is
//! served for the token's subject (or its client, when it has none).
const Guard = @This();

const std = @import("std");
const uplink = @import("uplink");
const oauth = @import("clearance.oauth");
const parley = @import("parley");
const http = @import("parley.http");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Endpoint = http.Endpoint;

verifier: *const oauth.bearer.Verifier,
/// Where the verifier fetches keys or introspects.
web: *uplink.Client,
/// The scopes every request needs.
scopes: []const []const u8 = &.{},
/// The scopes a request needs beyond those, by what it asks; null: none.
needs: ?Needs = null,

pub const Needs = struct {
    context: ?*anyopaque = null,
    /// The scopes `message` needs beyond the guard's own (a tool that
    /// writes, a method), on `arena`. `message` is null for a GET or a
    /// DELETE.
    scopes: *const fn (context: ?*anyopaque, arena: Allocator, message: ?parley.wire.Message) Allocator.Error![]const []const u8,
};

/// The guard as an endpoint's `access`. The guard must outlive the endpoint.
pub fn access(g: *Guard) Endpoint.Access {
    return .{ .context = g, .check = check };
}

fn check(context: ?*anyopaque, io: Io, arena: Allocator, request: *const uplink.server.Request, message: ?parley.wire.Message) Endpoint.Access.Error!Endpoint.Verdict {
    const g: *const Guard = @ptrCast(@alignCast(context.?)); // safe: `access` makes the context a guard
    const scopes = if (g.needs) |n| try std.mem.concat(arena, []const u8, &.{ g.scopes, try n.scopes(n.context, arena, message) }) else g.scopes;
    const outcome = g.verifier.check(io, g.web, arena, .{ .authorization = request.headers.get("Authorization") }, scopes) catch |err| return switch (err) {
        error.Unavailable => error.Unavailable,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
    switch (outcome) {
        .allowed => |p| return .{ .admitted = p.subject orelse p.client_id },
        .refused => |r| {
            var challenge: Io.Writer.Allocating = .init(arena);
            r.write(&challenge.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                // A value a challenge cannot carry (a scope or a realm with
                // a quote): the scheme alone, which still says what to use.
                error.InvalidValue, error.InvalidError => {
                    challenge.clearRetainingCapacity();
                    challenge.writer.writeAll("Bearer") catch return error.OutOfMemory;
                },
            };
            // The body says the same as the challenge, for a client that
            // reads JSON (RFC 6750 §3 leaves the body open).
            var body: Io.Writer.Allocating = .init(arena);
            if (r.challenge.@"error") |code| {
                body.writer.print("{{\"error\":\"{t}\"", .{code}) catch return error.OutOfMemory;
                if (r.challenge.error_description) |d| {
                    body.writer.writeAll(",\"error_description\":") catch return error.OutOfMemory;
                    parley.wire.writeString(&body.writer, d) catch return error.OutOfMemory;
                }
                body.writer.writeByte('}') catch return error.OutOfMemory;
            }
            return .{ .refused = .{ .status = r.status, .challenge = challenge.written(), .body = body.written() } };
        },
    }
}
