const std = @import("std");

/// What a project that depends on parley builds: `parley`, on std, aegis and
/// strand alone; with `http` (the default) `parley.http`, Streamable HTTP on
/// uplink, which is fetched only then: a project that serves over stdio
/// alone sets `.http = false` and fetches no uplink; with `process` (the
/// default) `parley.process`, a server launched as a child process, on
/// conduit, fetched only then; with `oauth` (the default, and `http`)
/// `parley.oauth`, MCP's authorization on clearance's OAuth 2.1, fetched only
/// then.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_http = b.option(bool, "http", "Build parley.http, Streamable HTTP on uplink, which fetches uplink") orelse true;
    const with_process = b.option(bool, "process", "Build parley.process, a server launched as a child process, which fetches conduit") orelse true;
    const with_oauth = b.option(bool, "oauth", "Build parley.oauth, MCP's authorization on OAuth 2.1, which fetches clearance") orelse true;
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const parley = b.addModule("parley", .{
        .root_source_file = b.path("src/parley.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "strand", .module = strand },
        },
    });
    if (with_process) {
        // Declared before conduit is fetched, as parley.http is below.
        const process = b.addModule("parley.process", .{
            .root_source_file = b.path("src/process.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aegis", .module = aegis },
                .{ .name = "parley", .module = parley },
            },
        });
        if (b.dependencyLazy("conduit", .{ .target = target, .optimize = optimize })) |conduit| process.addImport("conduit", conduit.module("conduit")) else |_| {}
    }
    if (!with_http) return;
    // Declared before uplink is fetched: a consumer's first pass must find
    // the module it asks for, and only learns here what to fetch.
    const http = b.addModule("parley.http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "strand", .module = strand },
            .{ .name = "parley", .module = parley },
        },
    });
    // Declared, as parley.http is, before what it needs is fetched.
    const oauth = if (with_oauth) b.addModule("parley.oauth", .{
        .root_source_file = b.path("src/oauth.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "parley", .module = parley },
            .{ .name = "parley.http", .module = http },
        },
    }) else null;
    if (b.dependencyLazy("uplink", .{ .target = target, .optimize = optimize })) |uplink| {
        http.addImport("uplink", uplink.module("uplink"));
        if (oauth) |o| o.addImport("uplink", uplink.module("uplink"));
    } else |_| {}
    const oauth_module = oauth orelse return;
    if (b.dependencyLazy("clearance", .{ .target = target, .optimize = optimize, .oauth = true })) |clearance| {
        oauth_module.addImport("clearance", clearance.module("clearance"));
        oauth_module.addImport("clearance.oauth", clearance.module("clearance.oauth"));
    } else |_| {}
}

