//! The core: what a server offers, and one request answered with one reply.
//! It holds no connection: everything it knows of a caller comes with the
//! request (`Context`), so the same server answers over stdio and HTTP, in
//! the 2026-07-28 revision and, through the session layer, the ones before.
const Server = @This();

const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const types = @import("types.zig");
const wire = @import("wire.zig");
const meta = @import("meta.zig");
const state = @import("state.zig");
const registry = @import("registry.zig");
const subscriptions = @import("subscriptions.zig");
const Call = @import("Call.zig");
const Revision = @import("revision.zig").Revision;
const Context = @import("context.zig").Context;
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Raw = strand.json.Raw;
const Writer = std.Io.Writer;

/// A span as MCP writes one: whole milliseconds.
pub const Duration = aegis.units.Duration(.millisecond, u32);

gpa: Allocator,
options: Options,
/// Private: seals the state a handler keeps across rounds.
sealer: state.Sealer,
/// Private: `"io.modelcontextprotocol/serverInfo":{...}`, written in every
/// 2026-07-28 result's `_meta`.
identity: []const u8,
/// Private: guards the four lists and their generations.
lock: Io.RwLock = .init,
tools: std.ArrayList(*registry.Tool) = .empty,
resources: std.ArrayList(*registry.Resource) = .empty,
templates: std.ArrayList(*registry.Template) = .empty,
prompts: std.ArrayList(*registry.Prompt) = .empty,
completer: ?Completer = null,
/// Private: bumped when a list changes, so a cursor into an older list is
/// refused rather than read against the new one.
generations: std.EnumArray(List, u32) = .initFill(0),
/// The open change streams.
hub: subscriptions.Hub = .{},

pub const Options = struct {
    info: types.Implementation,
    instructions: ?[]const u8 = null,
    /// How long a client may keep each list and read, and who may share it.
    cache: Cache = .{},
    /// Items per list page; null lists everything on one page.
    page_size: ?u32 = null,
    request_state: RequestState = .{},
    limits: Limits = .{},
    /// What is offered whatever is registered: a server that adds its tools
    /// later still says it has tools. Null: offered when registered.
    offers: Offers = .{},
    /// Whether a request's log lines are sent (when it asks for them).
    logging: bool = true,
    /// Whether every 2026-07-28 result names the server in its `_meta`.
    identify: bool = true,
    /// Decides per request what a client may see and use.
    filter: ?Filter = null,
};

pub const Cache = struct {
    discover: Hint = .{},
    tools: Hint = .{},
    prompts: Hint = .{},
    resources: Hint = .{},
    templates: Hint = .{},
    /// A read is about the user who made it unless said otherwise.
    read: Hint = .{ .scope = .private },

    pub const Hint = struct {
        ttl: Duration = .literal("0ms"),
        scope: types.CacheScope = .public,
    };
};

pub const RequestState = struct {
    /// The sealing key; null draws one when the server starts, so state
    /// sealed by one process opens only in it.
    key: ?[32]u8 = null,
    ttl: Duration = .literal("10m"),
};

pub const Limits = struct {
    /// Open `subscriptions/listen` streams and legacy session streams.
    listeners: u32 = 64,
    /// Resources one stream watches.
    watched: u32 = 256,
    /// Input requests in one input-required answer.
    input_requests: u32 = 16,
    /// A handler's state, before sealing.
    state: aegis.units.Bytes(u32) = .literal("64KiB"),
};

pub const Offers = struct {
    tools: ?bool = null,
    resources: ?bool = null,
    prompts: ?bool = null,
};

/// The four lists a server keeps.
pub const List = enum { tools, resources, templates, prompts };

pub const Filter = struct {
    context: ?*anyopaque = null,
    /// Whether the request may see and use the item of `list` named `name`
    /// (a tool or prompt name, a resource URI or template). A list a filter
    /// shapes is private to its caller.
    admit: *const fn (context: ?*anyopaque, request: *const Context, which: List, name: []const u8) bool,
};

/// Completes an argument of a prompt or a resource template.
pub const Completer = struct {
    context: ?*anyopaque = null,
    complete: *const fn (context: ?*anyopaque, call: *Call, request: types.CompleteParams) Call.Error!types.Completion,
};

pub const InitError = Allocator.Error || Io.RandomSecureError;

pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Server {
    var sealer = if (options.request_state.key) |key| state.Sealer.withKey(key, options.request_state.ttl.toIoDuration()) else try state.Sealer.init(io, options.request_state.ttl.toIoDuration());
    errdefer sealer.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.writeAll("\"" ++ meta.server_info ++ "\":") catch return error.OutOfMemory;
    strand.json.write(&out.writer, options.info, types.write_options) catch return error.OutOfMemory;
    return .{ .gpa = gpa, .options = options, .sealer = sealer, .identity = try out.toOwnedSlice() };
}

pub fn deinit(s: *Server) void {
    for (s.tools.items) |t| s.freeEntry(t);
    for (s.resources.items) |r| s.freeEntry(r);
    for (s.templates.items) |t| s.freeEntry(t);
    for (s.prompts.items) |p| {
        for (p.required) |r| s.gpa.free(r);
        s.gpa.free(p.required);
        s.freeEntry(p);
    }
    s.tools.deinit(s.gpa);
    s.resources.deinit(s.gpa);
    s.templates.deinit(s.gpa);
    s.prompts.deinit(s.gpa);
    s.hub.deinit(s.gpa);
    s.gpa.free(s.identity);
    s.sealer.deinit();
}

