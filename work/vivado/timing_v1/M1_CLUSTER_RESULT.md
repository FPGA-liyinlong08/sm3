# M1 Cluster Split Result — 16 Cores at 250 MHz

- Date: 2026-10-23
- Branch: `experiment/sm3-cluster-scaling`
- Tool: Vivado 2021.2
- Part: `xcku060-ffva1156-2-e`
- Planning reference: `SM3_HIGH_DENSITY_TIMING_ARCHITECTURE_PLAN.md`
- **Decision: choose 2 clusters × 8 cores. Reject 4 clusters × 4 cores.**
- **Timing status: the best 2×8 layout is post-route WNS `-0.076 ns`, TNS `-1.449 ns`, 57 failing endpoints. It is not a 250 MHz sign-off. The frozen v42 + ECO1 DCP remains the signed-off design at `+0.001 ns`.**

This report covers the M1 comparison only: same 16 cores, same 32 contexts, same part, clock, XDC and OOC methodology; only the cluster hierarchy changes. No v42/ECO1 RTL, constraints, flow script or final DCP was modified.

## 1. Scope and sign-off rules

- The M1 sign-off metric is **internal register-to-register timing** at 250 MHz (4.000 ns).
- Data-input-to-register, register-to-data-output, input-to-output and the corresponding hold paths are false-pathed, exactly as in the frozen v42 internal sign-off flow.
- The top-level 1 ns I/O budget is **not** modeled; no result here is a full-chip I/O sign-off.
- Post-synth negative WNS stops the candidate before place/route. This is why 4×4 has synthesis results but no P&R results.
- The frozen v42 + ECO1 final DCP is untouched:
  - `work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp`
  - SHA256 `16a2ed98f64128ce27fe40f4dd0698092ccf38c14d60b149695b8f2dcfdbbc0f`
  - internal WNS `+0.001 ns`, WHS `+0.015 ns`, TNS/THS `0`.

## 2. RTL, parameters and reproducibility

### 2.1 Parameters

| Parameter | 4×4 | 2×8 |
|---|---:|---:|
| `CORE_NUM` | 16 | 16 |
| `CTX_NUM` | 32 | 32 |
| `FAST_DEPTH` | 32 | 32 |
| `POOL_DEPTH` | 512 | 512 |
| `CLUSTER_NUM` | 4 | 2 |
| `CORE_PER_CLUSTER` | 4 | 8 |

Both variants use `sm3_accel_cluster_top`, the local builder/pool/engine cluster, and the same per-cluster RTL. The only top-level RTL change for M1 is the registered allocator in `sm3_accel_cluster_top.sv`:

- registered `cl_load_q` and `cl_ctx_count_q` snapshot of cluster status;
- registered `sel_q`/`sel_valid_q` selection, held until the descriptor handshake;
- the selected cluster's current `descriptor_ready` still gates the handshake, so a stale context count cannot force an invalid descriptor into a full cluster.

The split itself was not changed to work around the Verilator 5.020 four-cluster crash. The 2×8 final regression uses a simulator-only `-O0/--O0` build; the cluster split is unchanged.

### 2.2 Archived inputs

| Item | Value |
|---|---|
| Base git HEAD used by the synthesis/P&R runs | `82dd611574623117cce745a066d39663b6eb097a` |
| M1 top RTL SHA256 | `cc7175f398b0f6794f385c59c199672e5696871901709fc5a6c2d37c724896fb` |
| XDC | `work/vivado/top_16c_32ctx/top_16c_32ctx.xdc` |
| XDC SHA256 | `4d64715b56b72d0deedbd96c913de1e861b6c50a03df1026354c6eea60a51222` |
| Synthesis | default directive, `flatten_hierarchy=rebuilt`, `mode=out_of_context` |
| P&R | `opt_design -directive Explore`, `place_design -directive Explore`, `phys_opt_design -directive AggressiveFanoutOpt`, `route_design -directive Explore`, post-route `phys_opt_design -directive AggressiveExplore` |
| Seed | default |
| Threads | `maxThreads 6` |
| Clock source | `HD.CLK_SRC BUFGCTRL_X0Y0` on `clk` |
| Pblock layout | `pb_cluster_builders = SLICE_X18Y30:SLICE_X38Y90`, `CONTAIN_ROUTING=0` |

