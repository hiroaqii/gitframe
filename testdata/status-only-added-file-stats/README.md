# Status-only added file stats fixture

This fixture documents the bug where a status-only added file is shown in the
file tree without contributing its added-line stats to the parent directory.

Files:

- `active.diff`: active diff contains only `src/main.zig` with `+1 -0`.
- `src/selection.zig`: status-only added/untracked file content with 4 lines.
- `status-porcelain.txt`: human-readable porcelain equivalent.

Expected file tree stats when `src/selection.zig` is a status-only added row:

- `src/main.zig`: `+1 -0`
- `src/selection.zig`: `+4 -0`
- `src`: `+5 -0`

The raw porcelain status command is NUL-delimited in real Git output; this text
fixture uses visible text for review/debugging.