/// parley's development: its tests, its properties, the example and the
/// benchmarks, under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("parley", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("parley");
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const strand = p.dependency("strand", .{ .target = target, .optimize = optimize });
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    const test_step = b.step("test", "Run the tests, the example and each benchmark once");
    const check = b.step("check", "Compile the tests, the example and the benchmarks without running them");

    // The suite alone, in the mode asked for: what ThreadSanitizer runs.
    // parley.http's tests are a binary of their own, rooted in that module.
    const tests = suite(b, "parley-tests", target, optimize, filters);
    const uplink_package = p.dependencyLazy("uplink", .{ .target = target, .optimize = optimize }) catch return;
    const http_tests = b.addTest(.{ .name = "parley-http-tests", .filters = filters, .root_module = package.module("parley.http") });
    const unit = b.step("unit", "Run the test suite alone");
    const tests_run = b.addRunArtifact(tests);
    const http_run = b.addRunArtifact(http_tests);
    http_run.step.dependOn(&tests_run.step);
    unit.dependOn(&tests_run.step);
    unit.dependOn(&http_run.step);
    test_step.dependOn(unit);
    check.dependOn(&tests.step);
    check.dependOn(&http_tests.step);

    // parley.oauth's tests: an authorization server, a guarded endpoint and
    // a client signing in, over loopback.
    const clearance_package = p.dependencyLazy("clearance", .{ .target = target, .optimize = optimize, .oauth = true }) catch return;
    const oauth_module = package.module("parley.oauth");
    // The tests sign tokens with a cloak key.
    if (oauth_module.import_table.get("cloak") == null) {
        oauth_module.addImport("cloak", clearance_package.builder.dependency("cloak", .{ .target = target, .optimize = optimize }).module("cloak"));
    }
    const oauth_tests = b.addTest(.{ .name = "parley-oauth-tests", .filters = filters, .root_module = oauth_module });
    const oauth_run = b.addRunArtifact(oauth_tests);
    oauth_run.step.dependOn(&http_run.step);
    unit.dependOn(&oauth_run.step);
    check.dependOn(&oauth_tests.step);

    // parley.process's tests launch a real server: the fixture, built here
    // and named to them by its path from the package root, which holds on a
    // runner replaying the tests. The benchmarks launch it too.
    _ = p.dependencyLazy("conduit", .{ .target = target, .optimize = optimize }) catch return;
    const fixture = fixtureServer(b, "parley-fixture-server", target, optimize) orelse return;
    const process_module = package.module("parley.process");
    const test_options = b.addOptions();
    tools.preflight.addTestProgram(b, test_options, "server", fixture);
    process_module.addOptions("test_options", test_options);
    const process_tests = b.addTest(.{ .name = "parley-process-tests", .filters = filters, .root_module = process_module });
    const process_run = b.addRunArtifact(process_tests);
    process_run.step.dependOn(&http_run.step);
    unit.dependOn(&process_run.step);
    check.dependOn(&process_tests.step);
    b.step("fixture-server", "Build the server the process tests and the benchmarks launch, into zig-out/bin").dependOn(&b.addInstallArtifact(fixture, .{}).step);

    // The properties alone, every test of the binary a property: what the
    // fuzzer runs over every parser of what a peer sends.
    const properties = suite(b, "parley-properties", target, optimize, &.{"property_test."});
    const http_module = package.module("parley.http");
    if (http_module.import_table.get("shakedown") == null) {
        http_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    }
    const http_properties = b.addTest(.{ .name = "parley-http-properties", .filters = &.{"property_test."}, .root_module = http_module });
    const properties_step = b.step("properties", "Run the properties alone");
    properties_step.dependOn(&b.addRunArtifact(properties).step);
    properties_step.dependOn(&b.addRunArtifact(http_properties).step);
    check.dependOn(&properties.step);
    check.dependOn(&http_properties.step);

    // examples/usage.zig is also README.md's Usage blocks (bay docs --
    // usage), so the code a reader copies is code the tests run.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parley", .module = module },
                .{ .name = "parley.http", .module = package.module("parley.http") },
                .{ .name = "parley.process", .module = package.module("parley.process") },
                .{ .name = "uplink", .module = uplink_package.module("uplink") },
            },
        }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(check);

    // A server over stdio for a client to launch: `bay stdio-server`.
    const stdio_server = b.addExecutable(.{
        .name = "stdio-server",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/stdio_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "parley", .module = module }},
        }),
    });
    b.step("stdio-server", "Build the example stdio server into zig-out/bin").dependOn(&b.addInstallArtifact(stdio_server, .{}).step);
    check.dependOn(&stdio_server.step);

    // The server the official conformance suite drives, by hand:
    // `bay conformance-server -- --port 3000`. CI compiles it.
    const conformance = b.addExecutable(.{
        .name = "conformance-server",
        .root_module = b.createModule(.{
            .root_source_file = p.path("conformance/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parley", .module = module },
                .{ .name = "parley.http", .module = package.module("parley.http") },
                .{ .name = "uplink", .module = uplink_package.module("uplink") },
                .{ .name = "strand", .module = strand.module("strand") },
            },
        }),
    });
    const conformance_run = b.addRunArtifact(conformance);
    conformance_run.addPassthruArgs();
    b.step("conformance-server", "Serve the conformance suite's scenarios: -- --port <port>").dependOn(&conformance_run.step);
    check.dependOn(&conformance.step);
    // The client the suite runs, installed for its --command:
    // `bay conformance-client` puts it in zig-out/bin.
    const conformance_client = b.addExecutable(.{
        .name = "conformance-client",
        .root_module = b.createModule(.{
            .root_source_file = p.path("conformance/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parley", .module = module },
                .{ .name = "parley.http", .module = package.module("parley.http") },
                .{ .name = "parley.oauth", .module = package.module("parley.oauth") },
                .{ .name = "uplink", .module = uplink_package.module("uplink") },
                .{ .name = "strand", .module = strand.module("strand") },
                .{ .name = "clearance", .module = clearance_package.module("clearance") },
                .{ .name = "cloak", .module = clearance_package.builder.dependency("cloak", .{ .target = target, .optimize = optimize }).module("cloak") },
            },
        }),
    });
    b.step("conformance-client", "Build the client the conformance suite runs, into zig-out/bin").dependOn(&b.addInstallArtifact(conformance_client, .{}).step);
    check.dependOn(&conformance_client.step);

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier fuzzes the properties and runs the suite under
        // ThreadSanitizer.
        .hardened = .{ .fuzz_step = "properties", .tsan_step = "unit" },
        // `bay bench` times them in ReleaseFast, by hand; never timed in CI,
        // where `bay test` runs each row once.
        .bench = .{
            .programs = &.{.{ .name = "parley-bench", .source = "bench/main.zig" }},
            .imports = BenchImports(tools).imports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on parley by path, with only the packages
    // parley needs: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "parley", .program = p.path("ci/consumer.zig"), .packages = &.{ aegis, strand, uplink_package, p.dependencyLazy("conduit", .{ .target = target, .optimize = optimize }) catch return, clearance_package }, .modules = &.{ "parley", "parley.http", "parley.process", "parley.oauth" } });
}

