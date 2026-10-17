//! The server the official conformance suite drives
//! (`npx @modelcontextprotocol/conformance server --url
//! http://127.0.0.1:<port>/mcp`): the tools, resources and prompts its
//! scenarios name, on parley, over Streamable HTTP. By hand: `bay
//! conformance-server -- --port 3000`; it serves until it is stopped.
const std = @import("std");
const parley = @import("parley");
const http = @import("parley.http");
const uplink = @import("uplink");
const strand = @import("strand");

const Io = std.Io;
const Call = parley.Call;
const types = parley.types;
const ToolResult = parley.ToolResult;

const image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
const audio = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA=";

fn content(call: *Call, blocks: []const types.ContentBlock) Call.Error!ToolResult {
    return .{ .content = try call.arena.dupe(types.ContentBlock, blocks) };
}

fn simpleText(_: *Call) Call.Error!ToolResult {
    return .ofText("This is a simple text response for testing.");
}

fn imageContent(call: *Call) Call.Error!ToolResult {
    return content(call, &.{.{ .image = .{ .data = image, .mime_type = "image/png" } }});
}

fn audioContent(call: *Call) Call.Error!ToolResult {
    return content(call, &.{.{ .audio = .{ .data = audio, .mime_type = "audio/wav" } }});
}

fn embeddedResource(call: *Call) Call.Error!ToolResult {
    return content(call, &.{.{ .resource = .{ .resource = .{ .uri = "test://embedded-resource", .mime_type = "text/plain", .text = "This is an embedded resource content." } } }});
}

fn multipleContentTypes(call: *Call) Call.Error!ToolResult {
    return content(call, &.{
        .ofText("Multiple content types test:"),
        .{ .image = .{ .data = image, .mime_type = "image/png" } },
        .{ .resource = .{ .resource = .{ .uri = "test://mixed-content-resource", .mime_type = "application/json", .text = "{\"test\":\"data\",\"value\":123}" } } },
    });
}

fn withLogging(call: *Call) Call.Error!ToolResult {
    try call.log(.info, null, "Tool execution started");
    call.io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
    try call.log(.info, null, "Tool processing data");
    call.io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
    try call.log(.info, null, "Tool execution completed");
    return .ofText("Tool with logging executed successfully");
}

fn withProgress(call: *Call) Call.Error!ToolResult {
    var step: u32 = 0;
    while (step <= 100) : (step += 50) {
        if (step != 0) call.io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
        try call.progress(@floatFromInt(step), 100, try std.fmt.allocPrint(call.arena, "Completed step {d} of 100", .{step}));
    }
    const token = call.context.progress_token orelse return .ofText("0");
    return .ofText(switch (token) {
        .integer => |n| try std.fmt.allocPrint(call.arena, "{d}", .{n}),
        .string => |s| s,
    });
}

fn errorHandling(_: *Call) Call.Error!ToolResult {
    return .failure("This tool intentionally returns an error for testing");
}

fn sampling(call: *Call, args: struct { prompt: []const u8 }) Call.Error!ToolResult {
    var out: std.Io.Writer.Allocating = .init(call.arena);
    out.writer.writeAll("{\"type\":\"text\",\"text\":") catch return error.OutOfMemory;
    parley.wire.writeString(&out.writer, args.prompt) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    const message = out.written();
    const messages = try call.arena.dupe(types.SamplingMessage, &.{.{ .role = .user, .content = .{ .bytes = message } }});
    const answer = try call.sample("sample", .{ .messages = messages, .max_tokens = 100 }) orelse return error.InputRequired;
    const Text = struct { text: ?[]const u8 = null };
    const said = strand.json.parseLeaky(Text, call.arena, answer.content.bytes, parley.types.read_options) catch Text{};
    return .ofText(try std.fmt.allocPrint(call.arena, "LLM response: {s}", .{said.text orelse "No response"}));
}

fn elicitation(call: *Call, args: struct { message: []const u8 }) Call.Error!ToolResult {
    const answer = try call.elicit("response", .{ .form = .{
        .message = args.message,
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"response\":{\"type\":\"string\",\"description\":\"User's response\"}},\"required\":[\"response\"]}" },
    } }) orelse return error.InputRequired;
    return .ofText(try std.fmt.allocPrint(call.arena, "User response: action={t}, content={s}", .{ answer.action, if (answer.content) |c| c.bytes else "{}" }));
}

