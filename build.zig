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

    const draw_mod = b.createModule(.{
        .root_source_file = b.path("src/draw.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
        },
    });
    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
        },
    });
    const keymap_mod = b.createModule(.{
        .root_source_file = b.path("src/keymap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
        },
    });

    const mod = b.addModule("gitframe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
            .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
            .{ .name = "draw", .module = draw_mod },
            .{ .name = "theme", .module = theme_mod },
            .{ .name = "keymap", .module = keymap_mod },
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

    const draw_tests = b.addTest(.{
        .root_module = draw_mod,
    });
    const run_draw_tests = b.addRunArtifact(draw_tests);

    const diff_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_source_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_source_tests = b.addRunArtifact(diff_source_tests);

    const diff_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_parser_tests = b.addRunArtifact(diff_parser_tests);

    const diff_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_file_tests = b.addRunArtifact(diff_file_tests);

    const diff_render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                .{ .name = "draw", .module = draw_mod },
                .{ .name = "theme", .module = theme_mod },
                .{ .name = "keymap", .module = keymap_mod },
            },
        }),
    });
    const run_diff_render_tests = b.addRunArtifact(diff_render_tests);

    const diff_view_model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/view_model.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_view_model_tests = b.addRunArtifact(diff_view_model_tests);

    const diff_search_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/search.zig"),
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

    const sidebar_view_model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sidebar_view_model_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
            },
        }),
    });
    const run_sidebar_view_model_tests = b.addRunArtifact(sidebar_view_model_tests);

    const repo_discovery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/repo/discovery.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_repo_discovery_tests = b.addRunArtifact(repo_discovery_tests);

    const perf_baseline_exe = b.addExecutable(.{
        .name = "gitframe-perf-baseline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf_baseline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                .{ .name = "draw", .module = draw_mod },
                .{ .name = "theme", .module = theme_mod },
                .{ .name = "keymap", .module = keymap_mod },
            },
        }),
    });
    const run_perf_baseline = b.addRunArtifact(perf_baseline_exe);

    const perf_baseline_step = b.step("perf-baseline", "Run GitFrame performance baseline");
    perf_baseline_step.dependOn(&run_perf_baseline.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const core_wasm = b.addObject(.{
        .name = "gitframe-core-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_wasm_check.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });

    const check_core_wasm_step = b.step("check-core-wasm", "Compile the GitFrame shared core for wasm32-freestanding");
    check_core_wasm_step.dependOn(&core_wasm.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_draw_tests.step);
    test_step.dependOn(&run_diff_source_tests.step);
    test_step.dependOn(&run_diff_parser_tests.step);
    test_step.dependOn(&run_diff_file_tests.step);
    test_step.dependOn(&run_diff_render_tests.step);
    test_step.dependOn(&run_diff_view_model_tests.step);
    test_step.dependOn(&run_diff_search_tests.step);
    test_step.dependOn(&run_file_tree_tests.step);
    test_step.dependOn(&run_sidebar_view_model_tests.step);
    test_step.dependOn(&run_repo_discovery_tests.step);
    test_step.dependOn(&perf_baseline_exe.step);
    test_step.dependOn(&core_wasm.step);
    const keymap_tests = b.addTest(.{
        .root_module = keymap_mod,
    });
    test_step.dependOn(&b.addRunArtifact(keymap_tests).step);
}