/// The tests run in the `parley` module itself, which gets shakedown for
/// them, so a test binary holds one parley.
fn suite(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, filters: []const []const u8) *std.Build.Step.Compile {
    const module = b.dependency("parley", .{ .target = target, .optimize = optimize }).module("parley");
    if (module.import_table.get("shakedown") == null) {
        module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    }
    return b.addTest(.{ .name = name, .filters = filters, .root_module = module });
}

/// The server the process tests and the benchmarks launch
/// (src/testing/server.zig), in the mode asked for: over stdio or HTTP, on
/// a reactor runtime. Null until uplink is fetched.
fn fixtureServer(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) ?*std.Build.Step.Compile {
    const package = b.dependency("parley", .{ .target = target, .optimize = optimize });
    const uplink = package.builder.dependencyLazy("uplink", .{ .target = target, .optimize = optimize }) catch return null;
    const reactor = uplink.builder.dependencyLazy("reactor", .{ .target = target, .optimize = optimize }) catch return null;
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = package.path("src/testing/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parley", .module = package.module("parley") },
                .{ .name = "parley.http", .module = package.module("parley.http") },
                .{ .name = "uplink", .module = uplink.module("uplink") },
                .{ .name = "reactor", .module = reactor.module("reactor") },
            },
        }),
    });
}

/// parley again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module. `b` is the development build; preflight adds shakedown.
/// With it what the process rows drive: conduit to launch a server and read
/// its memory, uplink's client for HTTP, and the fixture server built in the
/// same mode, named by `bench_options.server`.
fn BenchImports(comptime tools: type) type {
    return struct {
        fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
            const package = b.dependency("parley", .{ .target = target, .optimize = optimize });
            const p = package.builder;
            const conduit = p.dependency("conduit", .{ .target = target, .optimize = optimize });
            const uplink = p.dependency("uplink", .{ .target = target, .optimize = optimize });
            // Its own name: the tests' fixture is another build of it, in their mode.
            const fixture = fixtureServer(b, "parley-bench-fixture-server", target, optimize).?; // the configure pass reaching benchmarks has fetched uplink and reactor
            const options = b.addOptions();
            tools.preflight.addTestProgram(b, options, "server", fixture);
            return b.allocator.dupe(std.Build.Module.Import, &.{
                .{ .name = "parley", .module = package.module("parley") },
                .{ .name = "conduit", .module = conduit.module("conduit") },
                .{ .name = "uplink", .module = uplink.module("uplink") },
                .{ .name = "bench_options", .module = options.createModule() },
            }) catch @panic("OOM");
        }
    };
}
