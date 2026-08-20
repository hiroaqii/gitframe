# AI Review Store v1 read fixtures

These files are strict codec fixtures, not a producer or Store seeding interface.

- `registry-valid.json` is compact canonical JSON with a final LF and exercises printable UTF-8 plus a non-UTF-8 raw path in padded RFC 4648 base64.
- `registry-duplicate.json` is a negative fixture: one durable repository ID is assigned to two physical locators and must invalidate the complete registry.

Run directories and Git objects are created under `std.testing.tmpDir` by the focused integration test because their device/inode binding and commit OIDs must be local to that test transaction. The fixture builder uses owner-only modes and is not installed.
