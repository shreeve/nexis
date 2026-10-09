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
pub const db = @import("db.zig");
pub const transact = @import("transact.zig");
pub const excise = @import("excise.zig");
pub const fulltext = @import("fulltext.zig");
pub const relation = @import("relation.zig");
pub const query = @import("query.zig");
pub const pull = @import("pull.zig");
pub const natives = @import("natives.zig");
pub const marshal = @import("marshal.zig");

pub const Val = key.Val;
pub const Index = key.Index;
pub const Datom = datom.Datom;
pub const Store = store.Store;
pub const boot = store.boot;
pub const Attr = schema.Attr;
pub const Conn = db.Conn;
pub const DbValue = db.DbValue;
pub const Report = transact.Report;
pub const Op = transact.Op;
pub const Relation = relation.Relation;
pub const Cell = relation.Cell;

test {
    @import("std").testing.refAllDecls(@This());
}
