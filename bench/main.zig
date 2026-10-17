//! parley's benchmarks. `bay bench` runs them in ReleaseFast and writes one
//! JSON line per row to stdout; `bay test` runs each row once with
//! `--smoke`. Timings are taken by hand, never in CI. `zig-out/bench/
//! parley-bench <row prefix>` runs the rows whose name starts with the prefix.
const std = @import("std");
const parley = @import("parley");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const WorkloadError = error{ OutOfMemory, Malformed, Invalid, WriteFailed, Canceled, Duplicate, InvalidSchema, EntropyUnavailable, Unanswered };
const Row = shakedown.bench.Row(Bench, WorkloadError);

/// What Claude Code sends to call a tool, `_meta` and all.
const call =
    \\{"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.302","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01TPoWJP87tokEt7hQxSLL7f","progressToken":1}},"jsonrpc":"2.0","id":1}
;

/// A tool whose schema is large: twenty described fields.
const Wide = struct {
    f0: []const u8,
    f1: i64,
    f2: bool,
    f3: ?f64 = null,
    f4: []const []const u8 = &.{},
    f5: []const u8,
    f6: i64,
    f7: bool,
    f8: ?f64 = null,
    f9: []const []const u8 = &.{},
    f10: []const u8,
    f11: i64,
    f12: bool,
    f13: ?f64 = null,
    f14: []const []const u8 = &.{},
    f15: []const u8,
    f16: i64,
    f17: bool,
    f18: ?f64 = null,
    f19: []const []const u8 = &.{},
};

fn wide(_: *parley.Call, _: Wide) error{}![]const u8 {
    return "ok";
}

fn echo(_: *parley.Call, args: struct { text: []const u8 }) error{}![]const u8 {
    return args.text;
}

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

const Bench = struct {
    gpa: std.mem.Allocator,
    io: std.Io = undefined,
    server: parley.Server = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    out: [256]u8 = undefined,
    sink: usize = 0,

    fn setup(b: *Bench) WorkloadError!void {
        b.arena = .init(b.gpa);
    }

    fn teardown(b: *Bench) WorkloadError!void {
        b.arena.deinit();
    }

    fn serverSetup(b: *Bench) WorkloadError!void {
        b.arena = .init(b.gpa);
        b.server = try parley.Server.init(b.gpa, b.io, .{ .info = .{ .name = "bench", .version = "0" } });
        var name_buffer: [16]u8 = undefined;
        for (0..100) |i| {
            const name = std.mem.print(&name_buffer, "wide_{d}", .{i}) catch unreachable; // unreachable: the name fits
            try b.server.addTool(b.io, .{ .name = name, .description = "A tool with twenty arguments" }, wide);
        }
        try b.server.addTool(b.io, .{ .name = "echo" }, echo);
    }

    fn serverTeardown(b: *Bench) WorkloadError!void {
        b.server.deinit();
        b.arena.deinit();
    }

    fn ask(b: *Bench, method: []const u8, params: []const u8) WorkloadError!void {
        const request: parley.wire.Request = .{ .id = .{ .integer = 1 }, .method = method, .params = params };
        const reply = try b.server.serve(b.io, b.arena.allocator(), request, null, .none);
        switch (reply) {
            .result => |r| b.sink +%= r.len,
            else => return error.Unanswered,
        }
        _ = b.arena.reset(.retain_capacity);
    }

    fn listTools(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| try b.ask("tools/list", "{" ++ meta ++ "}");
    }

    fn callEcho(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| try b.ask("tools/call", "{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}," ++ meta ++ "}");
    }

    fn decodeCall(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            const message = try parley.wire.decode(b.arena.allocator(), call, .{});
            b.sink +%= message.request.method.len;
        }
    }

    fn writeResult(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var w: std.Io.Writer = .fixed(&b.out);
            try parley.wire.writeResult(&w, .{ .integer = 1 }, "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}");
            b.sink +%= w.end;
        }
    }
};

const rows = [_]Row{
    .{ .name = "wire/decode-call", .unit = "message", .run = Bench.decodeCall, .fixture = .{ .lifetime = .row, .setup = Bench.setup, .teardown = Bench.teardown } },
    .{ .name = "wire/write-result", .unit = "message", .run = Bench.writeResult },
    .{ .name = "server/tools-list-100-wide", .unit = "request", .run = Bench.listTools, .fixture = .{ .lifetime = .row, .setup = Bench.serverSetup, .teardown = Bench.serverTeardown } },
    .{ .name = "server/call-echo", .unit = "request", .run = Bench.callEcho, .fixture = .{ .lifetime = .row, .setup = Bench.serverSetup, .teardown = Bench.serverTeardown } },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try shakedown.bench.Options.fromArguments(args[1..]);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var b: Bench = .{ .gpa = init.gpa, .io = init.io };
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &b, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(b.sink);
}
