# SM3 FPGA Multi-Core Accelerator — Complete Package Index

Date: 2026-10-22

This package collects the complete development history, the latest verified RTL, simulation assets, synthesis assets, offline tool packages, and the full architecture/logic framework for the SM3 FPGA multi-core accelerator developed in this session.

## Recommended current configuration

- 16 iterative SM3 cores
- 32 Message Contexts
- 512-slot Global Block Pool
- 128-bit raw payload frontend
- 1 Round/Cycle per SM3 core
- 65-cycle sustained service interval per block (load + 64 rounds)
- Single-block Fast Path
- Multi-block Context + linked Global Block Pool
- Round-Robin Context scheduling
- Adaptive Sticky scheduling, Q2/Q8
- Out-of-order completion identified by Message ID

## Package layout

- `docs/`
  - `PROJECT_INDEX.md`: this file
  - `LOGIC_FRAMEWORK.md`: complete design logic framework
  - `SYNTHESIS_REPORT.md`: Milestone-6 synthesis report
  - `resource_summary.csv`: 8/12/16-core resource comparison
- `latest/milestone6/`
  - latest verified SystemVerilog RTL
  - Python SM3 golden model
  - cocotb/SystemVerilog testbenches
  - Makefiles and run scripts
  - key simulation logs
  - Yosys UltraScale synthesis scripts and reports
- `history/`
  - `sm3_accel_milestone1.tar.gz` through `sm3_accel_milestone6.tar.gz`
  - early project snapshot
  - curated Milestone-5 working tree containing source, logs, synthesis experiments and benchmark outputs while excluding large regenerable compiler caches
- `tools/`
  - Verilator 5.032 Debian package
  - Verilator 5.048 Debian package
  - cocotb offline Python wheel bundle
  - Yosys 0.52 Debian package
  - Yosys-ABC 0.52 Debian package
- `logs/`
  - convenient copy of key latest simulation and synthesis logs
- `SHA256SUMS.txt`
  - SHA256 checksum for every file in this package except the checksum file itself

## Current verified synthesis results

| Configuration | Mixed throughput @250 MHz | Block/Cycle | Yosys LC | FF | CARRY4 | BRAM18 | BRAM36 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 8 Core / 32 Context | 14.452 Gbps | 0.11805 | 19,667 | 15,074 | 324 | 15 | 4 |
| 12 Core / 48 Context | 20.657 Gbps | 0.16873 | 29,350 | 21,467 | 481 | 15 | 4 |
| 16 Core / 32 Context | 25.394 Gbps | 0.20742 | 32,812 | 26,043 | 551 | 15 | 4 |

DSP usage is zero in the current Yosys UltraScale mapping.

Longer 1000-message mixed stress for the preferred 16-Core/32-Context configuration achieved approximately 0.22978 block/cycle and 28.270 Gbps original-payload throughput at the 250 MHz reference clock, with peak Context occupancy 29/32.

## Important interpretation

Yosys `synth_xilinx -family xcu` results are suitable for architecture/resource comparison but are not a substitute for Vivado implementation. Final KU060/KCU105/VU3P timing, exact LUT/FF/BRAM usage, placement congestion and 250 MHz closure must be determined with Vivado synthesis/place/route.

## Historical milestones

- Milestone 1: Python SM3 golden model + single iterative SM3 core
- Milestone 2: 8/16-core dynamic Core Pool + result arbitration
- Milestone 3: Multi-block Context storage and block-level rescheduling
- Milestone 4: raw-message frontend, SM3 padding, adaptive Sticky scheduling and end-to-end simulation
- Milestone 5: Global Block Pool, Free List, per-Context linked queues, Round-Robin scheduling and high-concurrency stress verification
- Milestone 6: synthesis-oriented RTL optimization, Yosys UltraScale mapping, 8/12/16-core resource comparison and Context-count optimization

## Reproduction starting point

Use `latest/milestone6/` as the working source tree. Historical milestone archives are retained for design evolution and regression comparison.
