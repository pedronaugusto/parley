//! MCP's data, as the 2026-07-28 schema has it, read and written with
//! strand. One set of types serves every revision parley speaks: a field a
//! revision does not know is left off what is written for it (absent fields
//! are null and written with `nulls = .omit`), and what a peer sends is read
//! with unknown fields passed over, as MCP asks of both sides.
const strand = @import("strand");

const Raw = strand.json.Raw;

/// How every MCP value is written: absent optionals left out, as the schema
/// has no null for them, within `limits` (`wire.limitsFor` the message limit).
pub fn writeOptions(limits: strand.core.Limits) strand.json.WriteOptions {
    return .{ .nulls = .omit, .limits = limits };
}

/// How every MCP value is read: members a type does not name are passed
/// over, so a newer peer's additions do not break an older reader, within
/// `limits` (`wire.limitsFor` the message limit).
pub fn readOptions(limits: strand.core.Limits) strand.json.ParseOptions {
    return .{ .ignore_unknown_fields = true, .limits = limits };
}

/// An icon for a tool, a resource, a prompt or an implementation.
pub const Icon = struct {
    src: []const u8,
    mime_type: ?[]const u8 = null,
    sizes: ?[]const []const u8 = null,
    theme: ?Theme = null,

    pub const Theme = enum { light, dark };
    pub const strand = .{ .rename_all = .camel_case };
};

/// A client or a server: its name and version, for display.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    website_url: ?[]const u8 = null,
    icons: ?[]const Icon = null,

    pub const strand = .{ .rename_all = .camel_case };
};

/// What a client says it can do. Only the parts a server acts on are typed;
/// the rest are kept as they came.
pub const ClientCapabilities = struct {
    experimental: ?Raw = null,
    roots: ?Raw = null,
    sampling: ?Sampling = null,
    elicitation: ?Elicitation = null,
    extensions: ?Raw = null,

    pub const Sampling = struct {
        context: ?Raw = null,
        tools: ?Raw = null,
    };
    pub const Elicitation = struct {
        form: ?Raw = null,
        url: ?Raw = null,
    };

    /// Whether the client takes requests of `kind` (2026-07-28: declared per
    /// request).
    pub fn accepts(c: ClientCapabilities, kind: InputKind) bool {
        return switch (kind) {
            .elicit_form => if (c.elicitation) |e| e.form != null or e.url == null else false,
            .elicit_url => if (c.elicitation) |e| e.url != null else false,
            .sample => c.sampling != null,
            .roots => c.roots != null,
        };
    }

    /// Whether `name` is among the client's extensions, read within
    /// `limits` (those the capabilities were read with).
    pub fn hasExtension(c: ClientCapabilities, name: []const u8, limits: strand.core.Limits) bool {
        const raw = c.extensions orelse return false;
        var members: strand.json.Members = undefined;
        members.init(raw.bytes, .{ .limits = limits });
        while (members.next() catch return false) |m| if (m.is(name)) return true;
        return false;
    }
};

/// The kinds of input a server may ask a client for.
pub const InputKind = enum { elicit_form, elicit_url, sample, roots };

pub const ServerCapabilities = struct {
    experimental: ?Raw = null,
    logging: ?Empty = null,
    completions: ?Empty = null,
    prompts: ?ListChanged = null,
    resources: ?Resources = null,
    tools: ?ListChanged = null,
    extensions: ?Raw = null,

    pub const ListChanged = struct {
        list_changed: ?bool = null,
        pub const strand = .{ .rename_all = .camel_case };
    };
    pub const Resources = struct {
        subscribe: ?bool = null,
        list_changed: ?bool = null,
        pub const strand = .{ .rename_all = .camel_case };
    };
};

/// `{}`.
pub const Empty = struct {};

pub const Role = enum { user, assistant };

pub const Annotations = struct {
    audience: ?[]const Role = null,
    priority: ?f64 = null,
    last_modified: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    read_only_hint: ?bool = null,
    destructive_hint: ?bool = null,
    idempotent_hint: ?bool = null,
    open_world_hint: ?bool = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const TextContent = struct {
    text: []const u8,
    annotations: ?Annotations = null,
    meta: ?Raw = null,

    pub const strand = .{ .fields = .{ .meta = .{ .name = "_meta" } } };
};

/// An image or audio clip, base64 in `data`.
pub const MediaContent = struct {
    data: []const u8,
    mime_type: []const u8,
    annotations: ?Annotations = null,
    meta: ?Raw = null,

    pub const strand = .{ .rename_all = .camel_case, .fields = .{ .meta = .{ .name = "_meta" } } };
};

pub const ResourceContents = struct {
    uri: []const u8,
    mime_type: ?[]const u8 = null,
    /// Exactly one of `text` and `blob` (base64) is set.
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    meta: ?Raw = null,

    pub const strand = .{ .rename_all = .camel_case, .fields = .{ .meta = .{ .name = "_meta" } } };
};

pub const EmbeddedResource = struct {
    resource: ResourceContents,
    annotations: ?Annotations = null,
    meta: ?Raw = null,

    pub const strand = .{ .fields = .{ .meta = .{ .name = "_meta" } } };
};

/// A resource as listed, or linked from a tool's result.
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    annotations: ?Annotations = null,
    size: ?u64 = null,
    icons: ?[]const Icon = null,
    meta: ?Raw = null,

    pub const strand = .{ .rename_all = .camel_case, .fields = .{ .meta = .{ .name = "_meta" } } };
};

pub const ResourceTemplate = struct {
    uri_template: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    annotations: ?Annotations = null,
    icons: ?[]const Icon = null,
    meta: ?Raw = null,

    pub const strand = .{ .rename_all = .camel_case, .fields = .{ .meta = .{ .name = "_meta" } } };
};

