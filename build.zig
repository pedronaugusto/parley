const std = @import("std");

/// What a project that depends on parley builds: the `parley` module, on std,
/// aegis and strand alone. The tests, example, benchmarks, conformance
/// programs and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize });
    _ = b.addModule("parley", .{
        .root_source_file = b.path("src/parley.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis.module("aegis") },
            .{ .name = "strand", .module = strand.module("strand") },
        },
    });
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
    const tests = suite(b, "parley-tests", target, optimize, filters);
    const unit = b.step("unit", "Run the test suite alone");
    unit.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(unit);
    check.dependOn(&tests.step);

    // The properties alone, every test of the binary a property: what the
    // fuzzer runs over every parser of what a peer sends.
    const properties = suite(b, "parley-properties", target, optimize, &.{"property_test."});
    b.step("properties", "Run the properties alone").dependOn(&b.addRunArtifact(properties).step);
    check.dependOn(&properties.step);

    // examples/usage.zig is also README.md's Usage blocks (bay docs --
    // usage), so the code a reader copies is code the tests run.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "parley", .module = module }},
        }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(check);

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
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on parley by path, with only the packages
    // parley needs: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "parley", .program = p.path("ci/consumer.zig"), .packages = &.{ aegis, strand }, .modules = &.{"parley"} });
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

/// parley again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module. `b` is the development build; preflight adds shakedown.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const parley = b.dependency("parley", .{ .target = target, .optimize = optimize }).module("parley");
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "parley", .module = parley }}) catch @panic("OOM");
}
