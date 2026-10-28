//! The protocol revisions parley speaks.
const std = @import("std");

/// The revisions parley speaks, newest first. 2026-07-28 is stateless; the
/// ones before it open a session with `initialize`.
pub const Revision = enum {
    @"2026-07-28",
    @"2025-11-25",
    @"2025-06-18",
    @"2025-03-26",
    @"2024-11-05",

    /// The newest revision.
    pub const latest: Revision = .@"2026-07-28";
    /// The newest revision that opens a session with `initialize`.
    pub const latest_legacy: Revision = .@"2025-11-25";

    /// Whether the revision carries version, identity and capabilities on
    /// every request rather than in an `initialize` handshake.
    pub fn stateless(r: Revision) bool {
        return r == .@"2026-07-28";
    }

    /// Whether a peer may send a JSON-RPC batch, which the receiver must
    /// take: 2025-03-26 says so, and 2024-11-05 is JSON-RPC 2.0 whole.
    /// 2025-06-18 removed them.
    pub fn batches(r: Revision) bool {
        return switch (r) {
            .@"2025-03-26", .@"2024-11-05" => true,
            .@"2026-07-28", .@"2025-11-25", .@"2025-06-18" => false,
        };
    }

    /// The revision a version string names, or null for one parley does not
    /// speak.
    pub fn named(name: []const u8) ?Revision {
        return std.meta.stringToEnum(Revision, name);
    }

    pub fn text(r: Revision) []const u8 {
        return @tagName(r);
    }
};
