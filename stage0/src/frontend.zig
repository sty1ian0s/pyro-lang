//! The front end (load, lex, parse, post-parse checks) as one module, for
//! tools built outside `stage0/src`: `build.zig` exposes this file as the
//! `frontend` import of the `tools` test tree, the fuzzer (`tools/fuzz/`) and
//! the front-end bench (`bench/frontend/`). It only re-exports; the APIs are
//! documented where they are defined.

pub const diag = @import("diag/diag.zig");
pub const SourceMap = @import("source/SourceMap.zig");
pub const Pool = @import("base/Pool.zig");
pub const Ast = @import("ast/Ast.zig");
pub const token = @import("lex/token.zig");
pub const lexer = @import("lex/lexer.zig");
pub const parallel = @import("lex/parallel.zig");
pub const Parser = @import("parse/Parser.zig");
pub const check = @import("parse/check.zig");
