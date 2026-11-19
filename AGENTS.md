# Agent instructions

These rules apply to every agent working in this repo, including subagents and
workflow agents. Their goal is to spend fewer tokens finding and reading code.

## Finding code: codegraph first

The repo has a CodeGraph index (`.codegraph/`, gitignored, kept current by a
file watcher).

- Use the `codegraph_explore` MCP tool before Grep, Glob or Read when you need to
  find or understand code. Give it symbol names, file names or a question. It
  returns line-numbered source you can edit from, plus callers and dependents.
- If the MCP tool is missing, run `codegraph explore "<symbols or question>"`.
- Do not re-check codegraph results with grep. Read a file directly only for
  what codegraph does not index (Markdown, `.pr`, TOML, config) or to confirm one
  detail.
- In a git worktree under `.claude/worktrees/`, the index describes main, not
  your branch. Read the files you changed yourself.

## Architecture questions: graphify

`graphify-out/` (gitignored, rebuilt by the post-commit hook) holds a knowledge
graph of the code, spec and docs.

- Read `graphify-out/GRAPH_REPORT.md` for an overview before reading many files.
- `graphify query "<question>"`: traverse the graph for a question.
- `graphify explain "X"`, `graphify path "A" "B"`, `graphify affected "X"`: one
  node, the link between two nodes, or what a change to X affects.
- From a worktree, pass `--graph /home/steli/pyro-lang/graphify-out/graph.json`.

## Shell output: rtk

Command output is already condensed by rtk. Treat it as complete. Put related
commands in one call.

- Re-run as `rtk bypass <cmd>` only when the output is unusable: empty when output
  was expected, contradicting the exit code, or garbled.
- To get an answer from many large files, such as long spec chapters, without
  reading them yourself: `rtk bulk-read --question "..." <paths...>`.
- To write a mechanical file that follows an existing one:
  `rtk code-write --spec "..." --reference <file> --target <file>`.
- Useful filters: `rtk test <cmd>` (failures only), `rtk err <cmd>` (errors and
  warnings only), `rtk diff`, `rtk git`.

## Reading spec and code

- Read only the line ranges you need (`Read` with offset and limit, or
  `sed -n`). Find the range first with codegraph, graphify or grep.
- Read `tasks.md` by task ID (`grep -n -A8 '\*\*T123\*\*' tasks.md`), not as a
  whole.
