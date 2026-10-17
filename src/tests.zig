//! Every test of parley, reached from here.
test {
    _ = @import("wire_test.zig");
    _ = @import("server_test.zig");
    _ = @import("stdio_test.zig");
    _ = @import("compat_test.zig");
    _ = @import("client_test.zig");
    _ = @import("property_test.zig");
    _ = @import("tasks.zig");
    _ = @import("tasks_test.zig");
}
