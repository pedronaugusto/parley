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
const tasks = @import("tasks.zig");
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
/// The tasks held, when the server serves the tasks extension. Whether it
/// does is asked of `options.tasks`: reading this optional whole would copy
/// its group while rounds change it.
task_table: ?tasks.Table = null,

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
    /// Serve the tasks extension (`io.modelcontextprotocol/tasks`): a tool
    /// call may run as a task the client polls. Null: not served.
    tasks: ?tasks.Options = null,
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
    /// The longest message, either way: what a transport reads (a longer
    /// one is refused unread), and what every read of a message and of a
    /// value within it allows (`wire.limitsFor`). A result past it is not
    /// written.
    message: aegis.units.Bytes(u32) = wire.default_message,
    /// Open `subscriptions/listen` streams and legacy session streams.
    listeners: u32 = 64,
    /// Resources one stream watches.
    watched: u32 = 256,
    /// Input requests in one input-required answer.
    input_requests: u32 = 16,
    /// A handler's state, before sealing.
    state: aegis.units.Bytes(u32) = .literal("64KiB"),
    /// Rounds a task's handler may run back to back keeping state and
    /// asking for nothing.
    quiet_rounds: u8 = 8,
};

/// strand's limits for every read and write of a message and of the values
/// within it: those of `options.limits.message`.
pub fn jsonLimits(s: *const Server) strand.core.Limits {
    return wire.limitsFor(s.options.limits.message);
}

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
    strand.json.write(&out.writer, options.info, types.writeOptions(wire.limitsFor(options.limits.message))) catch return error.OutOfMemory;
    return .{
        .gpa = gpa,
        .options = options,
        .sealer = sealer,
        .identity = try out.toOwnedSlice(),
        .task_table = if (options.tasks) |o| tasks.Table.init(gpa, io, o) else null,
    };
}

/// Stops the tasks' handlers first: every task ends with the server.
pub fn deinit(s: *Server) void {
    if (s.task_table) |*t| t.deinit();
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
    if (@TypeOf(entry) == *registry.Tool) {
        registry.freeHeaderParams(s.gpa, entry.headers);
    }
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

/// `TasksNotServed`: a tool whose calls may run as tasks, on a server that
/// does not serve the tasks extension.
pub const AddError = Allocator.Error || Io.Cancelable || error{ Duplicate, InvalidSchema, TasksNotServed };

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
    if (spec.task != .forbidden and s.options.tasks == null) return error.TasksNotServed;
    const tool = try s.gpa.create(registry.Tool);
    errdefer s.gpa.destroy(tool);
    const name = try s.gpa.dupe(u8, spec.name);
    errdefer s.gpa.free(name);
    const listed = try registry.listTool(s.gpa, s.jsonLimits(), spec, input, output);
    errdefer s.gpa.free(listed);
    const params = try registry.headerParams(s.gpa, input, s.jsonLimits());
    errdefer registry.freeHeaderParams(s.gpa, params);
    tool.* = .{ .name = name, .listed = listed, .handler = handler, .headers = params, .task = spec.task };
    try s.insert(io, .tools, &s.tools, tool, name);
}

/// The `x-mcp-header` marks of the tool named `name`, copied onto `arena`;
/// null when there is no such tool.
pub fn toolHeaders(s: *Server, io: Io, arena: Allocator, name: []const u8) (Allocator.Error || Io.Cancelable)!?[]const registry.HeaderParam {
    try s.lock.lockShared(io);
    defer s.lock.unlockShared(io);
    for (s.tools.items) |t| if (std.mem.eql(u8, t.name, name)) {
        const out = try arena.alloc(registry.HeaderParam, t.headers.len);
        for (out, t.headers) |*o, h| {
            const path = try arena.alloc([]const u8, h.path.len);
            for (path, h.path) |*p, step| p.* = try arena.dupe(u8, step);
            o.* = .{ .name = try arena.dupe(u8, h.name), .path = path, .kind = h.kind };
        }
        return out;
    };
    return null;
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
    const listed = try registry.listResource(s.gpa, s.jsonLimits(), spec);
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
    const listed = try registry.listTemplate(s.gpa, s.jsonLimits(), spec);
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
    const listed = try registry.listPrompt(s.gpa, s.jsonLimits(), spec, arguments);
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
    s.hub.changed(io, .resource, uri);
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
    /// The result object.
    result: Body,
    /// The handler needs input first. Under 2026-07-28 it is the result;
    /// under an earlier revision the session asks the client for it.
    input_required: InputRequired,
    failure: Failure,
};

/// A result object, as the transport writes it. Most are made whole; a
/// tool's result and a resource's contents, which may be as large as a
/// message, are written from what the handler returned as the transport
/// writes them, so the answer never holds a copy of them.
pub const Body = union(enum) {
    /// The JSON, made whole.
    json: []const u8,
    /// Written from a handler's result, whose memory outlives the reply.
    content: *const Content,

    /// The body's bytes.
    pub fn len(b: Body) usize {
        return switch (b) {
            .json => |bytes| bytes.len,
            .content => |c| c.len,
        };
    }

    /// Writes the body: exactly `len` bytes.
    pub fn write(b: Body, w: *Writer) Writer.Error!void {
        switch (b) {
            .json => |bytes| try w.writeAll(bytes),
            // Written once already, to count it: only the writer can fail.
            .content => |c| c.write(w) catch return error.WriteFailed,
        }
    }

    /// The body made whole on `arena`: for what keeps a result past its
    /// reply (a task's), and for a test that reads one.
    pub fn whole(b: Body, arena: Allocator) Allocator.Error![]const u8 {
        return switch (b) {
            .json => |json| json,
            .content => |c| {
                const out = try arena.alloc(u8, c.len);
                var w: Writer = .fixed(out);
                c.write(&w) catch unreachable; // unreachable: counted to fit exactly
                return out;
            },
        };
    }
};

