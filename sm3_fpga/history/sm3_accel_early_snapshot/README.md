# SM3 FPGA Multi-Core Accelerator

Verified RTL prototype for many independent short / medium SM3 messages using iterative cores, dynamic sharing, Context RAM, adaptive Sticky-Core scheduling, and a raw-message frontend.

## Toolchain

- Verilator 5.048
- cocotb 2.1.0
- Python 3.13
- 4 ns simulation clock (250 MHz reference)

The sandbox uses a locally extracted Verilator and Python venv; tool binaries are not included in the source archive.

## Current architecture

```text
128-bit raw message stream
        |
        v
+-----------------------+
| sm3_block_builder     |
| 512-bit block + pad   |
+-----------+-----------+
            |
            v
+-----------------------+
| context allocator     |
| single-block bypass   |
+-----------+-----------+
            |
            v
+-----------------------+
| adaptive scheduler    |
| Fast FIFO + Context   |
| Sticky Q2 / Q8        |
+-----------+-----------+
            |
      +-----+-----+ ...
      v           v
   sm3_core0   sm3_coreN
      |           |
      +-----+-----+
            v
      digest result
```

## RTL modules

### `rtl/core/sm3_core.sv`

- iterative SM3 compression core
- 1 round/cycle
- 16 x 32-bit W sliding window
- ready/valid interfaces
- output backpressure holding
- zero-bubble output/input handoff: a new block may be accepted in the same cycle that the previous result is consumed

### `rtl/front_end/sm3_block_builder.sv`

- accepts a message descriptor (`msg_id`, original byte length)
- accepts 128-bit MSB-first payload beats + 16-bit keep
- generates 512-bit SM3 compression blocks
- hardware SM3 padding and 64-bit original bit length insertion
- handles empty message and all padding boundaries, including 55/56, 63/64 and exact 64-byte multiples
- output remains stable under backpressure

The current frontend intentionally assembles one message at a time. This is functionally complete but is now the main end-to-end throughput bottleneck for workloads containing long messages.

### `rtl/context/sm3_context_store.sv`

- one pending 512-bit block per context
- one 256-bit chaining state per context
- synchronous dispatch read
- separate payload/state memories
- `ram_style="block"` synthesis hints

### `rtl/context/sm3_multiblock_engine.sv`

Milestone-3 baseline:

- parameterized 8/16 iterative cores
- one inflight + one pending block per Context
- synchronous Context RAM dispatch
- context hash writeback and final digest completion

### `rtl/context/sm3_hybrid_engine.sv`

Adds:

- Single-Block Fast FIFO
- `first && last` messages bypass Context RAM
- Fast:Context weighted arbitration

The Fast Path primarily saves Context resources. Pure single-block throughput was already close to core-pool saturation without it.

### `rtl/context/sm3_sticky_engine.sv`

Adds:

- Sticky-Core continuation for already-prefetched next blocks
- configurable block quantum
- direct completion-hash feedback to the next block
- avoids Context hash write/read on sticky continuations

### `rtl/context/sm3_adaptive_engine.sv`

Current preferred backend:

- Fast FIFO + Multi-Block Context sharing the same Core Pool
- Sticky quantum = 2 while short-message pressure is present
- Sticky quantum = 8 when Fast traffic is idle
- 32-cycle fast-pressure hold window avoids Q2/Q8 oscillation between short-message bursts
- Fast and Multi-Block result tagging

### `rtl/top/sm3_accel_top.sv`

Current end-to-end top:

- raw message descriptor + 128-bit payload input
- hardware block building / SM3 padding
- Context ID allocation/release
- Single-Block bypass
- adaptive 8/16-Core backend
- out-of-order Digest completion identified by Message ID

## Verification

### SM3 core

`tb/test_sm3_core.py`

- known SM3 vectors
- random compression blocks
- random complete messages 0..4096 bytes
- chaining-state verification against Python Golden Model

Latest zero-bubble core regression: **3/3 PASS**.

