//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "protocol", .patterns = &.{
        "src/revision.zig",
        "src/wire.zig",
        "src/types.zig",
    } },
    .{ .name = "a request", .patterns = &.{
        "src/meta.zig",
        "src/context.zig",
        "src/state.zig",
    } },
    .{ .name = "handlers and streams", .patterns = &.{
        "src/Call.zig",
        "src/subscriptions.zig",
    } },
    .{ .name = "what a server offers", .patterns = &.{"src/registry.zig"} },
    .{ .name = "the core", .patterns = &.{"src/Server.zig"} },
    .{ .name = "sessions", .patterns = &.{"src/compat.zig"} },
    .{ .name = "stdio", .patterns = &.{"src/stdio.zig"} },
    .{ .name = "public", .patterns = &.{"src/parley.zig"} },
    .{ .name = "HTTP headers", .patterns = &.{"src/http/headers.zig"} },
    .{ .name = "HTTP endpoint", .patterns = &.{"src/http/Endpoint.zig"} },
    .{ .name = "HTTP public", .patterns = &.{"src/http.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "parley", .path = "src/parley.zig", .from = "src/http/**" },
};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "builtin",
        "aegis",
        "strand",
        "uplink",
        "shakedown",
        "parley",
        "preflight_bench_options",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;
pub const owned: []const gantry.rules.TokenRule = &.{};

pub const required = [_][]const u8{
    "src/parley.zig",
    "src/http.zig",
    "src/wire.zig",
    "src/Server.zig",
    "src/tests.zig",
};
