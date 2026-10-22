# SM3 Multi-Core Accelerator — Yosys UltraScale Synthesis Report

## Scope

- Tool: Yosys 0.52 + yosys-abc 0.52
- Target family: Xilinx UltraScale (`synth_xilinx -family xcu`)
- I/O pads and clock buffer insertion disabled (`-noiopad -noclkbuf`)
- RTL: iterative 1-round/cycle SM3 cores, 128-bit message frontend, shared 512-slot block pool, adaptive sticky scheduler.
- These figures are synthesis estimates. Final KU060/KCU105/VU3P Fmax and exact utilization require Vivado synthesis/place-and-route.

## Synthesis-driven RTL changes

1. Moved the 512-slot payload pool into an isolated reset-free synchronous RAM process so it infers Block RAM.
2. Split `free_fifo` and linked-list `next_mem` into independent RAM processes; removed unnecessary self-link writes.
3. Rewrote the 128-bit frontend from dynamic 512-bit byte insertion into four fixed 128-bit lanes. This reduced the frontend ABC input network from ~98k gates to ~8.7k gates while keeping regression results unchanged.
4. Narrowed Context/Core selectors from SystemVerilog `integer` to `$clog2()`-sized vectors.
5. Split the 32-entry Fast FIFO payload/tag arrays into dedicated reset-free distributed-RAM processes. They now map to LUTRAM instead of ~16k payload FF bits.
6. Reduced the recommended 16-Core configuration from 64 Contexts to 32 after simulation showed identical throughput and a 1000-message stress peak occupancy of only 29 Contexts.

## Full synthesis results

| Configuration | Mixed payload @250 MHz | Block/cycle | Estimated LCs | FF | CARRY4 | RAMB18E2 | RAMB36E2 | RAM32M16 | RAM64M8 | DSP |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 Core / 32 Context / Pool512 | 14.452 Gbps | 0.11805 | 19,667 | 15,074 | 324 | 15 | 4 | 41 | 32 | 0 |
| 12 Core / 48 Context / Pool512 | 20.657 Gbps | 0.16873 | 29,350 | 21,467 | 481 | 15 | 4 | 41 | 32 | 0 |
| 16 Core / 32 Context / Pool512 | 25.394 Gbps | 0.20742 | 32,812 | 26,043 | 551 | 15 | 4 | 41 | 32 | 0 |

For 16 Core / 32 Context, the longer 1000-message mixed stress reaches 28.270 Gbps / 0.22978 block/cycle with peak Context occupancy 29/32.

## 16-Core resource breakdown

- Iterative SM3 core (`TAG_W=38`): ~1,514 LC per core, ~1,366 FF, 28 CARRY4, no DSP.
- 16 cores therefore dominate the datapath resource budget.
- Block Builder: about 2,047 LC after fixed-lane rewrite.
- Shared Block Pool data: 15 RAMB18E2 for 512 x 514-bit payload/flags.
- Hash Context RAM: 4 RAMB36E2 in Yosys' selected width/depth mapping.
- Pool free-list / link metadata and Fast FIFO use distributed RAM primitives.

## Context-count result

16 Core / 64 Context had identical mixed throughput but a Core-blackbox peripheral estimate of 12,182 LC. Reducing to 32 Contexts lowered the peripheral estimate to 6,513 LC (about 46.5% lower) without throughput loss in the tested workload. The 1000-message stress peaked at 29 Contexts, so 32 is the recommended default while retaining `CTX_NUM` as a build-time parameter.

## Current recommendation

On the identical 300-message mixed workload, payload-per-kLC is approximately 0.735 Gbps/kLC (8 Core), 0.704 Gbps/kLC (12 Core / 48 Context), and 0.774 Gbps/kLC (16 Core / 32 Context). The 16/32 point therefore gives both the highest throughput and the best resource efficiency among these three tested configurations.

Use `CORE_NUM=16`, `CTX_NUM=32`, `FAST_DEPTH=32`, `POOL_DEPTH=512` as the next Vivado baseline. Use 8 Core if area/power is more important than peak throughput. Do not increase Core count further before Vivado timing/place-route establishes the actual critical path and routing margin.