fn elicitWith(call: *Call, message: []const u8, schema: []const u8) Call.Error!ToolResult {
    const answer = try call.elicit("form", .{ .form = .{ .message = message, .requested_schema = .{ .bytes = schema } } }) orelse return error.InputRequired;
    return .ofText(try std.fmt.allocPrint(call.arena, "Elicitation completed: action={t}, content={s}", .{ answer.action, if (answer.content) |c| c.bytes else "{}" }));
}

fn elicitDefaults(call: *Call) Call.Error!ToolResult {
    return elicitWith(call, "Please review and update the form fields with defaults",
        \\{"type":"object","properties":{"name":{"type":"string","description":"User name","default":"John Doe"},"age":{"type":"integer","description":"User age","default":30},"score":{"type":"number","description":"User score","default":95.5},"status":{"type":"string","description":"User status","enum":["active","inactive","pending"],"default":"active"},"verified":{"type":"boolean","description":"Verification status","default":true}},"required":[]}
    );
}

fn elicitEnums(call: *Call) Call.Error!ToolResult {
    return elicitWith(call, "Please select options from the enum fields",
        \\{"type":"object","properties":{"untitledSingle":{"type":"string","description":"Select one option","enum":["option1","option2","option3"]},"titledSingle":{"type":"string","description":"Select one option with titles","oneOf":[{"const":"value1","title":"First Option"},{"const":"value2","title":"Second Option"},{"const":"value3","title":"Third Option"}]},"legacyEnum":{"type":"string","description":"Select one option (legacy)","enum":["opt1","opt2","opt3"],"enumNames":["Option One","Option Two","Option Three"]},"untitledMulti":{"type":"array","description":"Select multiple options","minItems":1,"maxItems":3,"items":{"type":"string","enum":["option1","option2","option3"]}},"titledMulti":{"type":"array","description":"Select multiple options with titles","minItems":1,"maxItems":3,"items":{"anyOf":[{"const":"value1","title":"First Choice"},{"const":"value2","title":"Second Choice"},{"const":"value3","title":"Third Choice"}]}}},"required":[]}
    );
}

// Multi round-trip requests (2026-07-28).

fn text(call: *Call, comptime format: []const u8, args: anytype) Call.Error!ToolResult {
    return .ofText(try std.fmt.allocPrint(call.arena, format, args));
}

/// A field of an elicitation's accepted content, or "unknown".
fn field(call: *Call, answer: types.ElicitResult, name: []const u8) []const u8 {
    const object = answer.content orelse return "unknown";
    var members: strand.json.Members = undefined;
    members.init(object.bytes, .{});
    while (members.next() catch return "unknown") |m| if (m.is(name)) {
        return strand.json.parseLeaky([]const u8, call.arena, m.value, .{}) catch "unknown";
    };
    return "unknown";
}

const name_form: types.Elicit = .{ .form = .{
    .message = "What is your name?",
    .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
} };

fn mrtrElicitation(call: *Call) Call.Error!ToolResult {
    const answer = try call.elicit("user_name", name_form) orelse return error.InputRequired;
    return text(call, "Hello, {s}!", .{field(call, answer, "name")});
}

fn capitalQuestion(call: *Call) Call.Error!types.CreateMessageParams {
    const messages = try call.arena.dupe(types.SamplingMessage, &.{.{ .role = .user, .content = .{ .bytes = "{\"type\":\"text\",\"text\":\"What is the capital of France?\"}" } }});
    return .{ .messages = messages, .max_tokens = 100 };
}

fn sampledText(call: *Call, result: types.CreateMessageResult) []const u8 {
    const Text = struct { text: ?[]const u8 = null };
    const t = strand.json.parseLeaky(Text, call.arena, result.content.bytes, parley.types.read_options) catch return "no response";
    return t.text orelse "no response";
}

fn mrtrSampling(call: *Call) Call.Error!ToolResult {
    const answer = try call.sample("sample_request", try capitalQuestion(call)) orelse return error.InputRequired;
    return text(call, "Sampling result: {s}", .{sampledText(call, answer)});
}

fn mrtrRoots(call: *Call) Call.Error!ToolResult {
    const answer = try call.roots("roots_request") orelse return error.InputRequired;
    return text(call, "Found {d} root(s)", .{answer.roots.len});
}

