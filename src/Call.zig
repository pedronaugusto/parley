//! One request, as the handler of a tool, a prompt or a resource sees it:
//! who asked and what they can do, an arena that lives until the answer is
//! written, the request's progress and log lines, and the input it may ask
//! the client for across rounds (multi round-trip requests).
//!
//! Asking for input: `elicit`, `sample` and `roots` return the client's
//! answer when the retry carried it, and otherwise record the request and
//! return null; the handler then returns `error.InputRequired`, and the
//! client is asked for everything recorded at once:
//!
//! ```
//! const login = (try call.elicit("login", form)) orelse return error.InputRequired;
//! ```
//!
//! `state` and `setState` keep a handler's own bytes across the rounds,
//! sealed by the server so the client can neither read nor change them.
const Call = @This();

const std = @import("std");
const strand = @import("strand");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Context = @import("context.zig").Context;
const Sink = @import("context.zig").Sink;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Raw = strand.json.Raw;

io: Io,
/// Freed when the answer is written: everything a handler returns may live here.
arena: Allocator,
context: *const Context,
/// The request's id.
id: wire.Id,
/// Private: where the request's notifications go.
sink: Sink,
/// Private: the `inputResponses` object of the retry, if it carried one.
responses: ?[]const u8 = null,
/// Private: the handler's state from the round before, opened.
state_in: ?[]const u8 = null,
/// Private: input asked for in this round.
pending: std.ArrayList(Pending) = .empty,
/// Private: the handler's state for the next round.
state_out: ?[]const u8 = null,
/// Private: the capability an input request needed and the client lacked.
missing: ?types.InputKind = null,
/// Private: the last progress sent, which every next one must pass.
progress_sent: ?f64 = null,
/// Private: how the call becomes a task, when it may.
task: ?TaskHook = null,

/// How a call becomes a task: given by the server for a call that may.
pub const TaskHook = struct {
    context: *anyopaque,
    become: *const fn (context: *anyopaque) Error!bool,
};

/// What a handler fails with, beside its own errors.
pub const Error = error{
    /// The request was canceled: return it, and nothing is answered.
    Canceled,
    OutOfMemory,
    /// Input was recorded (or state set) and the client must retry with it.
    InputRequired,
    /// Input was asked of a client that did not declare it can give it.
    MissingCapability,
    /// The retry's answer to an input request is not what was asked for.
    InvalidInput,
    /// What the request names does not exist (a resource's URI).
    NotFound,
    /// A prompt's or a resource's handler failed with an error of its own,
    /// answered as an internal error that does not name it.
    HandlerFailed,
};

/// One input request recorded in this round.
pub const Pending = struct {
    key: []const u8,
    request: types.InputRequest,
};

/// The answer the retry carried for `key`, as its bytes, or null after
/// recording `request` to be asked. Asking a client for what it did not
/// declare is `error.MissingCapability`, answered `-32021` naming it.
pub fn input(call: *Call, key: []const u8, request: types.InputRequest) Error!?Raw {
    if (!call.context.client.accepts(request.kind())) {
        call.missing = request.kind();
        return error.MissingCapability;
    }
    if (call.responses) |object| if (try member(object, key)) |value| return .{ .bytes = value };
    for (call.pending.items) |p| if (std.mem.eql(u8, p.key, key)) return error.InvalidInput;
    try call.pending.append(call.arena, .{ .key = key, .request = request });
    return null;
}

/// Asks the user, through the client, to fill a form or open a URL.
pub fn elicit(call: *Call, key: []const u8, request: types.Elicit) Error!?types.ElicitResult {
    const raw = try call.input(key, .{ .elicit = request }) orelse return null;
    return try parseAnswer(types.ElicitResult, call.arena, raw);
}

