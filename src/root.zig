//! The `nexis` module: the whole runtime as one Zig module.
//!
//! Every runtime file imports its siblings by relative path; test and
//! bench binaries import this module and reach a file as `nx.vm`,
//! `nx.nextomic` and so on. The declarations below are the layering
//! (PLAN §5, docs/FORMS.md §4), bottom-up: a file may import only
//! files declared above it. `parser.zig` and `nexis.zig` belong to
//! `reader.zig`; every file under `nextomic/` except `handle.zig`
//! belongs to `nextomic/root.zig`, and only `stdlib.zig` imports it.
//! Imports inside one of those units are free. The build's layering
//! check (build.zig `checkLayering`) enforces all of this.

pub const stack = @import("stack.zig");
pub const bench = @import("bench.zig");
pub const hash = @import("hash.zig");
pub const value = @import("value.zig");
pub const heap = @import("heap.zig");
pub const intern = @import("intern.zig");
pub const string = @import("string.zig");
pub const atom = @import("atom.zig");
pub const list = @import("coll/list.zig");
pub const vector = @import("coll/vector.zig");
pub const bignum = @import("bignum.zig");
pub const protocol = @import("protocol.zig");
pub const typed_vector = @import("coll/typed_vector.zig");
pub const champ = @import("coll/champ.zig");
pub const transient = @import("coll/transient.zig");
pub const record = @import("record.zig");
pub const codec = @import("codec.zig");
pub const db = @import("db.zig");
pub const nextomic_handle = @import("nextomic/handle.zig");
pub const gc = @import("gc.zig");
pub const dispatch = @import("dispatch.zig");
pub const vm = @import("vm.zig");
pub const reader = @import("reader.zig");
pub const expand = @import("expand.zig");
pub const compile = @import("compile.zig");
pub const format = @import("format.zig");
pub const loader = @import("loader.zig");
pub const disasm = @import("disasm.zig");
pub const nextomic = @import("nextomic/root.zig");
pub const stdlib = @import("stdlib.zig");

pub const emdb = @import("emdb");

test {
    @import("std").testing.refAllDecls(@This());
}
