//! JSON Schema validation through strand's `strand_schema`, in a parley built
//! with it (the build option `schema`, on by default). The client checks a
//! tool's structured content against the output schema `tools/list` gave for
//! it; the server checks the arguments of a tool whose input schema it was
//! given (a dynamic tool's, or one stricter than the tool's type) and the
//! content of an accepted elicitation against the schema it asked with.
//! Built without it, nothing is checked but by decoding into a type.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Whether parley was built with `strand_schema`.
pub const built = @import("parley_options").validation;
const strand_schema = if (built) @import("strand_schema") else struct {};

/// A compiled schema, held by whoever validates against it; the last
/// release frees it.
pub const Compiled = if (built) aegis.Shared(strand_schema.Schema, strand_schema.Schema.deinit) else void;

/// What a schema `pattern` spectra cannot run in linear time becomes: the
/// schema refused (a server's own schemas, which their author can change),
/// or the keyword left unchecked and named in every verdict through it (a
/// peer's).
pub const Patterns = enum { refuse, downgrade };

/// Why a schema did not compile, or an instance is not valid against it:
/// the reason, and where (each empty when it does not apply). On the arena
/// given.
pub const Failure = struct {
    message: []const u8 = "",
    /// The JSON Pointer to the value that failed.
    instance_location: []const u8 = "",
    /// Where in the schema: the keyword's absolute location, or where the
    /// schema failed to compile.
    schema_location: []const u8 = "",
};

/// `schema`, written as JSON, compiled: every `format` asserted by its strict
/// recognizer, no remote reference followed. `Refused`, with `failure` filled
/// on `arena` when given, for a schema `strand_schema` does not compile.
pub fn compile(gpa: Allocator, io: Io, schema: []const u8, patterns: Patterns, arena: Allocator, failure: ?*Failure) (Allocator.Error || Io.Cancelable || error{Refused})!Compiled {
    comptime std.debug.assert(built);
    var d: strand_schema.Schema.Diagnostic = .{};
    var s = strand_schema.Schema.compile(gpa, io, strand.json, .init(schema), .{
        .formats = .assert,
        .unsupported_pattern = switch (patterns) {
            .refuse => .refuse,
            .downgrade => .downgrade,
        },
        .diagnostics = &d,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => |e| {
            if (failure) |f| f.* = .{ .message = @errorName(e), .schema_location = try arena.dupe(u8, d.location()) };
            return error.Refused;
        },
    };
    errdefer s.deinit();
    return .create(gpa, s);
}

/// What one instance came to.
pub const Verdict = union(enum) {
    /// Valid: and the keywords left unchecked on the way, by their locations
    /// (`Patterns.downgrade`).
    valid: []const []const u8,
    invalid: Failure,
};

/// `instance`, JSON, against `schema`: its slots, state and the verdict's
/// text on `scratch`. An instance that does not read, or past the schema's
/// limits, is invalid; only memory and cancellation are errors.
pub fn check(schema: *const Compiled, io: Io, scratch: Allocator, instance: []const u8) (Allocator.Error || Io.Cancelable)!Verdict {
    comptime std.debug.assert(built);
    var errors: strand_schema.Schema.Errors = .{};
    const valid = schema.get().validate(io, scratch, strand.json, .init(instance), .{ .basic = &errors }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => |e| return .{ .invalid = .{ .message = @errorName(e) } },
    };
    if (!valid) {
        const r = if (errors.records.len != 0) errors.records[0] else return .{ .invalid = .{ .message = "not valid against the schema" } };
        return .{ .invalid = .{ .message = r.message, .instance_location = r.instance_location, .schema_location = r.absolute_keyword_location } };
    }
    const unchecked = try scratch.alloc([]const u8, errors.downgraded.len);
    for (unchecked, errors.downgraded) |*u, d| u.* = d.location;
    return .{ .valid = unchecked };
}

/// `failure` as one line: the message, then where.
pub fn describe(arena: Allocator, failure: Failure) Allocator.Error![]const u8 {
    if (failure.instance_location.len != 0) return arena.print("{s} at {s}", .{ failure.message, failure.instance_location });
    if (failure.schema_location.len != 0) return arena.print("{s} at {s}", .{ failure.message, failure.schema_location });
    return failure.message;
}
