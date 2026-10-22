# SM3 FPGA Multi-Core Accelerator — Milestone 5

Verified SystemVerilog/cocotb prototype for many independent SM3 messages using 8/16 iterative cores, a raw-message frontend, a global shared Block Pool, per-Context linked queues, adaptive Sticky-Core scheduling, and out-of-order completion by Message ID.

## Toolchain

- Verilator 5.048
- cocotb 2.1.0
- Python 3.13
- simulation clock: 4 ns (250 MHz reference)

Tool binaries are not included in the source archive.

## Current preferred architecture

```text
128-bit raw message stream
        |
        v
+------------------------+
| sm3_block_builder      |
| SM3 padding / 512b blk |
+-----------+------------+
            |
            | single block (first && last)
            +------------------------------+
            |                              |
            v                              v
   Multi-block Context              Fast FIFO
   allocation / mapping                    |
            |                              |
            v                              |
+--------------------------------------------------+
| Global Block Pool                                |
|                                                  |
|  512 x 512-bit payload slots (default)           |
|  Free List                                       |
|  per-slot next pointer                           |
|                                                  |
|  Context 0: head -> slot -> slot -> ... -> tail  |
|  Context 1: head -> slot -> ...                  |
|  ...                                             |
+-------------------------+------------------------+
                          |
                          v
+--------------------------------------------------+
| Dynamic Scheduler                                |
| - Round-Robin ready Context selection            |
| - Fast:Context weighted arbitration              |
| - adaptive Sticky quantum Q2/Q8                  |
| - one inflight block per Message Context         |
+-------------------------+------------------------+
                          |
              +-----------+-----------+ ...
              v                       v
        iterative Core 0        iterative Core 15
        1 round / cycle         1 round / cycle
              |                       |
              +-----------+-----------+
                          |
                          v
                 Completion / Digest
                 msg_id + 256-bit hash
```

The important invariant is unchanged: **one SM3 message may have at most one compression block inflight**, but it may now have many later blocks queued in the shared pool. This preserves the SM3 chaining dependency while removing the previous one-pending-block ingress bottleneck.

## New Milestone-5 RTL

### `rtl/context/sm3_block_pool.sv`

Global multi-block payload storage:

- parameterized `POOL_DEPTH`;
- default/recommended first implementation: 512 slots;
- one 512-bit SM3 block per slot;
- per-slot `{first,last}` metadata;
- per-slot linked-list `next` pointer;
- circular Free List;
- one allocation and one returned slot may occur in the same cycle;
- synchronous payload read for dispatch;
- payload memory has `ram_style="block"` hint;
- reset does not clear payload BRAM;
- Free List is initialized one slot/cycle after reset.

For `POOL_DEPTH=512`, initialization takes 512 cycles = 2.048 us at 250 MHz. The top-level `desc_ready` is held low until initialization completes.

### `rtl/context/sm3_pool_engine.sv`

Current preferred backend:

- 8/16 parameterized iterative cores;
- global shared Block Pool;
- each Context stores `head`, `tail`, message ID and chaining state;
- many pending blocks may queue behind one inflight block;
- simultaneous enqueue/dequeue of the same Context is handled explicitly;
- block slot is returned to Free List when dispatch has launched its synchronous read;
- Single-Block Fast FIFO bypasses Context/Block Pool;
- Fast:Context quota prevents long-message starvation;
- adaptive Sticky-Core policy:
  - short-message pressure: quantum 2;
  - no short-message pressure: quantum 8;
  - recent-fast hold window avoids oscillation;
- Round-Robin ready-Context selection removes fixed-low-ID starvation risk;
- non-sticky completions write chaining state to Hash RAM;
- sticky continuation bypasses Hash RAM and feeds completion hash directly to the next block;
- final digest releases the Message Context.

### `rtl/top/sm3_accel_top.sv`

- raw descriptor: `msg_id`, original byte length;
- 128-bit payload input;
- hardware padding;
- Message Context allocation/release;
- global pool backend;
- output may complete out-of-order and is matched by Message ID;
- exposes Core occupancy, Context allocation, Fast FIFO level and Block Pool free count for verification/performance measurements.

