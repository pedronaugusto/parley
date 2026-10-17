//! The tasks extension in process: a call that runs as a task, polled to
//! its end; input given to a task, all at once or a key at a time; a task
//! cancelled while it runs; failures and tool errors; and what a client
//! that did not declare the extension gets.
const std = @import("std");
const strand = @import("strand");
const parley = @import("parley.zig");

const testing = std.testing;
const Server = parley.Server;
const Call = parley.Call;
const Io = std.Io;

const with_tasks =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}},"extensions":{"io.modelcontextprotocol/tasks":{}}}}
;
const without_tasks =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}}}
;

/// Runs as a task, then waits `seconds` (cancelable) and answers.
fn slow(call: *Call, args: struct { seconds: f64 = 0 }) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    const ns: i96 = @intFromFloat(args.seconds * std.time.ns_per_s); // safe: the tests give small, finite spans
    call.io.sleep(.fromNanoseconds(ns), .awake) catch return error.Canceled;
    return .ofText("slept");
}

/// Runs as a task and asks for a confirmation.
fn confirm(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    const answer = try call.elicit("confirm", .{ .form = .{
        .message = "Delete it?",
        .requested_schema = .{ .bytes = "{\"type\":\"object\",\"properties\":{\"confirm\":{\"type\":\"boolean\"}}}" },
    } }) orelse return error.InputRequired;
    return .ofText(try call.arena.print("confirmed {s}", .{answer.content.?.bytes}));
}

/// Runs as a task and asks for two values at once.
fn two(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    const form: parley.types.Elicit = .{ .form = .{ .message = "A value", .requested_schema = .{ .bytes = "{\"type\":\"object\"}" } } };
    const a = try call.elicit("a", form);
    const b = try call.elicit("b", form);
    if (a == null or b == null) return error.InputRequired;
    return .ofText("both");
}

/// Asks for a name in the call's own rounds, then runs as a task.
fn nameThenTask(call: *Call) Call.Error!parley.ToolResult {
    const answer = try call.elicit("name", .{ .form = .{ .message = "Name?", .requested_schema = .{ .bytes = "{\"type\":\"object\"}" } } }) orelse return error.InputRequired;
    _ = try call.runAsTask();
    return .ofText(try call.arena.print("hello {s}", .{answer.content.?.bytes}));
}

fn toolError(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    return .failure("the job failed");
}

fn protocolError(call: *Call) Call.Error!parley.ToolResult {
    _ = try call.runAsTask();
    return error.HandlerFailed;
}

fn newServer(io: Io) !Server {
    var s = try Server.init(testing.allocator, io, .{ .info = .{ .name = "tasks", .version = "1" }, .tasks = .{ .poll_interval = .literal("10ms") } });
    errdefer s.deinit();
    try s.addTool(io, .{ .name = "slow", .task = .optional }, slow);
    try s.addTool(io, .{ .name = "confirm", .task = .required }, confirm);
    try s.addTool(io, .{ .name = "two", .task = .required }, two);
    try s.addTool(io, .{ .name = "name_then_task", .task = .required }, nameThenTask);
    try s.addTool(io, .{ .name = "tool_error", .task = .optional }, toolError);
    try s.addTool(io, .{ .name = "protocol_error", .task = .optional }, protocolError);
    return s;
}

/// The result of `method` with `params` (members, `_meta` added), or the
/// error's code as `error:<code>`.
fn ask(s: *Server, arena: std.mem.Allocator, method: []const u8, params: []const u8, declared: bool) ![]const u8 {
    const m = if (declared) with_tasks else without_tasks;
    const sep: []const u8 = if (params.len == 0) "" else ",";
    const message = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{{{s}{s}{s}}}}}", .{ method, params, sep, m });
    const request = (try parley.wire.decode(arena, message, .{ .limits = parley.wire.limitsFor(parley.wire.default_message) })).request;
    const reply = try s.serve(testing.io, arena, request, null, .none);
    return switch (reply) {
        .result => |r| try r.whole(arena),
        .input_required => |ir| try s.inputRequiredJson(arena, ir),
        .failure => |f| try arena.print("error:{d}", .{@backingInt(f.code)}),
    };
}

