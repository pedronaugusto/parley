# parley

parley is the Model Context Protocol (MCP) for Zig: servers and clients, a
stateless core on the 2026-07-28 revision with the 2025-11-25 handshake served
above it, over stdio and Streamable HTTP. It is for any Zig program that gives
tools, resources and prompts to a model, or uses them.

Work in progress toward the public cut: the JSON-RPC layer is built; the
server, the transports and the client are not yet.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/parley`, then take the `parley` module
through `b.dependency` and add it to your executable's imports. At run time
parley depends on std, on strand (JSON) and on aegis, a std-only library of
checked types.

## Usage

`wire` reads a JSON-RPC message off its bytes and tells it apart without
reading what it carries, and writes one around bytes its caller produces:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const parley = @import("parley");

fn envelope(arena: std.mem.Allocator) !void {
    // A message as a peer sent it, told apart without reading what it carries.
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}";
    var fault: parley.wire.Fault = .{};
    const message = parley.wire.decode(arena, line, .{ .fault = &fault }) catch {
        // Refused: answer with the code and the id the fault names.
        var buffer: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try parley.wire.writeFailure(&w, fault.id, fault.code, fault.reason, null);
        return;
    };
    const request = message.request;
    std.debug.assert(std.mem.eql(u8, request.method, "tools/call"));

    // The answer, around a result its caller writes.
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try parley.wire.writeResult(&w, request.id, "{\"resultType\":\"complete\",\"content\":[]}");
}
```
<!-- END GENERATED -->

## Design

**JSON-RPC.** `wire.decode` reads only the envelope (`jsonrpc`, `id`,
`method`, `params`, `result`, `error`) with strand's member reader, so a
message's params and result stay the bytes they were written as for the layer
that knows their shape, and nothing is allocated for a message without
escapes. An id is a string or an integer, never null; a refusal says which
code answers it (`-32700` for bytes that are not JSON, `-32600` for JSON that
is not a message: a batch, a scalar, a member given twice, a missing or wrong
`jsonrpc`) and the id when one could be read, so the answer names the request
it refuses. A string written is JSON whatever its bytes: controls are escaped
and broken UTF-8 is written as U+FFFD.

## Scope

MCP as the specification has it, both revisions in use: 2026-07-28 and
2025-11-25 with 2025-06-18. JSON-RPC batches are not read: MCP removed them
in 2025-06-18.

## Built with

- [strand](https://github.com/pedronaugusto/strand): JSON.
- [aegis](https://github.com/pedronaugusto/aegis): checked types.
- [shakedown](https://github.com/pedronaugusto/shakedown) (tests only):
  properties, fuzzing and benchmarks.
- [preflight](https://github.com/pedronaugusto/preflight) (development only):
  the gate.

## Testing

`bay test` runs the suite, the example and each benchmark once; `bay
properties` the properties alone, which the fuzzer runs (`bay properties
--fuzz`). The suite reads what Claude Code 2.1.302 and Codex 0.160.0 send to
an MCP server, captured from both.

## Licence

MIT
