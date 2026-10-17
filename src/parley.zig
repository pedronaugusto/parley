//! parley: the Model Context Protocol (MCP) for Zig.
//!
//! - `Server`: what a server offers, and one request answered with one
//!   reply, whatever carries it.
//! - `stdio`: a server over a process's standard streams (or any byte
//!   stream), one message a line.
//! - `wire`: JSON-RPC 2.0 as MCP speaks it, read and written without I/O.
//! - `types`: MCP's data.
const std = @import("std");

pub const wire = @import("wire.zig");
pub const types = @import("types.zig");
pub const Revision = @import("revision.zig").Revision;
pub const Server = @import("Server.zig");
pub const stdio = @import("stdio.zig");
pub const Call = @import("Call.zig");
pub const Context = @import("context.zig").Context;
pub const Sink = @import("context.zig").Sink;
pub const ToolResult = @import("registry.zig").ToolResult;
pub const ToolSpec = @import("registry.zig").ToolSpec;
pub const ToolHandler = @import("registry.zig").ToolHandler;
pub const ResourceSpec = @import("registry.zig").ResourceSpec;
pub const TemplateSpec = @import("registry.zig").TemplateSpec;
pub const ReadResult = @import("registry.zig").ReadResult;
pub const ReadHandler = @import("registry.zig").ReadHandler;
pub const PromptSpec = @import("registry.zig").PromptSpec;
pub const PromptResult = @import("registry.zig").PromptResult;
pub const PromptHandler = @import("registry.zig").PromptHandler;
/// A request's `_meta`, read.
pub const meta = @import("meta.zig");
/// The state a handler keeps across rounds, sealed.
pub const state = @import("state.zig");

// The tests run in this module, so test support that links parley takes
// this copy and the test binary holds one parley.
test {
    _ = @import("tests.zig");
}
