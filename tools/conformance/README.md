# Conformance harness (B.9)

`zig build conformance` builds `pyro` and runs:

```
pyro-conformance <pyro> conformance/ --examples examples/ --registry spec/A-diagnostics.md [args...]
```

Extra arguments come after `--`: `zig build conformance -- 02-lexical --coverage-out conformance/COVERAGE.md`.

| Argument | Meaning |
|---|---|
| `filter...` | run only cases and examples whose path contains one of the filters (`02-lexical/`, `e0332`, `examples/d1_hello`) |
| `--coverage-out <file>` | also write the full A.3 coverage table as Markdown |
| `--require-coverage` | fail if any A.3 code lacks a passing or a failing case |

Output is one line per case (`PASS`, `FAIL` with indented reasons, `XFAIL`, `XPASS`,
`SKIP`), a summary line, then the coverage report. The exit status is 1 if any case
failed or passed unexpectedly (XPASS), else 0. Files: `main.zig` (driver, mode table),
`case.zig` (case format), `exec.zig` (running `pyro`), `diagnostic.zig` (JSON format),
`coverage.zig`, `selftest.zig` (tests against a fake compiler, run by `zig build test`).

## What `pyro` must provide

The harness calls `pyro` only like this. Single-file `check` and `run` are stage-0
conveniences (T024).

| Call | Expected behaviour |
|---|---|
| `pyro check --message-format json [--stop-after lex\|parse] <file.pr>` | JSON diagnostics on stdout (below); exit 0 if no error was reported, 1 if one was |
| `pyro run --env <dev\|test\|prod> <file.pr>` | build and run the file; program stdout/stderr/exit status pass through |
| `pyro test` (cwd = example package) | exit 0 if all tests pass |
| `pyro run --env <env>` (cwd = example package) | build and run the package |

Any other exit status of `pyro check` (2 usage, 3 internal error, a signal) fails the
case. Stage 0: a full `pyro check` (no `--stop-after`) exits 3 until both a resolve and
a check pass are registered in `semantic_stages` (`stage0/src/cli/main.zig`), so
`stop-after: check` pass cases stay expected-fail until then. Each call is killed if it prints nothing for 60 s.

## JSON diagnostic format (`--message-format json`)

One JSON object per diagnostic, one object per line of stdout, nothing else on stdout.
Every field is required (use `[]` or `""` when empty) and no other fields are allowed;
`diagnostic.zig` parses strictly and is the reference.

```json
{"code":"E0332","severity":"error","message":"`arena` is changed while a slice from it is still in use",
 "spans":[{"file":"src/frame.pr","line":4,"column":5,"end_line":4,"end_column":18,"label":"`arena` is reset here","primary":true},
          {"file":"src/frame.pr","line":3,"column":15,"end_line":3,"end_column":20,"label":"`tmp` points into `arena` here","primary":false}],
 "help":["finish using `tmp` before calling `reset`, or move `arena.reset()` into a `defer`"],
 "fixes":[{"file":"src/frame.pr","range":{"line":4,"column":5,"end_line":4,"end_column":18},"replacement":"defer arena.reset()"}],
 "trace":[]}
```

(Shown wrapped; the real output is one line.)

| Field | Type | Meaning |
|---|---|---|
| `code` | string | A.3 code, e.g. `"E0332"`, `"W0201"` |
| `severity` | `"error"` \| `"warning"` | |
| `message` | string | the plain-language headline (A.1 item 3) |
| `spans` | array of span | exactly one has `primary: true`: the `-->` location |
| `help` | array of string | `help:` lines, in order |
| `fixes` | array of `{file, range, replacement}` | machine-applicable edits; `range` is `{line, column, end_line, end_column}` |
| `trace` | array of `{message, span}` | instantiation/expansion trace (A.1 item 5), innermost first; the last frame is in the user's code |

A span is `{file, line, column, end_line, end_column, label, primary}`. Lines and
columns are 1-based, columns count Unicode scalar values, and the end is exclusive
(one past the last character). `label` is `""` when the span has no label. `file` is
the path as given on the command line (or relative to the package root).

The harness compares the (`code`, primary-span `line`) pairs as a multiset.

## Cases

Cases are `.pr` files at any depth under `conformance/` (B.9: `conformance/<NN-chapter>/`).
Results are reported in path order.

### Expected diagnostics: `//~`

```pyro
arena.reset(); //~ E0332        expected on this line; text after the codes is free
let x = 1 << 2 + 3; //~ W0201 E0201
"unterminated
//~^ E0109                       ^ = one line up, ^^ = two lines up, ...
```

The set of (code, line) pairs reported by `pyro check` must equal the expected set
exactly: a missing, extra or misplaced diagnostic fails the case. A case without `//~`
must produce no diagnostics.

### Directives: `//@`

| Directive | Meaning |
|---|---|
| `//@ covers: E0332 W0201` | this is a passing case for these codes (coverage) |
| `//@ stop-after: lex\|parse\|check\|run` | overrides the directory setting |
| `//@ expected-fail: <reason>` | known failure: reported as XFAIL; if it passes, XPASS fails the run |
| `//@ debug_assertions` | run output may differ in `prod` (§13.3); see below |

An unknown directive or a malformed `//~` fails the case.

### `stop-after` and `dir.conf`

`stop-after` selects how far a case goes:

- `lex`, `parse`: `pyro check --stop-after <phase>`, then match diagnostics.
- `check` (default without `.out`): full `pyro check`, then match diagnostics.
- `run` (default with `<case>.out`): `check` as above (warnings may be expected, errors
  may not), then the run-pass test below. `run` and `<case>.out` go together.

A directory can set defaults in a `dir.conf` file (`key: value` lines, `#` comments).
The nearest `dir.conf` setting a key wins; a case directive beats all of them.

```
# conformance/03-syntax/dir.conf
stop-after: parse
mode: default
```

`mode` picks the runner (default `default`). A task adding a runner adds one file in
this directory and one line to the `modes` table in `main.zig`; its function has the
type `exec.RunFn` and returns `pass`, `fail: <reason>` or `skip: <reason>`.

### Run-pass cases

`<case>.pr` runs with `pyro run --env <env>` in `dev`, `test` and `prod`, and each run
is compared with:

| File | Required | Compared with |
|---|---|---|
| `<case>.out` | yes | stdout, byte for byte |
| `<case>.err` | no | stderr (not checked when absent) |
| `<case>.exit` | no | exit status, decimal (default 0; a trap is 134) |

All three environments must produce identical stdout, stderr and exit status. A case
marked `//@ debug_assertions` is exempt: `dev` and `test` (checked builds) use the files
above and `prod` uses `<case>.prod.out` (required), `.prod.err` and `.prod.exit`.
`.prod.*` files on an unmarked case are an error.

## Examples

Each `examples/<name>/` directory containing `expected.out` is a package: `pyro test`
must exit 0, then `pyro run --env <env>` in every environment is compared with
`expected.out`, `expected.err`, `expected.exit` exactly as for run-pass cases (all
environments identical). Reported as `examples/<name>`.

## Coverage

The registry is every code in the `## A.3` tables of `spec/A-diagnostics.md`. A code
has a failing case if a case expects it with `//~`, and a passing case if a case lists
it in `//@ covers:`. Expected-fail cases do not count. The report lists every code
lacking either; B.9 requires both for every code (T223 runs with
`--require-coverage --coverage-out conformance/COVERAGE.md`). Coverage counts only
the cases selected by the filters.
