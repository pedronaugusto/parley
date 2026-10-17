//! parley.http: MCP over Streamable HTTP, on uplink.
//!
//! - `Endpoint`: the server side, an uplink handler for the MCP endpoint.
//! - `headers`: the request headers mirrored from the body, and the Base64
//!   sentinel their values travel in.

pub const Endpoint = @import("http/Endpoint.zig");
/// The client's side: a server's endpoint, for `parley.Client`.
pub const Transport = @import("http/Transport.zig");
pub const headers = @import("http/headers.zig");

// The tests run in this module, against the `parley` module it imports.
test {
    _ = @import("http/tests.zig");
}
