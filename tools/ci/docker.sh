#!/usr/bin/env bash
# Run the CI steps from .github/workflows/ci.yml in a clean Ubuntu container
# (no LLVM), using a fresh clone of HEAD and the host's Zig install.
# Usage: tools/ci/docker.sh [zig-dir]   (default /opt/zig-0.17.1)
set -euo pipefail
zig_dir=${1:-/opt/zig-0.17.1}
repo=$(git rev-parse --show-toplevel)
docker run --rm -v "$repo:/src:ro" -v "$zig_dir:/zig:ro" ubuntu:24.04 bash -euo pipefail -c '
  export PATH=/zig:$PATH
  apt-get update -qq >/dev/null && apt-get install -y -qq git >/dev/null
  git clone -q /src /w && cd /w
  zig build
  set +e; out=$(./zig-out/bin/pyro 2>&1); rc=$?; set -e
  test $rc -eq 2 && grep -q "^usage: pyro" <<<"$out"
  zig build test --summary all
  zig build conformance
  echo "CI OK"
'
