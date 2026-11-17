//! `parley.validation`: JSON Schema validation through strand_schema, the
//! validator an application gives a client or a server
//! (`.validator = &parley.validation.json_schema`). A module of its own over
//! a lazy dependency: strand_schema is fetched with parley and compiled only
//! in a program that imports this module.
const std = @import("std");
const parley = @import("parley");
const strand_schema = @import("strand_schema");
const strand = strand_schema.strand;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Validator = parley.Validator;

/// strand_schema's validator: draft 2020-12 (and the drafts a schema's
/// `$schema` names), every `format` asserted by its strict recognizer, no
/// remote reference followed.
pub const json_schema: Validator = .{ .ptr = null, .vtable = &.{ .compile = compile, .check = check, .destroy = destroy } };

/// A compiled schema and the allocator it is freed with.
const Box = struct {
    gpa: Allocator,
    schema: strand_schema.Schema,
};

fn compile(_: ?*anyopaque, gpa: Allocator, io: Io, schema: []const u8, patterns: Validator.Patterns, arena: Allocator, failure: ?*Validator.Failure) Validator.CompileError!*anyopaque {
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
    const box = try gpa.create(Box);
    box.* = .{ .gpa = gpa, .schema = s };
    return box;
}

fn check(_: ?*anyopaque, schema: *anyopaque, io: Io, scratch: Allocator, instance: []const u8) Validator.CheckError!Validator.Verdict {
    const box: *Box = @ptrCast(@alignCast(schema));
    var errors: strand_schema.Schema.Errors = .{};
    const valid = box.schema.validate(io, scratch, strand.json, .init(instance), .{ .basic = &errors }) catch |err| switch (err) {
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

fn destroy(_: ?*anyopaque, schema: *anyopaque) void {
    const box: *Box = @ptrCast(@alignCast(schema));
    const gpa = box.gpa;
    box.schema.deinit();
    gpa.destroy(box);
}
