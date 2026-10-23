#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
cd "$ROOT"
CORE_NUM="${CORE_NUM:-16}"
CTX_NUM="${CTX_NUM:-32}"
FAST_DEPTH="${FAST_DEPTH:-32}"
POOL_DEPTH="${POOL_DEPTH:-512}"
CLUSTER_NUM="${CLUSTER_NUM:-4}"
NMSG="${NMSG:-300}"
PROFILE="${PROFILE:-short_heavy}"
export NMSG PROFILE POOL_DEPTH
make -f Makefile.top_cluster \
    CLUSTER_NUM="$CLUSTER_NUM" \
    CORE_NUM="$CORE_NUM" \
    CTX_NUM="$CTX_NUM" \
    FAST_DEPTH="$FAST_DEPTH" \
    POOL_DEPTH="$POOL_DEPTH" \
    SIM=verilator
