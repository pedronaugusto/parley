//! The core answering 2026-07-28 requests in process: discovery, the
//! lists and their caching hints, tools typed and dynamic, resources and
//! templates, prompts, input asked across rounds with sealed state, and the
//! refusals the revision asks for.
const std = @import("std");
const strand = @import("strand");
const parley = @import("parley.zig");
const validation = @import("parley.validation");
const shakedown = @import("shakedown");

const testing = std.testing;
const Server = parley.Server;
const Call = parley.Call;

/// A sink that keeps what it is sent.
const Recorder = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList([]u8) = .empty,
    mutex: std.Io.Mutex = .init,
    target: parley.Sink.Target = .{ .sendFn = send },

    fn sink(r: *Recorder) parley.Sink {
        return .{ .target = &r.target };
    }

    fn send(t: *parley.Sink.Target, io: std.Io, message: []const u8) parley.Sink.SendError!void {
        const r: *Recorder = @alignCast(@fieldParentPtr("target", t));
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.messages.append(r.gpa, r.gpa.dupe(u8, message) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }

    fn deinit(r: *Recorder) void {
        for (r.messages.items) |m| r.gpa.free(m);
        r.messages.deinit(r.gpa);
    }
};

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}},"progressToken":"p1"}
;

const Weather = struct {
    city: []const u8,
    days: u8 = 1,
    pub const strand = .{ .fields = .{
        .city = .{ .description = "The city to forecast" },
        .days = .{ .range = .{ .min = 1, .max = 7 } },
    } };
};
const Forecast = struct { city: []const u8, celsius: f64 };

fn forecast(call: *Call, args: Weather) Call.Error!Forecast {
    try call.progress(1, 2, "asking the sky");
    return .{ .city = args.city, .celsius = 21.5 };
}

fn echo(_: *Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

fn broken(_: *Call) error{DiskOnFire}!parley.ToolResult {
    return error.DiskOnFire;
}

/// Asks for a name across two rounds, keeping a counter in its state.
fn greet(call: *Call) Call.Error!parley.ToolResult {
    const answer = (try call.elicit("name", .{ .form = .{
        .message = "Who are you?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
    } })) orelse {
        try call.setState("round-1");
        return error.InputRequired;
    };
    if (!std.mem.eql(u8, call.state() orelse "", "round-1")) return error.InvalidInput;
    const Content = struct { name: []const u8 };
    const content = strand.json.parseLeaky(Content, call.arena, answer.content.?.bytes, .{}) catch return error.InvalidInput;
    return .ofText(try call.arena.print("hello {s}", .{content.name}));
}

fn sampleIt(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.sample("ask", .{ .messages = &.{}, .max_tokens = 10 }) orelse return error.InputRequired;
    return .ofText("sampled");
}

var read_static: parley.ReadHandler = .{ .readFn = readStatic };
var read_item: parley.ReadHandler = .{ .readFn = readItem };

fn readStatic(_: *parley.ReadHandler, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    const contents = try call.arena.alloc(parley.types.ResourceContents, 1);
    contents[0] = .{ .uri = uri, .mime_type = "text/plain", .text = "static" };
    return .{ .contents = contents };
}

fn readItem(_: *parley.ReadHandler, call: *Call, uri: []const u8) Call.Error!parley.ReadResult {
    const contents = try call.arena.alloc(parley.types.ResourceContents, 1);
    contents[0] = .{ .uri = uri, .text = uri["test://items/".len..] };
    return .{ .contents = contents };
}

const review_messages = [_]parley.types.PromptMessage{.{ .role = .user, .content = .{ .text = .{ .text = "review this" } } }};

fn review(_: *Call, args: struct { code: []const u8, style: ?[]const u8 = null }) error{}!parley.PromptResult {
    _ = args;
    return .{ .messages = &review_messages };
}

fn newServer(io: std.Io) !Server {
    var s = try Server.init(testing.allocator, io, .{
        .info = .{ .name = "test", .version = "1.0.0" },
        .validator = &validation.json_schema,
        .instructions = "for tests",
        .cache = .{ .tools = .{ .ttl = .literal("5m") } },
    });
    errdefer s.deinit();
    try s.addTool(io, .{ .name = "forecast", .description = "The weather" }, forecast);
    try s.addTool(io, .{ .name = "echo" }, echo);
    try s.addTool(io, .{ .name = "broken" }, broken);
    try s.addTool(io, .{ .name = "greet" }, greet);
    try s.addTool(io, .{ .name = "sample" }, sampleIt);
    try s.addResource(io, .{ .uri = "test://static", .name = "static" }, &read_static);
    try s.addTemplate(io, .{ .uri_template = "test://items/{id}", .name = "item" }, &read_item);
    try s.addPrompt(io, .{ .name = "review" }, review);
    return s;
}

/// The answer to one request, written as its message.
fn ask(s: *Server, arena: std.mem.Allocator, recorder: *Recorder, method: []const u8, params: []const u8) ![]const u8 {
    const request: parley.wire.Request = .{ .id = .{ .integer = 1 }, .method = method, .params = params };
    const reply = try s.serve(testing.io, arena, request, null, recorder.sink());
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (reply) {
        .result => |r| try parley.wire.writeResult(&out.writer, request.id, try r.whole(arena)),
        .input_required => |ir| try parley.wire.writeResult(&out.writer, request.id, try s.inputRequiredJson(arena, ir)),
        .failure => |f| try parley.wire.writeFailure(&out.writer, request.id, f.code, f.message, f.data),
    }
    return out.written();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("\n{s}\ndoes not contain\n{s}\n", .{ haystack, needle });
        return error.TestExpectedContains;
    }
}

