# 3. Syntax

This chapter gives the complete context-free grammar. Semantics are in the chapters that
follow. Notation is described in §1.3.

## 3.1 Parsing discipline

- The grammar is deterministic and parsed by recursive descent, with a Pratt parser for
  expressions (§3.9). No production needs more than **two tokens of lookahead**, and the
  parser never backtracks.
- The places that need two tokens are listed here so implementers can rely on the
  list:
  1. `IDENT ":"` at the start of a call argument (named argument) or statement (loop
     label);
  2. `"pub"` followed by `fn`/`const` (member) versus a field name or `mut` (field)
     inside a struct body.
- Parsing never consults the symbol table. Whether `a.b` is a module member, a field or
  an enum variant is decided during name resolution (§7.10).
- Inside a type context (§3.6), the token `>>` is split into two `>` tokens when the
  parser is closing generic arguments, and `>>=` is split into `>` and `>=`.

## 3.2 Modules

```
module        ::= MODULE_DOC* item* EOF
MODULE_DOC    ::= DOC_COMMENT starting with "//!"   (* only before the first item *)

item          ::= DOC_COMMENT* attribute* "pub"? item_kind
item_kind     ::= use_decl
                | const_decl
                | type_decl
                | fn_decl
                | struct_decl
                | enum_decl
                | protocol_decl
                | impl_decl
                | extern_block
                | comptime_block
```

`pub` on `impl_decl` and `comptime_block` is an error (**E0201**).

## 3.3 Attributes

```
attribute     ::= BUILTIN ( "(" attr_args? ")" )?
attr_args     ::= attr_arg ( "," attr_arg )* ","?
attr_arg      ::= ( IDENT ":" )? expr
```

Attributes may appear before items, struct members, fields, enum variants, parameters,
loop statements and `let` statements. The attributes defined by this specification are listed in §8.8.
An unknown attribute is an error (**E0202**). An attribute in a position it does not
support is an error (**E0203**).

## 3.4 Declarations

```
use_decl      ::= "use" path ( "as" IDENT | ".{" use_item ( "," use_item )* ","? "}" )? ";"
use_item      ::= IDENT ( "as" IDENT )?
path          ::= IDENT ( "." IDENT )*

const_decl    ::= "const" IDENT ( ":" type )? "=" expr ";"

type_decl     ::= "type" IDENT generic_params? "=" "distinct"? type ";"

fn_decl       ::= "fn" IDENT generic_params? "(" param_list? ")" fn_ret? ( block | ";" )
fn_ret        ::= "->" type
param_list    ::= param ( "," param )* ","?
param         ::= DOC_COMMENT* attribute* param_mode? param_name ( "=" expr )?
param_mode    ::= "comptime" | "mut" | "move"
param_name    ::= "self" | IDENT ":" type

generic_params ::= "<" generic_param ( "," generic_param )* ","? ">"
generic_param ::= IDENT ( ":" bound_list )?
bound_list    ::= type ( "+" type )*

struct_decl   ::= "struct" IDENT generic_params? struct_body
struct_body   ::= "{" field_list? member* "}"
field_list    ::= field ( "," field )* ","?
field         ::= DOC_COMMENT* attribute* field_vis? IDENT ":" type ( "=" expr )?
field_vis     ::= "pub" "mut"?
member        ::= DOC_COMMENT* attribute* "pub"? ( fn_decl | const_decl )

enum_decl     ::= "enum" IDENT generic_params? ( ":" type )? "{" variant_list? member* "}"
variant_list  ::= variant ( "," variant )* ","?
variant       ::= DOC_COMMENT* attribute* IDENT ( "(" type ( "," type )* ","? ")" )? ( "=" expr )?

protocol_decl ::= "protocol" IDENT generic_params? "{" member* "}"

impl_decl     ::= "impl" generic_params? type "for" type "{" member* "}"

extern_block  ::= "extern" STRING_LIT "{" extern_fn* "}"
extern_fn     ::= DOC_COMMENT* attribute* "pub"? "fn" IDENT "(" param_list? ")" fn_ret? ";"

comptime_block ::= "comptime" block
```

Rules the grammar does not express on its own:

- A `fn_decl` ends in `;` (no body) only inside `protocol_decl` (a required method).
  Anywhere else it is an error (**E0204**).
- `self` may appear only as the first parameter of a function declared inside a
  `struct_body`, `enum_decl`, `protocol_decl` or `impl_decl` (**E0205**).
  `comptime self` is invalid (**E0205**).
