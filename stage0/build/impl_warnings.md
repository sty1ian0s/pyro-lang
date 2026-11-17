# Implementation-defined warnings (W9xxx)

Appendix A lets an implementation add warnings with codes `W9xxx`. Stage 0 lists them
here, in the same table format as A.3; `gen_diag_codes.zig` adds every row to
`DiagCode`. Append one row per warning. Only `W9xxx` codes are accepted.

| Code | Meaning | § |
|------|---------|---|
