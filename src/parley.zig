//! parley: the Model Context Protocol (MCP) for Zig.
//!
//! - `wire`: JSON-RPC 2.0 as MCP speaks it, read and written without I/O.
const std = @import("std");

/// JSON-RPC 2.0 messages: read off their bytes, told apart, and written.
pub const wire = @import("wire.zig");

/// The protocol revisions parley speaks, newest first. 2026-07-28 is
/// stateless; the ones before it open a session with `initialize`.
pub const Revision = enum {
    @"2026-07-28",
    @"2025-11-25",
    @"2025-06-18",

    /// The newest revision.
    pub const latest: Revision = .@"2026-07-28";

    /// Whether the revision carries version, identity and capabilities on
    /// every request rather than in an `initialize` handshake.
    pub fn stateless(r: Revision) bool {
        return r == .@"2026-07-28";
    }

    /// The revision a version string names, or null for one parley does not
    /// speak.
    pub fn parse(text: []const u8) ?Revision {
        return std.meta.stringToEnum(Revision, text);
    }
};

// The tests run in this module, so test support that links parley takes
// this copy and the test binary holds one parley.
test {
    _ = @import("tests.zig");
}