The full per-file RTL SHA list, run date and dirty-tree state are in each `manifest.md`; the measurements were taken with the M1 RTL above on top of base commit `82dd611`. The M1 RTL, flow scripts and this report are committed together after the runs.

## 3. Synthesis gate

| Variant | Raw WNS | Internal WNS | TNS | Failing endpoints | WHS | LUT | FF | BRAM | Control sets | Gate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 4×4 | `-1.752 ns` | `-0.631 ns` | `-1.263 ns` | 2 | `+0.034 ns` | 38,234 | 43,177 | 46 | 699 | **stop; no P&R** |
| 2×8 | `+0.666 ns` | `+0.666 ns` | `0.000 ns` | 0 | `+0.034 ns` | 31,732 | 34,022 | 23 | 511 | **proceed** |

Synthesis DCPs:

| Variant | DCP | SHA256 |
|---|---|---|
| 4×4 | `m1_cluster_4x4/synth/top_m1_cluster_post_synth.dcp` | `8624569653941abb2ed33bc4b1bd2ca985c7c453fb30496608bd24a3887ac1e2` |
| 2×8 | `m1_cluster_2x8/synth/top_m1_cluster_post_synth.dcp` | `dd3b21f0568c1c15d4c08756a9befe145357943f3cfd810ff9298477cb19421b` |

### 3.1 Critical-path interpretation

- **4×4 critical path:** `u_clusters[0].u_cluster/u_block_builder/active_reg` → `sel_q_reg[0]`, 4.605 ns, 12 logic levels (logic 1.403 ns, route 3.202 ns), slack `-0.631 ns`. The four-cluster top allocator is the critical path.
- **2×8 critical path:** `u_clusters[0].u_cluster/u_engine/g_core[1].u_core/e_reg[1]` → `a_reg[29]`, 3.308 ns, 11 logic levels (logic 1.580 ns, route 1.728 ns), slack `+0.666 ns`. The two-cluster allocator is not critical; the local core path is.

The architectural result is direct: doubling the cluster count from 2 to 4 at fixed total core count turns the cross-cluster selection into the failing path and increases both allocator fanout and resource replication. The 4×4 candidate is rejected at the synthesis gate.

## 4. 2×8 place and route — two layouts

Both layouts use the same netlist, constraints, directives, default seed and clock source. Only the builder pblock differs.

| Metric | `none` | `pblock` |
|---|---:|---:|
| Post-place raw WNS | `-1.171 ns` | `-0.786 ns` |
| Post-place internal WNS | `-0.744 ns` | `-0.485 ns` |
| Post-route internal WNS | `-0.192 ns` | **`-0.076 ns`** |
| Post-route TNS | `-12.375 ns` | **`-1.449 ns`** |
| Post-route failing endpoints | 244 | **57** |
| Post-route WHS | `+0.008 ns` | **`+0.013 ns`** |
| Post-route THS | `0.000 ns` | `0.000 ns` |
| LUT | 32,731 | 32,566 |
| FF | 34,173 | 34,168 |
| BRAM | 23 | 23 |
| CLB | 6,335 | 6,889 |
| Routed DCP SHA256 | `ce55c251db84651d1126382ef79dba8bbf06aff0fc086978baa4990181157832` | `184b3cfc3f11578cef61b625900249cd1e37cbce9b3617b317347bda91c12b46` |

The pblock layout is the better candidate: it cuts the failing endpoints from 244 to 57, TNS from `-12.375` to `-1.449 ns`, and improves hold margin slightly. It costs 554 additional CLBs, with essentially unchanged LUT/FF and the same 23 BRAMs.

### 4.1 Critical path and clock skew

- **`none`:** core `e_reg[16] → hash_out_reg[231]`, data path 3.782 ns (logic 1.232 / route 2.550), 7 levels, clock skew `-0.385 ns`, slack `-0.192 ns`.
- **`pblock`:** core `e_reg[10] → hash_out_reg[252]`, data path 3.917 ns (logic 1.461 / route 2.456), 10 levels, clock skew `-0.134 ns`, slack `-0.076 ns`.