/// Asks the client's model for a completion.
pub fn sample(call: *Call, key: []const u8, request: types.CreateMessageParams) Error!?types.CreateMessageResult {
    const raw = try call.input(key, .{ .sample = request }) orelse return null;
    return try parseAnswer(types.CreateMessageResult, call.arena, raw);
}

/// Asks the client for its roots.
pub fn roots(call: *Call, key: []const u8) Error!?types.ListRootsResult {
    const raw = try call.input(key, .roots) orelse return null;
    return try parseAnswer(types.ListRootsResult, call.arena, raw);
}

/// Answers the request with a task (the tasks extension) and goes on as
/// it: the client polls for the outcome. True once the call runs as a task;
/// false when it may not (the tool forbids it, the client did not declare
/// the extension, the server holds as many tasks as it takes or has no task
/// to run it on), and the call goes on to be answered as it was asked.
///
/// From here the request's progress and log lines go nowhere, and input
/// asked for (`error.InputRequired`) is the task's: the client gives it
/// with `tasks/update`, and the handler runs again with it, as a retry
/// would. Input gathered before is the request's own rounds.
pub fn runAsTask(call: *Call) Error!bool {
    const hook = call.task orelse return false;
    return hook.become(hook.context);
}

/// The bytes the handler kept in the round before, or null in the first.
pub fn state(call: *const Call) ?[]const u8 {
    return call.state_in;
}

/// Keeps `bytes` for the next round, sealed: returning `error.InputRequired`
/// after it asks the client to retry with them, input or not.
pub fn setState(call: *Call, bytes: []const u8) Error!void {
    call.state_out = try call.arena.dupe(u8, bytes);
}

/// Reports progress, when the client asked for it with a progress token:
/// `done` must pass what was reported before (a report that does not is
/// left out).
pub fn progress(call: *Call, done: f64, total: ?f64, message: ?[]const u8) Error!void {
    const token = call.context.progress_token orelse return;
    if (call.progress_sent) |last| if (done <= last) return;
    call.progress_sent = done;
    var out: std.Io.Writer.Allocating = .init(call.arena);
    const Params = struct { progressToken: types.Token, progress: f64, total: ?f64, message: ?[]const u8 };
    writeNotification(&out.writer, "notifications/progress", Params{ .progressToken = token, .progress = done, .total = total, .message = message }) catch return error.OutOfMemory;
    call.sink.send(call.io, out.written()) catch |err| return sent(err);
}

/// A log line about this request, sent when the client asked for lines at
/// `level` or below: `data` is any value strand writes.
pub fn log(call: *Call, level: types.LoggingLevel, logger: ?[]const u8, data: anytype) Error!void {
    const minimum = call.context.log_level orelse return;
    if (!level.reaches(minimum)) return;
    var out: std.Io.Writer.Allocating = .init(call.arena);
    const Params = struct { level: types.LoggingLevel, logger: ?[]const u8, data: @TypeOf(data) };
    writeNotification(&out.writer, "notifications/message", Params{ .level = level, .logger = logger, .data = data }) catch return error.OutOfMemory;
    call.sink.send(call.io, out.written()) catch |err| return sent(err);
}

/// A notification that could not be sent: the stream is gone, so the request
/// is as good as canceled.
fn sent(err: Sink.SendError) Error {
    return switch (err) {
        error.Canceled, error.Closed => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeNotification(w: *std.Io.Writer, method: []const u8, params: anytype) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try wire.writeString(w, method);
    try w.writeAll(",\"params\":");
    try strand.json.write(w, params, types.write_options);
    try w.writeByte('}');
}

fn member(object: []const u8, key: []const u8) Error!?[]const u8 {
    var members: strand.json.Members = undefined;
    members.init(object, .{});
    while (members.next() catch return error.InvalidInput) |m| if (m.is(key)) return m.value;
    return null;
}

fn parseAnswer(comptime T: type, arena: Allocator, raw: Raw) Error!T {
    return strand.json.parseLeaky(T, arena, raw.bytes, types.read_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
}