fn mrtrRequestState(call: *Call) Call.Error!ToolResult {
    const confirm = try call.elicit("confirm", .{ .form = .{
        .message = "Please confirm",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"]}" },
    } });
    if (confirm) |answer| if (std.mem.eql(u8, call.state() orelse "", "request-state")) {
        const Ok = struct { ok: bool = false };
        const ok = if (answer.content) |c| strand.json.parseLeaky(Ok, call.arena, c.bytes, parley.types.read_options) catch Ok{} else Ok{};
        if (ok.ok) return .ofText("state-ok: requestState validated");
    };
    call.pending.clearRetainingCapacity();
    _ = try call.elicit("confirm", .{ .form = .{
        .message = "Please confirm",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"]}" },
    } });
    try call.setState("request-state");
    return error.InputRequired;
}

fn mrtrMultipleInputs(call: *Call) Call.Error!ToolResult {
    const name = try call.elicit("user_name", name_form);
    const greeting_messages = try call.arena.dupe(types.SamplingMessage, &.{.{ .role = .user, .content = .{ .bytes = "{\"type\":\"text\",\"text\":\"Generate a greeting\"}" } }});
    const greeting = try call.sample("greeting", .{ .messages = greeting_messages, .max_tokens = 50 });
    const roots = try call.roots("client_roots");
    if (name != null and greeting != null and roots != null and std.mem.eql(u8, call.state() orelse "", "multiple-inputs")) {
        return text(call, "Name: {s}; Greeting: {s}; Roots: {d}", .{ field(call, name.?, "name"), sampledText(call, greeting.?), roots.?.roots.len });
    }
    try call.setState("multiple-inputs");
    return error.InputRequired;
}

fn mrtrMultiRound(call: *Call) Call.Error!ToolResult {
    const round = call.state() orelse "";
    if (std.mem.startsWith(u8, round, "round-2:")) {
        const answer = try call.elicit("step2", .{ .form = .{
            .message = "Step 2: What is your favorite color?",
            .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\"}},\"required\":[\"color\"]}" },
        } }) orelse {
            try call.setState(round);
            return error.InputRequired;
        };
        return text(call, "Multi-round complete for {s} who likes {s}", .{ round["round-2:".len..], field(call, answer, "color") });
    }
    const first = try call.elicit("step1", .{ .form = .{
        .message = "Step 1: What is your name?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
    } }) orelse {
        try call.setState("round-1");
        return error.InputRequired;
    };
    call.pending.clearRetainingCapacity();
    _ = try call.elicit("step2", .{ .form = .{
        .message = "Step 2: What is your favorite color?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\"}},\"required\":[\"color\"]}" },
    } });
    try call.setState(try std.fmt.allocPrint(call.arena, "round-2:{s}", .{field(call, first, "name")}));
    return error.InputRequired;
}

fn mrtrTamperedState(call: *Call) Call.Error!ToolResult {
    if (call.state()) |s| if (std.mem.eql(u8, s, "tamper-test")) return .ofText("integrity-ok: state verified");
    _ = try call.elicit("confirm", .{ .form = .{
        .message = "Please confirm",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"]}" },
    } });
    try call.setState("tamper-test");
    return error.InputRequired;
}

fn mrtrCapabilities(call: *Call) Call.Error!ToolResult {
    if (call.responses) |object| if (!std.mem.eql(u8, std.mem.trim(u8, object, " \t\r\n"), "{}")) {
        var keys: std.ArrayList(u8) = .empty;
        var members: strand.json.Members = undefined;
        members.init(object, .{});
        while (members.next() catch null) |m| {
            if (keys.items.len != 0) try keys.append(call.arena, ',');
            try keys.appendSlice(call.arena, m.name);
        }
        return text(call, "capabilities-ok: received {s}", .{keys.items});
    };
    var asked = false;
    if (call.context.client.accepts(.elicit_form)) {
        _ = try call.elicit("elicit_input", .{ .form = .{
            .message = "Elicitation input",
            .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}" },
        } });
        asked = true;
    }
    if (call.context.client.accepts(.sample)) {
        const messages = try call.arena.dupe(types.SamplingMessage, &.{.{ .role = .user, .content = .{ .bytes = "{\"type\":\"text\",\"text\":\"Sample request\"}" } }});
        _ = try call.sample("sample_input", .{ .messages = messages, .max_tokens = 50 });
        asked = true;
    }
    if (!asked) return .ofText("No supported capabilities declared");
    try call.setState("capabilities-test");
    return error.InputRequired;
}

