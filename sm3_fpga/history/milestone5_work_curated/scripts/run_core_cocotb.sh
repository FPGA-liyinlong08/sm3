#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/env.sh"
cd "$ROOT_DIR"
VLT_VER="$(verilator --version | awk '{print $2}')"
python3 - <<PY
from packaging.version import Version
v=Version("$VLT_VER")
need=Version("5.036")
if v < need:
    raise SystemExit(f"Verilator {v} is too old for cocotb 2.x backend; need >= {need}")
PY
make clean
make
