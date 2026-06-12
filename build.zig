const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chasen_dep = b.dependency("chasen", .{
        .target = target,
        .optimize = optimize,
    });
    const chasen_ui_dep = b.dependency("chasen_ui", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("gitframe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
            .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "gitframe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gitframe", .module = mod },
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run GitFrame");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const diff_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_source.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_source_tests = b.addRunArtifact(diff_source_tests);

    const diff_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_parser_tests = b.addRunArtifact(diff_parser_tests);

    const diff_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_file_tests = b.addRunArtifact(diff_file_tests);

    const diff_render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
            },
        }),
    });
    const run_diff_render_tests = b.addRunArtifact(diff_render_tests);

    const diff_view_model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_view_model.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_view_model_tests = b.addRunArtifact(diff_view_model_tests);

    const diff_search_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_search.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_search_tests = b.addRunArtifact(diff_search_tests);

    const file_tree_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/file_tree.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_file_tree_tests = b.addRunArtifact(file_tree_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_diff_source_tests.step);
    test_step.dependOn(&run_diff_parser_tests.step);
    test_step.dependOn(&run_diff_file_tests.step);
    test_step.dependOn(&run_diff_render_tests.step);
    test_step.dependOn(&run_diff_view_model_tests.step);
    test_step.dependOn(&run_diff_search_tests.step);
    test_step.dependOn(&run_file_tree_tests.step);
}
