#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
cd "$ROOT"
CORE_NUM="${CORE_NUM:-8}"
CTX_NUM="${CTX_NUM:-32}"
NMSG="${NMSG:-300}"
PROFILE="${PROFILE:-short_heavy}"
export NMSG PROFILE
make -f Makefile.top CORE_NUM="$CORE_NUM" CTX_NUM="$CTX_NUM" SIM=verilator
