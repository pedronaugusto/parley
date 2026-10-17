//! What a server offers, each kept as the JSON `*/list` writes for it, made
//! once when it is added, and the handler that serves it, its types erased.
//! A typed handler's schemas are derived from its types at compile time by
//! strand; a dynamic one gives its own.
const std = @import("std");
const strand = @import("strand");
const types = @import("types.zig");
const Call = @import("Call.zig");

const Allocator = std.mem.Allocator;
const Raw = strand.json.Raw;

/// What a tool returns: content for the model, structured content for a
/// program, and whether it is an error the model may correct.
pub const ToolResult = struct {
    /// A text block, written before `content`: the common answer, with
    /// nothing to allocate for it.
    text: ?[]const u8 = null,
    content: []const types.ContentBlock = &.{},
    /// One JSON value, matching the tool's output schema when it has one.
    structured: ?Raw = null,
    is_error: bool = false,

    pub fn ofText(s: []const u8) ToolResult {
        return .{ .text = s };
    }

    /// An execution error: the model reads `message` and may try again.
    pub fn failure(message: []const u8) ToolResult {
        return .{ .text = message, .is_error = true };
    }
};

/// How a tool is listed. Its schemas are its handler's types' unless given
/// here, as JSON, kept byte for byte (`$schema`, `$defs` and any 2020-12
/// keyword).
pub const ToolSpec = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    annotations: ?types.ToolAnnotations = null,
    icons: ?[]const types.Icon = null,
    input_schema: ?[]const u8 = null,
    output_schema: ?[]const u8 = null,
    /// The tool's `_meta`, one JSON object.
    meta: ?[]const u8 = null,
    /// Whether a call may run as a task (the tasks extension).
    task: TaskSupport = .forbidden,
};

/// Whether a tool's calls may run as tasks: the handler decides per call
/// with `Call.runAsTask`, when the client declared the extension.
pub const TaskSupport = enum {
    /// Every call is answered as it is asked.
    forbidden,
    /// A call may run as a task.
    optional,
    /// A call must be able to run as a task: a client that did not declare
    /// the extension is refused (`-32021`) before the handler runs.
    required,
};

/// A handler whose types are erased: `arguments` is the call's arguments
/// object as written, or null.
pub const ToolHandler = struct {
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, call: *Call, arguments: ?[]const u8) Call.Error!ToolResult,
};

pub const Tool = struct {
    name: []const u8,
    /// The `Tool` object, as `tools/list` writes it.
    listed: []const u8,
    handler: ToolHandler,
    /// The arguments its schema mirrors into `Mcp-Param-{name}` headers.
    headers: []const HeaderParam = &.{},
    task: TaskSupport = .forbidden,
};

/// An argument a tool's input schema marks with `x-mcp-header`: an HTTP
/// client sends its value as `Mcp-Param-{name}` too, and the server holds
/// the two to each other.
pub const HeaderParam = struct {
    /// The header's name after `Mcp-Param-`.
    name: []const u8,
    /// The argument's place: the property names from the root.
    path: []const []const u8,
    kind: Kind,

    pub const Kind = enum { string, integer, boolean };
};

/// The `x-mcp-header` marks of an input schema, on `gpa`, or
/// `error.InvalidSchema` for a mark 2026-07-28 does not allow: not a token,
/// two that differ only in case, on a property that is not a string, an
/// integer or a boolean, or reached other than through `properties`.
pub fn headerParams(gpa: Allocator, schema: []const u8) (Allocator.Error || error{InvalidSchema})![]const HeaderParam {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = strand.json.parseLeaky(strand.json.Value, arena.allocator(), schema, .{}) catch return error.InvalidSchema;
    var found: std.ArrayList(HeaderParam) = .empty;
    errdefer {
        for (found.items) |p| freeHeaderParam(gpa, p);
        found.deinit(gpa);
    }
    try collectHeaders(gpa, &found, root, &.{});
    if (!marksBelowProperties(root, false)) return error.InvalidSchema;
    for (found.items, 0..) |a, i| for (found.items[0..i]) |b| {
        if (std.ascii.eqlIgnoreCase(a.name, b.name)) return error.InvalidSchema;
    };
    return found.toOwnedSlice(gpa);
}

/// Frees what `headerParams` returned.
pub fn freeHeaderParams(gpa: Allocator, params: []const HeaderParam) void {
    for (params) |p| freeHeaderParam(gpa, p);
    gpa.free(params);
}

