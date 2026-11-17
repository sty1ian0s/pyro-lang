#!/usr/bin/env python3
"""Check and regenerate the dependency data in tasks.md.

Source of truth: each task's "Blocked by:" line and "Size:". Everything else
(Blocks lines, Parallel wave tags, the Waves table, [CRITICAL] tags, the
Critical paths section, and the >=6-dependents [GATE] tags) is derived.

  python3 tools/plan/tasks.py check   # report DAG, wave and same-wave file problems; exit 1 on error
  python3 tools/plan/tasks.py regen   # rewrite derived data in place, then check

[GATE] tags are only added automatically (>= 6 direct dependents). Gates that
freeze a shared contract are set by hand and never removed by regen.
"""
import collections
import functools
import pathlib
import re
import sys

PATH = pathlib.Path(__file__).resolve().parents[2] / "tasks.md"
WEIGHT = dict(S=2, M=5, L=15, XL=30)  # days, for critical paths
GATE_FANOUT = 6
FIRST_LIGHT, STAGE0_DONE = "T095", "T223"

TASK_RE = re.compile(r"- \[[ x]\] \*\*(T\d+)\*\* ")
key = lambda t: int(t[1:])


def parse(lines):
    tasks, cur = {}, None
    for i, l in enumerate(lines):
        m = TASK_RE.match(l)
        if m:
            cur = m.group(1)
            if cur in tasks:
                sys.exit(f"duplicate task {cur}")
            tasks[cur] = {"title": i}
            continue
        if l.startswith("## "):
            cur = None
        if cur:
            m = re.match(r"  - (Blocked by|Blocks|Size|Deliverable|Conflicts): (.*)", l)
            if m:
                tasks[cur][m.group(1)] = i
    for t, d in tasks.items():
        for f in ("Blocked by", "Blocks", "Size"):
            if f not in d:
                sys.exit(f"{t}: missing '{f}:' line")
    return tasks


class Graph:
    def __init__(self, lines):
        self.lines = lines
        self.tasks = parse(lines)
        self.by = {t: set(re.findall(r"T\d+", lines[d["Blocked by"]])) for t, d in self.tasks.items()}
        self.size = {t: re.search(r"Size: (\S+)", lines[d["Size"]]).group(1) for t, d in self.tasks.items()}
        self.blocks = collections.defaultdict(set)
        for t, s in self.by.items():
            for b in s:
                self.blocks[b].add(t)

    def errors(self):
        errs = []
        for t, s in self.by.items():
            errs += [f"{t}: unknown blocker {b}" for b in s if b not in self.tasks]
            if self.size[t] not in WEIGHT:
                errs.append(f"{t}: bad size {self.size[t]}")
        # cycle check (iterative DFS)
        state = {}
        for root in self.tasks:
            stack = [(root, iter(self.by[root]))]
            state[root] = state.get(root, 1)
            while stack:
                n, it = stack[-1]
                nxt = next((b for b in it if b in self.tasks), None)
                if nxt is None:
                    state[n] = 2
                    stack.pop()
                elif state.get(nxt) == 1:
                    errs.append(f"cycle through {n} <- {nxt}")
                elif nxt not in state:
                    state[nxt] = 1
                    stack.append((nxt, iter(self.by[nxt])))
        return errs

    @functools.lru_cache(None)
    def depth(self, t):
        return 0 if not self.by[t] else 1 + max(self.depth(b) for b in self.by[t])

    @functools.lru_cache(None)
    def up(self, t):
        return WEIGHT[self.size[t]] + max((self.up(b) for b in self.by[t]), default=0)

    def zero_slack(self, end):
        anc, st = set(), [end]
        while st:
            x = st.pop()
            if x not in anc:
                anc.add(x)
                st += self.by[x]

        @functools.lru_cache(None)
        def dn(t):
            return WEIGHT[self.size[t]] + max((dn(c) for c in self.blocks[t] if c in anc), default=0)

        total = self.up(end)
        return {t for t in anc if self.up(t) + dn(t) - WEIGHT[self.size[t]] == total}

    def chain(self, end):
        out = [end]
        while self.by[out[-1]]:
            out.append(max(self.by[out[-1]], key=lambda b: (self.up(b), -key(b))))
        return " -> ".join(reversed(out))


fmt = lambda s: ", ".join(sorted(s, key=key)) or "none"


