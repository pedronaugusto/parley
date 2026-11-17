//! A JSON Schema validator, as an application gives one to a client or a
//! server (`Client.Options.validator`, `Server.Options.validator`): the
//! client checks a tool's structured content against the output schema
//! `tools/list` gave for it; the server checks the arguments of a tool whose
//! input schema it was given (a dynamic tool's, or one stricter than the
//! tool's type) and the content of an accepted elicitation against the
//! schema it asked with. A pointer and its functions, as `std.mem.Allocator`
//! is: parley names no implementation, so a program that validates nothing
//! compiles none. `parley.validation.json_schema` is strand_schema's.
const std = @import("std");
const aegis = @import("aegis");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Validator = @This();

/// The implementation's own state, given back to each function; null for
/// one that keeps none.
ptr: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// `schema`, written as JSON, compiled, on `gpa`: every `format`
    /// asserted, no remote reference followed. `Refused`, with `failure`
    /// filled on `arena` when given, for a schema it does not compile.
    compile: *const fn (ptr: ?*anyopaque, gpa: Allocator, io: Io, schema: []const u8, patterns: Patterns, arena: Allocator, failure: ?*Failure) CompileError!*anyopaque,
    /// `instance`, JSON, against a schema `compile` returned: scratch and the
    /// verdict's text on `scratch`. An instance that does not read, or past
    /// the schema's limits, is invalid; only memory and cancellation are
    /// errors.
    check: *const fn (ptr: ?*anyopaque, schema: *anyopaque, io: Io, scratch: Allocator, instance: []const u8) CheckError!Verdict,
    /// Frees a schema `compile` returned.
    destroy: *const fn (ptr: ?*anyopaque, schema: *anyopaque) void,
};

pub const CompileError = Allocator.Error || Io.Cancelable || error{Refused};
pub const CheckError = Allocator.Error || Io.Cancelable;

/// What a schema `pattern` that cannot run in linear time becomes: the
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

/// What one instance came to.
pub const Verdict = union(enum) {
    /// Valid: and the keywords left unchecked on the way, by their locations
    /// (`Patterns.downgrade`).
    valid: []const []const u8,
    invalid: Failure,
};

/// A compiled schema and the validator it came from.
pub const Schema = struct {
    ptr: *anyopaque,
    validator: *const Validator,

    fn deinit(s: *Schema) void {
        s.validator.vtable.destroy(s.validator.ptr, s.ptr);
    }
};

/// A compiled schema, held by whoever validates against it; the last
/// release frees it.
pub const Compiled = aegis.Shared(Schema, Schema.deinit);

/// `schema` compiled by `v`, as `VTable.compile` says.
pub fn compile(v: *const Validator, gpa: Allocator, io: Io, schema: []const u8, patterns: Patterns, arena: Allocator, failure: ?*Failure) CompileError!Compiled {
    const ptr = try v.vtable.compile(v.ptr, gpa, io, schema, patterns, arena, failure);
    errdefer v.vtable.destroy(v.ptr, ptr);
    return .create(gpa, .{ .ptr = ptr, .validator = v });
}

/// `instance` against `schema`, as `VTable.check` says.
pub fn check(schema: *const Compiled, io: Io, scratch: Allocator, instance: []const u8) CheckError!Verdict {
    const s = schema.get();
    return s.validator.vtable.check(s.validator.ptr, s.ptr, io, scratch, instance);
}

/// `failure` as one line: the message, then where.
pub fn describe(arena: Allocator, failure: Failure) Allocator.Error![]const u8 {
    if (failure.instance_location.len != 0) return arena.print("{s} at {s}", .{ failure.message, failure.instance_location });
    if (failure.schema_location.len != 0) return arena.print("{s} at {s}", .{ failure.message, failure.schema_location });
    return failure.message;
}