fn field(arena: std.mem.Allocator, json: []const u8, name: []const u8) ![]const u8 {
    var members: strand.json.Members = undefined;
    members.init(json, .{});
    while (try members.next()) |m| if (m.is(name)) {
        if (m.value[0] == '"') return try strand.json.parseLeaky([]const u8, arena, m.value, .{});
        return m.value;
    };
    return error.NoSuchField;
}

/// Polls the task until its status is `want` or an end.
fn poll(s: *Server, arena: std.mem.Allocator, id: []const u8, want: []const u8) ![]const u8 {
    const params = try arena.print("\"taskId\":\"{s}\"", .{id});
    for (0..500) |_| {
        const got = try ask(s, arena, "tasks/get", params, true);
        const status = try field(arena, got, "status");
        if (std.mem.eql(u8, status, want) or std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) return got;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.NeverGotThere;
}

test "a call runs as a task the client polls to its result" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const created = try ask(&s, a, "tools/call", "\"name\":\"slow\",\"arguments\":{\"seconds\":0.05}", true);
    try testing.expectEqualStrings("task", try field(a, created, "resultType"));
    const id = try field(a, created, "taskId");
    try testing.expectEqual(32, id.len);
    _ = try field(a, created, "createdAt");
    try testing.expectEqualStrings("10", try field(a, created, "pollIntervalMs"));
    const done = try poll(&s, a, id, "completed");
    try testing.expectEqualStrings("complete", try field(a, done, "resultType"));
    try testing.expectEqualStrings("completed", try field(a, done, "status"));
    const result = try field(a, done, "result");
    try testing.expect(std.mem.find(u8, result, "\"text\":\"slept\"") != null);
    try testing.expect(std.mem.find(u8, result, "_meta") == null);
}

test "a client that did not declare the extension: answered as asked, or -32021" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sync = try ask(&s, a, "tools/call", "\"name\":\"slow\",\"arguments\":{}", false);
    try testing.expectEqualStrings("complete", try field(a, sync, "resultType"));
    try testing.expectEqualStrings("error:-32021", try ask(&s, a, "tools/call", "\"name\":\"confirm\",\"arguments\":{}", false));
    try testing.expectEqualStrings("error:-32021", try ask(&s, a, "tasks/get", "\"taskId\":\"x\"", false));
    try testing.expectEqualStrings("error:-32602", try ask(&s, a, "tasks/get", "\"taskId\":\"nonexistent\"", true));
    try testing.expectEqualStrings("error:-32602", try ask(&s, a, "tasks/cancel", "\"taskId\":\"nonexistent\"", true));
    try testing.expectEqualStrings("error:-32601", try ask(&s, a, "tasks/list", "", true));
    const discovered = try ask(&s, a, "server/discover", "", true);
    try testing.expect(std.mem.find(u8, discovered, "\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}") != null);
}

test "input given to a task: asked, answered, finished" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try field(a, try ask(&s, a, "tools/call", "\"name\":\"confirm\",\"arguments\":{}", true), "taskId");
    const waiting = try poll(&s, a, id, "input_required");
    try testing.expectEqualStrings("input_required", try field(a, waiting, "status"));
    const requests = try field(a, waiting, "inputRequests");
    try testing.expect(std.mem.find(u8, requests, "\"confirm\":{\"method\":\"elicitation/create\"") != null);
    const ack = try ask(&s, a, "tasks/update", try a.print("\"taskId\":\"{s}\",\"inputResponses\":{{\"confirm\":{{\"action\":\"accept\",\"content\":{{\"confirm\":true}}}}}}", .{id}), true);
    try testing.expectEqualStrings("complete", try field(a, ack, "resultType"));
    const done = try poll(&s, a, id, "completed");
    try testing.expect(std.mem.find(u8, try field(a, done, "result"), "confirmed {\\\"confirm\\\":true}") != null);
}

