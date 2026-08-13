const std = @import("std");
const builtin = @import("builtin");

const SyntaxProvider = enum {
    none,
    flow_syntax,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const syntax_provider = b.option(SyntaxProvider, "syntax-provider", "Syntax provider: none or flow_syntax") orelse defaultSyntaxProvider(target);
    const provider_enabled = syntax_provider == .flow_syntax;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run aggregate tests matching any filter",
    ) orelse &.{};

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
    const build_options = b.addOptions();
    build_options.addOption(bool, "syntax_provider_flow_syntax", provider_enabled);
    build_options.addOption(
        usize,
        "expected_package_root_test_count",
        if (!provider_enabled and test_filters.len == 0) 1800 else 0,
    );

    const mod = mod: {
        const base_imports: [6]std.Build.Module.Import = .{
            .{ .name = "chasen", .module = chasen_dep.module("chasen") },
            .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
            .{ .name = "draw", .module = draw_mod },
            .{ .name = "theme", .module = theme_mod },
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        };
        switch (syntax_provider) {
            .none => break :mod b.addModule("gitframe", .{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .imports = &base_imports,
            }),
            .flow_syntax => {
                if (!supportsFlowSyntaxProvider(target)) {
                    std.process.fatal("-Dsyntax-provider=flow_syntax is currently supported only for macOS and Linux targets", .{});
                }
                // Calling lazyDependency marks the dependency as needed, so keep
                // it inside the provider branch. Explicit `none` and
                // unsupported-target defaults must not resolve flow-syntax.
                const flow_syntax_dep = b.lazyDependency("flow_syntax", .{
                    .target = target,
                    .optimize = optimize,
                    .@"use-llvm" = true,
                }) orelse return;
                const flow_imports: [7]std.Build.Module.Import = base_imports ++ .{
                    std.Build.Module.Import{ .name = "flow_syntax", .module = flow_syntax_dep.module("syntax") },
                };
                break :mod b.addModule("gitframe", .{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .imports = &flow_imports,
                });
            },
        }
    };

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
    configureFlowSyntaxArtifact(exe, target, provider_enabled);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run GitFrame");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });
    configureFlowSyntaxArtifact(mod_tests, target, provider_enabled);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const package_root_test_step = b.step("test-package-root", "Run only the package-root test artifact");
    package_root_test_step.dependOn(&run_mod_tests.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });
    configureFlowSyntaxArtifact(exe_tests, target, provider_enabled);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const draw_tests = b.addTest(.{
        .root_module = draw_mod,
        .filters = test_filters,
    });
    const run_draw_tests = b.addRunArtifact(draw_tests);

    const diff_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_source_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_diff_source_tests = b.addRunArtifact(diff_source_tests);

    const diff_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_diff_parser_tests = b.addRunArtifact(diff_parser_tests);

    const diff_view_model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/view_model.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_diff_view_model_tests = b.addRunArtifact(diff_view_model_tests);

    const diff_search_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff/search.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_diff_search_tests = b.addRunArtifact(diff_search_tests);

    const file_tree_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/file_tree.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
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
        .filters = test_filters,
    });
    const run_sidebar_view_model_tests = b.addRunArtifact(sidebar_view_model_tests);

    const check_flow_syntax_step = b.step("check-flow-syntax", "Compile the pinned flow-syntax provider API check");
    const flow_syntax_check = b.option(
        bool,
        "flow-syntax-check",
        "Fetch and compile the pinned flow-syntax API canary",
    ) orelse false;
    if (flow_syntax_check) {
        // lazyDependency marks the package as needed when called. Keep the call
        // behind an option so default build/test paths do not fetch it.
        const flow_syntax_dep = b.lazyDependency("flow_syntax", .{
            .target = target,
            .optimize = optimize,
            .@"use-llvm" = true,
        }) orelse return;
        const flow_syntax_check_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/flow_syntax_check.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "flow_syntax", .module = flow_syntax_dep.module("syntax") },
                },
            }),
        });
        flow_syntax_check_tests.use_llvm = true;
        flow_syntax_check_tests.use_lld = if (builtin.os.tag.isDarwin()) null else true;
        const run_flow_syntax_check_tests = b.addRunArtifact(flow_syntax_check_tests);
        check_flow_syntax_step.dependOn(&run_flow_syntax_check_tests.step);
    } else {
        check_flow_syntax_step.dependOn(&b.addFail(
            "run `zig build check-flow-syntax -Dflow-syntax-check=true` to fetch and compile the pinned flow-syntax API canary",
        ).step);
    }

    const test_syntax_provider_step = b.step("test-syntax-provider", "Run syntax provider integration tests");
    if (syntax_provider == .flow_syntax) {
        const syntax_provider_tests = b.addTest(.{
            .root_module = mod,
        });
        configureFlowSyntaxArtifact(syntax_provider_tests, target, true);
        const run_syntax_provider_tests = b.addRunArtifact(syntax_provider_tests);
        test_syntax_provider_step.dependOn(&run_syntax_provider_tests.step);
    } else {
        test_syntax_provider_step.dependOn(&b.addFail(
            "run `zig build test-syntax-provider -Dsyntax-provider=flow_syntax` on macOS or Linux",
        ).step);
    }

    const perf_baseline_exe = b.addExecutable(.{
        .name = "gitframe-perf-baseline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf_baseline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
                .{ .name = "draw", .module = draw_mod },
                .{ .name = "theme", .module = theme_mod },
                .{ .name = "keymap", .module = keymap_mod },
            },
        }),
    });
    const run_perf_baseline = b.addRunArtifact(perf_baseline_exe);

    const perf_baseline_step = b.step("perf-baseline", "Run GitFrame performance baseline");
    perf_baseline_step.dependOn(&run_perf_baseline.step);

    const projection_perf_step = b.step(
        "projection-perf",
        "Profile staged projection construction from a patch or component pair",
    );
    const source_syntax_perf_step = b.step(
        "source-syntax-perf",
        "Profile Repository full-file syntax parsing and no-cache revisit",
    );
    const source_syntax_capacity_step = b.step(
        "source-syntax-capacity",
        "Inspect bounded Repository full-file syntax metadata capacity",
    );
    if (syntax_provider == .flow_syntax) {
        const flow_syntax_dep = b.lazyDependency("flow_syntax", .{
            .target = target,
            .optimize = optimize,
            .@"use-llvm" = true,
        }) orelse return;
        const projection_perf_exe = b.addExecutable(.{
            .name = "gitframe-projection-perf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/projection_perf.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "flow_syntax", .module = flow_syntax_dep.module("syntax") },
                    .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                    .{ .name = "chasen_ui", .module = chasen_ui_dep.module("chasen_ui") },
                    .{ .name = "draw", .module = draw_mod },
                    .{ .name = "theme", .module = theme_mod },
                    .{ .name = "keymap", .module = keymap_mod },
                },
            }),
        });
        configureFlowSyntaxArtifact(projection_perf_exe, target, true);
        const run_projection_perf = b.addRunArtifact(projection_perf_exe);
        if (b.args) |args| run_projection_perf.addArgs(args);
        projection_perf_step.dependOn(&run_projection_perf.step);

        const source_syntax_perf_exe = b.addExecutable(.{
            .name = "gitframe-source-syntax-perf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/source_syntax_perf.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "flow_syntax", .module = flow_syntax_dep.module("syntax") },
                    .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                },
            }),
        });
        configureFlowSyntaxArtifact(source_syntax_perf_exe, target, true);
        const run_source_syntax_perf = b.addRunArtifact(source_syntax_perf_exe);
        if (b.args) |args| run_source_syntax_perf.addArgs(args);
        source_syntax_perf_step.dependOn(&run_source_syntax_perf.step);

        const source_syntax_capacity_exe = b.addExecutable(.{
            .name = "gitframe-source-syntax-capacity",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/source_syntax_capacity.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "flow_syntax", .module = flow_syntax_dep.module("syntax") },
                    .{ .name = "chasen", .module = chasen_dep.module("chasen") },
                },
            }),
        });
        configureFlowSyntaxArtifact(source_syntax_capacity_exe, target, true);
        const run_source_syntax_capacity = b.addRunArtifact(source_syntax_capacity_exe);
        if (b.args) |args| run_source_syntax_capacity.addArgs(args);
        source_syntax_capacity_step.dependOn(&run_source_syntax_capacity.step);
    } else {
        projection_perf_step.dependOn(&b.addFail(
            "run `zig build projection-perf -Dsyntax-provider=flow_syntax -- <patch-file> [iterations]` or its `--component-pair` mode on macOS or Linux",
        ).step);
        source_syntax_perf_step.dependOn(&b.addFail(
            "run `zig build source-syntax-perf -Dsyntax-provider=flow_syntax -- <file-a> <file-b> [iterations]` on macOS or Linux",
        ).step);
        source_syntax_capacity_step.dependOn(&b.addFail(
            "run `zig build source-syntax-capacity -Dsyntax-provider=flow_syntax -- <file>` on macOS or Linux",
        ).step);
    }

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
    test_step.dependOn(&run_diff_view_model_tests.step);
    test_step.dependOn(&run_diff_search_tests.step);
    test_step.dependOn(&run_file_tree_tests.step);
    test_step.dependOn(&run_sidebar_view_model_tests.step);
    test_step.dependOn(&perf_baseline_exe.step);
    test_step.dependOn(&core_wasm.step);
    const keymap_tests = b.addTest(.{
        .root_module = keymap_mod,
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(keymap_tests).step);
}

fn supportsFlowSyntaxProvider(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

fn defaultSyntaxProvider(target: std.Build.ResolvedTarget) SyntaxProvider {
    return if (supportsFlowSyntaxProvider(target)) .flow_syntax else .none;
}

fn configureFlowSyntaxArtifact(artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, provider_enabled: bool) void {
    if (!provider_enabled) return;
    artifact.use_llvm = true;
    artifact.use_lld = switch (target.result.os.tag) {
        .linux => true,
        else => null,
    };
}
