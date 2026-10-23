#!/usr/bin/env bash
# Timing-optimization V1 regression, requires verilator + cocotb in PATH.
# Usage: bash scripts/check_timing_v1.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v verilator >/dev/null || { echo "ERROR: verilator not in PATH" >&2; exit 1; }
command -v cocotb-config >/dev/null || { echo "ERROR: cocotb-config not in PATH" >&2; exit 1; }

RTL=(
  rtl/core/sm3_core.sv
  rtl/front_end/sm3_block_builder.sv
  rtl/context/sm3_block_pool.sv
  rtl/context/sm3_pool_engine.sv
  rtl/top/sm3_accel_top.sv
)

echo "=== Verilator syntax/lint: CORE_NUM=16 CTX_NUM=32 POOL_DEPTH=512 ==="
verilator --lint-only --timing -Wall -Wno-fatal -Wno-PINCONNECTEMPTY \
  --top-module sm3_accel_top \
  -GCORE_NUM=16 -GCTX_NUM=32 -GFAST_DEPTH=32 -GPOOL_DEPTH=512 \
  "${RTL[@]}"

echo "=== Mixed smoke: 8 cores ==="
PROFILE=mixed NMSG=300 \
  make -f Makefile.top CORE_NUM=8 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512 SIM=verilator

echo "=== Mixed stress: 16 cores, 32 contexts ==="
PROFILE=mixed NMSG=1000 \
  make -f Makefile.top CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512 SIM=verilator

echo "=== Short-heavy stress: 16 cores ==="
PROFILE=short_heavy NMSG=500 \
  make -f Makefile.top CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512 SIM=verilator

echo "Regression commands completed; inspect cocotb PASS summaries before sign-off."
