//! parley's benchmarks. `bay bench` runs them in ReleaseFast and writes one
//! JSON line per row to stdout; `bay test` runs each row once with
//! `--smoke`. Timings are taken by hand, never in CI. `zig-out/bench/
//! parley-bench <row prefix>` runs the rows whose name starts with the prefix.
const std = @import("std");
const parley = @import("parley");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const WorkloadError = error{ OutOfMemory, Malformed, Invalid, WriteFailed };
const Row = shakedown.bench.Row(Bench, WorkloadError);

/// What Claude Code sends to call a tool, `_meta` and all.
const call =
    \\{"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.302","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01TPoWJP87tokEt7hQxSLL7f","progressToken":1}},"jsonrpc":"2.0","id":1}
;

const Bench = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator = undefined,
    out: [256]u8 = undefined,
    sink: usize = 0,

    fn setup(b: *Bench) WorkloadError!void {
        b.arena = .init(b.gpa);
    }

    fn teardown(b: *Bench) WorkloadError!void {
        b.arena.deinit();
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
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try shakedown.bench.Options.fromArguments(args[1..]);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var b: Bench = .{ .gpa = init.gpa };
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &b, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(b.sink);
}