fn freeEntry(s: *Server, entry: anytype) void {
    inline for (@typeInfo(@TypeOf(entry.*)).@"struct".field_names) |name| {
        const F = @FieldType(@TypeOf(entry.*), name);
        if (F == []const u8) s.gpa.free(@field(entry, name));
    }
    s.gpa.destroy(entry);
}

/// Ends every change stream, each with a `complete` result.
pub fn close(s: *Server, io: Io) void {
    s.hub.close(io);
}

// Registration. Each change to a list is a list change: the streams that
// asked are told.

pub const AddError = Allocator.Error || Io.Cancelable || error{ Duplicate, InvalidSchema };

/// Adds a tool whose arguments and result are `handler`'s types: `fn
/// (*Call, Args) E!Out` or `fn (*Call) E!Out`. `Args` is a struct whose
/// schema is the input schema; `Out` is `ToolResult`, text (`[]const u8`),
/// `void`, or a struct written as structured content with its schema as the
/// output schema.
pub fn addTool(s: *Server, io: Io, spec: registry.ToolSpec, comptime handler: anytype) AddError!void {
    const S = registry.Signature(handler);
    return s.addToolWith(io, spec, spec.input_schema orelse registry.inputSchema(S.Args), spec.output_schema orelse registry.outputSchema(S.Out), registry.typedTool(handler));
}

/// Adds a tool with a handler that takes its arguments as JSON; `spec`
/// must give its input schema.
pub fn addDynamicTool(s: *Server, io: Io, spec: registry.ToolSpec, handler: registry.ToolHandler) AddError!void {
    return s.addToolWith(io, spec, spec.input_schema orelse return error.InvalidSchema, spec.output_schema, handler);
}

fn addToolWith(s: *Server, io: Io, spec: registry.ToolSpec, input: []const u8, output: ?[]const u8, handler: registry.ToolHandler) AddError!void {
    const tool = try s.gpa.create(registry.Tool);
    errdefer s.gpa.destroy(tool);
    const name = try s.gpa.dupe(u8, spec.name);
    errdefer s.gpa.free(name);
    const listed = try registry.listTool(s.gpa, spec, input, output);
    errdefer s.gpa.free(listed);
    tool.* = .{ .name = name, .listed = listed, .handler = handler };
    try s.insert(io, .tools, &s.tools, tool, name);
}

/// Removes the tool named `name`; false when there is none.
pub fn removeTool(s: *Server, io: Io, name: []const u8) Io.Cancelable!bool {
    return s.remove(io, .tools, &s.tools, name);
}

/// Adds a resource read by `read`.
pub fn addResource(s: *Server, io: Io, spec: registry.ResourceSpec, handler: registry.ReadHandler) AddError!void {
    const resource = try s.gpa.create(registry.Resource);
    errdefer s.gpa.destroy(resource);
    const uri = try s.gpa.dupe(u8, spec.uri);
    errdefer s.gpa.free(uri);
    const listed = try registry.listResource(s.gpa, spec);
    errdefer s.gpa.free(listed);
    resource.* = .{ .uri = uri, .listed = listed, .handler = handler };
    try s.insert(io, .resources, &s.resources, resource, uri);
}

pub fn removeResource(s: *Server, io: Io, uri: []const u8) Io.Cancelable!bool {
    return s.remove(io, .resources, &s.resources, uri);
}

/// Adds a resource template: a URI that matches it (RFC 6570, `{name}` a
/// segment, `{+name}` anything) is read by `read`.
pub fn addTemplate(s: *Server, io: Io, spec: registry.TemplateSpec, handler: registry.ReadHandler) AddError!void {
    const template = try s.gpa.create(registry.Template);
    errdefer s.gpa.destroy(template);
    const pattern = try s.gpa.dupe(u8, spec.uri_template);
    errdefer s.gpa.free(pattern);
    const listed = try registry.listTemplate(s.gpa, spec);
    errdefer s.gpa.free(listed);
    template.* = .{ .uri_template = pattern, .listed = listed, .handler = handler };
    try s.insert(io, .templates, &s.templates, template, pattern);
}

/// Adds a prompt whose arguments are `handler`'s argument struct (string
/// fields, required unless optional or defaulted).
pub fn addPrompt(s: *Server, io: Io, spec: registry.PromptSpec, comptime handler: anytype) AddError!void {
    const S = registry.Signature(handler);
    return s.addPromptWith(io, spec, spec.arguments orelse comptime registry.promptArguments(S.Args), registry.typedPrompt(handler));
}

/// Adds a prompt whose handler takes its arguments as JSON.
pub fn addDynamicPrompt(s: *Server, io: Io, spec: registry.PromptSpec, handler: registry.PromptHandler) AddError!void {
    return s.addPromptWith(io, spec, spec.arguments orelse &.{}, handler);
}