- Default values (`= expr`) are allowed only on trailing parameters (**E0206**).
- In a struct body all fields come before the first member, which the grammar
  enforces. In an enum body all variants come before the first member.

## 3.5 Statements and blocks

```
block         ::= "{" stmt* expr? "}"

stmt          ::= ";"
                | let_stmt
                | const_decl
                | guard_stmt
                | defer_stmt
                | errdefer_stmt
                | return_stmt
                | break_stmt
                | continue_stmt
                | spawn_stmt
                | launch_stmt
                | nursery_stmt
                | label? attribute* loop_stmt
                | label "loop" block                 (* labelled `loop` *)
                | attribute* let_stmt
                | "_" "=" expr ";"                     (* discard, §6.11.1 *)
                | block_expr                         (* no ";" needed *)
                | expr ( assign_op expr )? ";"

let_stmt      ::= "let" pattern ( ":" type )? "=" expr ";"
guard_stmt    ::= "guard" "let" pattern "=" expr "else" block
defer_stmt    ::= "defer" ( block | expr ";" )
errdefer_stmt ::= "errdefer" ( block | expr ";" )
return_stmt   ::= "return" ( "tail" expr | expr )? ";"
break_stmt    ::= "break" ( ":" IDENT )? expr? ";"
continue_stmt ::= "continue" ( ":" IDENT )? ";"
spawn_stmt    ::= "spawn" expr ";"
launch_stmt   ::= "launch" IDENT expr ( "over" expr )? ";"
nursery_stmt  ::= "nursery" block

label         ::= IDENT ":"
loop_stmt     ::= while_stmt | for_stmt | parallel_for_stmt
while_stmt    ::= "while" condition block
for_stmt      ::= "inline"? "for" pattern ( "," pattern )? "in" expr_ns ( "where" expr_ns )? block
parallel_for_stmt ::= "parallel_for" pattern "in" expr_ns block
condition     ::= expr_ns | "let" pattern "=" expr_ns

assign_op     ::= "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^=" | "<<=" | ">>="
```

- Assignment is a statement, not an expression. `a = b = c` and `if a = b` are syntax
  errors.
- The left side of an assignment must be a place (§1.6, **E0207**).
- `_ = e;` evaluates `e` and discards the value. It is an error if `e` has resource
  type (**E0327**).
- `let` always has an initializer. `let mut` comes from the `pattern` binding form
  (`mut IDENT`, §3.7).
- `block_expr` means `if`, `match`, `loop`, `unsafe`, `comptime` or a bare block
  (§3.8). At statement position a `block_expr` ends the statement: `if c {} - 1` parses
  as an `if` statement followed by the expression statement `-1;`.
- A `spawn_stmt` must be lexically inside a `nursery` block, without crossing a
  `fn` or lambda boundary (**E0501**). Its expression must be a call (**E0208**).
- A `launch_stmt`'s `IDENT` must be `gpu` or `cpu` (**E0209**), and its expression must
  be a call (**E0208**).
- `return tail` requires a call expression (**E0208**). Semantics are in §6.9.
- A label may be used only by `break`/`continue` inside the labelled loop (**E0210**).

## 3.6 Types

```
type          ::= "[" expr "]" type                       (* fixed array *)
                | "[" "]" type                            (* slice view *)
                | "soa" "[" expr "]" type                 (* SoA fixed array *)
                | "soa" "[" "]" type                      (* SoA slice view *)
                | "*" "const"? type                       (* raw pointer *)
                | "mut" type                              (* mutable view, §4.5.3 *)
                | "fn" "(" ( fn_type_param ( "," fn_type_param )* ","? )? ")" ( "->" type )?
                | "type"                                  (* the type of types, §8.3 *)
                | BUILTIN "(" builtin_args? ")"           (* comptime builtin yielding a type *)
                | "(" type "," ( type ( "," type )* )? ","? ")"   (* tuple *)
                | "(" type ")"
                | "Self"
                | "struct" struct_body                    (* anonymous struct type *)
                | path generic_args?
                | path "(" call_args? ")"                 (* comptime type-function call *)

fn_type_param ::= ( "mut" | "move" )? type   (* a leading `mut`/`move` is a parameter mode *)
generic_args  ::= "<" generic_arg ( "," generic_arg )* ","? ">"
generic_arg   ::= type | INT_LIT | "-" INT_LIT | CHAR_LIT | "true" | "false" | "{" expr "}"
```

A generic argument that is an expression other than a literal is written in braces:
`Channel<Msg, {CAP * 2}>`. A bare identifier is parsed as a type path. If name
resolution finds a constant instead, that constant is the argument
(`Channel<Msg, CAP>`).