fn missingCapability(call: *Call) Call.Error!ToolResult {
    const messages = try call.arena.dupe(types.SamplingMessage, &.{.{ .role = .user, .content = .{ .bytes = "{\"type\":\"text\",\"text\":\"hello\"}" } }});
    _ = try call.sample("needs_sampling", .{ .messages = messages, .max_tokens = 10 }) orelse return error.InputRequired;
    return .ofText("Success");
}

fn loggingTool(call: *Call) Call.Error!ToolResult {
    try call.log(.info, null, "Diagnostic trace logging activated");
    return .ofText("Logging evaluated");
}

fn streamingElicitation(call: *Call) Call.Error!ToolResult {
    try call.progress(50, 100, null);
    return .ofText("Streaming complete");
}

/// What the triggers add and take away, so each call is a change.
var dynamic_present: bool = false;
var dynamic_prompt_present: bool = false;

fn triggerToolChange(call: *Call) Call.Error!ToolResult {
    const server = server_handle.?;
    if (dynamic_present) {
        _ = server.removeTool(call.io, "test_dynamic_tool") catch return error.Canceled;
    } else server.addTool(call.io, .{ .name = "test_dynamic_tool", .description = "A tool added and removed at run time" }, simpleText) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    };
    dynamic_present = !dynamic_present;
    return .ofText("Mutation triggered");
}

fn dynamicPrompt(_: *Call) error{}!parley.PromptResult {
    return .{ .messages = &simple_messages };
}

fn triggerPromptChange(call: *Call) Call.Error!ToolResult {
    const server = server_handle.?;
    if (dynamic_prompt_present) {
        _ = server.removePrompt(call.io, "test_dynamic_prompt") catch return error.Canceled;
    } else server.addPrompt(call.io, .{ .name = "test_dynamic_prompt", .description = "A prompt added and removed at run time" }, dynamicPrompt) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    };
    dynamic_prompt_present = !dynamic_prompt_present;
    return .ofText("Mutation triggered");
}

var server_handle: ?*parley.Server = null;

const json_schema_2020_12 =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","$defs":{"address":{"$anchor":"addressDef","type":"object","properties":{"street":{"type":"string"},"city":{"type":"string"}}}},"properties":{"name":{"type":"string"},"address":{"$ref":"#/$defs/address"},"contactMethod":{"type":"string","enum":["phone","email"]},"phone":{"type":"string"},"email":{"type":"string"}},"allOf":[{"anyOf":[{"required":["phone"]},{"required":["email"]}]}],"if":{"properties":{"contactMethod":{"const":"phone"}},"required":["contactMethod"]},"then":{"required":["phone"]},"else":{"required":["email"]},"additionalProperties":false}
;

fn jsonSchemaTool(_: ?*anyopaque, _: *Call, arguments: ?[]const u8) Call.Error!ToolResult {
    return .ofText(arguments orelse "{}");
}

// Resources.

fn staticText(_: ?*anyopaque, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    return .{ .contents = try call.arena.dupe(types.ResourceContents, &.{.{ .uri = uri, .mime_type = "text/plain", .text = "This is the content of the static text resource." }}) };
}

fn staticBinary(_: ?*anyopaque, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    return .{ .contents = try call.arena.dupe(types.ResourceContents, &.{.{ .uri = uri, .mime_type = "image/png", .blob = image }}) };
}

fn watched(_: ?*anyopaque, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    return .{ .contents = try call.arena.dupe(types.ResourceContents, &.{.{ .uri = uri, .mime_type = "text/plain", .text = "Watched resource content" }}) };
}

fn templated(_: ?*anyopaque, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    const prefix = "test://template/";
    const id = uri[prefix.len .. uri.len - "/data".len];
    const body = try std.fmt.allocPrint(call.arena, "{{\"id\":\"{s}\",\"templateTest\":true,\"data\":\"Data for ID: {s}\"}}", .{ id, id });
    return .{ .contents = try call.arena.dupe(types.ResourceContents, &.{.{ .uri = uri, .mime_type = "application/json", .text = body }}) };
}

// Prompts.

const simple_messages = [_]types.PromptMessage{.{ .role = .user, .content = .{ .text = .{ .text = "This is a simple prompt for testing." } } }};

fn simplePrompt(_: *Call) error{}!parley.PromptResult {
    return .{ .messages = &simple_messages };
}

