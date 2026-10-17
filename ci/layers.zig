//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "protocol", .patterns = &.{
        "src/revision.zig",
        "src/wire.zig",
        "src/types.zig",
    } },
    .{ .name = "streams", .patterns = &.{"src/subscriptions.zig"} },
    .{ .name = "a request", .patterns = &.{
        "src/meta.zig",
        "src/context.zig",
        "src/state.zig",
    } },
    .{ .name = "handlers", .patterns = &.{"src/Call.zig"} },
    .{ .name = "what a server offers", .patterns = &.{"src/registry.zig"} },
    .{ .name = "the tasks held", .patterns = &.{"src/tasks.zig"} },
    .{ .name = "the core and the client", .patterns = &.{
        "src/Server.zig",
        "src/Client.zig",
    } },
    .{ .name = "sessions", .patterns = &.{"src/compat.zig"} },
    .{ .name = "stdio", .patterns = &.{"src/stdio.zig"} },
    .{ .name = "public", .patterns = &.{"src/parley.zig"} },
    .{ .name = "HTTP headers", .patterns = &.{"src/http/headers.zig"} },
    .{ .name = "HTTP ends", .patterns = &.{
        "src/http/Endpoint.zig",
        "src/http/Transport.zig",
    } },
    .{ .name = "HTTP public", .patterns = &.{"src/http.zig"} },
    .{ .name = "a server process", .patterns = &.{"src/process.zig"} },
    .{ .name = "authorization", .patterns = &.{
        "src/oauth/Authorizer.zig",
        "src/oauth/Guard.zig",
        "src/oauth/ResourceMetadata.zig",
    } },
    .{ .name = "authorization public", .patterns = &.{"src/oauth.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "parley", .path = "src/parley.zig", .from = "src/http/**" },
    .{ .name = "parley", .path = "src/parley.zig", .from = "src/process*.zig" },
    .{ .name = "parley", .path = "src/parley.zig", .from = "src/oauth/**" },
    .{ .name = "parley.http", .path = "src/http.zig", .from = "src/oauth/**" },
};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "builtin",
        "aegis",
        "strand",
        "uplink",
        "conduit",
        "shakedown",
        "test_options",
        "parley",
        "parley.http",
        "clearance",
        "clearance.oauth",
        "cloak",
        "reactor",
        "preflight_bench_options",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;
pub const owned: []const gantry.rules.TokenRule = &.{};

pub const required = [_][]const u8{
    "src/parley.zig",
    "src/http.zig",
    "src/process.zig",
    "src/oauth.zig",
    "src/wire.zig",
    "src/Server.zig",
    "src/tests.zig",
};
