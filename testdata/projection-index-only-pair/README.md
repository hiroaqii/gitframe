# Index-only projection component pair

This fixture records one logical `A = HEAD` to `C = working tree` presentation
under two different `B = index` partitions.

- `before-cached.diff` stages the first hunk.
- `before-unstaged.diff` leaves the second and third hunks unstaged.
- `after-cached.diff` stages the first and second hunks.
- `after-unstaged.diff` leaves only the third hunk unstaged.

The visible normalized hunks are identical before and after. Component `index`
metadata and hunk origins intentionally differ, so the pair catches any proposed
presentation identity that accidentally includes index/action authority.

Run the developer-only profiler with:

```sh
zig build projection-perf -- --component-pair \
  testdata/projection-index-only-pair/before-cached.diff \
  testdata/projection-index-only-pair/before-unstaged.diff \
  testdata/projection-index-only-pair/after-cached.diff \
  testdata/projection-index-only-pair/after-unstaged.diff \
  7
```