test "two inputs answered one at a time: the task waits for the rest" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try field(a, try ask(&s, a, "tools/call", "\"name\":\"two\",\"arguments\":{}", true), "taskId");
    _ = try poll(&s, a, id, "input_required");
    _ = try ask(&s, a, "tasks/update", try a.print("\"taskId\":\"{s}\",\"inputResponses\":{{\"a\":{{\"action\":\"accept\",\"content\":{{}}}},\"never\":{{}}}}", .{id}), true);
    const still = try ask(&s, a, "tasks/get", try a.print("\"taskId\":\"{s}\"", .{id}), true);
    try testing.expectEqualStrings("input_required", try field(a, still, "status"));
    const requests = try field(a, still, "inputRequests");
    try testing.expect(std.mem.find(u8, requests, "\"a\":") == null);
    try testing.expect(std.mem.find(u8, requests, "\"b\":") != null);
    _ = try ask(&s, a, "tasks/update", try a.print("\"taskId\":\"{s}\",\"inputResponses\":{{\"b\":{{\"action\":\"accept\",\"content\":{{}}}}}}", .{id}), true);
    const done = try poll(&s, a, id, "completed");
    try testing.expectEqualStrings("completed", try field(a, done, "status"));
}

test "a task cancelled while it runs ends cancelled; cancelling an ended one is acknowledged" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try field(a, try ask(&s, a, "tools/call", "\"name\":\"slow\",\"arguments\":{\"seconds\":30}", true), "taskId");
    const params = try a.print("\"taskId\":\"{s}\"", .{id});
    const ack = try ask(&s, a, "tasks/cancel", params, true);
    try testing.expectEqualStrings("complete", try field(a, ack, "resultType"));
    const done = try poll(&s, a, id, "cancelled");
    try testing.expectEqualStrings("cancelled", try field(a, done, "status"));
    try testing.expectEqualStrings("complete", try field(a, try ask(&s, a, "tasks/cancel", params, true), "resultType"));
}

test "a tool's error completes the task; a protocol error fails it" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool = try poll(&s, a, try field(a, try ask(&s, a, "tools/call", "\"name\":\"tool_error\",\"arguments\":{}", true), "taskId"), "completed");
    try testing.expectEqualStrings("completed", try field(a, tool, "status"));
    try testing.expectEqualStrings("true", try field(a, try field(a, tool, "result"), "isError"));
    const protocol = try poll(&s, a, try field(a, try ask(&s, a, "tools/call", "\"name\":\"protocol_error\",\"arguments\":{}", true), "taskId"), "failed");
    try testing.expectEqualStrings("failed", try field(a, protocol, "status"));
    try testing.expectEqualStrings("-32603", try field(a, try field(a, protocol, "error"), "code"));
    try testing.expect(std.mem.find(u8, protocol, "\"result\"") == null);
}

test "input asked before the task is the call's own round; the task comes after" {
    var s = try newServer(testing.io);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try ask(&s, a, "tools/call", "\"name\":\"name_then_task\",\"arguments\":{}", true);
    try testing.expectEqualStrings("input_required", try field(a, first, "resultType"));
    const second = try ask(&s, a, "tools/call", "\"name\":\"name_then_task\",\"arguments\":{},\"inputResponses\":{\"name\":{\"action\":\"accept\",\"content\":{\"n\":\"ada\"}}}", true);
    try testing.expectEqualStrings("task", try field(a, second, "resultType"));
    const done = try poll(&s, a, try field(a, second, "taskId"), "completed");
    try testing.expect(std.mem.find(u8, try field(a, done, "result"), "hello {\\\"n\\\":\\\"ada\\\"}") != null);
}

test "a tool that may run as a task needs a server that serves tasks" {
    var s = try Server.init(testing.allocator, testing.io, .{ .info = .{ .name = "plain", .version = "1" } });
    defer s.deinit();
    try testing.expectError(error.TasksNotServed, s.addTool(testing.io, .{ .name = "slow", .task = .optional }, slow));
}
