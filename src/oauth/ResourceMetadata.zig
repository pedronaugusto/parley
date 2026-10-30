//! A protected resource's metadata (RFC 9728), served where MCP's clients
//! look for it: `location` is its URL for the server's own (the well-known
//! path with the resource's path inserted), the one a `Guard`'s verifier
//! names in its challenges, and `handler` serves it there.
const ResourceMetadata = @This();

const std = @import("std");
const uplink = @import("uplink");
const oauth = @import("clearance.oauth");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The document, JSON, owned.
document: []u8,
/// Private: the metadata as an uplink handler (`handler`), which finds the
/// metadata by `@fieldParentPtr`.
handling: uplink.server.Handler = .{ .handleFn = served },

/// The document for `metadata`: its `resource` this server's MCP URL, its
/// `authorization_servers` the issuers that grant tokens for it.
pub fn init(gpa: Allocator, metadata: oauth.metadata.ProtectedResource) Allocator.Error!ResourceMetadata {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    metadata.write(&out.writer) catch return error.OutOfMemory;
    return .{ .document = try out.toOwnedSlice() };
}

pub fn deinit(m: *ResourceMetadata, gpa: Allocator) void {
    gpa.free(m.document);
    m.* = undefined;
}

/// Where a client looks for the metadata of `resource` first:
/// `/.well-known/oauth-protected-resource` before its path, written into
/// `w` (a URL; its path is where to mount `handler`).
pub fn location(w: *Io.Writer, resource: []const u8) (oauth.url.Error || Io.Writer.Error)!void {
    return oauth.url.writeResourceDiscovery(w, resource, .inserted);
}

/// The document, for a GET at its location, for as long as the metadata
/// stays where it is.
pub fn handler(m: *ResourceMetadata) *uplink.server.Handler {
    return &m.handling;
}

fn served(h: *uplink.server.Handler, io: Io, request: *uplink.server.Request, response: *uplink.server.Response) anyerror!void {
    const m: *const ResourceMetadata = @alignCast(@fieldParentPtr("handling", h));
    return serve(m, io, request, response);
}

fn serve(m: *const ResourceMetadata, io: Io, request: *uplink.server.Request, response: *uplink.server.Response) anyerror!void {
    if (!std.mem.eql(u8, request.method.name, "GET") and !std.mem.eql(u8, request.method.name, "HEAD")) {
        response.status = .method_not_allowed;
        try response.header("Allow", "GET, HEAD");
        return response.send(io, "");
    }
    try response.header("Content-Type", "application/json");
    // A page another site serves may read it (RFC 9728 §3 leaves it public).
    try response.header("Access-Control-Allow-Origin", "*");
    return response.send(io, m.document);
}
