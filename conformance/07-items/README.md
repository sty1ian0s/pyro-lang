# 07-items: modules and imports (§7.8, E0901-E0905)

Single-file cases (`*.pr` here) run as `pyro check <file>`. Each `e09xx_*/`
directory is a fixture package; see `../13-packages/README.md` for how package
cases are checked and matched.

| Code | Fail case | Pass case |
|---|---|---|
| E0901 | `e0901_bad_segment/` | `e0901_ok_nested_module/` |
| E0902 | `e0902_import_cycle/` | `e0902_ok_diamond/` |
| E0903 | `e0903_import_collides_with_item.pr`, `e0903_two_imports_same_name.pr` | `e0903_ok_renamed.pr` |
| E0904 | `e0904_local_shadows_dep/` | `e0904_ok_distinct_names/` |
| E0905 | `e0905_private_import/` | `e0905_ok_pub_use/` |
