# Pyro source style

`pyro fmt` (§13.8) formats every `.pr` file in one canonical style. The style
has no options. This file records the style decisions; the implementation is
`stage0/src/fmt/fmt.zig`. The style was taken from the spec's examples: 72 of
the 77 `pyro` blocks in `spec/` are already formatted. The other 5 align code
inside a line with extra spaces (`let rock   = ...`) or align a continuation
line under an opening bracket, and the formatter does neither.

## Guarantees

- **Tokens are kept.** The formatter only changes the whitespace and ordinary
  comments between tokens (§2.1.1, §2.8). The token stream is the same, so the
  AST is the same. Before it writes anything, `pyro fmt` lexes its own output
  again and checks this.
- **Idempotent.** Formatting formatted text changes nothing.
- **Only valid files are formatted.** A file with a lexical or syntax error is
  left unchanged, and its diagnostics are reported.
- `pyro fmt --check` writes nothing. It names each file that would change and
  exits 1 if there is at least one.

## Lines

- Line breaks between tokens stay where the author put them. The formatter
  does not join or split lines, and it has no maximum line width.
- One blank line is kept where the source has one or more. Blank lines at the
  start and end of the file are removed, and so are blank lines directly after
  an opening bracket or directly before a closing bracket.
- No trailing whitespace. The file ends with exactly one LF. Line ends are LF
  (CR LF becomes LF), and a byte-order mark is dropped.

## Indentation

- 4 spaces per level. Tabs are never used for indentation.
- Each line inside an open bracket (`(`, `[`, `{`, `.{`) is indented one level
  deeper than the line where the bracket opened. Several brackets that open on
  one line add only one level.
- A line that starts with a closing bracket is indented like the line where its
  bracket opened.
- **Continuation lines** are indented one more level. A line continues the
  previous one unless the previous line ends with `;`, `,`, `{`, `}`, an opening
  bracket, a doc comment, or an attribute (`@soa`, `@align(16)`). A line that
  starts with `;` or `{` is not a continuation.
- The lines of one multi-line string (§2.6.5) all have the same indentation:

  ```pyro
  const USAGE: str =
      \\usage: pyro build [options]
      \\  --env <name>   select environment
  ;
  ```

## Spaces inside a line

| Where | Style |
|-------|-------|
| binary and assignment operators, `\|` between pattern alternatives, `=>`, `->`, `=` | one space on each side: `a + b`, `x += 1`, `.a \| .b => 1` |
| after `,` `;` `:` | one space: `f(a, b)`, `[0; 4]`, `x: f32` |
| before `,` `;` `:` `?` `)` `]` and after `(` `[` | none: `f(a)`, `xs[i]`, `foo()?` |
| prefix operators `-` `!` `~` `*` `&`, pointer types | none after: `-x`, `!ok`, `*const T`, `&mut v` |
| `.` (field access, inferred member) | none: `p.x`, `.red` |
| calls, indexing, builtins | none before `(` / `[`: `f(x)`, `@size_of(T)`, `fn(i32) -> i32` |
| array and slice types | none after `]`: `[4]f32`, `[]u8`; `soa [N]T` keeps its space |
| generic arguments and parameters | none inside `<` `>`: `Vec<T>`, `fn max<T: Ord>(a: T, b: T)` |
| generic expression argument | no inner space: `Channel<Msg, {CAP * 2}>` |
| ranges | none next to an operand: `0..n`, `a..=b`, `xs[1..]`, `..b` |
| lambdas | none inside the bars: `\|x, i\| x + i` |
| labels | `outer: loop { break :outer; }` |
| braces `{ }` and `.{ }` on one line | one space inside: `Point { x: 1 }`, `.{ a, b }`; empty: `{}` |
| `use` lists | no space before or inside the braces: `use std.mem.{Arena, FixedArena};` |
| comment after code | keeps its column (moved along with its line, see below), at least one space after the code |

A comment after code keeps the column it had in the source, shifted by as many
columns as re-indenting moved its line. Aligned comments therefore stay
aligned:

```pyro
struct Unit {
    health: u7,          // unit 0, bits 0..=6
    is_crouching: bool,  // unit 0, bit 7
}
```

If the code before a comment gets longer than the space allows, the comment
moves right to one space after the code. Comments on their own line are
indented like the code line after them. Inside a bracket that closes on the
next line, they are indented one level deeper than the closing bracket.

Where two tokens written together would lex as one (`>` `=`, `&` `&`), they
keep one space.

## Not done by stage 0

- `pyro fmt` normalizes generic types in type positions to `<…>` (§3.6). That
  changes tokens, and telling a generic type `Pool(T)` from a comptime type
  function call needs name resolution, so stage 0 keeps the author's spelling.
- The naming conventions of §2.3 are not checked yet.
