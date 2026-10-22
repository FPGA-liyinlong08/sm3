#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/env.sh"
cd "$ROOT_DIR"
CORE_NUM="${CORE_NUM:-8}"
CTX_NUM="${CTX_NUM:-32}"
NMSG="${NMSG:-250}"
NMSG="$NMSG" make -f Makefile.multi CORE_NUM="$CORE_NUM" CTX_NUM="$CTX_NUM" SIM=verilator
