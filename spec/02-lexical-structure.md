# 2. Lexical Structure

## 2.1 Source files

- A source file has extension `.pr` and is encoded in UTF-8. An invalid UTF-8 sequence
  anywhere in the file is an error (**E0101**). A leading byte-order mark (`EF BB BF`)
  is ignored.
- Lines end with LF (`0x0A`). A CR (`0x0D`) is allowed only directly before an LF and is
  ignored. A CR anywhere else is an error (**E0102**).
- A file is at most 2³² − 1 bytes long (**E0103**).
- Horizontal tab (`0x09`) and space (`0x20`) are whitespace. All other control characters
  (U+0000–U+001F except TAB and LF, plus U+007F) are an error outside comments
  (**E0104**).

### 2.1.1 Line locality (normative)

**No token spans more than one line.** Pyro has no block comments and no multi-line
string literals. Multi-line text uses multi-line string *lines* (§2.6.5), and each of
those is a separate token.

Consequence: the token stream of a file is the concatenation of the token streams of
its lines, each lexed independently. Implementations may split a file at any LF and lex
the pieces in parallel (appendix B.2).

## 2.2 Tokens

The lexer turns each line into a sequence of tokens, choosing the longest possible token
at each position (*maximal munch*). Token classes:

| Class | Description |
|-------|-------------|
| `IDENT` | identifier (§2.3) |
| keyword | reserved word (§2.4) |
| `INT_LIT`, `FLOAT_LIT`, `CHAR_LIT`, `STRING_LIT`, `ML_STRING_LINE` | literals (§2.6) |
| `BUILTIN` | `@` immediately followed by an identifier, e.g. `@size_of` (§2.5) |
| punctuator | operator or delimiter (§2.7) |
| `DOC_COMMENT` | `///` comment, kept as a token for documentation tools (§2.8) |
| `EOF` | end of file |

Whitespace and ordinary comments separate tokens and are otherwise discarded.

## 2.3 Identifiers

```
IDENT        ::= ident_start ident_continue*
ident_start  ::= [A-Za-z_]
ident_continue ::= [A-Za-z0-9_]
```

- Identifiers are ASCII-only. Non-ASCII letters are allowed only in comments and in
  string and character literals. This keeps identifier comparison a byte comparison.
- `_` alone is the *wildcard*. It is not a name and cannot be read.
- Identifiers are case-sensitive and at most 255 bytes long (**E0105**).
- **Raw identifiers** `r#name` let a keyword be used as a name: `r#type` is the
  identifier `type`. `r#_` is invalid.

Naming conventions (style, checked by `pyro fmt --check`, not by the compiler): types and
protocols `PascalCase`; functions, variables, fields and enum variants `snake_case`;
constants `SCREAMING_SNAKE_CASE`.

## 2.4 Keywords

### 2.4.1 Reserved keywords

These words cannot be used as identifiers except in raw form:

```
as        break     comptime  const     continue  defer     distinct  else
enum      errdefer  extern    false     fn        for       guard     if
impl      in        inline    launch    let       loop      match     move
mut       nursery   parallel_for        protocol  pub       return    self
Self      soa       spawn     struct    tail      true      type      unsafe
use       where     while
```

### 2.4.2 Reserved for future use

These are rejected as identifiers (**E0106**) so later editions can use them:

```
actor  async  await  macro  static  try  union  var  yield
```

### 2.4.3 Contextual keywords

These are ordinary identifiers except in the positions listed:

| Word | Special only in |
|------|-----------------|
| `gpu`, `cpu` | directly after `launch` |
| `over` | in a `launch` statement after the call |
| `result` | inside an `@ensures(...)` condition |

## 2.5 Builtins

`BUILTIN ::= "@" IDENT` with no whitespace between `@` and the identifier.

A builtin token is either an **attribute** (in attribute position, §3.3) or a **builtin
call** (in expression position, chapter 8). The names come from one shared namespace
(§8.7).

## 2.6 Literals

### 2.6.1 Integer literals

```
INT_LIT      ::= ( dec_lit | hex_lit | oct_lit | bin_lit ) int_suffix?
dec_lit      ::= [0-9] ( "_"? [0-9] )*
hex_lit      ::= "0x" [0-9a-fA-F] ( "_"? [0-9a-fA-F] )*
oct_lit      ::= "0o" [0-7] ( "_"? [0-7] )*
bin_lit      ::= "0b" [01] ( "_"? [01] )*
int_suffix   ::= ( "u" | "i" ) width | "usize" | "isize"
width        ::= [1-9] | [1-5][0-9] | "6" [0-4]        (* 1..=64 *)
```

- An underscore may appear only between digits. `1__000` and `1_` are errors
  (**E0107**).
