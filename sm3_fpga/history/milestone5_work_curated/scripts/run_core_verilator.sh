#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/env.sh"
cd "$ROOT_DIR"
python3 model/sm3_ref.py
python3 tb/gen_vectors.py
verilator --lint-only -Wall -Wno-fatal --top-module sm3_core rtl/core/sm3_core.sv
rm -rf sim/obj_dir
verilator --binary --timing -Wall -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSEDSIGNAL -Wno-BLKSEQ \
  --top-module tb_sm3_core rtl/core/sm3_core.sv tb/tb_sm3_core.sv -Mdir sim/obj_dir
./sim/obj_dir/Vtb_sm3_core