fn freeHeaderParam(gpa: Allocator, p: HeaderParam) void {
    gpa.free(p.name);
    freePath(gpa, p.path);
}

fn freePath(gpa: Allocator, path: []const []const u8) void {
    for (path) |step| gpa.free(step);
    gpa.free(path);
}

fn get(object: anytype, key: []const u8) ?strand.json.Value {
    for (object) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
    return null;
}

fn collectHeaders(gpa: Allocator, found: *std.ArrayList(HeaderParam), schema: strand.json.Value, path: []const []const u8) (Allocator.Error || error{InvalidSchema})!void {
    if (schema != .object) return;
    const properties = get(schema.object, "properties") orelse return;
    if (properties != .object) return;
    for (properties.object) |p| {
        if (p.value != .object) continue;
        const here = try std.mem.concat(gpa, []const u8, &.{ path, &.{p.key} });
        defer gpa.free(here);
        if (get(p.value.object, "x-mcp-header")) |mark| {
            if (mark != .string or !token(mark.string)) return error.InvalidSchema;
            const t = get(p.value.object, "type") orelse return error.InvalidSchema;
            if (t != .string) return error.InvalidSchema;
            const kind = std.meta.stringToEnum(HeaderParam.Kind, t.string) orelse return error.InvalidSchema;
            try found.ensureUnusedCapacity(gpa, 1);
            const steps = try gpa.alloc([]const u8, here.len);
            var filled: usize = 0;
            errdefer {
                for (steps[0..filled]) |step| gpa.free(step);
                gpa.free(steps);
            }
            for (steps, here) |*step, name| {
                step.* = try gpa.dupe(u8, name);
                filled += 1;
            }
            found.appendAssumeCapacity(.{ .name = try gpa.dupe(u8, mark.string), .path = steps, .kind = kind });
        }
        try collectHeaders(gpa, found, p.value, here);
    }
}

/// Whether every `x-mcp-header` in `schema` is reached through
/// `properties` alone (`under` says whether `schema` itself was).
fn marksBelowProperties(schema: strand.json.Value, under: bool) bool {
    switch (schema) {
        .object => |object| {
            for (object) |m| {
                if (std.mem.eql(u8, m.key, "x-mcp-header") and !under) return false;
                if (std.mem.eql(u8, m.key, "properties")) {
                    if (m.value == .object) for (m.value.object) |p| {
                        if (!marksBelowProperties(p.value, true)) return false;
                    };
                    continue;
                }
                if (!marksBelowProperties(m.value, false)) return false;
            }
            return true;
        },
        .array => |items| {
            for (items) |item| if (!marksBelowProperties(item, false)) return false;
            return true;
        },
        else => return true,
    }
}

/// RFC 9110's `1*tchar`.
fn token(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!ok) return false;
    }
    return true;
}

pub const ResourceSpec = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    size: ?u64 = null,
    annotations: ?types.Annotations = null,
    icons: ?[]const types.Icon = null,
    meta: ?[]const u8 = null,
};

pub const TemplateSpec = struct {
    uri_template: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    annotations: ?types.Annotations = null,
    icons: ?[]const types.Icon = null,
    meta: ?[]const u8 = null,
};

/// What reading a resource gives: its contents, one or more.
pub const ReadResult = struct {
    contents: []const types.ResourceContents,
};

pub const ReadHandler = struct {
    context: ?*anyopaque = null,
    /// `uri` is the URI asked for, which a template matched.
    read: *const fn (context: ?*anyopaque, call: *Call, uri: []const u8) Call.Error!ReadResult,
};

pub const Resource = struct {
    uri: []const u8,
    listed: []const u8,
    handler: ReadHandler,
};

pub const Template = struct {
    uri_template: []const u8,
    listed: []const u8,
    handler: ReadHandler,
};

pub const PromptSpec = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Null: derived from a typed handler's argument struct.
    arguments: ?[]const types.PromptArgument = null,
    icons: ?[]const types.Icon = null,
    meta: ?[]const u8 = null,
};

pub const PromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const types.PromptMessage,
};

pub const PromptHandler = struct {
    context: ?*anyopaque = null,
    /// `arguments` is the request's arguments object (names to strings), or null.
    get: *const fn (context: ?*anyopaque, call: *Call, arguments: ?[]const u8) Call.Error!PromptResult,
};

pub const Prompt = struct {
    name: []const u8,
    listed: []const u8,
    /// The names of the arguments that must be given.
    required: []const []const u8,
    handler: PromptHandler,
};

