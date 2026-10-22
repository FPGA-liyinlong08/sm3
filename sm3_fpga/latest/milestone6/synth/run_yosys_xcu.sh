#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${YOSYS:=yosys}"
for cfg in top8_ctx32_full top12_ctx48_full top16_ctx32_full; do
  "$YOSYS" -s "synth/${cfg}.ys" | tee "synth/${cfg}.rerun.log"
done