The pblock does not shorten the core logic; it mainly improves clock skew (source/destination clock delays) and reduces the number of simultaneously failing core paths. The remaining failure is still a local SM3 core path, not the cluster allocator.

### 4.2 Physical quality of the selected pblock layout

- Route status: 49,430 routable nets, **all fully routed**, 0 routing errors.
- DRC: 0 errors, 2 warnings (configuration-bank CFGBVS/CONFIG_VOLTAGE property, and RTSTAT-10 no-load nets). The no-load nets are outputs/debug/static nets, not timing paths.
- Methodology: 593 warnings, dominated by existing SYNTH-6 replication warnings; no methodology error was treated as a timing sign-off criterion.
- Congestion: no placer congestion windows above level 5 in `post_route_congestion.rpt`. The router logged CLB utilization pressure and generated `iter_*` diagnostics, but completed routing with 0 errors.
- Control sets: 467 in the routed pblock design (511 at synthesis, 699 for 4×4).
- High fanout in the selected pblock: reset `33,578`; the core `h` network is `806` (worst slack `+0.111 ns`). The synthesis report additionally flags `core_launch_tag[36]` at `6,217` before physical optimization. CLK/RESET/CE were not mixed into the data-fanout metric.
- Unconstrained internal endpoints: 0; the input/output false paths are the declared M1 sign-off convention.

## 5. Function and throughput

### 5.1 Functional coverage

The complete regression is the shared cocotb test with golden digest checking, message ID checking, duplicate/loss checking and final resource-release checking.

- On base RTL `82dd611`, **both 4×4 and 2×8 passed all five cases**: 40 mixed, 24 boundary, 40 backpressure, 1000 mixed, 1000 long-heavy.
- The final 2×8 registered-allocator RTL `cc7175` passed all five cases with the simulator-only `-O0/--O0` build.
- The final 4×4 registered-allocator RTL was gated out by post-synth timing and received no P&R. Its four-cluster Verilator 5.020 model still crashes at `--O0/-O0`; this is recorded as a simulator limitation, not a reason to change the split. The 4×4 intermediate registered-selection/load-register RTL passed 40 mixed at 5,719 cycles / 10.055 Gbps, and the 4×4 base RTL passed the full regression.
- No 4×4 P&R, no 4×4 final sign-off attempt, and no v42 modification were made.

### 5.2 Measured throughput

All figures are from the same 16-core / 32-context / 512-block-pool configuration. `cycles` is the end-to-end test duration; Gbps and Mmsg/s are payload throughput.

| Case | 4×4 base `82dd611` | 2×8 base `82dd611` | 2×8 final `cc7175` |
|---|---:|---:|---:|
| 40 mixed | 5,686 cyc / 10.114 Gbps / 1.759 Mmsg/s | 5,686 / 10.114 / 1.759 | 5,721 / 10.052 / 1.748 |
| 24 boundary | 5,184 / 5.360 / 1.157 | 5,184 / 5.360 / 1.157 | 5,209 / 5.335 / 1.152 |
| 40 backpressure | 6,283 / 9.153 / 1.592 | 6,291 / 9.141 / 1.590 | 7,128 / 8.068 / 1.403 |
| 1000 mixed | 78,157 / 25.117 / 3.199 | 71,779 / 27.348 / 3.483 | **72,267 / 27.164 / 3.459** |
| 1000 long-heavy | 146,188 / 25.816 / 1.710 | 134,354 / 28.090 / 1.861 | **134,291 / 28.103 / 1.862** |

The 40-message mixed and 24-message boundary cases are essentially tied; they are too short to expose the steady-state cluster effect. The 40-message backpressure case is a stability stress, not a throughput comparison. The 1000-message sustained cases are the decision basis:

- Same-RTL base comparison: 2×8 uses **8.16% fewer cycles** on 1000 mixed and **8.09% fewer cycles** on 1000 long-heavy than 4×4.
- Final 2×8 vs 4×4 base: **7.54% fewer cycles** on mixed, **8.14% fewer** on long-heavy; **+8.15%** and **+8.86%** payload Gbps respectively.
- The registered allocator costs the 2×8 about **0.6–0.7%** on the mixed workloads (5,686 → 5,721 cycles for 40 mixed; 71,779 → 72,267 for 1000 mixed) and is neutral on long-heavy (134,354 → 134,291 cycles).
- The final 2×8 still beats the 4×4 base despite that allocator cost.