**Generic application in expressions.** Expression positions never contain `<...>`. In
an expression (including call and builtin arguments), a generic type is applied with
parentheses instead: `Pool(Particle)` denotes the same type as `Pool<Particle>`
(§7.6.2). So `@size_of(Pool(T))`, `Pool(Particle).init()` and
`arena.alloc_slice(vec(4, f32), n)` are all valid. (Prelude constructors such as
`vec3(x, y, z)` are functions. `vec(4, f32)` is the generic type `vec<4, f32>`.) In type positions both spellings are
accepted. `pyro fmt` normalizes type positions to `<…>`.

**Types after `as`.** The right operand of `as` is a type, but in that position a path
never takes `<…>` arguments: `x as u32 < y` compares. Write `x as (Handle<T>)` for a
generic target type.

## 3.7 Patterns

```
pattern       ::= pattern_single ( "|" pattern_single )*
pattern_single ::= "_"
                | "mut"? IDENT                                     (* binding *)
                | literal_pattern ( ( ".." | "..=" ) literal_pattern )?
                | "." IDENT ( "(" pattern ( "," pattern )* ","? ")" )?  (* enum variant *)
                | "(" pattern "," ( pattern ( "," pattern )* )? ","? ")"   (* tuple *)
                | path "{" field_pattern_list "}"                  (* struct *)
                | ".{" field_pattern_list "}"                      (* struct, inferred type *)
literal_pattern ::= "-"? INT_LIT | CHAR_LIT | "true" | "false"
field_pattern_list ::= ( field_pattern ( "," field_pattern )* ","? )? ( ".." )?
field_pattern ::= IDENT ( ":" pattern )? | "mut" IDENT
```

- Alternatives (`|`) are allowed only in `match` arms. They must bind the same names
  with the same types (**E0211**).
- A trailing `..` in a struct pattern ignores the remaining fields. Without it, every
  field must be named (**E0212**).
- Float and string literals are not patterns. Compare them with `if` instead.
- An `IDENT` pattern always introduces a new binding. To compare against a constant,
  use a guard: `x if x == LIMIT => ...`.

## 3.8 Expressions

```
expr          ::= range                                (* Pratt, §3.9 *)
expr_ns       ::= expr with struct literals disallowed at top level (§3.8.1)

primary       ::= literal
                | IDENT
                | "self" | "Self"
                | BUILTIN ( "(" builtin_args? ")" )?   (* builtin call; builtin variables take no parentheses, §8.7 *)
                | "(" expr ")"
                | "(" expr "," ( expr ( "," expr )* )? ","? ")"   (* tuple *)
                | array_lit
                | struct_lit
                | anon_lit
                | "." IDENT                             (* inferred member *)
                | lambda
                | block_expr
                | "struct" struct_body                  (* comptime only, §8.3 *)

literal       ::= INT_LIT | FLOAT_LIT | CHAR_LIT | STRING_LIT | ML_STRING_LINE+ | "true" | "false"

block_expr    ::= block
                | "if" condition block ( "else" ( block | if_expr ) )?
                | "match" expr_ns "{" match_arm* "}"
                | "loop" block
                | "unsafe" block
                | "comptime" block
                | "comptime" if_expr                    (* conditional compilation, §8.5 *)
if_expr       ::= "if" condition block ( "else" ( block | if_expr ) )?
match_arm     ::= pattern ( "if" expr )? "=>" ( block ","? | expr ( "," | &"}" ) )

array_lit     ::= "[" "]"
                | "[" expr ( "," expr )* ","? "]"
                | "[" expr ";" expr "]"                 (* repeat: [value; count] *)
                | "[" expr "for" pattern ( "," pattern )? "in" expr_ns ( "where" expr_ns )? "]"

struct_lit    ::= ( path | "Self" ) "{" field_inits? "}"
field_inits   ::= field_init ( "," field_init )* ( "," ".." )? ","? | ".."
anon_lit      ::= ".{" ( anon_elem ( "," anon_elem )* ( "," ".." )? ","? | ".." )? "}"
anon_elem     ::= IDENT ":" expr | expr      (* all elements named, or all positional *)
field_init    ::= IDENT ( ":" expr )?                   (* `x` is shorthand for `x: x` *)

lambda        ::= "|" ( lambda_param ( "," lambda_param )* ","? )? "|" expr
                | "||" expr
lambda_param  ::= IDENT ( ":" type )?

builtin_args  ::= builtin_arg ( "," builtin_arg )* ","?
builtin_arg   ::= type_only | expr
type_only     ::= a `type` whose first token is "soa", "fn", "struct" or "type"
                  (* "[" and "*" are excluded: they also start array literals and
                     dereferences. Pass array, slice and pointer types through a
                     `const` alias: `const Quad = [4]f32; arena.alloc_slice(Quad, n)` *)

call_args     ::= call_arg ( "," call_arg )* ","?
call_arg      ::= ( IDENT ":" )? "mut"? ( type_only | expr )
```