fn promptWithArguments(call: *Call, args: struct { arg1: []const u8, arg2: []const u8 }) Call.Error!parley.PromptResult {
    const t = try std.fmt.allocPrint(call.arena, "Prompt with arguments: arg1='{s}', arg2='{s}'", .{ args.arg1, args.arg2 });
    return .{ .messages = try call.arena.dupe(types.PromptMessage, &.{.{ .role = .user, .content = .ofText(t) }}) };
}

fn promptWithEmbeddedResource(call: *Call, args: struct { resourceUri: []const u8 }) Call.Error!parley.PromptResult {
    return .{ .messages = try call.arena.dupe(types.PromptMessage, &.{
        .{ .role = .user, .content = .{ .resource = .{ .resource = .{ .uri = args.resourceUri, .mime_type = "text/plain", .text = "Embedded resource content for testing." } } } },
        .{ .role = .user, .content = .ofText("Please process the embedded resource above.") },
    }) };
}

fn promptWithImage(call: *Call) Call.Error!parley.PromptResult {
    return .{ .messages = try call.arena.dupe(types.PromptMessage, &.{
        .{ .role = .user, .content = .{ .image = .{ .data = image, .mime_type = "image/png" } } },
        .{ .role = .user, .content = .ofText("Please analyze the image above.") },
    }) };
}

fn promptInputRequired(call: *Call) Call.Error!parley.PromptResult {
    const answer = try call.elicit("user_context", .{ .form = .{
        .message = "What context should the prompt use?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"context\":{\"type\":\"string\"}},\"required\":[\"context\"]}" },
    } }) orelse return error.InputRequired;
    const t = try std.fmt.allocPrint(call.arena, "Prompt with context: {s}", .{field(call, answer, "context")});
    return .{ .messages = try call.arena.dupe(types.PromptMessage, &.{.{ .role = .user, .content = .ofText(t) }}) };
}