test "server/discover names the versions, the capabilities and the server, with caching hints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const answer = try ask(&s, arena.allocator(), &r, "server/discover", "{" ++ meta ++ "}");
    try expectContains(answer, "\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\",\"2024-11-05\"]");
    try expectContains(answer, "\"tools\":{\"listChanged\":true}");
    try expectContains(answer, "\"resources\":{\"subscribe\":true,\"listChanged\":true}");
    try expectContains(answer, "\"instructions\":\"for tests\"");
    try expectContains(answer, "\"ttlMs\":0,\"cacheScope\":\"public\"");
    try expectContains(answer, "\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"test\",\"version\":\"1.0.0\"}}");
}

test "tools/list in order, schemas derived from the handlers' types" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const answer = try ask(&s, arena.allocator(), &r, "tools/list", "{" ++ meta ++ "}");
    try expectContains(answer, "{\"name\":\"forecast\",\"description\":\"The weather\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"The city to forecast\"},\"days\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":7}},\"required\":[\"city\"],\"additionalProperties\":false},\"outputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"},\"celsius\":{\"type\":\"number\"}},\"required\":[\"city\",\"celsius\"],\"additionalProperties\":false}}");
    try expectContains(answer, "{\"name\":\"broken\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false}}");
    try expectContains(answer, "\"ttlMs\":300000,\"cacheScope\":\"public\"");
    try testing.expect(std.mem.find(u8, answer, "forecast").? < std.mem.find(u8, answer, "\"echo\"").?);
}

test "a page at a time, and a cursor into a list that changed is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    s.options.page_size = 2;
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const first = try ask(&s, arena.allocator(), &r, "tools/list", "{" ++ meta ++ "}");
    try expectContains(first, "\"nextCursor\":\"5.2\"");
    const second = try ask(&s, arena.allocator(), &r, "tools/list", "{\"cursor\":\"5.2\"," ++ meta ++ "}");
    try expectContains(second, "\"name\":\"broken\"");
    _ = try s.removeTool(testing.io, "echo", null);
    const stale = try ask(&s, arena.allocator(), &r, "tools/list", "{\"cursor\":\"5.2\"," ++ meta ++ "}");
    try expectContains(stale, "\"code\":-32602");
}

