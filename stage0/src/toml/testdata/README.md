# toml-test corpus (TOML 1.0.0)

Vendored from https://github.com/toml-lang/toml-test, tag `v2.2.0`
(commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`): exactly the files listed in
`tests/files-toml-1.0.0`, under `valid/` and `invalid/` with their original paths.

Licence: MIT, see `LICENSE` (copied from the toml-test repository).

`corpus.zig` embeds every case for `../corpus_test.zig`. It was generated from
the file list; regenerate it when updating the corpus. Files here are not
auto-discovered as tests (the `testdata` directory is skipped). The
`.gitattributes` file disables line-ending conversion so the CRLF cases stay
byte-exact.