### Block builder / padding

`tb/test_sm3_block_builder.py`

- 500 random messages
- 3881 generated compression blocks
- explicit padding-boundary vectors
- random payload gaps
- random block-output backpressure
- byte-exact comparison against Python `pad()`

Result: **PASS**.

### Backend scheduling

`tb/test_sm3_hybrid.py`

16-Core representative results before/after scheduling optimization:

| Workload | Backend | Block/cycle | Avg Core util |
|---|---|---:|---:|
| single-block only | adaptive + zero-bubble | 0.237756 | 97.97% |
| mixed | hybrid, no sticky | 0.195918 | 80.88% |
| mixed | adaptive sticky + pressure hold + zero-bubble | 0.203928 | 82.89% |
| short-heavy | hybrid, no sticky | 0.209497 | 86.66% |
| short-heavy | adaptive sticky + pressure hold + zero-bubble | 0.220939 | 90.21% |
| multi-block only | hybrid, no sticky | 0.226535 | 93.45% |
| multi-block only | adaptive sticky + pressure hold + zero-bubble | 0.230988 | 93.85% |

Quantum sweep showed:

- Q2 is better when many short messages are waiting.
- Q8 is better for pure Multi-Block throughput.
- adaptive Q2/Q8 with a recent-fast-traffic hold window gives the best robust mixed behavior observed so far.

### End-to-end raw-message regression

`tb/test_sm3_accel_top.py`

Covers raw descriptors/payloads, hardware padding, Context allocation, 8/16 Core scheduling, random input gaps, result backpressure, and final digest comparison.

Verified:

- 8-Core / 32 Context, short-heavy, 300 messages: **PASS**
- 16-Core / 64 Context, short-heavy, 500 messages: **PASS**
  - 95,676 original payload bytes
  - 79,653 cycles
  - max 16/16 cores occupied
  - 2.402 Gbps effective original-payload rate at 250 MHz
  - 1.569 Mmsg/s
- 16-Core / 64 Context, mixed, 300 messages: **PASS**
  - 271,234 original payload bytes
  - 262,494 cycles
  - max 12/16 cores occupied
  - 2.067 Gbps effective original-payload rate at 250 MHz
  - 0.286 Mmsg/s

The backend itself is much faster than these end-to-end numbers. The gap is caused by the current ingress architecture: one message is assembled at a time and every Context has only one pending block. A long message therefore backpressures the raw input while waiting for its chain state, preventing enough independent messages from accumulating to fill all cores.

## Run

```bash
source scripts/env.sh

# Core
make SIM=verilator

# Padding / block builder
NMSG=500 make -f Makefile.frontend SIM=verilator

# Multi-block baseline
PROFILE=mixed NMSG=250 make -f Makefile.multi CORE_NUM=8 CTX_NUM=32

# Adaptive backend
PROFILE=short_heavy NMSG=1000 make -f Makefile.adaptive CORE_NUM=16 CTX_NUM=64

# Full raw-message top
PROFILE=short_heavy NMSG=500 make -f Makefile.top CORE_NUM=16 CTX_NUM=64
```

Or:

```bash
CORE_NUM=16 CTX_NUM=64 PROFILE=short_heavy NMSG=500 scripts/run_top_cocotb.sh
```

## Next architecture milestone

Do **not** add more SM3 cores yet. The next change should decouple ingress from per-message chaining:

1. replace the one-pending-block-per-Context model with a shared Block Pool;
2. store blocks as 128-bit words so BRAM width is efficient;
3. maintain per-message / per-Context pending-block queues using head/tail pointers;
4. let the raw frontend continue accepting later messages even while an earlier long message waits for its previous hash state;
5. schedule only the head block of each Context, preserving the SM3 chaining invariant;
6. measure how many queued independent Contexts are required to sustain 16 Core occupancy.

This is expected to give a much larger end-to-end gain than further tuning the current core arithmetic or adding more cores.
