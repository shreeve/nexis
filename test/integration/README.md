# test/integration

Reserved for Phase 6+ end-to-end integration tests. Empty for now.

These will exercise the full pipeline: `.nx` source → reader → Form →
lower → Tiny IR → compile → bytecode → VM → result. Today, end-to-end
behavior is covered by:

- inline tests in `src/compile.zig` (Tiny → bytecode → VM)
- `test/golden/` (source → Form, Phase 0 reader)

Once step #7 (reader.Form integration) lands, source-to-execution
tests will start appearing inline in `src/compile.zig`. As the test
suite grows, end-to-end fixtures may move here for organization.
