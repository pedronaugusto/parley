//! What the core knows of a request beyond its params: the revision it is
//! in, the client's identity and capabilities, its log level and progress
//! token, and where its notifications go. A 2026-07-28 request carries all
//! of it in `_meta`; under an earlier revision the session holds it.
const std = @import("std");
const types = @import("types.zig");
const Revision = @import("revision.zig").Revision;

pub const Context = struct {
    revision: Revision,
    client: types.ClientCapabilities = .{},
    client_info: ?types.Implementation = null,
    log_level: ?types.LoggingLevel = null,
    progress_token: ?types.Token = null,
    /// The request's whole `_meta`, vendor keys included.
    meta: ?[]const u8 = null,
    /// Who sent the request, as the transport authenticated them; null when
    /// it did not (stdio).
    principal: ?[]const u8 = null,
};

/// Where the notifications that belong to one request go: a line on stdio,
/// an event on the request's HTTP stream. Each is one whole JSON-RPC
/// message.
pub const Sink = struct {
    context: *anyopaque,
    sendFn: *const fn (context: *anyopaque, io: std.Io, message: []const u8) SendError!void,
    /// A stream that would close when nothing crosses it for a while (an
    /// HTTP response behind a proxy) is kept open by `keepAliveFn`, every
    /// `keep_alive`, while a long-lived request has nothing to send.
    keep_alive: ?std.Io.Duration = null,
    keepAliveFn: ?*const fn (context: *anyopaque, io: std.Io) SendError!void = null,

    /// `Closed`: the stream the request came on is gone.
    pub const SendError = error{ Canceled, Closed, OutOfMemory };

    pub fn send(s: Sink, io: std.Io, message: []const u8) SendError!void {
        return s.sendFn(s.context, io, message);
    }

    pub fn keepAlive(s: Sink, io: std.Io) SendError!void {
        if (s.keepAliveFn) |f| return f(s.context, io);
    }

    /// A sink that drops everything: for a request whose notifications have
    /// nowhere to go.
    pub const none: Sink = .{ .context = undefined, .sendFn = drop };

    fn drop(_: *anyopaque, _: std.Io, _: []const u8) SendError!void {}
};