fn complete(_: ?*anyopaque, _: *Call, _: types.CompleteParams) Call.Error!types.Completion {
    return .{ .values = &.{}, .total = 0, .has_more = false };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 3000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        }
    }

    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "parley-conformance-server", .version = "1.0.0" },
        .cache = .{
            .tools = .{ .ttl = .literal("5m") },
            .prompts = .{ .ttl = .literal("5m") },
            .resources = .{ .ttl = .literal("5m") },
            .templates = .{ .ttl = .literal("5m") },
            .read = .{ .ttl = .literal("5m"), .scope = .private },
        },
    });
    defer server.deinit();
    server_handle = &server;

    try server.addTool(io, .{ .name = "test_simple_text", .description = "Tests simple text content response" }, simpleText);
    try server.addTool(io, .{ .name = "test_image_content", .description = "Tests image content response" }, imageContent);
    try server.addTool(io, .{ .name = "test_audio_content", .description = "Tests audio content response" }, audioContent);
    try server.addTool(io, .{ .name = "test_embedded_resource", .description = "Tests embedded resource content response" }, embeddedResource);
    try server.addTool(io, .{ .name = "test_multiple_content_types", .description = "Tests response with multiple content types (text, image, resource)" }, multipleContentTypes);
    try server.addTool(io, .{ .name = "test_tool_with_logging", .description = "Tests tool that emits log messages during execution" }, withLogging);
    try server.addTool(io, .{ .name = "test_tool_with_progress", .description = "Tests tool that reports progress notifications" }, withProgress);
    try server.addTool(io, .{ .name = "test_error_handling", .description = "Tests error response handling" }, errorHandling);
    try server.addTool(io, .{ .name = "test_sampling", .description = "Tests server-initiated sampling (LLM completion request)" }, sampling);
    try server.addTool(io, .{ .name = "test_elicitation", .description = "Tests server-initiated elicitation (user input request)" }, elicitation);
    try server.addTool(io, .{ .name = "test_elicitation_sep1034_defaults", .description = "Tests elicitation with default values per SEP-1034" }, elicitDefaults);
    try server.addTool(io, .{ .name = "test_elicitation_sep1330_enums", .description = "Tests elicitation with enum schema improvements per SEP-1330" }, elicitEnums);
    try server.addDynamicTool(io, .{ .name = "json_schema_2020_12_tool", .description = "Tool with JSON Schema 2020-12 features", .input_schema = json_schema_2020_12 }, .{ .call = jsonSchemaTool });
    try server.addTool(io, .{ .name = "test_missing_capability", .description = "Test tool requiring sampling" }, missingCapability);
    try server.addTool(io, .{ .name = "test_input_required_result_elicitation", .description = "MRTR: returns InputRequiredResult with elicitation request" }, mrtrElicitation);
    try server.addTool(io, .{ .name = "test_input_required_result_sampling", .description = "MRTR: returns InputRequiredResult with sampling request" }, mrtrSampling);
    try server.addTool(io, .{ .name = "test_input_required_result_list_roots", .description = "MRTR: returns InputRequiredResult with roots/list request" }, mrtrRoots);
    try server.addTool(io, .{ .name = "test_input_required_result_request_state", .description = "MRTR: returns InputRequiredResult with requestState" }, mrtrRequestState);
    try server.addTool(io, .{ .name = "test_input_required_result_multiple_inputs", .description = "MRTR: returns InputRequiredResult with multiple input requests" }, mrtrMultipleInputs);
    try server.addTool(io, .{ .name = "test_input_required_result_multi_round", .description = "MRTR: multi-round InputRequiredResult workflow" }, mrtrMultiRound);
    try server.addTool(io, .{ .name = "test_input_required_result_tampered_state", .description = "MRTR: sealed requestState integrity test" }, mrtrTamperedState);
    try server.addTool(io, .{ .name = "test_input_required_result_capabilities", .description = "MRTR: respects client capabilities in inputRequests" }, mrtrCapabilities);
    try server.addTool(io, .{ .name = "test_streaming_elicitation", .description = "Diagnostic tool validating response progress streams" }, streamingElicitation);
    try server.addTool(io, .{ .name = "test_logging_tool", .description = "Diagnostic logging validator tool" }, loggingTool);
    try server.addTool(io, .{ .name = "test_trigger_tool_change", .description = "Adds or removes test_dynamic_tool" }, triggerToolChange);
    try server.addTool(io, .{ .name = "test_trigger_prompt_change", .description = "Adds or removes test_dynamic_prompt" }, triggerPromptChange);

    try server.addResource(io, .{ .uri = "test://static-text", .name = "static-text", .title = "Static Text Resource", .description = "A static text resource for testing", .mime_type = "text/plain" }, .{ .read = staticText });
    try server.addResource(io, .{ .uri = "test://static-binary", .name = "static-binary", .title = "Static Binary Resource", .description = "A static binary resource (image) for testing", .mime_type = "image/png" }, .{ .read = staticBinary });
    try server.addResource(io, .{ .uri = "test://watched-resource", .name = "watched-resource", .title = "Watched Resource", .description = "A resource that auto-updates every 3 seconds", .mime_type = "text/plain" }, .{ .read = watched });
    try server.addTemplate(io, .{ .uri_template = "test://template/{id}/data", .name = "template", .title = "Resource Template", .description = "A resource template with parameter substitution", .mime_type = "application/json" }, .{ .read = templated });

    try server.addPrompt(io, .{ .name = "test_simple_prompt", .title = "Simple Test Prompt", .description = "A simple prompt without arguments" }, simplePrompt);
    try server.addPrompt(io, .{ .name = "test_prompt_with_arguments", .title = "Prompt With Arguments", .description = "A prompt with required arguments", .arguments = &.{
        .{ .name = "arg1", .description = "First test argument", .required = true },
        .{ .name = "arg2", .description = "Second test argument", .required = true },
    } }, promptWithArguments);
    try server.addPrompt(io, .{ .name = "test_prompt_with_embedded_resource", .title = "Prompt With Embedded Resource", .description = "A prompt that includes an embedded resource", .arguments = &.{
        .{ .name = "resourceUri", .description = "URI of the resource to embed", .required = true },
    } }, promptWithEmbeddedResource);
    try server.addPrompt(io, .{ .name = "test_prompt_with_image", .title = "Prompt With Image", .description = "A prompt that includes image content" }, promptWithImage);
    try server.addPrompt(io, .{ .name = "test_input_required_result_prompt", .description = "MRTR: prompt that requires elicitation input" }, promptInputRequired);
    server.setCompleter(.{ .complete = complete });

    var endpoint: http.Endpoint = .init(gpa, &server, .{});
    defer endpoint.deinit();
    var router: uplink.server.Router = .init(gpa);
    defer router.deinit();
    try router.add("/mcp", endpoint.handler());
    var web: uplink.Server = .init(gpa, .{}, router.handler());
    defer web.deinit(io);
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", port)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("serving http://127.0.0.1:{d}/mcp", .{port});
    try web.serve(io, &listener);
}