- Leading zeros in decimal literals are allowed and have no octal meaning.
- A suffix fixes the type: `255u8`, `5u3`, `-1i7`. A literal without a suffix is an
  *untyped integer constant* (§4.8).
- A literal directly followed by an identifier character (for example `5u128`, `12abc`)
  is an error (**E0108**). Maximal munch never splits it.
- **Tuple-field rule:** directly after a `.` token, a digit sequence is lexed as a plain
  decimal `INT_LIT` with no fraction, exponent or suffix. So `t.0.1` lexes as
  `t . 0 . 1`, not `t . 0.1`.
- The value must fit the suffixed type (**E0108**). A minus sign is not part of the
  literal: `-128i8` is negation applied to `128i8`, which is handled as a constant
  expression and fits.

### 2.6.2 Floating-point literals

```
FLOAT_LIT    ::= dec_lit "." [0-9] ( "_"? [0-9] )* exponent? float_suffix?
               | dec_lit exponent float_suffix?
exponent     ::= [eE] [+-]? dec_lit
float_suffix ::= "f32" | "f64"
```

`1.` and `.5` are not float literals: digits are required on both sides of `.`. This
keeps `0..10` (a range) unambiguous. A float literal without a suffix is an *untyped
float constant*.

### 2.6.3 Character literals

```
CHAR_LIT     ::= "'" ( char_plain | escape ) "'"
char_plain   ::= any Unicode scalar value except "'", "\", LF
```

A character literal is an untyped integer constant equal to the Unicode scalar value.
`'a'` is 97 and fits `u8`. `'€'` is 8364 and needs at least `u14`.

### 2.6.4 String literals

```
STRING_LIT   ::= "\"" ( str_plain | escape )* "\""
               | "r\"" [^"\n]* "\""                    (* raw: no escapes *)
str_plain    ::= any Unicode scalar value except "\"", "\", LF
escape       ::= "\" ( "n" | "r" | "t" | "0" | "\" | "'" | "\"" )
               | "\x" hex hex                           (* byte value ≤ 0x7F *)
               | "\u{" hex+ "}"                         (* 1–6 hex digits, scalar value *)
```

- A string literal has type `str` (§4.5.4) and static origin (§5.4). Its bytes are
  UTF-8 with escapes resolved. No NUL terminator is added.
- `\x80`–`\xFF` are invalid (**E0109**): string literals are always valid UTF-8. Use a
  `[N]u8` array literal for arbitrary bytes.
- `\u{D800}`–`\u{DFFF}` and values above `\u{10FFFF}` are invalid (**E0109**).

### 2.6.5 Multi-line strings

```
ML_STRING_LINE ::= "\\" [^\n]*
```

A line whose first non-whitespace characters are `\\` is a multi-line string line. Its
content is the rest of the line after `\\`, taken verbatim with no escapes. One or more
consecutive `ML_STRING_LINE` tokens (only whitespace and ordinary comments between them)
form one string literal. Their contents are joined with LF, with no trailing LF.

```pyro
const USAGE: str =
    \\usage: pyro build [options]
    \\  --env <name>   select environment
;
```

### 2.6.6 Boolean literals

`true` and `false` are keywords of type `bool`.

## 2.7 Punctuators

The lexer matches the longest punctuator at each position:

```
Three chars:  <<=  >>=  ..=
Two chars:    ==  !=  <=  >=  &&  ||  <<  >>  +=  -=  *=  /=  %=  &=  |=  ^=
              ->  =>  ..  .{
One char:     +  -  *  /  %  &  |  ^  ~  !  <  >  =  .  ,  ;  :  ?
              (  )  [  ]  {  }
```

`.{` is a single token that opens an anonymous literal (§3.8). `@` appears only as part
of a `BUILTIN` token. A lone `@` is an error (**E0110**). `#`, `$` and backtick are not
used and are errors outside comments and literals (**E0104**).

## 2.8 Comments

```
line_comment ::= "//" [^\n]*        (* except doc comments below *)
DOC_COMMENT  ::= "///" [^\n]*       (* documents the following item or field *)
               | "//!" [^\n]*       (* documents the enclosing module; file start only *)
```

There are no block comments (rationale: §2.1.1 and appendix C, D-02). `////` (four or
more slashes) is an ordinary comment.

Doc comments are tokens so `pyro doc` can extract them. The parser attaches them to the
next item, field, variant or parameter. A doc comment with nothing after it to document
gets warning **W0101**.

## 2.9 Lexer output

Each token records its kind, byte offset and byte length within the file. Line and
column are derived from the offset. A conforming implementation must report diagnostics
with 1-based line and 1-based column counted in Unicode scalar values.