test "a typed tool: structured content, the same JSON as text, progress on the request's stream" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const answer = try ask(&s, arena.allocator(), &r, "tools/call", "{\"name\":\"forecast\",\"arguments\":{\"city\":\"Lisbon\"}," ++ meta ++ "}");
    try expectContains(answer, "\"content\":[{\"type\":\"text\",\"text\":\"{\\\"city\\\":\\\"Lisbon\\\",\\\"celsius\\\":21.5}\"}],\"structuredContent\":{\"city\":\"Lisbon\",\"celsius\":21.5}");
    try testing.expectEqual(@as(usize, 1), r.messages.items.len);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"p1\",\"progress\":1,\"total\":2,\"message\":\"asking the sky\"}}", r.messages.items[0]);
}

test "arguments a tool cannot take, and a tool's own error, are errors the model reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const bad = try ask(&s, arena.allocator(), &r, "tools/call", "{\"name\":\"forecast\",\"arguments\":{\"city\":\"Oslo\",\"days\":9}," ++ meta ++ "}");
    try expectContains(bad, "\"isError\":true");
    try expectContains(bad, "invalid arguments: NumberOutOfRange at days");
    const own = try ask(&s, arena.allocator(), &r, "tools/call", "{\"name\":\"broken\"," ++ meta ++ "}");
    try expectContains(own, "{\"type\":\"text\",\"text\":\"DiskOnFire\"}],\"isError\":true");
    const unknown = try ask(&s, arena.allocator(), &r, "tools/call", "{\"name\":\"nope\"," ++ meta ++ "}");
    try expectContains(unknown, "\"error\":{\"code\":-32602,\"message\":\"Unknown tool: nope\"}");
}

test "input across rounds: asked, retried with the answer and the sealed state, completed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const first = try ask(&s, a, &r, "tools/call", "{\"name\":\"greet\"," ++ meta ++ "}");
    try expectContains(first, "\"resultType\":\"input_required\",\"inputRequests\":{\"name\":{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"form\",\"message\":\"Who are you?\",\"requestedSchema\":{");
    const Answer = struct { result: struct { requestState: []const u8 } };
    const parsed = try strand.json.parseLeaky(Answer, a, first, .{ .ignore_unknown_fields = true });
    const sealed = parsed.result.requestState;
    try testing.expect(std.mem.find(u8, sealed, "round-1") == null);
    const retry = try a.print("{{\"name\":\"greet\",\"inputResponses\":{{\"name\":{{\"action\":\"accept\",\"content\":{{\"name\":\"ada\"}}}}}},\"requestState\":\"{s}\",{s}}}", .{ sealed, meta });
    const done = try ask(&s, a, &r, "tools/call", retry);
    try expectContains(done, "\"text\":\"hello ada\"");
    // The same state on another tool, or changed, is refused.
    const elsewhere = try a.print("{{\"name\":\"echo\",\"arguments\":{{\"text\":\"x\"}},\"requestState\":\"{s}\",{s}}}", .{ sealed, meta });
    try expectContains(try ask(&s, a, &r, "tools/call", elsewhere), "\"code\":-32602");
    const changed = try a.dupe(u8, sealed);
    changed[changed.len / 2] = if (changed[changed.len / 2] == 'A') 'B' else 'A';
    const tampered = try a.print("{{\"name\":\"greet\",\"inputResponses\":{{\"name\":{{\"action\":\"accept\",\"content\":{{\"name\":\"ada\"}}}}}},\"requestState\":\"{s}\",{s}}}", .{ changed, meta });
    try expectContains(try ask(&s, a, &r, "tools/call", tampered), "\"code\":-32602");
    // An answer that is not an elicitation's is a protocol error.
    const wrong = try ask(&s, a, &r, "tools/call", "{\"name\":\"greet\",\"inputResponses\":{\"name\":12345}," ++ meta ++ "}");
    try expectContains(wrong, "\"code\":-32602");
}

test "input a client did not declare it can give is -32021, naming the capability" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const answer = try ask(&s, arena.allocator(), &r, "tools/call", "{\"name\":\"sample\"," ++ meta ++ "}");
    try expectContains(answer, "\"error\":{\"code\":-32021,\"message\":\"Missing required client capability\",\"data\":{\"requiredCapabilities\":{\"sampling\":{}}}}");
}