/// A tool's result or a resource's contents as a result object: counted when
/// the reply is made (so one past the message limit is refused before a byte
/// goes out), written when the transport writes it.
pub const Content = struct {
    /// Private: what writes it.
    server: *const Server,
    revision: Revision,
    of: Of,
    /// The bytes it is.
    len: usize = 0,

    const Of = union(enum) {
        /// With the server's identity when `identify`.
        tool: struct { result: registry.ToolResult, identify: bool },
        /// Under the read's caching hint, private when a filter decides.
        resource: struct { contents: []const types.ResourceContents, private: bool },
    };

    /// A body for `of`, counted: `TooLong` past the server's message limit.
    fn body(s: *const Server, arena: Allocator, revision: Revision, of: Of) BuildError!Body {
        const c = try arena.create(Content);
        c.* = .{ .server = s, .revision = revision, .of = of };
        var buffer: [256]u8 = undefined;
        var counter: Writer.Discarding = .init(&buffer);
        try c.write(&counter.writer);
        c.len = std.math.cast(usize, counter.fullCount()) orelse return error.TooLong;
        if (c.len > s.jsonLimits().output_bytes.raw()) return error.TooLong;
        return .{ .content = c };
    }

    fn write(c: *const Content, w: *Writer) BuildError!void {
        const s = c.server;
        var r: Result = .over(s, w, c.revision);
        switch (c.of) {
            .tool => |t| {
                if (t.result.text) |text| {
                    // The text block first, then the handler's own blocks.
                    try r.open("content");
                    try r.item(types.ContentBlock.ofText(text));
                    for (t.result.content) |block| try r.item(block);
                    try r.close();
                } else try r.field("content", t.result.content);
                if (t.result.structured) |value| try r.raw("structuredContent", value.bytes);
                if (t.result.is_error) try r.field("isError", true);
                if (t.identify) try r.end(s, null, false) else try r.endPlain();
            },
            .resource => |x| {
                try r.field("contents", x.contents);
                try r.end(s, s.options.cache.read, x.private);
            },
        }
    }
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

/// Building an answer: `TooLong` when it is past the message limit, which
/// `handle` answers as an internal error rather than write it.
const BuildError = HandleError || error{TooLong};

const too_long = "the answer is longer than the server's message limit";

/// Answers a 2026-07-28 request: its context is read from its `_meta`, and
/// one that lacks what every request must carry, or names a version this
/// server does not speak, is refused. `principal` is who sent it, as the
/// transport authenticated them.
pub fn serve(s: *Server, io: Io, arena: Allocator, request: wire.Request, principal: ?[]const u8, sink: Sink) HandleError!Reply {
    const m = meta.read(arena, request.params, s.jsonLimits()) catch |err| switch (err) {
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
    return s.route(io, arena, request, context, sink) catch |err| switch (err) {
        error.TooLong => failure(.internal_error, too_long),
        error.Canceled, error.OutOfMemory => |e| e,
    };
}

fn route(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const methods = [_][]const u8{
        "server/discover", "tools/list",   "tools/call",   "resources/list",      "resources/templates/list",
        "resources/read",  "prompts/list", "prompts/get",  "completion/complete", "subscriptions/listen",
        "tasks/get",       "tasks/update", "tasks/cancel",
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
        9 => if (context.revision.stateless()) s.listen(io, arena, request, context, sink) else failure(.method_not_found, "Method not found"),
        10 => s.taskRequest(io, arena, request, context, .get),
        11 => s.taskRequest(io, arena, request, context, .update),
        12 => s.taskRequest(io, arena, request, context, .cancel),
        else => unreachable,
    };
}

/// A result object being written: `resultType` first under 2026-07-28,
/// then the members, then the caching hints and the server's identity. It
/// is made whole on an arena (`begin`, then `json`) or written to a
/// transport's writer (`over`).
const Result = struct {
    /// Set when it is made whole: the writer `w` writes to.
    made: ?Writer.Allocating,
    /// The writer, when it is not made whole.
    target: ?*Writer,
    revision: Revision,
    /// The server's: no answer is longer than its message limit.
    limits: strand.core.Limits,
    /// Whether the object's brace is written, and whether a member is.
    opened: bool = false,
    members: bool = false,
    /// Whether an array is open (`open`), and whether it has an item.
    items: bool = false,

    fn begin(s: *const Server, arena: Allocator, revision: Revision) Result {
        return .{ .made = .init(arena), .target = null, .revision = revision, .limits = s.jsonLimits() };
    }

    fn over(s: *const Server, target: *Writer, revision: Revision) Result {
        return .{ .made = null, .target = target, .revision = revision, .limits = s.jsonLimits() };
    }

    fn w(r: *Result) *Writer {
        if (r.target) |t| return t;
        return &r.made.?.writer;
    }

    /// `"name":` and `value` as strand writes it, after the members before it.
    fn field(r: *Result, member: []const u8, v: anytype) BuildError!void {
        try r.name(member);
        try r.value(v);
    }

    /// `"name":[`: the items follow (`item`), then `close`.
    fn open(r: *Result, member: []const u8) BuildError!void {
        try r.name(member);
        r.w().writeByte('[') catch return error.OutOfMemory;
        r.items = false;
    }

    fn item(r: *Result, v: anytype) BuildError!void {
        if (r.items) r.w().writeByte(',') catch return error.OutOfMemory;
        r.items = true;
        try r.value(v);
    }

    fn close(r: *Result) BuildError!void {
        r.w().writeByte(']') catch return error.OutOfMemory;
    }

    fn name(r: *Result, member: []const u8) BuildError!void {
        r.separate() catch return error.OutOfMemory;
        wire.writeString(r.w(), member) catch return error.OutOfMemory;
        r.w().writeByte(':') catch return error.OutOfMemory;
    }

    fn value(r: *Result, v: anytype) BuildError!void {
        strand.json.write(r.w(), v, types.writeOptions(r.limits)) catch |err| return switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            // strand's limits are the message limit's (`wire.limitsFor`): a
            // value past one is an answer past it.
            error.InputLimit, error.OutputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.AllocationLimit, error.WorkLimit => error.TooLong,
            // A value a handler built that is not JSON (text that is not
            // UTF-8): the result cannot be written.
            else => error.OutOfMemory,
        };
    }

    /// `"name":` and `json`, one value as written.
    fn raw(r: *Result, member: []const u8, json: []const u8) BuildError!void {
        try r.name(member);
        r.w().writeAll(json) catch return error.OutOfMemory;
    }

    /// Before a member: the object's brace (and `resultType`), or a comma.
    fn separate(r: *Result) Writer.Error!void {
        if (!r.opened) {
            r.opened = true;
            try r.w().writeByte('{');
            if (r.revision.stateless()) try r.w().writeAll("\"resultType\":\"complete\"");
            r.members = r.revision.stateless();
        }
        if (r.members) try r.w().writeByte(',');
        r.members = true;
    }

    /// Ends the object as it is: a result inside another.
    fn endPlain(r: *Result) BuildError!void {
        if (!r.opened) {
            r.opened = true;
            r.w().writeByte('{') catch return error.OutOfMemory;
            if (r.revision.stateless()) r.w().writeAll("\"resultType\":\"complete\"") catch return error.OutOfMemory;
        }
        r.w().writeByte('}') catch return error.OutOfMemory;
    }

    /// Ends the object: caching hints when `hint` is given (2026-07-28),
    /// the server's identity when it names itself.
    fn end(r: *Result, s: *const Server, hint: ?Cache.Hint, private: bool) BuildError!void {
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
        try r.endPlain();
    }

    /// The object made whole (`begin`), ended: past the message limit, refused.
    fn body(r: *Result) BuildError!Body {
        const bytes = r.made.?.written();
        if (bytes.len > r.limits.output_bytes.raw()) return error.TooLong;
        return .{ .json = bytes };
    }
};

/// The extension objects `server/discover` names (2026-07-28).
const extensions_json = "{\"" ++ tasks.extension ++ "\":{}}";

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
    strand.json.write(&out.writer, s.capabilities(), types.writeOptions(s.jsonLimits())) catch return error.OutOfMemory;
    return out.written();
}

