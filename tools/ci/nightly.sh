#!/usr/bin/env bash
# Nightly job (T028): 10-minute front-end fuzz run, then the front-end bench.
# Appends `<date>\t<commit>\tbench\tfrontend\t<lines/s/core>\t<bytes/s/core>`
# to bench/frontend/results.tsv; commit that file to track the result.
# Usage: tools/ci/nightly.sh [fuzz-seconds]   (default 600)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
zig build fuzz -Doptimize=ReleaseSafe -- --seconds "${1:-600}"
line=$(zig build bench -Doptimize=ReleaseFast | tee /dev/stderr | grep $'^bench\tfrontend\t')
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%d)" "$(git rev-parse --short HEAD)" "$line" >> bench/frontend/results.tsv