test "resources: a static one, a template's match, and a URI that is neither" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const static = try ask(&s, arena.allocator(), &r, "resources/read", "{\"uri\":\"test://static\"," ++ meta ++ "}");
    try expectContains(static, "\"contents\":[{\"uri\":\"test://static\",\"mimeType\":\"text/plain\",\"text\":\"static\"}],\"ttlMs\":0,\"cacheScope\":\"private\"");
    const item = try ask(&s, arena.allocator(), &r, "resources/read", "{\"uri\":\"test://items/42\"," ++ meta ++ "}");
    try expectContains(item, "\"text\":\"42\"");
    const missing = try ask(&s, arena.allocator(), &r, "resources/read", "{\"uri\":\"test://nothing\"," ++ meta ++ "}");
    try expectContains(missing, "\"error\":{\"code\":-32602,\"message\":\"Resource not found\",\"data\":{\"uri\":\"test://nothing\"}}");
    const templates = try ask(&s, arena.allocator(), &r, "resources/templates/list", "{" ++ meta ++ "}");
    try expectContains(templates, "\"resourceTemplates\":[{\"uriTemplate\":\"test://items/{id}\",\"name\":\"item\"}]");
}

test "prompts: arguments from the handler's struct, a missing required one refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const listed = try ask(&s, arena.allocator(), &r, "prompts/list", "{" ++ meta ++ "}");
    try expectContains(listed, "\"prompts\":[{\"name\":\"review\",\"arguments\":[{\"name\":\"code\",\"required\":true},{\"name\":\"style\"}]}]");
    const got = try ask(&s, arena.allocator(), &r, "prompts/get", "{\"name\":\"review\",\"arguments\":{\"code\":\"x\"}," ++ meta ++ "}");
    try expectContains(got, "\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"review this\"}}]");
    const without = try ask(&s, arena.allocator(), &r, "prompts/get", "{\"name\":\"review\"," ++ meta ++ "}");
    try expectContains(without, "Missing required argument: code");
}

test "what every 2026-07-28 request must carry, and versions not served" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    try expectContains(try ask(&s, arena.allocator(), &r, "tools/list", "{}"), "\"code\":-32602");
    try expectContains(try ask(&s, arena.allocator(), &r, "tools/list", "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}"), "\"code\":-32602");
    const old = try ask(&s, arena.allocator(), &r, "tools/list", "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}");
    try expectContains(old, "\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\",\"2024-11-05\"],\"requested\":\"1900-01-01\"}}");
    try expectContains(try ask(&s, arena.allocator(), &r, "ping", "{" ++ meta ++ "}"), "\"code\":-32601");
    try expectContains(try ask(&s, arena.allocator(), &r, "initialize", "{" ++ meta ++ "}"), "\"code\":-32601");
}

test "an RFC 6570 template matches what it describes and nothing else" {
    try testing.expect(Server.matches("test://items/{id}", "test://items/42"));
    try testing.expect(!Server.matches("test://items/{id}", "test://items/"));
    try testing.expect(!Server.matches("test://items/{id}", "test://items/4/2"));
    try testing.expect(Server.matches("test://template/{id}/data", "test://template/7/data"));
    try testing.expect(!Server.matches("test://template/{id}/data", "test://template/7/other"));
    try testing.expect(Server.matches("file:///{+path}", "file:///a/b/c.txt"));
    try testing.expect(!Server.matches("test://static", "test://static/x"));
}

/// A dynamic tool: answers with the arguments it was given.
fn echoArguments(_: *parley.ToolHandler, call: *Call, arguments: ?[]const u8) Call.Error!parley.ToolResult {
    return .ofText(try call.arena.dupe(u8, arguments orelse "{}"));
}

