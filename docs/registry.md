# Package registry protocol and source cache

Spec §13.4 says dependencies come from "a registry (versioned archives), git, or a
local path" and that fetched sources live in "a global content-addressed cache and
are never modified", but leaves the registry wire protocol, archive format and
publish authentication open (see `tasks.md`, *Spec issues*). This document records
the decisions the stage-0 toolchain implements (`stage0/src/pkg/fetch.zig`,
`stage0/src/pkg/cache.zig`). Nothing here is normative language semantics; it is
the toolchain's contract with registries.

## Registry layout

A registry is a tree of static files under a base URL. No server logic is needed:
any static file host works, and so does a local directory.

```
<base>/index/<name>.toml                     release index of package <name>
<base>/archives/<name>/<name>-<version>.tar.gz   source archive of one release
```

`<name>` is a package name (`[a-z][a-z0-9_]*`, §13.2), so it is always a safe path
segment. `<version>` is the full SemVer 2.0 text, build metadata included.

### Index file

TOML, one `[[release]]` table per published version, in any order:

```toml
[[release]]
version = "1.2.0"
sha256 = "<64 lowercase hex digits>"   # tree hash of the archive's contents
deps = { base = "^1.0", log = "0.3" }  # optional; name -> requirement (§13.4)
```

Registry packages may depend only on registry packages of the same registry, so a
dependency is just a name and a requirement. Unknown keys are errors. A missing
index file means the registry has no package of that name.

### Archive format

A gzip-compressed POSIX tar (ustar or pax) whose entries are the package directory's
contents at the archive root (`pyro.toml`, `src/lib.pr`, ...; a leading `./` is
allowed). Only regular files, directories and symbolic links are accepted. An entry
is rejected if its path is absolute or contains `..`, and a symbolic link is rejected
if its target is absolute or contains `..`; so no entry can reach outside the
package directory, even through other links.

### Hash

`sha256` is not the hash of the `.tar.gz` bytes but the tree hash of its extracted
contents (`lock.hashTree`: sorted relative paths, kinds and contents; timestamps,
directory order and compression settings do not matter). The same hash is what
`pyro.lock` records for every source kind and what names the source's cache entry,
so registry archives and git trees are verified the same way.

### Transport

Stage 0 supports `file://` base URLs only. HTTP(S) is the same layout fetched with
`GET`; it is deferred until the toolchain has a network test environment.

### Registry names

The manifest's `registry = "<name>"` key (§13.2) names a registry; omitted means the
default registry. The command-line front end maps names to base URLs: the default
registry from `PYRO_REGISTRY`, a named registry `<name>` from
`PYRO_REGISTRY_<NAME>` (name upper-cased). An unconfigured registry is an error.

### Publishing

`pyro publish` (T164) writes the archive, then adds a `[[release]]` to the index.
For `file://` registries that is a file write; publish authentication for remote
registries is left for when HTTP is supported.

## Git sources

A git dependency is cloned once into a bare mirror (`git clone --mirror`) in the
cache and exported with `git archive <commit>`, then extracted and hashed exactly
like a registry archive. `tag = "t"` resolves `refs/tags/t`, `branch = "b"`
resolves `refs/heads/b`, `rev = "r"` is passed to `git rev-parse`, and no ref means
the remote's `HEAD`. `pyro.lock` records the resolved commit. The mirror is fetched
again only when a ref is not a full commit hash already present (so branches move
when not locked) and never with `--offline`.

## Path sources

A `path` dependency is read in place, relative to the root manifest's directory,
and never copied into the cache. Its tree hash is still computed so `pyro.lock` can
record it.

## Cache

One global cache directory, chosen by the front end: `PYRO_CACHE` if set, else
`$XDG_CACHE_HOME/pyro`, else `$HOME/.cache/pyro`.

```
<cache>/src/<sha256>/          an extracted source tree, named by its tree hash
<cache>/tmp/<random>/          staging; renamed into src/ in one atomic step
<cache>/git/<key>.git          bare mirror of one git remote
<cache>/index/<key>/<name>.toml   last index file read from one registry
```

`<key>` is the first 16 hex digits of the SHA-256 of the remote URL.

- Entries in `src/` are written once, by renaming a fully extracted and verified
  staging directory, and never modified afterwards. Their files are created
  read-only. Two concurrent fetches of the same tree both stage it; the second
  rename finds the entry present and discards its copy.
- A fetch whose expected hash is already in `src/` reads the entry, re-hashes it to
  verify it (E0911 on mismatch) and writes nothing.
- `--offline` uses only the cache: a missing source, git commit or registry index
  is an error naming the package, never a network access.
- Registry index copies under `index/` are rewritten only when their content
  changed; they let `--offline` resolve against the last index seen.
