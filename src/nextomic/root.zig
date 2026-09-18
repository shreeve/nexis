//! root.zig — the `nextomic` module (NEXTOMIC.md §8).
//!
//! Storage layer: sortable keys, datoms, the store, idents, schema,
//! transactions and db-values. The query pipeline, pull and the Lisp
//! natives sit above these files inside the same module.

pub const key = @import("key.zig");
pub const datom = @import("datom.zig");

pub const Val = key.Val;
pub const ValueType = key.ValueType;
pub const Index = key.Index;
pub const Datom = datom.Datom;

test {
    _ = key;
    _ = datom;
}
