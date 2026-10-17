//! parley.oauth: MCP's authorization over Streamable HTTP, on clearance's
//! OAuth 2.1.
//!
//! - `Authorizer`: a client's side. It gives `parley.http.Transport` the
//!   requests' bearer token, and answers a server's 401 or 403 the way MCP
//!   asks: the resource's metadata (RFC 9728) from the challenge or its
//!   well-known locations, its authorization server's (RFC 8414, OpenID
//!   Connect), the client as that server knows it (registered beforehand, a
//!   client ID metadata document, or registered now, RFC 7591), the scope
//!   the challenge names (or the resource lists), the user's sign-in with
//!   PKCE and the resource named (RFC 8707), a refresh, a step-up to more
//!   scopes on `insufficient_scope`.
//! - `Guard`: a server's side. It holds every request to an endpoint to a
//!   bearer token valid for this resource (a JWT checked against the
//!   authorization server's keys, or introspection), answering one without
//!   with the 401 and challenge that say where to get one.
//! - `ResourceMetadata`: the resource's metadata document, served where a
//!   client looks for it.

pub const Authorizer = @import("oauth/Authorizer.zig");
pub const Guard = @import("oauth/Guard.zig");
pub const ResourceMetadata = @import("oauth/ResourceMetadata.zig");

test {
    _ = @import("oauth/tests.zig");
}