fn addPromptWith(s: *Server, io: Io, spec: registry.PromptSpec, arguments: []const types.PromptArgument, handler: registry.PromptHandler) AddError!void {
    const prompt = try s.gpa.create(registry.Prompt);
    errdefer s.gpa.destroy(prompt);
    const name = try s.gpa.dupe(u8, spec.name);
    errdefer s.gpa.free(name);
    const listed = try registry.listPrompt(s.gpa, spec, arguments);
    errdefer s.gpa.free(listed);
    var required: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (required.items) |r| s.gpa.free(r);
        required.deinit(s.gpa);
    }
    for (arguments) |a| if (a.required orelse false) try required.append(s.gpa, try s.gpa.dupe(u8, a.name));
    prompt.* = .{ .name = name, .listed = listed, .required = try required.toOwnedSlice(s.gpa), .handler = handler };
    try s.insert(io, .prompts, &s.prompts, prompt, name);
}

pub fn removePrompt(s: *Server, io: Io, name: []const u8) Io.Cancelable!bool {
    return s.remove(io, .prompts, &s.prompts, name);
}

/// Completes prompt and template arguments with `completer`.
pub fn setCompleter(s: *Server, completer: Completer) void {
    s.completer = completer;
}

/// The resource `uri` changed: streams watching it are told.
pub fn resourceUpdated(s: *Server, io: Io, uri: []const u8) void {
    s.hub.resourceUpdated(io, uri);
}

fn keyOf(entry: anytype) []const u8 {
    const E = @TypeOf(entry.*);
    if (@hasField(E, "uri_template")) return entry.uri_template;
    if (@hasField(E, "uri")) return entry.uri;
    return entry.name;
}

fn insert(s: *Server, io: Io, comptime which: List, items: anytype, entry: anytype, key: []const u8) AddError!void {
    {
        try s.lock.lock(io);
        defer s.lock.unlock(io);
        for (items.items) |e| if (std.mem.eql(u8, keyOf(e), key)) return error.Duplicate;
        try items.append(s.gpa, entry);
        s.generations.getPtr(which).* +%= 1;
    }
    s.hub.listChanged(io, changeOf(which));
}

fn remove(s: *Server, io: Io, comptime which: List, items: anytype, key: []const u8) Io.Cancelable!bool {
    const gone = found: {
        try s.lock.lock(io);
        defer s.lock.unlock(io);
        for (items.items, 0..) |e, i| if (std.mem.eql(u8, keyOf(e), key)) {
            // Order kept: a list is written in the order it was made.
            break :found items.orderedRemove(i);
        };
        return false;
    };
    s.generations.getPtr(which).* +%= 1;
    // A handler running now holds no pointer into the entry: it was copied out.
    if (which == .prompts) {
        for (gone.required) |r| s.gpa.free(r);
        s.gpa.free(gone.required);
    }
    s.freeEntry(gone);
    s.hub.listChanged(io, changeOf(which));
    return true;
}

fn changeOf(which: List) subscriptions.Kind {
    return switch (which) {
        .tools => .tools,
        .prompts => .prompts,
        .resources, .templates => .resources,
    };
}

// Answering.

/// What a request is answered with.
pub const Reply = union(enum) {
    /// The result object, as JSON.
    result: []const u8,
    /// The handler needs input first. Under 2026-07-28 it is the result;
    /// under an earlier revision the session asks the client for it.
    input_required: InputRequired,
    failure: Failure,
};

pub const InputRequired = struct {
    requests: []const Call.Pending,
    /// Sealed; null when the handler kept none.
    state: ?[]const u8,
};

pub const Failure = struct {
    code: wire.Code,
    message: []const u8,
    /// One JSON value, or null.
    data: ?[]const u8 = null,
    /// The request lacks what every request must carry: over HTTP, a 400.
    malformed: bool = false,
};

/// `Canceled`: the request was canceled, and nothing is answered.
pub const HandleError = error{ Canceled, OutOfMemory };

/// Answers a 2026-07-28 request: its context is read from its `_meta`, and
/// one that lacks what every request must carry, or names a version this
/// server does not speak, is refused. `principal` is who sent it, as the
/// transport authenticated them.
pub fn serve(s: *Server, io: Io, arena: Allocator, request: wire.Request, principal: ?[]const u8, sink: Sink) HandleError!Reply {
    const m = meta.read(arena, request.params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return malformed("params or _meta are not what the schema says"),
    };
    if (m.raw == null) return malformed("the request has no _meta: every request carries its protocol version and client capabilities");
    const version = m.version orelse return malformed("_meta has no io.modelcontextprotocol/protocolVersion");
    const revision = Revision.named(version) orelse return try unsupported(arena, version);
    if (!revision.stateless()) return try unsupported(arena, version);
    const client = m.client_capabilities orelse return malformed("_meta has no io.modelcontextprotocol/clientCapabilities");
    const context: Context = .{
        .revision = revision,
        .client = client,
        .client_info = m.client_info,
        .log_level = m.log_level,
        .progress_token = m.progress_token,
        .meta = m.raw,
        .principal = principal,
    };
    return s.handle(io, arena, request, &context, sink);
}