fn discover(s: *Server, arena: Allocator, context: *const Context) BuildError!Reply {
    var r: Result = .begin(s, arena, context.revision);
    const versions = comptime blk: {
        var names: []const []const u8 = &.{};
        for (@typeInfo(Revision).@"enum".field_names) |name| names = names ++ .{name};
        break :blk names;
    };
    try r.field("supportedVersions", versions);
    var caps = s.capabilities();
    if (s.options.tasks != null) caps.extensions = .{ .bytes = extensions_json };
    try r.field("capabilities", caps);
    if (s.options.instructions) |text| try r.field("instructions", text);
    try r.end(s, s.options.cache.discover, false);
    return .{ .result = try r.body() };
}

fn admitted(s: *const Server, context: *const Context, which: List, name: []const u8) bool {
    const f = s.options.filter orelse return true;
    return f.admit(f.context, context, which, name);
}

fn parseParams(s: *const Server, comptime T: type, arena: Allocator, params: ?[]const u8) HandleError!?T {
    return strand.json.parseLeaky(T, arena, params orelse "{}", types.readOptions(s.jsonLimits())) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// One page of a list. A cursor names the list's generation and an offset:
/// a cursor into a list that changed since is refused.
fn listPage(s: *Server, io: Io, arena: Allocator, comptime which: List, params: ?[]const u8, context: *const Context) BuildError!Reply {
    const p = try s.parseParams(types.PaginatedParams, arena, params) orelse return failure(.invalid_params, "params are not what the schema says");
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
    var r: Result = .begin(s, arena, context.revision);
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
        try r.field("nextCursor", std.mem.print(&buffer, "{d}.{d}", .{ generation, i }) catch unreachable); // unreachable: two integers fit 32 bytes
    }
    try r.end(s, hint, s.options.filter != null);
    return .{ .result = try r.body() };
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
fn round(s: *Server, io: Io, arena: Allocator, context: *const Context, method: []const u8, subject: []const u8, responses: ?Raw, sealed: ?[]const u8) BuildError!union(enum) { ok: Round, refused: Reply } {
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

fn newCall(s: *const Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink, r: Round) Call {
    return .{ .io = io, .arena = arena, .context = context, .id = request.id, .sink = sink, .limits = s.jsonLimits(), .responses = r.responses, .state_in = r.state };
}

/// What a handler's failure is answered with, or the input it asked for.
fn outcome(s: *Server, io: Io, arena: Allocator, call: *Call, err: Call.Error, method: []const u8, subject: []const u8) BuildError!Reply {
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

fn inputRequired(s: *Server, io: Io, arena: Allocator, call: *Call, method: []const u8, subject: []const u8) BuildError!Reply {
    if (call.pending.items.len == 0 and call.state_out == null)
        return failure(.internal_error, "the handler asked for input without asking for any");
    if (call.pending.items.len > s.options.limits.input_requests) return failure(.internal_error, "the handler asked for more input than the server allows at once");
    var sealed: ?[]const u8 = null;
    if (call.state_out) |payload| {
        const size: aegis.units.Bytes(u32) = .fromRaw(std.math.cast(u32, payload.len) orelse std.math.maxInt(u32));
        if (size.compare(s.options.limits.state) == .gt) return failure(.internal_error, "the handler's state is past the server's limit");
        sealed = s.sealer.seal(io, arena, .{ .principal = call.context.principal, .method = method, .subject = subject }, payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.EntropyUnavailable => return failure(.internal_error, "no entropy to seal the request's state"),
        };
    }
    return .{ .input_required = .{ .requests = call.pending.items, .state = sealed } };
}

/// `-32021`, naming the capability as a `ClientCapabilities` object.
fn missing(arena: Allocator, kind: types.InputKind) BuildError!Reply {
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
            strand.json.write(w, p.request, types.writeOptions(s.jsonLimits())) catch return error.OutOfMemory;
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

fn callTool(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const p = try s.parseParams(types.CallToolParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    if (p.arguments) |a| if (a.bytes[0] != '{') return failure(.invalid_params, "arguments is not an object");
    const handler, const task_support = found: {
        s.lock.lockShared(io) catch return error.Canceled;
        defer s.lock.unlockShared(io);
        for (s.tools.items) |t| if (std.mem.eql(u8, t.name, p.name)) break :found .{ t.handler, t.task };
        break :found null;
    } orelse return try unknown(arena, "Unknown tool: ", p.name);
    if (!s.admitted(context, .tools, p.name)) return try unknown(arena, "Unknown tool: ", p.name);
    const tasks_declared = s.options.tasks != null and context.revision.stateless() and context.client.hasExtension(tasks.extension, s.jsonLimits());
    // A tool that cannot answer but as a task, asked by a client that
    // cannot take one (tasks extension: required capabilities).
    if (task_support == .required and !tasks_declared) return missingTasks();
    const r = switch (try s.round(io, arena, context, request.method, p.name, p.input_responses, p.request_state)) {
        .ok => |r| r,
        .refused => |reply| return reply,
    };
    if (task_support != .forbidden and tasks_declared) return s.callAsTask(io, arena, request, context, sink, handler, p.name, r);
    var call = s.newCall(io, arena, request, context, sink, r);
    const returned = handler.call(handler.context, &call, if (p.arguments) |a| a.bytes else null);
    return s.answerTool(io, arena, &call, returned, request.method, p.name, context.revision);
}

/// A tool call's answer: its result, the input it asks for, or its failure.
fn answerTool(s: *Server, io: Io, arena: Allocator, call: *Call, returned: Call.Error!registry.ToolResult, method: []const u8, name: []const u8, revision: Revision) BuildError!Reply {
    const result = returned catch |err| return s.outcome(io, arena, call, err, method, name);
    return .{ .result = try Content.body(s, arena, revision, .{ .tool = .{ .result = result, .identify = true } }) };
}

// Tasks: a call that may run as one runs its handler on a task of the
// server's (a round), which the call waits on until the handler becomes a
// task (`Call.runAsTask`: the call answers with it) or answers (the call
// answers as it was asked). A task waiting for input runs another round
// once the client gave it all.

/// `-32021` for a client that did not declare the tasks extension.
fn missingTasks() Reply {
    return .{ .failure = .{
        .code = .missing_required_client_capability,
        .message = "Missing required client capability",
        .data = "{\"requiredCapabilities\":{\"extensions\":{\"" ++ tasks.extension ++ "\":{}}}}",
    } };
}

/// One round of a task's handler.
const Run = struct {
    server: *Server,
    task: *tasks.Task,
    handler: registry.ToolHandler,
    arena: std.heap.ArenaAllocator,
    context: Context,
    call: Call,
    arguments: ?[]const u8,
    /// The call waits on the round until the handler runs as a task.
    attached: bool,
    /// Whether the handler may run as a task: not when the round runs on
    /// the call's own task (no task was free).
    may_detach: bool = true,
    /// Set when the waiting call has its answer: the task, or the outcome.
    decided: Io.Event = .unset,
    /// The handler's outcome, for the waiting call.
    outcome: ?(Call.Error!registry.ToolResult) = null,
    /// Who holds the round: the round itself, and the call waiting on it.
    /// The last to let go frees it.
    holders: std.atomic.Value(u8),

    /// A round over `task`'s call, with the answers and state given.
    fn create(s: *Server, task: *tasks.Task, handler: registry.ToolHandler, attached: bool, id: wire.Id, sink: Sink, responses: ?[]const u8, state_in: ?[]const u8) Allocator.Error!*Run {
        const run = try s.gpa.create(Run);
        errdefer s.gpa.destroy(run);
        run.* = .{
            .server = s,
            .task = task,
            .handler = handler,
            .arena = .init(s.gpa),
            .context = undefined,
            .call = undefined,
            .arguments = null,
            .attached = attached,
            .holders = .init(if (attached) 2 else 1),
        };
        errdefer run.arena.deinit();
        const a = run.arena.allocator();
        // The params were read once already, when the call came.
        const m = meta.read(a, task.params, s.jsonLimits()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => unreachable, // unreachable: `serve` read these params before the task was made
        };
        const p = (s.parseParams(types.CallToolParams, a, task.params) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => unreachable, // unreachable: parsing does not wait
        }) orelse unreachable; // unreachable: `callTool` parsed these params before the task was made
        run.arguments = if (p.arguments) |args| args.bytes else null;
        run.context = .{
            .revision = .@"2026-07-28",
            .client = m.client_capabilities orelse .{},
            .client_info = m.client_info,
            // A task carries no progress or log lines.
            .log_level = if (attached) m.log_level else null,
            .progress_token = if (attached) m.progress_token else null,
            .meta = m.raw,
            .principal = task.principal,
        };
        const owned_id: wire.Id = switch (id) {
            .integer => id,
            .string => |text| .{ .string = try a.dupe(u8, text) },
        };
        run.call = .{
            .io = s.task_table.?.io,
            .arena = a,
            .context = &run.context,
            .id = owned_id,
            .sink = sink,
            .limits = s.jsonLimits(),
            .responses = if (responses) |r| try a.dupe(u8, r) else null,
            .state_in = if (state_in) |st| try a.dupe(u8, st) else null,
            .task = .{ .context = run, .become = become },
        };
        return run;
    }

    /// Lets go of the round; the last holder frees it.
    fn release(run: *Run) void {
        if (run.holders.fetchSub(1, .acq_rel) != 1) return;
        const gpa = run.server.gpa;
        run.arena.deinit();
        gpa.destroy(run);
    }
};

fn callAsTask(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink, handler: registry.ToolHandler, name: []const u8, r: Round) BuildError!Reply {
    const table = &s.task_table.?;
    const task = table.create(context.principal, request.params orelse "{}", now(io)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.EntropyUnavailable => return failure(.internal_error, "no entropy for a task's id"),
    };
    const run = Run.create(s, task, handler, true, request.id, sink, r.responses, r.state) catch |err| {
        table.destroy(task);
        return err;
    };
    defer run.release();
    table.group.concurrent(table.io, runRound, .{run}) catch {
        // No task to run it on: answered here, as it was asked.
        run.may_detach = false;
        runRound(run);
    };
    run.decided.wait(io) catch {
        // The call was canceled: its handler stops, unless it runs as a
        // task already.
        table.mutex.lockUncancelable(table.io);
        const attached = run.attached;
        if (attached) task.cancel.set(table.io);
        table.mutex.unlock(table.io);
        if (attached) {
            run.decided.waitUncancelable(io);
            table.destroy(task);
        }
        return error.Canceled;
    };
    table.mutex.lockUncancelable(table.io);
    if (!run.attached) {
        defer table.mutex.unlock(table.io);
        var out: Writer.Allocating = .init(arena);
        tasks.write(&out.writer, task, .created, table.options.ttl, table.options.poll_interval, s.identityMembers()) catch return error.OutOfMemory;
        return .{ .result = .{ .json = out.written() } };
    }
    table.mutex.unlock(table.io);
    // Answered as asked: the reply is written on the call's arena before the
    // round's goes.
    defer table.destroy(task);
    const reply = try s.answerTool(io, arena, &run.call, run.outcome.?, request.method, name, context.revision);
    return switch (reply) {
        .input_required => |ir| .{ .result = .{ .json = try s.inputRequiredJson(arena, ir) } },
        // Made whole: what the handler returned is on the round's arena.
        .result => |body| .{ .result = .{ .json = try body.whole(arena) } },
        .failure => reply,
    };
}

/// The server's identity as `_meta` members, or null when it names none.
fn identityMembers(s: *const Server) ?[]const u8 {
    return if (s.options.identify) s.identity else null;
}

fn now(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

/// `Call.runAsTask` for a round: the task is held, and the waiting call
/// answers with it.
fn become(context: *anyopaque) Call.Error!bool {
    const run: *Run = @ptrCast(@alignCast(context)); // safe: the hook was made from this round
    if (!run.attached) return true;
    if (!run.may_detach) return false;
    const s = run.server;
    const table = &s.task_table.?;
    {
        table.mutex.lockUncancelable(table.io);
        defer table.mutex.unlock(table.io);
        // A call canceled while it waited takes its task with it.
        if (run.task.cancel.isSet()) return error.Canceled;
        if (!try table.hold(run.task, now(table.io))) return false;
        run.task.running = true;
        run.attached = false;
    }
    // From here the request is answered: nothing more goes on its stream.
    run.call.sink = .none;
    run.decided.set(table.io);
    return true;
}

const Outcome = union(enum) {
    done: Call.Error!registry.ToolResult,
    canceled: Io.Cancelable!void,
};

/// Runs the round's handler until it returns or its task is canceled, then
/// records what came of it.
fn runRound(run: *Run) void {
    const returned = answerRound(run);
    run.server.recordRound(run, returned);
}

fn answerRound(run: *Run) Call.Error!registry.ToolResult {
    const io = run.call.io;
    var buffer: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &buffer);
    // Both tasks end before the round's memory goes; what they return is
    // on the round's arena.
    defer select.cancelDiscard();
    select.concurrent(.done, callHandler, .{run}) catch return callHandler(run);
    select.concurrent(.canceled, waitCancel, .{ &run.task.cancel, io }) catch {
        const first = select.await() catch return error.Canceled;
        return first.done;
    };
    return switch (select.await() catch return error.Canceled) {
        .done => |result| result,
        .canceled => error.Canceled,
    };
}

fn callHandler(run: *Run) Call.Error!registry.ToolResult {
    return run.handler.call(run.handler.context, &run.call, run.arguments);
}

fn waitCancel(event: *Io.Event, io: Io) Io.Cancelable!void {
    try event.wait(io);
}

/// What came of a round: the waiting call's answer, or the task's next
/// status, and the next round when the handler asked for nothing.
fn recordRound(s: *Server, run: *Run, returned: Call.Error!registry.ToolResult) void {
    const table = &s.task_table.?;
    const io = table.io;
    table.mutex.lockUncancelable(io);
    if (run.attached) {
        run.outcome = returned;
        table.mutex.unlock(io);
        run.decided.set(io);
        run.release();
        return;
    }
    const task = run.task;
    const again = s.recordOutcome(table, run, returned) catch blk: {
        // glint-ignore: Z026 -- out of memory while recording: the task fails with what fits, or stays as it was
        table.fail(task, now(io), "{\"code\":-32603,\"message\":\"out of memory\"}", "out of memory") catch {};
        break :blk false;
    };
    task.running = again;
    const state_for_next = task.state;
    // Copied: a task no round runs may be let go once the lock is.
    const id = task.id;
    table.mutex.unlock(io);
    s.hub.changed(io, .task, &id);
    const handler = run.handler;
    run.release();
    if (again) s.startRound(task, handler, null, state_for_next);
}

/// Records `returned` on the run's task (the caller holds the table's lock):
/// true when the handler is to run again at once.
fn recordOutcome(s: *Server, table: *tasks.Table, run: *Run, returned: Call.Error!registry.ToolResult) Allocator.Error!bool {
    const task = run.task;
    const at = now(table.io);
    const a = run.arena.allocator();
    const result = returned catch |err| switch (err) {
        error.Canceled => {
            try table.cancelled(task, at, "The task was cancelled");
            return false;
        },
        error.InputRequired => {
            const call = &run.call;
            if (task.cancel.isSet()) {
                try table.cancelled(task, at, "The task was cancelled");
                return false;
            }
            if (call.state_out) |payload| {
                const size: aegis.units.Bytes(u32) = .fromRaw(std.math.cast(u32, payload.len) orelse std.math.maxInt(u32));
                if (size.compare(s.options.limits.state) == .gt) {
                    try table.fail(task, at, "{\"code\":-32603,\"message\":\"the handler's state is past the server's limit\"}", "the handler's state is past the server's limit");
                    return false;
                }
            }
            if (call.pending.items.len == 0) {
                // State kept and nothing asked: the handler runs again, a
                // few times at most.
                task.quiet_rounds += 1;
                if (task.quiet_rounds > s.options.limits.quiet_rounds) {
                    try table.fail(task, at, "{\"code\":-32603,\"message\":\"the handler kept asking for nothing\"}", "the handler kept asking for nothing");
                    return false;
                }
                try table.keepState(task, call.state_out);
                return true;
            }
            if (call.pending.items.len > s.options.limits.input_requests) {
                try table.fail(task, at, "{\"code\":-32603,\"message\":\"the handler asked for more input than the server allows at once\"}", "the handler asked for more input than the server allows at once");
                return false;
            }
            task.quiet_rounds = 0;
            const asked = try a.alloc(tasks.Asked, call.pending.items.len);
            for (asked, call.pending.items) |*x, pending| {
                var out: Writer.Allocating = .init(a);
                strand.json.write(&out.writer, pending.request, types.writeOptions(s.jsonLimits())) catch return error.OutOfMemory;
                x.* = .{ .key = pending.key, .request = out.written() };
            }
            try table.ask(task, at, asked, call.state_out);
            return false;
        },
        else => |e| {
            const reply = s.outcome(table.io, a, &run.call, e, "tools/call", "") catch |failed| switch (failed) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooLong => failure(.internal_error, too_long),
                error.Canceled => unreachable, // unreachable: only `error.InputRequired` waits, handled above
            };
            const f = reply.failure;
            var out: Writer.Allocating = .init(a);
            const w = &out.writer;
            w.print("{{\"code\":{d},\"message\":", .{@backingInt(f.code)}) catch return error.OutOfMemory;
            wire.writeString(w, f.message) catch return error.OutOfMemory;
            if (f.data) |data| w.print(",\"data\":{s}", .{data}) catch return error.OutOfMemory;
            w.writeByte('}') catch return error.OutOfMemory;
            try table.fail(task, at, out.written(), f.message);
            return false;
        },
    };
    const body = Content.body(s, a, .@"2026-07-28", .{ .tool = .{ .result = result, .identify = false } }) catch return error.OutOfMemory;
    try table.complete(task, at, try body.whole(a));
    return false;
}

/// Starts a round of `task`'s handler with `responses` (its `inputResponses`)
/// and `state`; one that cannot start ends the task failed.
fn startRound(s: *Server, task: *tasks.Task, handler: registry.ToolHandler, responses: ?[]const u8, state_in: ?[]const u8) void {
    const table = &s.task_table.?;
    const run = Run.create(s, task, handler, false, .{ .string = &task.id }, .none, responses, state_in) catch {
        table.mutex.lockUncancelable(table.io);
        // glint-ignore: Z026 -- out of memory: the task fails if that fits, and is let go at its time either way
        table.fail(task, now(table.io), "{\"code\":-32603,\"message\":\"out of memory\"}", "out of memory") catch {};
        task.running = false;
        table.mutex.unlock(table.io);
        return;
    };
    table.group.concurrent(table.io, runRound, .{run}) catch runRound(run);
}

const TaskMethod = enum { get, update, cancel };

/// `tasks/get`, `tasks/update` and `tasks/cancel`, for a client that
/// declared the extension.
fn taskRequest(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, method: TaskMethod) BuildError!Reply {
    const table = if (s.task_table) |*t| t else return failure(.method_not_found, "Method not found");
    if (!context.revision.stateless()) return failure(.method_not_found, "Method not found");
    if (!context.client.hasExtension(tasks.extension, s.jsonLimits())) return missingTasks();
    const task_id = switch (method) {
        .get, .cancel => (try s.parseParams(types.TaskParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says")).task_id,
        .update => (try s.parseParams(types.UpdateTaskParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says")).task_id,
    };
    var next: ?[]const u8 = null;
    var changed = false;
    var handler: ?registry.ToolHandler = null;
    var task: *tasks.Task = undefined;
    var id: tasks.Id = undefined;
    {
        table.mutex.lockUncancelable(table.io);
        defer table.mutex.unlock(table.io);
        task = table.find(task_id, context.principal, now(io)) orelse return failure(.invalid_params, "Failed to retrieve task: Task not found");
        // Copied: a task no round runs may be let go once the lock is.
        id = task.id;
        switch (method) {
            .get => {
                var out: Writer.Allocating = .init(arena);
                tasks.write(&out.writer, task, .polled, table.options.ttl, table.options.poll_interval, s.identityMembers()) catch return error.OutOfMemory;
                return .{ .result = .{ .json = out.written() } };
            },
            .update => {
                const p = (try s.parseParams(types.UpdateTaskParams, arena, request.params)).?;
                if (p.input_responses.bytes[0] != '{') return failure(.invalid_params, "inputResponses is not an object");
                next = table.answer(task, now(io), arena, p.input_responses.bytes, s.jsonLimits()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => return failure(.invalid_params, "inputResponses is not an object"),
                };
                if (next != null) {
                    handler = s.toolOf(io, task) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    if (handler == null) {
                        try table.fail(task, now(io), "{\"code\":-32602,\"message\":\"the task's tool is gone\"}", "the task's tool is gone");
                        next = null;
                    } else task.running = true;
                    changed = true;
                }
            },
            .cancel => if (!task.lifecycle.isTerminal()) {
                if (task.running) {
                    // The round sees it and ends the task cancelled.
                    task.cancel.set(table.io);
                } else {
                    try table.cancelled(task, now(io), "The task was cancelled");
                    changed = true;
                }
            },
        }
    }
    if (changed) s.hub.changed(io, .task, &id);
    if (next) |responses| s.startRound(task, handler.?, responses, task.state);
    var out: Result = .begin(s, arena, context.revision);
    try out.end(s, null, false);
    return .{ .result = try out.body() };
}

/// The task `id` as `form` writes it, or null when it is not held.
fn taskJson(s: *Server, io: Io, arena: Allocator, id: []const u8, principal: ?[]const u8, form: tasks.Form) BuildError!?[]const u8 {
    const table = &s.task_table.?;
    table.mutex.lockUncancelable(table.io);
    defer table.mutex.unlock(table.io);
    const task = table.find(id, principal, now(io)) orelse return null;
    var out: Writer.Allocating = .init(arena);
    tasks.write(&out.writer, task, form, table.options.ttl, table.options.poll_interval, s.identityMembers()) catch return error.OutOfMemory;
    return out.written();
}

/// The handler of the tool `task` calls, or null when it is gone.
fn toolOf(s: *Server, io: Io, task: *const tasks.Task) (Allocator.Error || Io.Cancelable)!?registry.ToolHandler {
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const p = (s.parseParams(types.CallToolParams, scratch.allocator(), task.params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
    }) orelse return null;
    try s.lock.lockShared(io);
    defer s.lock.unlockShared(io);
    for (s.tools.items) |t| if (std.mem.eql(u8, t.name, p.name)) return t.handler;
    return null;
}

fn unknown(arena: Allocator, comptime what: []const u8, name: []const u8) Allocator.Error!Reply {
    return failure(.invalid_params, try std.mem.concat(arena, u8, &.{ what, name }));
}

fn readResource(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const p = try s.parseParams(types.ReadResourceParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
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
    var call = s.newCall(io, arena, request, context, sink, r);
    const result = handler.read(handler.context, &call, p.uri) catch |err| switch (err) {
        error.NotFound => return try notFound(arena, context.revision, p.uri),
        else => |e| return s.outcome(io, arena, &call, e, request.method, p.uri),
    };
    // An empty list would read as a resource with nothing in it (2026-07-28
    // resources: MUST NOT for one that does not exist).
    if (result.contents.len == 0) return try notFound(arena, context.revision, p.uri);
    return .{ .result = try Content.body(s, arena, context.revision, .{ .resource = .{ .contents = result.contents, .private = s.options.filter != null } }) };
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

fn getPrompt(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const p = try s.parseParams(types.GetPromptParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
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
        const given = if (p.arguments) |a| has(a.bytes, name, s.jsonLimits()) else false;
        if (!given) return failure(.invalid_params, try std.mem.concat(arena, u8, &.{ "Missing required argument: ", name }));
    }
    const r = switch (try s.round(io, arena, context, request.method, p.name, p.input_responses, p.request_state)) {
        .ok => |r| r,
        .refused => |reply| return reply,
    };
    var call = s.newCall(io, arena, request, context, sink, r);
    const result = handler.get(handler.context, &call, if (p.arguments) |a| a.bytes else null) catch |err|
        return s.outcome(io, arena, &call, err, request.method, p.name);
    var out: Result = .begin(s, arena, context.revision);
    if (result.description) |d| try out.field("description", d);
    try out.field("messages", result.messages);
    try out.end(s, null, false);
    return .{ .result = try out.body() };
}

fn has(object: []const u8, name: []const u8, limits: strand.core.Limits) bool {
    var members: strand.json.Members = undefined;
    members.init(object, .{ .limits = limits });
    while (members.next() catch return false) |m| if (m.is(name)) return !std.mem.eql(u8, m.value, "null");
    return false;
}

fn complete(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const completer = s.completer orelse return failure(.method_not_found, "Method not found");
    const p = try s.parseParams(types.CompleteParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
    var call = s.newCall(io, arena, request, context, sink, .{ .responses = null, .state = null });
    const completion: types.Completion = completer.complete(completer.context, &call, p) catch |err| switch (err) {
        error.NotFound => return failure(.invalid_params, "nothing to complete there"),
        else => |e| return s.outcome(io, arena, &call, e, request.method, ""),
    };
    var out: Result = .begin(s, arena, context.revision);
    // At most 100 values in one answer (2025-11-25 completion: MUST NOT exceed).
    const capped = completion.values.len > 100;
    try out.field("completion", types.Completion{
        .values = if (capped) completion.values[0..100] else completion.values,
        .total = if (capped) completion.total orelse completion.values.len else completion.total,
        .has_more = if (capped) true else completion.has_more,
    });
    try out.end(s, null, false);
    return .{ .result = try out.body() };
}

/// `subscriptions/listen`: acknowledges what it will send, then sends each
/// change as it comes, until the transport ends the stream (`Sink.end`: the
/// client canceled the request or left; nothing is answered) or the server
/// closes (answered `complete`).
fn listen(s: *Server, io: Io, arena: Allocator, request: wire.Request, context: *const Context, sink: Sink) BuildError!Reply {
    const p = try s.parseParams(types.ListenParams, arena, request.params) orelse return failure(.invalid_params, "params are not what the schema says");
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
        for (uris) |uri| listener.watch(io, s.gpa, .resource, uri, s.options.limits.watched) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.TooMany => return failure(.invalid_params, "more resources than one stream may watch"),
        };
        agreed.resource_subscriptions = uris;
    };
    if (p.notifications.task_ids) |ids| if (s.task_table) |*table| {
        // Task statuses go only to a client that declared the extension
        // (tasks extension: status notifications).
        if (!context.client.hasExtension(tasks.extension, s.jsonLimits())) return missingTasks();
        var held: std.ArrayList([]const u8) = .empty;
        for (ids) |id| {
            const known = known: {
                table.mutex.lockUncancelable(table.io);
                defer table.mutex.unlock(table.io);
                break :known table.find(id, context.principal, now(io)) != null;
            };
            if (!known) continue;
            listener.watch(io, s.gpa, .task, id, s.options.limits.watched) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.TooMany => return failure(.invalid_params, "more tasks than one stream may watch"),
            };
            try held.append(arena, id);
        }
        agreed.task_ids = held.items;
    };
    s.hub.add(io, s.gpa, &listener, s.options.limits.listeners) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.TooMany => return failure(.internal_error, "too many open streams"),
    };
    defer s.hub.remove(io, &listener);
    // Ended before it started: the client canceled it, or its input ended.
    if (sink.end) |end| if (!end.attach(io, &listener)) return error.Canceled;
    defer if (sink.end) |end| end.detach(io);

    const tag = try subscriptionMeta(arena, request.id);
    try s.notify(io, arena, sink, "notifications/subscriptions/acknowledged", .{ .notifications = agreed }, tag);
    var seen: u32 = 0;
    while (true) {
        const timeout: Io.Timeout = if (sink.keep_alive) |every| .{ .duration = .{ .raw = every, .clock = .awake } } else .none;
        seen = (listener.wait(io, &s.hub, seen, timeout) catch return error.Canceled) orelse {
            // Quiet for a while: a comment keeps the stream open, and a
            // stream the client left fails to take it.
            sink.keepAlive(io) catch return error.Canceled;
            continue;
        };
        // Ended by its client: nothing more is written, and nothing answered.
        if (listener.ended.load(.acquire)) return error.Canceled;
        var turn: std.heap.ArenaAllocator = .init(s.gpa);
        defer turn.deinit();
        const changed = listener.takeLists();
        if (changed.contains(.tools)) try s.notify(io, turn.allocator(), sink, "notifications/tools/list_changed", .{}, tag);
        if (changed.contains(.prompts)) try s.notify(io, turn.allocator(), sink, "notifications/prompts/list_changed", .{}, tag);
        if (changed.contains(.resources)) try s.notify(io, turn.allocator(), sink, "notifications/resources/list_changed", .{}, tag);
        if (changed.contains(.resource)) {
            const uris = listener.takeChanged(io, turn.allocator(), .resource) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
            };
            for (uris) |uri| try s.notify(io, turn.allocator(), sink, "notifications/resources/updated", .{ .uri = uri }, tag);
        }
        if (changed.contains(.task)) {
            const ids = listener.takeChanged(io, turn.allocator(), .task) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
            };
            for (ids) |id| if (try s.taskJson(io, turn.allocator(), id, context.principal, .notified)) |json| {
                try s.notify(io, turn.allocator(), sink, "notifications/tasks", Raw{ .bytes = json }, tag);
            };
        }
        if (s.hub.closed.load(.acquire)) break;
    }
    var out: Writer.Allocating = .init(arena);
    out.writer.print("{{\"resultType\":\"complete\",\"_meta\":{{{s}}}}}", .{tag}) catch return error.OutOfMemory;
    return .{ .result = .{ .json = out.written() } };
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
pub fn notify(s: *const Server, io: Io, arena: Allocator, sink: Sink, method: []const u8, params: anytype, tag: []const u8) HandleError!void {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
    wire.writeString(w, method) catch return error.OutOfMemory;
    w.writeAll(",\"params\":") catch return error.OutOfMemory;
    const at = out.written().len;
    strand.json.write(w, params, types.writeOptions(s.jsonLimits())) catch return error.OutOfMemory;
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
