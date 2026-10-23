#!/usr/bin/env bash
# Optional local development environment.  If it is not present, fall back to
# the system Verilator/cocotb installation instead of breaking the caller.
SM3_DEV_ROOT="${SM3_DEV_ENV:-/mnt/data/sm3_dev_env}"
SM3_VROOT="$SM3_DEV_ROOT/verilator-5.048-root"
if [[ -x "$SM3_DEV_ROOT/venv/bin/python" && -x "$SM3_VROOT/usr/bin/verilator" ]]; then
    export PATH="$SM3_DEV_ROOT/venv/bin:$SM3_VROOT/usr/bin:$PATH"
    export VERILATOR_ROOT="$SM3_VROOT/usr/share/verilator"
fi
