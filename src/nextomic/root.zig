//! root.zig — the `nextomic` module (NEXTOMIC.md §8).
//!
//! Storage layer: sortable keys, datoms, the store, idents, schema,
//! transactions and db-values. The query pipeline, pull and the Lisp
//! natives sit above these files inside the same module.

pub const key = @import("key.zig");
pub const datom = @import("datom.zig");
pub const store = @import("store.zig");
pub const idents = @import("idents.zig");
pub const schema = @import("schema.zig");

pub const Val = key.Val;
pub const ValueType = key.ValueType;
pub const Index = key.Index;
pub const Datom = datom.Datom;
pub const Store = store.Store;
pub const boot = store.boot;
pub const Idents = idents.Idents;
pub const Schema = schema.Schema;
pub const Attr = schema.Attr;

test {
    _ = key;
    _ = datom;
    _ = store;
    _ = idents;
    _ = schema;
}