test "a given input schema checks every call's arguments before the handler runs, as an execution error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    var handler: parley.ToolHandler = .{ .callFn = echoArguments };
    try s.addDynamicTool(testing.io, .{ .name = "book", .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","pattern":"^[A-Z]{3}$"},"day":{"type":"string","format":"date"}},
        \\ "required":["code"],"additionalProperties":false}
    }, &handler);
    const Case = struct { arguments: []const u8, answer: []const u8 };
    const cases = [_]Case{
        .{ .arguments = "{\"code\":\"LIS\",\"day\":\"2026-11-17\"}", .answer = "\"text\":\"{\\\"code\\\":\\\"LIS\\\",\\\"day\\\":\\\"2026-11-17\\\"}\"}]" },
        // The pattern, the format asserted, a member required, one not allowed.
        .{ .arguments = "{\"code\":\"lis\"}", .answer = "\"text\":\"invalid arguments: " },
        .{ .arguments = "{\"code\":\"LIS\",\"day\":\"2026-02-30\"}", .answer = "at /day\"}],\"isError\":true" },
        .{ .arguments = "{\"day\":\"2026-11-17\"}", .answer = "\"isError\":true" },
        .{ .arguments = "{\"code\":\"LIS\",\"seat\":1}", .answer = "\"isError\":true" },
    };
    for (cases) |c| {
        const answer = try ask(&s, a, &r, "tools/call", try a.print("{{\"name\":\"book\",\"arguments\":{s},{s}}}", .{ c.arguments, meta }));
        try expectContains(answer, c.answer);
    }
    // No arguments are the empty object, which lacks `code`.
    try expectContains(try ask(&s, a, &r, "tools/call", "{\"name\":\"book\"," ++ meta ++ "}"), "\"isError\":true");
    // A typed tool given a schema stricter than its type is checked by both.
    try s.addTool(testing.io, .{ .name = "short", .input_schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"maxLength\":3}},\"required\":[\"text\"]}" }, echo);
    try expectContains(try ask(&s, a, &r, "tools/call", "{\"name\":\"short\",\"arguments\":{\"text\":\"abc\"}," ++ meta ++ "}"), "\"text\":\"abc\"}]");
    try expectContains(try ask(&s, a, &r, "tools/call", "{\"name\":\"short\",\"arguments\":{\"text\":\"abcd\"}," ++ meta ++ "}"), "\"text\":\"invalid arguments: ");
    // A schema strand_schema does not compile, or a pattern it cannot run in
    // linear time, is refused when the tool is added.
    try testing.expectError(error.InvalidSchema, s.addDynamicTool(testing.io, .{ .name = "bad", .input_schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":12}}}" }, &handler));
    try testing.expectError(error.InvalidSchema, s.addDynamicTool(testing.io, .{ .name = "slow", .input_schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"pattern\":\"(a)\\\\1\"}}}" }, &handler));
    // A tool removed while nothing holds its schema frees it.
    try testing.expect(try s.removeTool(testing.io, "book", null));
}

test "an accepted elicitation's content is checked against the schema it asked with" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try newServer(testing.io);
    defer s.deinit();
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.deinit();
    const first = try ask(&s, a, &r, "tools/call", "{\"name\":\"greet\"," ++ meta ++ "}");
    const Answer = struct { result: struct { requestState: []const u8 } };
    const sealed = (try strand.json.parseLeaky(Answer, a, first, .{ .ignore_unknown_fields = true })).result.requestState;
    // `name` is required and a string: content without it, or with a
    // number, is not the answer to what was asked.
    for ([_][]const u8{ "{}", "{\"name\":5}" }) |content| {
        const retry = try a.print("{{\"name\":\"greet\",\"inputResponses\":{{\"name\":{{\"action\":\"accept\",\"content\":{s}}}}},\"requestState\":\"{s}\",{s}}}", .{ content, sealed, meta });
        try expectContains(try ask(&s, a, &r, "tools/call", retry), "\"error\":{\"code\":-32602,\"message\":\"an input response is not the answer to what was asked\"}");
    }
    // What it asked for, accepted.
    const retry = try a.print("{{\"name\":\"greet\",\"inputResponses\":{{\"name\":{{\"action\":\"accept\",\"content\":{{\"name\":\"ada\"}}}}}},\"requestState\":\"{s}\",{s}}}", .{ sealed, meta });
    try expectContains(try ask(&s, a, &r, "tools/call", retry), "\"text\":\"hello ada\"");
}

