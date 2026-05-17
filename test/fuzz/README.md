# test/fuzz

Reserved for Phase 6+ fuzz testing infrastructure. Empty for now.

Likely targets when this lands:

- Reader: feed malformed `.nx` byte sequences; assert the reader either
  produces a Form tree or surfaces a structured error (no panics, no
  hangs).
- Codec: random valid Values → encode → decode → assert equal; random
  byte sequences → decode → assert either a Value or a structured
  error (never a panic).
- VM: random bytecode within `Inst` budget → run with fuel limit;
  assert any failure surfaces as a `VmError` from the published
  taxonomy (VM.md §13) rather than a panic.

See `docs/PERF.md` and `PLAN.md` Phase 6 for the larger context.