/// `Tool` JSON for `spec`, on `gpa`.
pub fn listTool(gpa: Allocator, spec: ToolSpec, input_schema: []const u8, output_schema: ?[]const u8) (Allocator.Error || error{InvalidSchema})![]const u8 {
    try checkObject(input_schema);
    if (output_schema) |s| try checkObject(s);
    const Listed = struct {
        name: []const u8,
        title: ?[]const u8,
        description: ?[]const u8,
        inputSchema: Raw,
        outputSchema: ?Raw,
        annotations: ?types.ToolAnnotations,
        icons: ?[]const types.Icon,
        _meta: ?Raw,
    };
    return encode(gpa, Listed{
        .name = spec.name,
        .title = spec.title,
        .description = spec.description,
        .inputSchema = .{ .bytes = input_schema },
        .outputSchema = if (output_schema) |s| .{ .bytes = s } else null,
        .annotations = spec.annotations,
        .icons = spec.icons,
        ._meta = if (spec.meta) |m| .{ .bytes = m } else null,
    });
}

pub fn listResource(gpa: Allocator, spec: ResourceSpec) (Allocator.Error || error{InvalidSchema})![]const u8 {
    return encode(gpa, types.Resource{
        .uri = spec.uri,
        .name = spec.name,
        .title = spec.title,
        .description = spec.description,
        .mime_type = spec.mime_type,
        .annotations = spec.annotations,
        .size = spec.size,
        .icons = spec.icons,
        .meta = if (spec.meta) |m| .{ .bytes = m } else null,
    });
}

pub fn listTemplate(gpa: Allocator, spec: TemplateSpec) (Allocator.Error || error{InvalidSchema})![]const u8 {
    return encode(gpa, types.ResourceTemplate{
        .uri_template = spec.uri_template,
        .name = spec.name,
        .title = spec.title,
        .description = spec.description,
        .mime_type = spec.mime_type,
        .annotations = spec.annotations,
        .icons = spec.icons,
        .meta = if (spec.meta) |m| .{ .bytes = m } else null,
    });
}

pub fn listPrompt(gpa: Allocator, spec: PromptSpec, arguments: []const types.PromptArgument) (Allocator.Error || error{InvalidSchema})![]const u8 {
    return encode(gpa, types.Prompt{
        .name = spec.name,
        .title = spec.title,
        .description = spec.description,
        .arguments = if (arguments.len == 0) null else arguments,
        .icons = spec.icons,
        .meta = if (spec.meta) |m| .{ .bytes = m } else null,
    });
}

fn encode(gpa: Allocator, value: anytype) (Allocator.Error || error{InvalidSchema})![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    strand.json.write(&out.writer, value, types.write_options) catch |err| return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        // A `_meta` or schema given that is not JSON.
        else => error.InvalidSchema,
    };
    return out.toOwnedSlice();
}

/// A schema given as JSON must be one object.
fn checkObject(bytes: []const u8) error{InvalidSchema}!void {
    var members: strand.json.Members = undefined;
    members.init(bytes, .{});
    _ = members.finish() catch return error.InvalidSchema;
}

// Typed handlers.

/// The input schema of a tool whose handler takes `Args`.
pub fn inputSchema(comptime Args: type) []const u8 {
    if (Args == void) return "{\"type\":\"object\",\"additionalProperties\":false}";
    if (@typeInfo(Args) != .@"struct" or @typeInfo(Args).@"struct".is_tuple)
        @compileError("a tool's arguments are a struct: MCP's input schema is an object");
    return comptime strand.json.schema.of(Args, .{ .dialect = false });
}

/// The output schema of a tool whose handler returns `Out`, or null when it
/// returns content rather than structured data.
pub fn outputSchema(comptime Out: type) ?[]const u8 {
    if (Out == ToolResult or Out == []const u8 or Out == void) return null;
    if (@typeInfo(Out) != .@"struct" or @typeInfo(Out).@"struct".is_tuple)
        @compileError("a tool's structured output is a struct: MCP's output schema is an object");
    return comptime strand.json.schema.of(Out, .{ .dialect = false, .direction = .encode });
}

/// What a handler function takes and returns: `fn (*Call) E!Out` or
/// `fn (*Call, Args) E!Out`.
pub fn Signature(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.param_types.len == 0 or info.param_types[0] != *Call or info.param_types.len > 2)
        @compileError("a handler is fn (*parley.Call) or fn (*parley.Call, Args)");
    const R = info.return_type.?;
    if (@typeInfo(R) != .error_union) @compileError("a handler returns an error union: it may be canceled");
    return struct {
        pub const Args = if (info.param_types.len == 2) info.param_types[1].? else void;
        pub const Out = @typeInfo(R).error_union.payload;
        pub const HandlerError = @typeInfo(R).error_union.error_set;
    };
}

