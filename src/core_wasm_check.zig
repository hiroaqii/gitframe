const core_wasm_check = @import("tools/core_wasm_check.zig");

pub export fn gitframe_core_wasm_compile_check() usize {
    return core_wasm_check.gitframeCoreWasmCompileCheck();
}