/// `-32022`, naming the versions served and the one asked for.
pub fn unsupported(arena: Allocator, requested: []const u8) Allocator.Error!Reply {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"supported\":[") catch return error.OutOfMemory;
    inline for (@typeInfo(Revision).@"enum".field_names, 0..) |name, i| {
        w.writeAll((if (i == 0) "" else ",") ++ "\"" ++ name ++ "\"") catch return error.OutOfMemory;
    }
    w.writeAll("],\"requested\":") catch return error.OutOfMemory;
    wire.writeString(w, requested) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    return .{ .failure = .{ .code = .unsupported_protocol_version, .message = "Unsupported protocol version", .data = out.written() } };
}

fn malformed(message: []const u8) Reply {
    return .{ .failure = .{ .code = .invalid_params, .message = message, .malformed = true } };
}

fn failure(code: wire.Code, message: []const u8) Reply {
    return .{ .failure = .{ .code = code, .message = message } };
}

/// Answers `request` in `context`. The session layer calls it for a request
/// under an earlier revision, with the context its handshake gave.
pub fn handle(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) HandleError!Reply {
    const methods = [_][]const u8{
        "server/discover", "tools/list",   "tools/call",  "resources/list",      "resources/templates/list",
        "resources/read",  "prompts/list", "prompts/get", "completion/complete", "subscriptions/listen",
    };
    const index = for (methods, 0..) |name, i| {
        if (std.mem.eql(u8, request.method, name)) break i;
    } else return failure(.method_not_found, "Method not found");
    return switch (index) {
        0 => s.discover(arena, context),
        1 => s.listPage(io, arena, .tools, request.params, context),
        2 => s.callTool(io, arena, request, context, sink),
        3 => s.listPage(io, arena, .resources, request.params, context),
        4 => s.listPage(io, arena, .templates, request.params, context),
        5 => s.readResource(io, arena, request, context, sink),
        6 => s.listPage(io, arena, .prompts, request.params, context),
        7 => s.getPrompt(io, arena, request, context, sink),
        8 => s.complete(io, arena, request, context, sink),
        9 => if (context.revision.stateless()) s.listen(io, arena, request, sink) else failure(.method_not_found, "Method not found"),
        else => unreachable,
    };
}

/// A result object being written: `resultType` first under 2026-07-28,
/// then the members, then the caching hints and the server's identity.
const Result = struct {
    out: Writer.Allocating,
    revision: Revision,

    fn begin(arena: Allocator, revision: Revision) Result {
        return .{ .out = .init(arena), .revision = revision };
    }

    fn w(r: *Result) *Writer {
        return &r.out.writer;
    }

    /// `"name":` and `value` as strand writes it, after the members before it.
    fn field(r: *Result, name: []const u8, value: anytype) HandleError!void {
        r.separate() catch return error.OutOfMemory;
        wire.writeString(r.w(), name) catch return error.OutOfMemory;
        r.w().writeByte(':') catch return error.OutOfMemory;
        strand.json.write(r.w(), value, types.write_options) catch |err| return switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            // A value a handler built that is not JSON (text that is not
            // UTF-8): the result cannot be written.
            else => error.OutOfMemory,
        };
    }

    /// `"name":` and `json`, one value as written.
    fn raw(r: *Result, name: []const u8, json: []const u8) HandleError!void {
        r.separate() catch return error.OutOfMemory;
        wire.writeString(r.w(), name) catch return error.OutOfMemory;
        r.w().writeByte(':') catch return error.OutOfMemory;
        r.w().writeAll(json) catch return error.OutOfMemory;
    }

    fn separate(r: *Result) Writer.Error!void {
        if (r.out.written().len == 0) {
            try r.w().writeByte('{');
            if (r.revision.stateless()) try r.w().writeAll("\"resultType\":\"complete\",");
        } else if (r.out.written()[r.out.written().len - 1] != '{') try r.w().writeByte(',');
    }

    /// Ends the object: caching hints when `hint` is given (2026-07-28),
    /// the server's identity when it names itself.
    fn end(r: *Result, s: *const Server, hint: ?Cache.Hint, private: bool) HandleError![]const u8 {
        if (r.revision.stateless()) {
            if (hint) |h| {
                try r.field("ttlMs", h.ttl.raw());
                try r.field("cacheScope", if (private) types.CacheScope.private else h.scope);
            }
            if (s.options.identify) {
                r.separate() catch return error.OutOfMemory;
                r.w().print("\"_meta\":{{{s}}}", .{s.identity}) catch return error.OutOfMemory;
            }
        }
        if (r.out.written().len == 0) {
            r.separate() catch return error.OutOfMemory;
        }
        r.w().writeByte('}') catch return error.OutOfMemory;
        return r.out.written();
    }
};

fn capabilities(s: *Server) types.ServerCapabilities {
    const offered = struct {
        fn of(given: ?bool, have: bool) bool {
            return given orelse have;
        }
    }.of;
    return .{
        .tools = if (offered(s.options.offers.tools, s.tools.items.len != 0)) .{ .list_changed = true } else null,
        .resources = if (offered(s.options.offers.resources, s.resources.items.len + s.templates.items.len != 0)) .{ .subscribe = true, .list_changed = true } else null,
        .prompts = if (offered(s.options.offers.prompts, s.prompts.items.len != 0)) .{ .list_changed = true } else null,
        .completions = if (s.completer != null) .{} else null,
        .logging = if (s.options.logging) .{} else null,
    };
}