**Rest marker.** In a struct or anonymous literal, `..` directly followed by `}` (or by
`,` `}`) is the *rest marker* (§6.2.1), not a range.

**Anonymous-literal elements.** All elements of one `.{…}` are either named
(`f: e`) or positional (`e`). Mixing them is an error (**E0215**). A bare identifier
`x` is positional when the expected type is a tuple or `vec`, and shorthand for
`x: x` otherwise.

**Tuple fields.** The postfix `.` accepts an `INT_LIT` as well as an `IDENT`: `t.0`
(§2.6.1 tuple-field rule).

`"comptime" expr` (comptime evaluation of a single expression) is the prefix form in
§3.9. `comptime { ... }` is the block form. `comptime if` is a separate construct: its
condition is evaluated at compile time, and only the chosen branch is compiled (§8.5).
The prefix form never applies to an `if`.

### 3.8.1 Struct-literal restriction

`expr_ns` is used where a `{` must start a block: `if`/`while` conditions, `match`
scrutinees, `for`/`parallel_for` iterables and `where` clauses. At the top level of an
`expr_ns`, `path {` is **not** a struct literal: the `{` opens the following block.
Wrap the literal in parentheses to use it there: `if p == (Point { x: 0, y: 0 }) { … }`.

### 3.8.2 Named arguments, `mut` and `move`

In `call_arg`, `IDENT ":"` makes the argument named (§7.2.4). `mut` is an argument mode
(§5.5). It is not an operator and may appear only directly in a call argument
(**E0213**).

`move e` is a prefix expression (level 12). It may appear only as a call argument, a
`let` initializer, a struct-literal field value, an assigned value, a `return` value, a
`match`/`if let` scrutinee, or a `spawn` argument (**E0213**). Its operand must be a
local or `move` parameter (§5.3.2).

## 3.9 Operator precedence

Binding power from loosest (1) to tightest (13):

| Level | Operators | Associativity | Notes |
|------:|-----------|---------------|-------|
| 1 | `..` `..=` | none | both operands optional: `a..b`, `a..`, `..b`, `..` |
| 2 | `\|\|` | left | short-circuit |
| 3 | `&&` | left | short-circuit |
| 4 | `==` `!=` `<` `>` `<=` `>=` | **none** | `a < b < c` is an error (**E0214**) |
| 5 | `\|` | left | bitwise OR |
| 6 | `^` | left | bitwise XOR |
| 7 | `&` | left | bitwise AND |
| 8 | `<<` `>>` | left | shifts |
| 9 | `+` `-` | left | |
| 10 | `*` `/` `%` | left | |
| 11 | `as` | left | `x as T`: the right operand is a `type` |
| 12 | prefix `-` `!` `~` `*` `&` `comptime` `move` | right | `*` and `&` only inside `unsafe` (§12.2) |
| 13 | postfix `.f` `.0` `.m(args)` `(args)` `[i]` `?` | left | |

Bitwise operators bind tighter than comparisons, so `flags & MASK == 0` parses as
`(flags & MASK) == 0`. This removes the C precedence trap (principle 6).

Prefix `-` applied to an integer literal is folded into the constant before the type is
checked, so `-128i8` is valid.

Mixing `&&` and `||` without parentheses is allowed (`&&` binds tighter). Mixing `<<`/`>>`
with `+`/`-` without parentheses is a warning (**W0201**).

### 3.9.1 Pratt parser contract (normative for the reference parser)

`parse_expr(min_bp)` parses a prefix or primary expression, then repeatedly consumes an
infix or postfix operator `op` while `left_bp(op) > min_bp`. For a left-associative
level *L*: `left_bp = 2L`, and the right operand is parsed with `parse_expr(2L)`. For a
non-associative level, after parsing one operator of that level, the parser rejects a
second operator of the same level (**E0214**). Prefix operators (level 12) parse their
operand with `parse_expr(24)`, so only postfix operators (level 13, `left_bp = 26`) bind
inside them: `-x as u8` is `(-x) as u8`, and `-a.b()` is `-(a.b())`. A table-driven
implementation with these binding powers is conforming.