def regen(lines):
    g = Graph(lines)
    errs = g.errors()
    if errs:
        sys.exit("\n".join(errs))
    ends = [t for t in g.tasks if not g.blocks[t]]
    final = max(ends, key=g.up)
    crit = g.zero_slack(FIRST_LIGHT) | g.zero_slack(STAGE0_DONE) | g.zero_slack(final)
    for t, d in g.tasks.items():
        lines[d["Blocks"]] = "  - Blocks: " + fmt(g.blocks[t])
        lines[d["Size"]] = re.sub(r"Parallel: W\d+", "Parallel: W%02d" % g.depth(t), lines[d["Size"]])
        title = lines[d["title"]].replace(" **[CRITICAL]**", "")
        gate = " **[GATE]**" in title or len(g.blocks[t]) >= GATE_FANOUT
        title = title.replace(" **[GATE]**", "")
        lines[d["title"]] = title + (" **[CRITICAL]**" if t in crit else "") + (" **[GATE]**" if gate else "")
    s = lines.index("| Wave | Tasks (run concurrently) |")
    e = s + 2
    while lines[e].startswith("| W"):
        e += 1
    waves = collections.defaultdict(list)
    for t in g.tasks:
        waves[g.depth(t)].append(t)
    lines[s + 2 : e] = ["| W%02d | %s |" % (w, fmt(waves[w])) for w in sorted(waves)]
    i = lines.index("## Critical paths")
    j = i + 1
    while not lines[j].startswith("## "):
        j += 1
    lines[i + 1 : j] = [
        "",
        "Weights: S=2, M=5, L=15, XL=30 days. **[CRITICAL]** = zero slack on one of these chains.",
        "",
        "- To first light (first end-to-end run): " + g.chain(FIRST_LIGHT),
        "- To stage-0 completion: " + g.chain(STAGE0_DONE),
        "- Overall (ends at %s): " % final + g.chain(final),
        "",
    ]
    return lines


def deliverable_paths(line):
    paths = set()
    for p in re.findall(r"`([^`]*/[^`]*)`", line):
        m = re.match(r"(.*)\{([^}]*)\}(.*)", p)
        paths |= {m.group(1) + x + m.group(3) for x in m.group(2).split(",")} if m else {p}
    return paths


def check(lines):
    g = Graph(lines)
    errs = g.errors()
    warns = []
    if not errs:
        table = {}
        for l in lines:
            m = re.match(r"\| (W\d+) \| (.*) \|", l)
            for t in re.findall(r"T\d+", m.group(2)) if m else ():
                if t in table:
                    errs.append(f"{t} listed twice in Waves table")
                table[t] = int(m.group(1)[1:])
        for t, d in g.tasks.items():
            tag = int(re.search(r"Parallel: W(\d+)", lines[d["Size"]]).group(1))
            listed = set(re.findall(r"T\d+", lines[d["Blocks"]]))
            if listed != g.blocks[t]:
                errs.append(f"{t}: Blocks line out of sync (run regen)")
            if tag != g.depth(t) or table.get(t) != tag:
                errs.append(f"{t}: wave W{tag:02d} / table {table.get(t)} / expected W{g.depth(t):02d} (run regen)")
            if len(g.blocks[t]) >= GATE_FANOUT and "[GATE]" not in lines[d["title"]]:
                errs.append(f"{t}: {len(g.blocks[t])} dependents but no [GATE] (run regen)")
            if "Deliverable" not in d or not deliverable_paths(lines[d["Deliverable"]]):
                warns.append(f"{t}: Deliverable names no file paths")
        # same-wave file ownership overlap
        bywave = collections.defaultdict(list)
        for t in g.tasks:
            bywave[g.depth(t)].append(t)
        for w, ts in sorted(bywave.items()):
            own = collections.defaultdict(set)
            for t in ts:
                if "Deliverable" in g.tasks[t]:
                    for p in deliverable_paths(lines[g.tasks[t]["Deliverable"]]):
                        own[p].add(t)
            for p, o in own.items():
                for q, o2 in own.items():
                    hit = o2 - o if p != q and p.endswith("/") and q.startswith(p) else (o if p == q else set())
                    if len(hit) > (1 if p == q else 0):
                        unflagged = [t for t in (o | hit) if "Conflicts" not in g.tasks[t]]
                        if unflagged:
                            warns.append(f"W{w:02d}: {q} shared by {fmt(o | hit)}; no Conflicts note on {fmt(unflagged)}")
    for w in warns:
        print("warn:", w)
    for e in errs:
        print("error:", e)
    print(f"{len(g.tasks)} tasks, {max(map(g.depth, g.tasks)) + 1 if not g.errors() else '?'} waves, "
          f"{len(errs)} errors, {len(warns)} warnings")
    return not errs


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    lines = PATH.read_text().split("\n")
    if cmd == "regen":
        lines = regen(lines)
        PATH.write_text("\n".join(lines))
    elif cmd != "check":
        sys.exit(__doc__)
    sys.exit(0 if check(lines) else 1)
