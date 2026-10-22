#!/usr/bin/env bash
ROOT="/mnt/data/sm3_dev_env"
VROOT="$ROOT/verilator-5.048-root"
export PATH="$ROOT/venv/bin:$VROOT/usr/bin:$PATH"
export VERILATOR_ROOT="$VROOT/usr/share/verilator"