/// The server's capabilities as `initialize` and `server/discover` write them.
pub fn capabilitiesJson(s: *Server, io: Io, arena: Allocator) HandleError![]const u8 {
    s.lock.lockShared(io) catch return error.Canceled;
    defer s.lock.unlockShared(io);
    var out: Writer.Allocating = .init(arena);
    strand.json.write(&out.writer, s.capabilities(), types.write_options) catch return error.OutOfMemory;
    return out.written();
}

fn discover(s: *Server, arena: Allocator, context: *const Context) HandleError!Reply {
    var r: Result = .begin(arena, context.revision);
    const versions = comptime blk: {
        var names: []const []const u8 = &.{};
        for (@typeInfo(Revision).@"enum".field_names) |name| names = names ++ .{name};
        break :blk names;
    };
    try r.field("supportedVersions", versions);
    try r.field("capabilities", s.capabilities());
    if (s.options.instructions) |text| try r.field("instructions", text);
    return .{ .result = try r.end(s, s.options.cache.discover, false) };
}

fn admitted(s: *const Server, context: *const Context, which: List, name: []const u8) bool {
    const f = s.options.filter orelse return true;
    return f.admit(f.context, context, which, name);
}

fn parseParams(comptime T: type, arena: Allocator, params: ?[]const u8) HandleError!?T {
    return strand.json.parseLeaky(T, arena, params orelse "{}", types.read_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// One page of a list. A cursor names the list's generation and an offset:
/// a cursor into a list that changed since is refused.
fn listPage(s: *Server, io: Io, arena: Allocator, comptime which: List, params: ?[]const u8, context: *const Context) HandleError!Reply {
    const p = try parseParams(types.PaginatedParams, arena, params) orelse return failure(.invalid_params, "params are not what the schema says");
    s.lock.lockShared(io) catch return error.Canceled;
    defer s.lock.unlockShared(io);
    const generation = s.generations.get(which);
    var start: usize = 0;
    if (p.cursor) |cursor| {
        const at = parseCursor(cursor) orelse return failure(.invalid_params, "the cursor is not one this server made");
        if (at.generation != generation) return failure(.invalid_params, "the list changed since the cursor was made: list again from the start");
        start = at.offset;
    }
    const items = switch (which) {
        .tools => s.tools.items,
        .resources => s.resources.items,
        .templates => s.templates.items,
        .prompts => s.prompts.items,
    };
    const name, const hint = switch (which) {
        .tools => .{ "tools", s.options.cache.tools },
        .resources => .{ "resources", s.options.cache.resources },
        .templates => .{ "resourceTemplates", s.options.cache.templates },
        .prompts => .{ "prompts", s.options.cache.prompts },
    };
    var r: Result = .begin(arena, context.revision);
    r.separate() catch return error.OutOfMemory;
    r.w().print("\"{s}\":[", .{name}) catch return error.OutOfMemory;
    const size = s.options.page_size orelse std.math.maxInt(u32);
    var written: usize = 0;
    var i = @min(start, items.len);
    while (i < items.len and written < size) : (i += 1) {
        const item = items[i];
        if (!s.admitted(context, which, keyOf(item))) continue;
        if (written != 0) r.w().writeByte(',') catch return error.OutOfMemory;
        r.w().writeAll(item.listed) catch return error.OutOfMemory;
        written += 1;
    }
    r.w().writeByte(']') catch return error.OutOfMemory;
    if (i < items.len) {
        var buffer: [32]u8 = undefined;
        try r.field("nextCursor", std.fmt.bufPrint(&buffer, "{d}.{d}", .{ generation, i }) catch unreachable); // unreachable: two integers fit 32 bytes
    }
    return .{ .result = try r.end(s, hint, s.options.filter != null) };
}

const Cursor = struct { generation: u32, offset: usize };

fn parseCursor(text: []const u8) ?Cursor {
    const dot = std.mem.findScalar(u8, text, '.') orelse return null;
    return .{
        .generation = std.fmt.parseInt(u32, text[0..dot], 10) catch return null,
        .offset = std.fmt.parseInt(usize, text[dot + 1 ..], 10) catch return null,
    };
}

/// The round a multi round-trip request is in: what the retry carried.
const Round = struct {
    responses: ?[]const u8,
    state: ?[]const u8,
};

/// Reads a retry's `inputResponses` and opens its `requestState`, bound to
/// what the request names.
fn round(s: *Server, io: Io, arena: Allocator, context: *const Context, method: []const u8, subject: []const u8, responses: ?Raw, sealed: ?[]const u8) HandleError!union(enum) { ok: Round, refused: Reply } {
    var result: Round = .{ .responses = null, .state = null };
    if (responses) |raw| {
        if (raw.bytes.len == 0 or raw.bytes[0] != '{') return .{ .refused = failure(.invalid_params, "inputResponses is not an object") };
        result.responses = raw.bytes;
    }
    if (sealed) |text| {
        result.state = s.sealer.open(io, arena, .{ .principal = context.principal, .method = method, .subject = subject }, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Tampered => return .{ .refused = failure(.invalid_params, "requestState is not one this server sealed for this request") },
            error.Expired => return .{ .refused = failure(.invalid_params, "requestState has expired: send the request again without it") },
        };
    }
    return .{ .ok = result };
}

fn newCall(io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink, r: Round) Call {
    return .{ .io = io, .arena = arena, .context = context, .id = request.id, .sink = sink, .responses = r.responses, .state_in = r.state };
}

/// What a handler's failure is answered with, or the input it asked for.
fn outcome(s: *Server, io: Io, arena: Allocator, call: *Call, err: Call.Error, method: []const u8, subject: []const u8) HandleError!Reply {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.InputRequired => s.inputRequired(io, arena, call, method, subject),
        error.MissingCapability => missing(arena, call.missing.?),
        error.InvalidInput => failure(.invalid_params, "an input response is not the answer to what was asked"),
        error.NotFound => failure(.invalid_params, "not found"),
        error.HandlerFailed => failure(.internal_error, "the handler failed"),
    };
}

fn inputRequired(s: *Server, io: Io, arena: Allocator, call: *Call, method: []const u8, subject: []const u8) HandleError!Reply {
    if (call.pending.items.len == 0 and call.state_out == null)
        return failure(.internal_error, "the handler asked for input without asking for any");
    if (call.pending.items.len > s.options.limits.input_requests) return failure(.internal_error, "the handler asked for more input than the server allows at once");
    var sealed: ?[]const u8 = null;
    if (call.state_out) |payload| {
        if (payload.len > s.options.limits.state.raw()) return failure(.internal_error, "the handler's state is past the server's limit");
        sealed = s.sealer.seal(io, arena, .{ .principal = call.context.principal, .method = method, .subject = subject }, payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.EntropyUnavailable => return failure(.internal_error, "no entropy to seal the request's state"),
        };
    }
    return .{ .input_required = .{ .requests = call.pending.items, .state = sealed } };
}

/// `-32021`, naming the capability as a `ClientCapabilities` object.
fn missing(arena: Allocator, kind: types.InputKind) HandleError!Reply {
    const data = switch (kind) {
        .elicit_form => "{\"requiredCapabilities\":{\"elicitation\":{\"form\":{}}}}",
        .elicit_url => "{\"requiredCapabilities\":{\"elicitation\":{\"url\":{}}}}",
        .sample => "{\"requiredCapabilities\":{\"sampling\":{}}}",
        .roots => "{\"requiredCapabilities\":{\"roots\":{}}}",
    };
    _ = arena;
    return .{ .failure = .{ .code = .missing_required_client_capability, .message = "Missing required client capability", .data = data } };
}

/// The JSON of an input-required answer under 2026-07-28.
pub fn inputRequiredJson(s: *const Server, arena: Allocator, ir: InputRequired) HandleError![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"resultType\":\"input_required\"") catch return error.OutOfMemory;
    if (ir.requests.len != 0) {
        w.writeAll(",\"inputRequests\":{") catch return error.OutOfMemory;
        for (ir.requests, 0..) |p, i| {
            if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
            wire.writeString(w, p.key) catch return error.OutOfMemory;
            w.writeByte(':') catch return error.OutOfMemory;
            strand.json.write(w, p.request, types.write_options) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
    }
    if (ir.state) |sealed| {
        w.writeAll(",\"requestState\":") catch return error.OutOfMemory;
        wire.writeString(w, sealed) catch return error.OutOfMemory;
    }
    if (s.options.identify) w.print(",\"_meta\":{{{s}}}", .{s.identity}) catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    return out.written();
}

fn callTool(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) HandleError!Reply {
    const p = try parseParams(types.CallToolParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    if (p.arguments) |a| if (a.bytes[0] != '{') return failure(.invalid_params, "arguments is not an object");
    const handler = found: {
        s.lock.lockShared(io) catch return error.Canceled;
        defer s.lock.unlockShared(io);
        for (s.tools.items) |t| if (std.mem.eql(u8, t.name, p.name)) break :found t.handler;
        break :found null;
    } orelse return try unknown(arena, "Unknown tool: ", p.name);
    if (!s.admitted(context, .tools, p.name)) return try unknown(arena, "Unknown tool: ", p.name);
    const r = switch (try s.round(io, arena, context, request.method, p.name, p.input_responses, p.request_state)) {
        .ok => |r| r,
        .refused => |reply| return reply,
    };
    var call = newCall(io, arena, request, context, sink, r);
    const result = handler.call(handler.context, &call, if (p.arguments) |a| a.bytes else null) catch |err|
        return s.outcome(io, arena, &call, err, request.method, p.name);
    var out: Result = .begin(arena, context.revision);
    if (result.text) |text| {
        const content = try arena.alloc(types.ContentBlock, result.content.len + 1);
        content[0] = .ofText(text);
        @memcpy(content[1..], result.content);
        try out.field("content", content);
    } else try out.field("content", result.content);
    if (result.structured) |value| try out.raw("structuredContent", value.bytes);
    if (result.is_error) try out.field("isError", true);
    return .{ .result = try out.end(s, null, false) };
}

fn unknown(arena: Allocator, comptime what: []const u8, name: []const u8) Allocator.Error!Reply {
    return failure(.invalid_params, try std.mem.concat(arena, u8, &.{ what, name }));
}

fn readResource(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) HandleError!Reply {
    const p = try parseParams(types.ReadResourceParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    const handler = found: {
        s.lock.lockShared(io) catch return error.Canceled;
        defer s.lock.unlockShared(io);
        for (s.resources.items) |res| if (std.mem.eql(u8, res.uri, p.uri)) {
            if (!s.admitted(context, .resources, res.uri)) break :found null;
            break :found res.handler;
        };
        for (s.templates.items) |t| if (matches(t.uri_template, p.uri)) {
            if (!s.admitted(context, .templates, t.uri_template)) break :found null;
            break :found t.handler;
        };
        break :found null;
    } orelse return try notFound(arena, context.revision, p.uri);
    const r = switch (try s.round(io, arena, context, request.method, p.uri, p.input_responses, p.request_state)) {
        .ok => |r| r,
        .refused => |reply| return reply,
    };
    var call = newCall(io, arena, request, context, sink, r);
    const result = handler.read(handler.context, &call, p.uri) catch |err| switch (err) {
        error.NotFound => return try notFound(arena, context.revision, p.uri),
        else => |e| return s.outcome(io, arena, &call, e, request.method, p.uri),
    };
    // An empty list would read as a resource with nothing in it (2026-07-28
    // resources: MUST NOT for one that does not exist).
    if (result.contents.len == 0) return try notFound(arena, context.revision, p.uri);
    var out: Result = .begin(arena, context.revision);
    try out.field("contents", result.contents);
    return .{ .result = try out.end(s, s.options.cache.read, s.options.filter != null) };
}

/// A resource that does not exist: `-32602` under 2026-07-28, `-32002`
/// before it, naming the URI.
fn notFound(arena: Allocator, revision: Revision, uri: []const u8) Allocator.Error!Reply {
    var out: Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"uri\":") catch return error.OutOfMemory;
    wire.writeString(&out.writer, uri) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    return .{ .failure = .{
        .code = if (revision.stateless()) .invalid_params else .resource_not_found,
        .message = "Resource not found",
        .data = out.written(),
    } };
}

/// Whether `uri` matches the RFC 6570 template `pattern`: literal text
/// matches itself, `{name}` one or more characters but `/`, `{+name}` and
/// `{#name}` one or more of any.
pub fn matches(pattern: []const u8, uri: []const u8) bool {
    var p: usize = 0;
    var u: usize = 0;
    while (p < pattern.len) {
        if (pattern[p] != '{') {
            if (u >= uri.len or uri[u] != pattern[p]) return false;
            p += 1;
            u += 1;
            continue;
        }
        const close_at = std.mem.findScalarPos(u8, pattern, p, '}') orelse return false;
        const any = close_at > p + 1 and (pattern[p + 1] == '+' or pattern[p + 1] == '#');
        p = close_at + 1;
        // The expression runs to the next literal of the pattern (or the end).
        const next: ?u8 = if (p < pattern.len) pattern[p] else null;
        const begin = u;
        while (u < uri.len) : (u += 1) {
            if (next) |n| if (uri[u] == n and (any or true)) break;
            if (!any and uri[u] == '/') break;
        }
        if (u == begin) return false;
    }
    return u == uri.len;
}

fn getPrompt(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) HandleError!Reply {
    const p = try parseParams(types.GetPromptParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    const prompt = found: {
        s.lock.lockShared(io) catch return error.Canceled;
        defer s.lock.unlockShared(io);
        for (s.prompts.items) |item| if (std.mem.eql(u8, item.name, p.name)) {
            // Copied out: the prompt may be removed while it runs.
            var required: std.ArrayList([]const u8) = .empty;
            for (item.required) |name| try required.append(arena, try arena.dupe(u8, name));
            break :found .{ item.handler, required.items };
        };
        break :found null;
    } orelse return try unknown(arena, "Unknown prompt: ", p.name);
    if (!s.admitted(context, .prompts, p.name)) return try unknown(arena, "Unknown prompt: ", p.name);
    const handler, const required = prompt;
    for (required) |name| {
        const given = if (p.arguments) |a| has(a.bytes, name) else false;
        if (!given) return failure(.invalid_params, try std.mem.concat(arena, u8, &.{ "Missing required argument: ", name }));
    }
    const r = switch (try s.round(io, arena, context, request.method, p.name, p.input_responses, p.request_state)) {
        .ok => |r| r,
        .refused => |reply| return reply,
    };
    var call = newCall(io, arena, request, context, sink, r);
    const result = handler.get(handler.context, &call, if (p.arguments) |a| a.bytes else null) catch |err|
        return s.outcome(io, arena, &call, err, request.method, p.name);
    var out: Result = .begin(arena, context.revision);
    if (result.description) |d| try out.field("description", d);
    try out.field("messages", result.messages);
    return .{ .result = try out.end(s, null, false) };
}

fn has(object: []const u8, name: []const u8) bool {
    var members: strand.json.Members = undefined;
    members.init(object, .{});
    while (members.next() catch return false) |m| if (m.is(name)) return !std.mem.eql(u8, m.value, "null");
    return false;
}

fn complete(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) HandleError!Reply {
    const completer = s.completer orelse return failure(.method_not_found, "Method not found");
    const p = try parseParams(types.CompleteParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    var call = newCall(io, arena, request, context, sink, .{ .responses = null, .state = null });
    const completion = completer.complete(completer.context, &call, p) catch |err| switch (err) {
        error.NotFound => return failure(.invalid_params, "nothing to complete there"),
        else => |e| return s.outcome(io, arena, &call, e, request.method, ""),
    };
    var out: Result = .begin(arena, context.revision);
    // At most 100 values in one answer (2025-11-25 completion: MUST NOT exceed).
    var c = completion;
    if (c.values.len > 100) {
        c.has_more = true;
        c.total = c.total orelse c.values.len;
        c.values = c.values[0..100];
    }
    try out.field("completion", c);
    return .{ .result = try out.end(s, null, false) };
}

/// `subscriptions/listen`: acknowledges what it will send, then sends each
/// change as it comes, until the stream is canceled (nothing is answered) or
/// the server closes (answered `complete`).
fn listen(s: *Server, io: Io, arena: Allocator, request: wire.Request, sink: Sink) HandleError!Reply {
    const p = try parseParams(types.ListenParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    const caps = s.capabilities();
    var listener: subscriptions.Listener = .{ .id = request.id, .lists = .empty };
    defer listener.deinit(s.gpa);
    var agreed: types.SubscriptionFilter = .{};
    if ((p.notifications.tools_list_changed orelse false) and caps.tools != null) {
        listener.lists.insert(.tools);
        agreed.tools_list_changed = true;
    }
    if ((p.notifications.prompts_list_changed orelse false) and caps.prompts != null) {
        listener.lists.insert(.prompts);
        agreed.prompts_list_changed = true;
    }
    if ((p.notifications.resources_list_changed orelse false) and caps.resources != null) {
        listener.lists.insert(.resources);
        agreed.resources_list_changed = true;
    }
    if (p.notifications.resource_subscriptions) |uris| if (caps.resources != null) {
        for (uris) |uri| listener.watch(io, s.gpa, uri, s.options.limits.watched) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.TooMany => return failure(.invalid_params, "more resources than one stream may watch"),
        };
        agreed.resource_subscriptions = uris;
    };
    s.hub.add(io, s.gpa, &listener, s.options.limits.listeners) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.TooMany => return failure(.internal_error, "too many open streams"),
    };
    defer s.hub.remove(io, &listener);

    const tag = try subscriptionMeta(arena, request.id);
    try notify(io, arena, sink, "notifications/subscriptions/acknowledged", .{ .notifications = agreed }, tag);
    var seen: u32 = 0;
    while (true) {
        const timeout: Io.Timeout = if (sink.keep_alive) |every| .{ .duration = .{ .raw = every, .clock = .awake } } else .none;
        seen = (listener.wait(io, &s.hub, seen, timeout) catch return error.Canceled) orelse {
            // Quiet for a while: a comment keeps the stream open, and a
            // stream the client left fails to take it.
            sink.keepAlive(io) catch return error.Canceled;
            continue;
        };
        var turn: std.heap.ArenaAllocator = .init(s.gpa);
        defer turn.deinit();
        const changed = listener.takeLists();
        if (changed.contains(.tools)) try notify(io, turn.allocator(), sink, "notifications/tools/list_changed", .{}, tag);
        if (changed.contains(.prompts)) try notify(io, turn.allocator(), sink, "notifications/prompts/list_changed", .{}, tag);
        if (changed.contains(.resources)) try notify(io, turn.allocator(), sink, "notifications/resources/list_changed", .{}, tag);
        if (changed.contains(.resource)) {
            const uris = listener.takeUpdated(io, turn.allocator()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
            };
            for (uris) |uri| try notify(io, turn.allocator(), sink, "notifications/resources/updated", .{ .uri = uri }, tag);
        }
        if (s.hub.closed.load(.acquire)) break;
    }
    var out: Writer.Allocating = .init(arena);
    out.writer.print("{{\"resultType\":\"complete\",\"_meta\":{{{s}}}}}", .{tag}) catch return error.OutOfMemory;
    return .{ .result = out.written() };
}

/// `"io.modelcontextprotocol/subscriptionId":<id>`.
fn subscriptionMeta(arena: Allocator, id: wire.Id) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    out.writer.writeAll("\"" ++ meta.subscription_id ++ "\":") catch return error.OutOfMemory;
    id.write(&out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// Sends a notification whose params are `params` plus `_meta` holding
/// `tag` (members, without braces) when it is not empty.
pub fn notify(io: Io, arena: Allocator, sink: Sink, method: []const u8, params: anytype, tag: []const u8) HandleError!void {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
    wire.writeString(w, method) catch return error.OutOfMemory;
    w.writeAll(",\"params\":") catch return error.OutOfMemory;
    const at = out.written().len;
    strand.json.write(w, params, types.write_options) catch return error.OutOfMemory;
    if (tag.len != 0) {
        // Into the params object, before its closing brace.
        const empty = out.written().len - at == 2;
        out.shrinkRetainingCapacity(out.written().len - 1);
        if (!empty) w.writeByte(',') catch return error.OutOfMemory;
        w.print("\"_meta\":{{{s}}}}}", .{tag}) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    sink.send(io, out.written()) catch |err| return switch (err) {
        error.Canceled, error.Closed => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}