Occupancy/utilisation observations for the 1000-message cases:

- 4×4 base, mixed: `avg_core=13.88`, `max_core=16`, `max_ctx=26`, `min_pool_free=167`.
- 2×8 final, mixed: `avg_core=15.01`, `max_core=16`, `max_ctx=31`, `min_pool_free=108`.
- 4×4 base, long-heavy: `avg_core=14.01`, `max_core=16`, `max_ctx=23`, `min_pool_free=135`.
- 2×8 final, long-heavy: `avg_core=15.25`, `max_core=16`, `max_ctx=27`, `min_pool_free=91`.

The 2×8 keeps the cores busier and uses more of the context/pool capacity, but it does not exhaust either resource: 108 and 91 of 512 pool entries remain free in the two 1000-message runs, and the highest observed context count is 31 of 32. The backpressure run is a stability stress, not a throughput comparison; it passes with all outputs checked.

## 6. Resource, congestion and control comparison

| Resource / quality | 4×4 synthesis | 2×8 synthesis | 2×8 P&R `none` | 2×8 P&R `pblock` |
|---|---:|---:|---:|---:|
| LUT | 38,234 | 31,732 | 32,731 | 32,566 |
| FF | 43,177 | 34,022 | 34,173 | 34,168 |
| BRAM | 46 | 23 | 23 | 23 |
| CLB | not placed | not placed | 6,335 | 6,889 |
| Control sets | 699 | 511 | — | 467 |
| Replicated builder/pool | 4 / 4 | 2 / 2 | 2 / 2 | 2 / 2 |
| Congestion windows > level 5 | not placed | not placed | none reported | none reported |

Relative to 2×8 synthesis, 4×4 costs **+20.5% LUT, +26.9% FF, +100% BRAM, +36.8% control sets**. That is the expected cost of four builder/pool copies and four local schedulers. The 4×4 candidate is larger and slower at the same core count; it has no physical-layout result because its post-synth WNS is negative.

The 4×4 synthesis congestion report correctly says congestion data is unavailable until placement. It would be incorrect to claim a post-route congestion comparison for 4×4; no P&R was run by design.

## 7. Decision

### 7.1 Split choice

**Choose 2 clusters × 8 cores for the next cluster step.**

Reasons:

1. 2×8 passes the post-synth gate at `+0.666 ns` with 0 failing endpoints; 4×4 fails at `-0.631 ns` and never reaches P&R.
2. 2×8 uses less logic, fewer registers, half the BRAM and fewer control sets than 4×4.
3. 2×8 is about 8% faster on sustained mixed/long-heavy traffic; the short 40-message cases are tied.
4. The 2×8 builder-pblock layout is materially better than the unconstrained layout (`-0.076` vs `-0.192 ns`) and is the best M1 physical candidate.

**Reject 4 clusters × 4 cores.** The extra cluster count does not improve throughput and turns the cluster allocator into the critical path.

### 7.2 Timing sign-off status

The selected 2×8 pblock layout is **not** a 250 MHz sign-off:

- WNS `-0.076 ns`
- TNS `-1.449 ns`
- 57 failing endpoints
- WHS `+0.013 ns`, THS `0.000 ns`
- critical path: local core `e_reg[10] → hash_out_reg[252]`, 3.917 ns, 10 levels, skew `-0.134 ns`

The gap to the 250 MHz zero-slack boundary is **76 ps**; relative to the frozen v42 `+0.001 ns` reference it is **77 ps**. The 2×8 candidate therefore must not be presented as a signed-off replacement for v42, and no bitstream/sign-off claim should be made from it.

### 7.3 Next actions