/// `handler` as a `ToolHandler`: its arguments decoded with strand (a
/// decode failure is an execution error naming the field, which the model
/// can correct), its result turned into a `ToolResult`, and any error of its
/// own an execution error naming it.
pub fn typedTool(comptime handler: anytype) ToolHandler {
    const S = Signature(handler);
    const Erased = struct {
        fn call(_: ?*anyopaque, c: *Call, arguments: ?[]const u8) Call.Error!ToolResult {
            const out = if (S.Args == void)
                handler(c)
            else blk: {
                var diagnostics: strand.core.Diagnostics = .{};
                var options = types.read_options;
                options.ignore_unknown_fields = false;
                options.diagnostics = &diagnostics;
                const args = strand.json.parseLeaky(S.Args, c.arena, arguments orelse "{}", options) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return .failure(try invalidArguments(c.arena, err, &diagnostics)),
                };
                break :blk handler(c, args);
            };
            const value = out catch |err| return handlerError(err);
            return toolResult(c.arena, value);
        }
    };
    return .{ .call = Erased.call };
}

fn invalidArguments(arena: Allocator, err: anyerror, diagnostics: *const strand.core.Diagnostics) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("invalid arguments: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
    const steps = diagnostics.path.frames();
    if (steps.len != 0) {
        w.writeAll(" at ") catch return error.OutOfMemory;
        for (steps, 0..) |step, i| switch (step.kind) {
            .field => w.print("{s}{s}", .{ if (i == 0) "" else ".", step.name.view() }) catch return error.OutOfMemory,
            .index => w.print("[{d}]", .{step.index}) catch return error.OutOfMemory,
        };
    }
    return out.written();
}

/// A handler's error: the core's pass through; its own become an
/// execution error naming them.
fn handlerError(err: anyerror) Call.Error!ToolResult {
    inline for (@typeInfo(Call.Error).error_set.error_names.?) |name| if (err == @field(Call.Error, name)) return @field(Call.Error, name);
    return .failure(@errorName(err));
}

fn toolResult(arena: Allocator, value: anytype) Call.Error!ToolResult {
    const Out = @TypeOf(value);
    if (Out == ToolResult) return value;
    if (Out == void) return .{};
    if (Out == []const u8) return .ofText(value);
    // Structured: the value, and the same JSON as text for a client that
    // reads only content (2025-06-18 tools: SHOULD).
    var out: std.Io.Writer.Allocating = .init(arena);
    strand.json.write(&out.writer, value, types.write_options) catch |err| return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        else => .failure(@errorName(err)),
    };
    return .{ .text = out.written(), .structured = .{ .bytes = out.written() } };
}

/// The arguments of a prompt whose handler takes `Args`: each field a
/// string, required unless it is optional or has a default.
pub fn promptArguments(comptime Args: type) []const types.PromptArgument {
    if (Args == void) return &.{};
    comptime {
        const info = @typeInfo(Args).@"struct";
        var out: [info.field_names.len]types.PromptArgument = undefined;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (F != []const u8 and F != ?[]const u8) @compileError("a prompt's arguments are strings: " ++ name);
            out[i] = .{ .name = name, .required = if (F == []const u8 and attrs.default_value_ptr == null) true else null };
        }
        const final = out;
        return &final;
    }
}

/// `handler` as a `PromptHandler`, its arguments decoded with strand.
pub fn typedPrompt(comptime handler: anytype) PromptHandler {
    const S = Signature(handler);
    const Erased = struct {
        fn get(_: ?*anyopaque, c: *Call, arguments: ?[]const u8) Call.Error!PromptResult {
            const out = if (S.Args == void) handler(c) else blk: {
                const args = strand.json.parseLeaky(S.Args, c.arena, arguments orelse "{}", types.read_options) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidInput,
                };
                break :blk handler(c, args);
            };
            return out catch |err| ownError(err);
        }
    };
    return .{ .get = Erased.get };
}

/// A handler's error: the core's pass through; any of its own is
/// `HandlerFailed`, answered as an internal error.
pub fn ownError(err: anyerror) Call.Error {
    inline for (@typeInfo(Call.Error).error_set.error_names.?) |name| if (err == @field(Call.Error, name)) return @field(Call.Error, name);
    return error.HandlerFailed;
}
