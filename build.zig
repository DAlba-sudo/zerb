const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // zmpl build-time passthrough. Template roots are compiled into a
    // manifest, so they cannot be a runtime value; zerb declares the same
    // options zmpl does and forwards them by name without interpreting them.
    // A consuming app sets them through `b.dependency("zerb", .{ ... })` or
    // on the command line, e.g.
    // `-Dzmpl_templates_paths=prefix=templates,path=src/templates`.
    // ------------------------------------------------------------------
    const templates_paths = b.option(
        []const []const u8,
        "zmpl_templates_paths",
        "Template roots, each `prefix=<name>,path=<dir>` (forwarded to zmpl)",
    );
    const default_templates_paths: []const []const u8 = &.{"prefix=templates,path=src/templates"};
    const zmpl_constants = b.option([]const u8, "zmpl_constants", "Template constants (forwarded to zmpl)");
    const zmpl_options_header = b.option([]const u8, "zmpl_options_header", "Additional options header (forwarded to zmpl)");
    const zmpl_manifest_header = b.option([]const u8, "zmpl_manifest_header", "Additional manifest header (forwarded to zmpl)");
    const zmpl_markdown_fragments = b.option([]const u8, "zmpl_markdown_fragments", "Custom markdown fragments (forwarded to zmpl)");
    const zmpl_auto_build = b.option(bool, "zmpl_auto_build", "Automatically compile Zmpl templates (forwarded to zmpl)");

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const zmpl = b.dependency("zmpl", .{
        .target = target,
        .optimize = optimize,
        .zmpl_templates_paths = templates_paths orelse default_templates_paths,
        .zmpl_constants = zmpl_constants,
        .zmpl_options_header = zmpl_options_header,
        .zmpl_manifest_header = zmpl_manifest_header,
        .zmpl_markdown_fragments = zmpl_markdown_fragments,
        .zmpl_auto_build = zmpl_auto_build,
    });

    // ------------------------------------------------------------------
    // The `zerb` module.
    // ------------------------------------------------------------------
    const mod = b.addModule("zerb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("httpz", httpz.module("httpz"));
    mod.addImport("zmpl", zmpl.module("zmpl"));

    // Re-export our dependencies under our own namespace. `zerb` exposes
    // httpz and zmpl types in its public API, so consumers need to import the
    // exact same module instances we were built against; declaring their own
    // httpz or zmpl dependency would build a second copy with incompatible
    // types. `Dependency.module` only searches `b.modules`, so `addImport`
    // alone is not enough to make `zerb_dep.module("httpz")` resolve.
    b.modules.put(b.graph.arena, "httpz", httpz.module("httpz")) catch @panic("OOM");
    b.modules.put(b.graph.arena, "zmpl", zmpl.module("zmpl")) catch @panic("OOM");

    // ------------------------------------------------------------------
    // Demo executable (`zig build run`).
    // ------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zerb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zerb", .module = mod },
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "zmpl", .module = zmpl.module("zmpl") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ------------------------------------------------------------------
    // Tests (`zig build test`).
    // ------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
