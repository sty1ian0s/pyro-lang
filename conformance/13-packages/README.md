# 13-packages: package fixtures (§13, §7.8, §14.1.1, §14.12)

Every `.pr` file under `conformance/` is a case, including the modules of the
fixture packages here and in `07-items/`. A fixture package is a directory with
a `pyro.toml`. Conventions these cases rely on:

- `pyro check <pkg>/src/x.pr` (or `<pkg>/build.pr`) checks the whole package
  that contains the file, so every `.pr` file of one package expects the same
  diagnostics.
- The harness matches (code, line) pairs and ignores the file. A diagnostic in
  `pyro.toml`, `pyro.lock` or another module is expected with a `//~` on the
  same line number of each `.pr` file of the package. Fixtures put the
  offending manifest entry on a fixed line (dependencies on line 7) so the
  annotation does not depend on which file the compiler blames.
- Package-level errors without a better place (E0908) point at line 1 of
  `pyro.toml` (`[package]`). E0901/E0904 point at line 1 of the misnamed module.
- Dependencies are `path` dependencies (`../<name>`), so no registry or network
  is needed. Fixtures with dependencies carry no `pyro.lock`, except the E0911
  ones. If `pyro check` writes a lock file, T163 commits the generated files.
- E0911: the lock records a SHA-256 for path dependencies too (`hashTree` in
  `stage0/src/pkg/lock.zig`), with keys `name`, `version`, `source`, `sha256`
  in `[[package]]`. `e0911_ok_locked/app/pyro.lock` holds the real digest of
  `e0911_ok_locked/util/`, so editing any file there means regenerating it.
  The cases wait on T163, which wires the lock into the driver. A fail case
  with a tampered cached registry or git source waits on T160 (fetch/cache).
- E0907 assumes `pyro check` runs build scripts (their generated modules are
  needed for name resolution).

| Code | Fail case | Pass case |
|---|---|---|
| E0906 | `e0906_package_cycle/` | `e0906_ok_diamond/` |
| E0907 | `e0907_untrusted_build_script/` | `e0907_ok_trusted/` |
| E0908 | `e0908_both_roots/`, `e0908_no_root/` | `e0908_ok_library/` (and every executable fixture) |
| E0909 | `e0909_unknown_keys/` | `e0909_ok_full_manifest/` |
| E0910 | `e0910_unsatisfiable/` | `e0910_ok_satisfied/` |
| E0911 | `e0911_lock_hash_mismatch/` | `e0911_ok_locked/`, `e0911_ok_no_dependencies/` |
| E0912 | `e0912_no_std_imports/` | `e0912_ok_core_only/` |
| E0913 | `e0913_std_build_in_src/` | `e0913_ok_build_script/` |

E0901-E0905 (modules) are in `../07-items/`.