## Why the Block Pool changes performance so much

Milestone 4 allowed only:

```text
one inflight block + one pending block / Context
```

A 4 KB message therefore stalled the frontend after only two blocks until chaining state advanced. Independent later messages could not enter quickly enough to fill 16 cores.

Milestone 5 instead allows:

```text
Message A: B1 -> B2 -> B3 -> ... -> B65 in global pool
Message B: B1 -> B2 -> ...
Message C: ...
```

Only the queue head is eligible to execute, but the frontend can continue to later messages. This converts BRAM capacity into independent-message concurrency, which is exactly what iterative multi-core SM3 needs.

## Pool depth sweep — 16 Core / 64 Context / mixed workload

Steady-state measurement starts after the one-time Free List initialization. Input/result are driven without random gaps for this depth comparison.

| Pool depth | Block/cycle | Avg Core occupied | Effective payload | Minimum free slots |
|---:|---:|---:|---:|---:|
| 128 | 0.11355 | 7.38 / 16 | 13.902 Gbps | 0 |
| 256 | 0.19172 | 12.46 / 16 | 23.471 Gbps | 0 |
| **512** | **0.21545** | **14.01 / 16** | **26.377 Gbps** | **66** |
| 1024 | 0.21545 | 14.01 / 16 | 26.377 Gbps | 578 |

Conclusion: **512 slots is the first tested point that removes Block Pool capacity as the bottleneck.** 1024 brings no throughput gain for this workload and only consumes more storage.

## BRAM width decision

The previous plan proposed lowering payload storage to 128-bit words. With the global pool, that is no longer an automatic win.

A 512-slot pool contains:

```text
512 slots x 512 bit = 262,144 bit = 32 KiB payload
```

On Xilinx BRAM36, a common configuration is 72 x 512. A logical 512 x 512 memory can therefore be implemented approximately as eight BRAM36 primitives in parallel:

```text
8 x (72 x 512) = 294,912 physical bits
payload utilization ~= 88.9%
```

A 128-bit x 2048 implementation contains the same payload bits and also needs roughly eight BRAM36 primitives after width/depth banking, while adding four-cycle block assembly/read scheduling. Therefore Milestone 5 intentionally keeps the logical 512-bit pool. **Vivado synthesis must still confirm the exact inferred primitive count on the target device.**

## Current verified performance

### 16 Core / 64 Context / 512-slot Pool

1000-message mixed random stress:

- 981,523 original payload bytes;
- 15,956 compression blocks;
- random input gaps;
- random result backpressure;
- Context reuse and Free List wraparound;
- final resource-reclamation assertions enabled;
- **PASS**;
- `0.22978 block/cycle`;
- average occupied cores: `14.94 / 16`;
- effective original-payload throughput: **28.270 Gbps @ 250 MHz**;
- message rate: **3.600 Mmsg/s**.

For the current core, a new block has an actual service interval of 65 cycles (load + 64 rounds), so the 16-core theoretical compression issue ceiling is:

```text
16 / 65 = 0.24615 block/cycle
```

The observed stress result is therefore about **93.35% of that block-rate ceiling**.

Its compression-block traffic corresponds to approximately:

```text
0.22978 x 512 x 250 MHz = 29.41 Gbps
```

Padding explains the difference between compression traffic and the 28.27 Gbps original-payload number.

### 8 Core / 32 Context / 512-slot Pool

500-message mixed random stress:

- 8/8 cores reached occupancy;
- `0.11858 block/cycle`;
- average occupied cores: `7.71 / 8`;
- effective payload: **14.595 Gbps @ 250 MHz**;
- message rate: **1.834 Mmsg/s**;
- **PASS**.

8-core theoretical block ceiling is `8/65 = 0.12308 block/cycle`; the observed block rate is about **96.35%** of that ceiling.

### Message-mix examples, 16 Core / 512 Pool

Ideal input/result readiness used to separate architectural limits from artificial testbench gaps:

| Profile | Messages | Effective payload | Message rate |
|---|---:|---:|---:|
| single/short-biased test set | 500 | 10.445 Gbps | 23.997 Mmsg/s |
| short-heavy | 500 | 18.037 Gbps | 11.782 Mmsg/s |
| mixed | 300 | 26.377 Gbps | 3.647 Mmsg/s |

Payload Gbps is intentionally lower for tiny messages because every message still consumes at least one full 512-bit SM3 compression block.

## Verification checks now enforced

The end-to-end cocotb test checks:

- final digest equals Python SM3 Golden Model;
- no unknown or duplicate Message ID result;
- output data is stable while `valid && !ready`;
- all submitted messages eventually complete;
- final Context allocation bitmap is zero;
- final Fast FIFO level is zero;
- final Block Pool free count returns exactly to `POOL_DEPTH`;
- RTL raises an error if a final block commits while later blocks are still queued for that Context.

The 1000-message stress run exercises enough blocks to wrap the Free List many times.

## Main source files

```text
rtl/core/sm3_core.sv
rtl/front_end/sm3_block_builder.sv
rtl/context/sm3_block_pool.sv       # new
rtl/context/sm3_pool_engine.sv      # new preferred backend
rtl/top/sm3_accel_top.sv            # now uses pool engine
model/sm3_ref.py
tb/test_sm3_accel_top.py
Makefile.top
```

Older context/hybrid/adaptive engines are retained as comparison baselines.

## Run

```bash
source scripts/env.sh

# 16-Core / 64-Context / recommended 512-slot pool
PROFILE=mixed NMSG=1000 \
make -f Makefile.top CORE_NUM=16 CTX_NUM=64 POOL_DEPTH=512

# Ideal-interface benchmark
PROFILE=mixed NMSG=300 DRIVE_PROB=100 READY_PROB=100 \
make -f Makefile.top CORE_NUM=16 CTX_NUM=64 POOL_DEPTH=512

# 8-Core configuration
PROFILE=mixed NMSG=500 \
make -f Makefile.top CORE_NUM=8 CTX_NUM=32 POOL_DEPTH=512
```

## Recommended next milestone

Do not add 32 cores yet. The current 8/16-core datapath is already close to its iterative-core ceiling. The next useful work is **implementation realism and timing/resource closure**:

1. run Vivado synthesis on the actual target FPGA and confirm BRAM inference for the 512 x 512 Block Pool and Context Hash RAM;
2. inspect the SM3 round critical path (`TT1`, `TT2`, `SS1`) and determine real Fmax;
3. add synthesis-friendly pipelining/CSA only if Fmax misses target;
4. replace linear combinational `for` scans for Core/Context selection with hierarchical priority/RR arbitration if timing requires it;
5. add per-message latency counters/P99 measurements, not only aggregate throughput;
6. after resource/Fmax data is known, decide whether 16 cores is the best throughput/LUT point or whether 8/12/16 should be selected per device.


## Milestone 6: Yosys UltraScale synthesis

Yosys 0.52 (`synth_xilinx -family xcu`) is now part of the regression flow. Synthesis-driven rewrites ensure that the global block pool, free-list/link metadata, hash context, and Fast FIFO infer FPGA memories instead of large FF/mux networks. The recommended baseline is now `CORE_NUM=16`, `CTX_NUM=32`, `FAST_DEPTH=32`, `POOL_DEPTH=512`.

Full Yosys results:

- 8 Core / 32 Context: 19,667 estimated LC, 15,074 FF, 324 CARRY4, 15 RAMB18E2, 4 RAMB36E2; mixed workload 14.452 Gbps.
- 12 Core / 48 Context: 29,350 estimated LC, 21,467 FF, 481 CARRY4, same BRAM footprint; mixed workload 20.657 Gbps.
- 16 Core / 32 Context: 32,812 estimated LC, 26,043 FF, 551 CARRY4, same BRAM footprint; mixed workload 25.394 Gbps.
- 16 Core / 32 Context 1000-message stress: 28.270 Gbps, 0.22978 block/cycle, peak context occupancy 29/32.

These are synthesis estimates, not placed-and-routed timing results. Vivado is required for device-specific utilization, timing and Fmax. See `synth/SYNTHESIS_REPORT.md`.