1. Keep the frozen v42 + ECO1 DCP as the signed-off baseline. Do not modify it.
2. Perform a dedicated 2×8 post-route core-path/clock optimization, analogous in scope to the v42 ECO1 (local placement/reroute on the failing core path), or add a third layout that reduces the local core clock skew while preserving the builder pblock. The failing path is local to a core; the cluster allocator is no longer the limiter.
3. Re-run the complete functional regression and the full P&R flow after any RTL, constraint or physical change.
4. Do not expand to 32/64 cores until the 2×8 250 MHz closure is achieved with 0 failing endpoints and checked DRC/unconstrained paths.

## 8. Artifacts and reproduction

### 8.1 M1 artifacts

| Artifact | Path / SHA256 |
|---|---|
| 4×4 synthesis manifest | `work/vivado/timing_v1/m1_cluster_4x4/synth/manifest.md` |
| 4×4 post-synth DCP | `m1_cluster_4x4/synth/top_m1_cluster_post_synth.dcp` — `8624569653941abb2ed33bc4b1bd2ca985c7c453fb30496608bd24a3887ac1e2` |
| 2×8 synthesis manifest | `work/vivado/timing_v1/m1_cluster_2x8/synth/manifest.md` |
| 2×8 post-synth DCP | `m1_cluster_2x8/synth/top_m1_cluster_post_synth.dcp` — `dd3b21f0568c1c15d4c08756a9befe145357943f3cfd810ff9298477cb19421b` |
| 2×8 `none` manifest | `work/vivado/timing_v1/m1_cluster_2x8/place_route_none/manifest.md` |
| 2×8 `none` routed DCP | `m1_cluster_2x8/place_route_none/top_m1_cluster_routed.dcp` — `ce55c251db84651d1126382ef79dba8bbf06aff0fc086978baa4990181157832` |
| 2×8 `pblock` manifest | `work/vivado/timing_v1/m1_cluster_2x8/place_route_pblock/manifest.md` |
| **2×8 `pblock` final candidate DCP** | `m1_cluster_2x8/place_route_pblock/top_m1_cluster_routed.dcp` — `184b3cfc3f11578cef61b625900249cd1e37cbce9b3617b317347bda91c12b46` |
| Frozen v42 + ECO1 DCP | `route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp` — `16a2ed98f64128ce27fe40f4dd0698092ccf38c14d60b149695b8f2dcfdbbc0f` |

The M1 output directories and DCPs are intentionally ignored by git; the SHAs above identify the exact routed checkpoints. The frozen v42 DCP is likewise on disk and untouched.

### 8.2 Reproduction commands

Synthesis:

```bash
cd work/vivado/timing_v1
vivado -mode batch -nojournal -nolog -notrace \
  -source run_m1_synth.tcl -tclargs 4
vivado -mode batch -nojournal -nolog -notrace \
  -source run_m1_synth.tcl -tclargs 2
```

Place and route (2×8, both required layouts):

```bash
vivado -mode batch -nojournal -nolog -notrace \
  -source run_m1_place_route.tcl -tclargs 2 none
vivado -mode batch -nojournal -nolog -notrace \
  -source run_m1_place_route.tcl -tclargs 2 pblock
```

Functional regression (2×8 final RTL; simulator-only `-O0/--O0` build):

```bash
cd sm3_fpga/latest/milestone6
make -f Makefile.top_cluster CLUSTER_NUM=2 CORE_NUM=16 CTX_NUM=32 \
  FAST_DEPTH=32 POOL_DEPTH=512 NMSG=1000 PROFILE=mixed SIM=verilator
make -f Makefile.top_cluster CLUSTER_NUM=2 CORE_NUM=16 CTX_NUM=32 \
  FAST_DEPTH=32 POOL_DEPTH=512 NMSG=1000 PROFILE=long_heavy SIM=verilator
```

The 4×4 final registered-allocator RTL is not run through Verilator because of the documented four-cluster 5.020 crash; 4×4 is already excluded by the synthesis gate.

## 9. Final sign-off statement

The M1 comparison is complete: **2×8 is the selected cluster split; 4×4 is rejected.** The 2×8 pblock layout is the best physical candidate at `-0.076 ns`, but it is **not** a 250 MHz sign-off. The frozen v42 + ECO1 DCP remains the signed-off design at `+0.001 ns`. Closing the remaining 76 ps on the 2×8 local core path is the next required step before any 32/64-core expansion.