/// A dynamic tool whose calls take simulated time, and which records any of
/// them still running once a remove of it has returned.
const Slow = struct {
    handler: parley.registry.ToolHandler = .{ .callFn = call },
    server: *Server = undefined,
    running: std.atomic.Value(u32) = .init(0),
    removed: std.atomic.Value(bool) = .init(false),
    /// A call that ran on after its tool's remove returned.
    outlived: std.atomic.Value(bool) = .init(false),
    /// The tool each call removes from inside it, as the call asking, and
    /// what the last such remove was answered.
    removes: ?[]const u8 = null,
    removal: ?parley.Server.RemoveError!bool = null,
    /// Held shut, calls wait until it opens.
    gate: std.atomic.Value(bool) = .init(true),

    fn call(h: *parley.registry.ToolHandler, c: *Call, _: ?[]const u8) Call.Error!parley.registry.ToolResult {
        const slow: *Slow = @alignCast(@fieldParentPtr("handler", h));
        _ = slow.running.fetchAdd(1, .acq_rel);
        defer _ = slow.running.fetchSub(1, .acq_rel);
        while (!slow.gate.load(.acquire)) try c.io.sleep(.fromMilliseconds(1), .awake);
        try c.io.sleep(.fromMilliseconds(1), .awake);
        // After a pause, so that calls started together are all inside their handlers.
        if (slow.removes) |name| slow.removal = slow.server.removeTool(c.io, name, c);
        if (slow.removed.load(.acquire)) slow.outlived.store(true, .release);
        return .ofText("done");
    }
};

fn callSlow(s: *Server, io: std.Io) void {
    callNamed(s, io, "slow");
}

fn callNamed(s: *Server, io: std.Io, name: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const params = arena.allocator().print("{{\"name\":\"{s}\",{s}}}", .{ name, meta }) catch @panic("out of memory");
    const request: parley.wire.Request = .{ .id = .{ .integer = 1 }, .method = "tools/call", .params = params };
    // Its answer is not what is tested: what runs while it is asked is.
    _ = s.serve(io, arena.allocator(), request, null, .none) catch return;
}

fn removeSlow(s: *Server, io: std.Io, slow: *Slow, delay: u8) parley.Server.RemoveError!void {
    io.sleep(.fromMilliseconds(delay), .awake) catch return error.Canceled;
    const removed = try s.removeTool(io, "slow", null);
    slow.removed.store(removed, .release);
    // Returned: no call runs the handler now.
    if (removed and slow.running.load(.acquire) != 0) slow.outlived.store(true, .release);
}

/// A server at `s`, where it stays: the tool's handler holds its address.
fn slowServer(s: *Server, io: std.Io, slow: *Slow) !void {
    s.* = try Server.init(testing.allocator, io, .{ .info = .{ .name = "test", .version = "1.0.0" }, .validator = &validation.json_schema });
    errdefer s.deinit();
    try addSlow(s, io, "slow", slow);
}

fn addSlow(s: *Server, io: std.Io, name: []const u8, slow: *Slow) !void {
    slow.server = s;
    try s.addDynamicTool(io, .{ .name = name, .input_schema = "{\"type\":\"object\"}" }, &slow.handler);
}

fn finished(outcome: shakedown.Sim.Outcome) !void {
    if (outcome == .failed) return outcome.failed;
    errdefer switch (outcome) {
        .deadlock => |tasks| for (tasks) |t| std.debug.print("waiting: {any}\n", .{t}),
        else => std.debug.print("the simulation ended {t}\n", .{outcome}),
    };
    try testing.expect(outcome == .finished);
}