/// What a tool returns, a prompt's message holds, a sampling answer carries.
pub const ContentBlock = union(enum) {
    text: TextContent,
    image: MediaContent,
    audio: MediaContent,
    resource_link: Resource,
    resource: EmbeddedResource,

    pub const strand = .{ .tag = "type" };

    pub fn ofText(text: []const u8) ContentBlock {
        return .{ .text = .{ .text = text } };
    }
};

pub const PromptArgument = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    icons: ?[]const Icon = null,
    meta: ?Raw = null,

    pub const strand = .{ .fields = .{ .meta = .{ .name = "_meta" } } };
};

pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,
};

pub const LoggingLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,

    /// Whether a line at `level` goes out where `minimum` was asked for.
    pub fn reaches(level: LoggingLevel, minimum: LoggingLevel) bool {
        return @backingInt(level) >= @backingInt(minimum);
    }
};

/// A string or an integer, as a progress token is.
pub const Token = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Token {
        return switch (try access.peek()) {
            .number => .{ .integer = try access.read(i64) },
            .text => .{ .string = try access.read([]const u8) },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Token, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .integer => |n| try access.write(n),
            .string => |s| try access.write(s),
        }
    }
    pub const strand_json_schema = "{\"type\":[\"string\",\"integer\"]}";
};

// Input a server asks a client for (multi round-trip requests).

/// What an elicitation asks for: a form the client shows (its fields'
/// schema as the server wrote it), or a URL the user opens.
pub const Elicit = union(enum) {
    form: struct {
        message: []const u8,
        requested_schema: Raw,
        pub const strand = .{ .rename_all = .camel_case };
    },
    url: struct {
        message: []const u8,
        url: []const u8,
    },

    pub const strand = .{ .tag = "mode" };
};

pub const ModelHint = struct { name: ?[]const u8 = null };

pub const ModelPreferences = struct {
    hints: ?[]const ModelHint = null,
    cost_priority: ?f64 = null,
    speed_priority: ?f64 = null,
    intelligence_priority: ?f64 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const SamplingMessage = struct {
    role: Role,
    content: Raw,
};

pub const CreateMessageParams = struct {
    messages: []const SamplingMessage,
    max_tokens: u32,
    model_preferences: ?ModelPreferences = null,
    system_prompt: ?[]const u8 = null,
    temperature: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    metadata: ?Raw = null,

    pub const strand = .{ .rename_all = .camel_case };
};

/// One request of an input-required answer, written as `{"method": ...,
/// "params": ...}`.
pub const InputRequest = union(enum) {
    elicit: Elicit,
    sample: CreateMessageParams,
    roots,

    pub const strand = .{ .tag = "method", .content = "params", .variants = .{
        .elicit = .{ .name = "elicitation/create" },
        .sample = .{ .name = "sampling/createMessage" },
        .roots = .{ .name = "roots/list" },
    } };

    pub fn kind(r: InputRequest) InputKind {
        return switch (r) {
            .elicit => |e| switch (e) {
                .form => .elicit_form,
                .url => .elicit_url,
            },
            .sample => .sample,
            .roots => .roots,
        };
    }

    /// The method the request is sent under.
    pub fn method(r: InputRequest) []const u8 {
        return switch (r) {
            .elicit => "elicitation/create",
            .sample => "sampling/createMessage",
            .roots => "roots/list",
        };
    }
};

pub const ElicitResult = struct {
    action: Action,
    content: ?Raw = null,

    pub const Action = enum { accept, decline, cancel };
};

pub const CreateMessageResult = struct {
    role: Role,
    content: Raw,
    model: []const u8,
    stop_reason: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const Root = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
};

pub const ListRootsResult = struct {
    roots: []const Root,
};

// Requests a client sends, as their params read.

pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?Raw = null,
    input_responses: ?Raw = null,
    request_state: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const GetPromptParams = struct {
    name: []const u8,
    arguments: ?Raw = null,
    input_responses: ?Raw = null,
    request_state: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const ReadResourceParams = struct {
    uri: []const u8,
    input_responses: ?Raw = null,
    request_state: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const PaginatedParams = struct {
    cursor: ?[]const u8 = null,
};

pub const CompleteParams = struct {
    ref: Reference,
    argument: Argument,
    context: ?Context = null,

    pub const Reference = union(enum) {
        prompt: struct { name: []const u8 },
        resource: struct { uri: []const u8 },
        pub const strand = .{ .tag = "type", .variants = .{ .prompt = .{ .name = "ref/prompt" }, .resource = .{ .name = "ref/resource" } } };
    };
    pub const Argument = struct { name: []const u8, value: []const u8 };
    pub const Context = struct { arguments: ?Raw = null };
};

pub const Completion = struct {
    values: []const []const u8,
    total: ?u64 = null,
    has_more: ?bool = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const SubscriptionFilter = struct {
    tools_list_changed: ?bool = null,
    prompts_list_changed: ?bool = null,
    resources_list_changed: ?bool = null,
    resource_subscriptions: ?[]const []const u8 = null,
    /// The tasks whose status the stream carries (the tasks extension).
    task_ids: ?[]const []const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const ListenParams = struct {
    notifications: SubscriptionFilter,
};

/// `tasks/get` and `tasks/cancel` (the tasks extension).
pub const TaskParams = struct {
    task_id: []const u8,

    pub const strand = .{ .rename_all = .camel_case };
};

/// `tasks/update`: answers to what a task waits for.
pub const UpdateTaskParams = struct {
    task_id: []const u8,
    input_responses: Raw,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const CancelledParams = struct {
    request_id: Raw,
    reason: ?[]const u8 = null,

    pub const strand = .{ .rename_all = .camel_case };
};

pub const CacheScope = enum { public, private };