test "a removed tool is freed only after every call that found it ends, and its remove returns only then: raced in the simulation" {
    const Race = struct {
        fn run(io: std.Io, seed: u64) !void {
            var slow: Slow = .{};
            var s: Server = undefined;
            try slowServer(&s, io, &slow);
            defer s.deinit();
            var group: std.Io.Group = .init;
            for (0..4) |_| group.async(io, callSlow, .{ &s, io });
            const removal = io.async(removeSlow, .{ &s, io, &slow, @as(u8, @truncate(seed % 4)) });
            var r = removal;
            try r.await(io);
            try group.await(io);
            try testing.expect(slow.removed.load(.acquire));
            try testing.expect(!slow.outlived.load(.acquire));
        }
    };
    for (0..64) |seed| {
        const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .seed = seed });
        defer sim.deinit();
        errdefer std.debug.print("seed {d}\n", .{seed});
        try finished(sim.run(Race.run, .{ sim.io(), seed }));
    }
}

test "a call removes its own tool without waiting on itself, and the tool is freed when the call ends" {
    const Own = struct {
        fn run(io: std.Io) !void {
            var slow: Slow = .{ .removes = "slow" };
            var s: Server = undefined;
            try slowServer(&s, io, &slow);
            defer s.deinit();
            callSlow(&s, io);
            try testing.expect(try slow.removal.?);
            // Unlinked at once, freed as the call ended: the allocator's leak check holds it to that.
            try testing.expect(!try s.removeTool(io, "slow", null));
        }
    };
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try finished(sim.run(Own.run, .{sim.io()}));
}

test "two calls removing each other's tools never wait in a cycle: raced in the simulation" {
    const Cycle = struct {
        fn run(io: std.Io) !void {
            var a: Slow = .{ .removes = "b" };
            var b: Slow = .{ .removes = "a" };
            var s = try Server.init(testing.allocator, io, .{ .info = .{ .name = "test", .version = "1.0.0" }, .validator = &validation.json_schema });
            defer s.deinit();
            try addSlow(&s, io, "a", &a);
            try addSlow(&s, io, "b", &b);
            var group: std.Io.Group = .init;
            // Concurrent, so that both are inside their handlers when each removes the other's tool.
            try group.concurrent(io, callNamed, .{ &s, io, "a" });
            try group.concurrent(io, callNamed, .{ &s, io, "b" });
            try group.await(io);
            // Neither waited: both calls ended, each having removed the other's tool.
            try testing.expect(try a.removal.?);
            try testing.expect(try b.removal.?);
            _ = try s.removeTool(io, "a", null);
            _ = try s.removeTool(io, "b", null);
        }
    };
    for (0..64) |seed| {
        const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .seed = seed });
        defer sim.deinit();
        errdefer std.debug.print("seed {d}\n", .{seed});
        try finished(sim.run(Cycle.run, .{sim.io()}));
    }
}

test "a canceled remove returns Canceled with the tool unlinked, and the last call to end frees it" {
    const Canceled = struct {
        fn run(io: std.Io) !void {
            var slow: Slow = .{ .gate = .init(false) };
            var s: Server = undefined;
            try slowServer(&s, io, &slow);
            defer s.deinit();
            // Concurrent, not async: the simulation may run an async call at once, on this task.
            var call = try io.concurrent(callSlow, .{ &s, io });
            while (slow.running.load(.acquire) == 0) try io.sleep(.fromMilliseconds(1), .awake);
            var removal = try io.concurrent(removeSlow, .{ &s, io, &slow, @as(u8, 0) });
            try io.sleep(.fromMilliseconds(5), .awake);
            try testing.expectError(error.Canceled, removal.cancel(io));
            // Unlinked: no new call finds it, and no remove does.
            try testing.expect(!try s.removeTool(io, "slow", null));
            try testing.expectEqual(@as(u32, 1), slow.running.load(.acquire));
            slow.gate.store(true, .release);
            call.await(io);
            // The call's end freed the entry; the allocator's leak check holds it to that.
        }
    };
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try finished(sim.run(Canceled.run, .{sim.io()}));
}
