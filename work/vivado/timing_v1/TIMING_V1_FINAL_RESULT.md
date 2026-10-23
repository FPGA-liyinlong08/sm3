# Timing Pipeline V1 — 250 MHz 最终时序收敛报告

- 日期：2026-10-23
- Vivado：2021.2
- 器件：`xcku060-ffva1156-2-e`
- 目标：250 MHz / 4.000 ns
- 配置：`CORE_NUM=16`、`CTX_NUM=32`、`FAST_DEPTH=32`、`POOL_DEPTH=512`
- 最终结论：**顶层内部 reg-to-reg WNS `+0.001 ns`、WHS `+0.015 ns`，TNS/THS 均为 0，所有用户时序约束满足。**

## 1. 最终指标

| 阶段 | WNS (ns) | TNS (ns) | 失败端点 | WHS (ns) | THS (ns) |
|---|---:|---:|---:|---:|---:|
| `main` 基线综合 | -4.548 | -14,970.275 | 6,856 | +0.034 | 0.000 |
| v42 综合 (`synth_v38`) | +0.568 | 0.000 | 0 | +0.034 | 0.000 |
| v42 布局 (`place_v42`) | -0.114 | -4.212 | 155 | -0.082 | -0.785 |
| v42 布线 (`route_v42_internal`) | -0.070 | -0.202 | 5 | +0.015 | 0.000 |
| v42 post-route physopt | -0.009 | -0.009 | 1 | +0.015 | 0.000 |
| ECO1：挪动 Tj 关键位并重布线 | -0.028 | -0.075 | 6 | +0.015 | 0.000 |
| **ECO1 + physopt（最终）** | **+0.001** | **0.000** | **0** | **+0.015** | **0.000** |

最终顶层时序提升：

```text
基线 main 综合 WNS      -4.548 ns
最终布线内部 WNS         +0.001 ns
提升                     4.549 ns
```

说明：

- 基线 `main` 的综合 WNS 已经很负，按“综合发现时序问题就不做布局布线”的原则没有继续 P&R。
- 最终 v42 综合到布线的代价为 `+0.568 -> +0.001 ns`，主要由布局/布线拥塞和跨核提交路径造成。
- 最终 sign-off 口径为**内部 reg-to-reg 时序**，对数据输入/输出端口施加 false path；未建模的顶层 I/O 延迟不计入该 WNS。
- 最终裕量只有 **1 ps**，满足 250 MHz，但属于边界收敛；任何后续 RTL/约束改动都应重新跑完整 P&R。

## 2. 最终报告与 checkpoint

- 最终 checkpoint：`work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp`
- 最终 summary：`work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_summary_eco_physopt.rpt`
- 最终 setup 路径：`work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_max_eco_physopt.rpt`
- 最终 hold 路径：`work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_min_eco_physopt.rpt`

最终 summary 原文：

```text
WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints   WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints
+0.001       0.000                       0                63808      +0.015       0.000                       0               63808

All user specified timing constraints are met.
```

### 最终最差 setup 路径

```text
Source:      u_engine/g_core[5].u_core/a_reg[27]/C
Destination: u_engine/g_core[5].u_core/hash_out_reg[235]/D
Data Path:   3.853 ns  (logic 1.378 / route 2.475)
Clock Skew:  -0.120 ns
Uncertainty: 0.085 ns
Slack:       +0.001 ns (MET)
```

第二条路径 slack `+0.002 ns`，同样处于临界状态。

### 最终最差 hold 路径

```text
Source:      u_engine/g_core[1].u_core/hash_base_reg[66]/C
Destination: u_engine/g_core[1].u_core/hash_out_reg[66]/D
Data Path:   0.149 ns
Slack:       +0.015 ns (MET)
```

## 3. 最终 RTL（v42）

最终 RTL 就是 v42 版本，不包含后续实验性的 hash pipeline、staging 或 Tj 拆分：

- `sm3_fpga/latest/milestone6/rtl/top/sm3_accel_top.sv`
  - block builder 与 engine 之间的两级 head FIFO；
  - 寄存化 context grant（`alloc_grant_valid/ctx_id`）；
  - FIFO head 提前一拍分配 context（`head_ctx_valid_q/head_ctx_id_q`）；
  - 切断 `free_bitmap -> bb_ready` 和 `core_out_valid -> commit -> ctx_head` 的组合链。
- `sm3_fpga/latest/milestone6/rtl/core/sm3_core.sv`
  - `in_ready = ~busy & ~out_valid`，切断 `core_out_valid -> commit_accept -> core_out_ready -> core_in_ready -> scheduler -> ctx_head` 的组合环；
  - `tt1/tt2` 保持 v42 的 `(ff+d) + (ss2+wpj)` 分组。
- `sm3_fpga/latest/milestone6/rtl/front_end/sm3_block_builder.sv`
  - 使用 `out_slot_ready_q` 寄存输出 slot ready，切断 builder 内部计数到引擎 ready 的长组合路径。
- `sm3_fpga/latest/milestone6/rtl/context/sm3_pool_engine.sv`
  - context 分配、launch/commit 与 link 写侧的寄存化/仲裁改动。

最终 RTL 的 v42 综合结果：WNS `+0.568 ns`、WHS `+0.034 ns`，所有约束满足。

## 4. 物理收敛过程（post-route ECO）

1. **v42 综合、布局、布线**：综合 `+0.568`，布局 `-0.114`，布线 `-0.070`。
2. **post-route `phys_opt_design -directive AggressiveExplore`**：WNS 从 `-0.070` 提升到 `-0.009`，只剩一个失败端点：
   - `u_engine/g_core[9].u_core/tj_rot_q_reg[9] -> hash_out_reg[246]`，slack `-0.009 ns`。
3. **ECO1：只移动关键 Tj 位**
   - 在已有 v42 布线 checkpoint 上执行：
   ```tcl
   place_cell [get_cells u_engine/g_core[9].u_core/tj_rot_q_reg[9]] \
              [get_sites SLICE_X4Y152]
   route_design -directive Explore
   ```
   - 该寄存器最终落在 `SLICEM.AFF2`，`IS_LOC_FIXED=1`，紧邻 `ss1` 低半加法的 LUT/CARRY 链；
   - 重布线后 WNS `-0.028`，失败路径转移到 core[4]/core[5]，但原 core[9] 的 Tj 路径已消失。
4. **ECO1 + `phys_opt_design -directive AggressiveExplore`**
   - 最终 WNS `+0.001 ns`，TNS `0.000`，WHS `+0.015 ns`；
   - 第二次 `phys_opt_design -directive AggressiveExplore` 结果仍为 `+0.001`，没有进一步收益，最终采用第一次 physopt 的 checkpoint。

关键点：**这个 ECO 必须发生在 post-route 的既有 v42 布局上**。如果改为在布局阶段给该 cell 加 LOC（`place_v53`），placer 会把 core[9] 放到 `X19Y124`，WNS 反而变成 `-0.276 ns`。因此最终交付以 `route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp` 为准，RTL 中不写这个 LOC。

## 5. 功能回归

### Core 回归

最终 v42 core 的 3 个测试全部通过：

```text
test_sm3_core_local.known_vectors                 PASS
test_sm3_core_local.random_compression_blocks     PASS
test_sm3_core_local.random_messages_0_to_4096     PASS
3/3 passed
```

### 顶层回归

最终 v42 top 在 `16 cores / 32 contexts / 512 pool` 下通过：

```text
SM3 E2E PASS: messages=100, payload_bytes=28488, cycles=6043
max_core=16, max_ctx=17, max_fast=5, min_pool_free=305
blocks=510, block/cycle=0.08440, avg_core=5.74
avg_ready_ctx=0.33, max_ready_ctx=9
payload=9.428 Gbps, rate=4.137 Mmsg/s
```

运行命令（本地 cocotb 1.9.2 / Verilator 5.020 / Python 3.8 兼容副本）：

```bash
NMSG=100 PROFILE=short_heavy \
PYTHONPATH=/tmp/opencode/tb:/tmp/opencode/model:$PYTHONPATH \
make -f Makefile.top SIM=verilator MODULE=test_sm3_accel_top_local \
  CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512
```

本地测试副本只做了 Python 3.8 兼容替换（`unit=` -> `units=`，`int.bit_count()` -> `popcount()`），不改变 DUT。

## 6. 被否决的方案

| 方案 | 结果 | 原因 |
|---|---:|---|
| v48：hash pipeline + staging | 布局 `-0.197`，布线 `-0.105` | 去掉 hash 路径但改变布局，状态路径成为新瓶颈 |
| v49：staging + hash + 新分组 | 布局 `-0.344` | 布局显著变差，engine 路径主导 |
| v50：v42 top + hash pipeline | 布局 `-0.403` | core 被推到 `Y271`，floorplan 破坏 |
| v51：v42 top + 新分组 | 布局 `-0.215` | 新分组没有降低 hash 路径，布局反而变差 |
| v52：v42 + Tj 低半拆分 | 布局 `-0.255` | 布局改变，commit 路径成为新瓶颈 |
| v53：布局阶段加 LOC | 布局 `-0.276` | core[9] 被放到 `X19Y124`，LOC 必须 post-route 加 |
| ECO2：只 route 移动 cell 的 Q/D 网 | WNS `-0.616` | 局部布线绕行，Q 网延迟 1.327 ns |
| v42 physopt2 / 重布线 | `-0.009` 或 `+0.001` | 无进一步收益，确认最终 checkpoint |

结论：对当前 floorplan，任何核心 RTL 结构性改动都会显著改变布局；最有效的方案是保留 v42 RTL/布局，只对已布线的单个关键寄存器做 post-route ECO，再做一次全局 physopt。

## 7. 复现与产物

### 最终流程脚本（按顺序）

```text
work/vivado/timing_v1/run_synth_v38.tcl          # v42 综合
work/vivado/timing_v1/run_place_v42.tcl          # v42 布局 + block-builder pblock
work/vivado/timing_v1/run_route_v42_internal.tcl # v42 布线
work/vivado/timing_v1/run_physopt_v42.tcl        # post-route physopt -> -0.009
work/vivado/timing_v1/run_eco_v42_1.tcl          # ECO1：place_cell + 全局重布线
work/vivado/timing_v1/run_physopt_eco1.tcl       # ECO1 + physopt -> +0.001
```

### 最终 checkpoint

```text
work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp
```

### 最终报告

```text
work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_summary_eco_physopt.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_max_eco_physopt.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/top_timing_v1_internal_min_eco_physopt.rpt
```

### 说明

- 最终 DCP 是签核依据；RTL 回放不包含 ECO 的 LOC，因为布局阶段加 LOC 会改变 floorplan。
- 若要再次优化，请先保存当前 DCP；任何 `place_design`/`route_design`/`phys_opt_design` 全量重跑都可能丢失当前的 1 ps 裕量。
- 最终 WNS 是内部 reg-to-reg 口径，顶层 I/O 延迟未建模；这与本项目此前的时序签核口径一致。

## 8. 资源、逻辑级数与扇出（最终 DCP）

数据来源：对最终 checkpoint `route_v42_eco1_physopt/top_timing_v1_eco_physopt.dcp` 重新运行 `report_utilization`、`report_high_fanout_nets`、`report_design_analysis -logic_level_distribution` 和 `report_timing`。报告见本节末尾。

### 8.1 资源利用率

| 资源 | 使用 | 可用 | 利用率 |
|---|---:|---:|---:|
| CLB LUTs | 29,000 | 331,680 | 8.74% |
| LUT as Logic | 28,492 | 331,680 | 8.59% |
| LUT as Memory (LUTRAM) | 508 | 146,880 | 0.35% |
| CLB Registers (FF) | 29,015 | 663,360 | 4.37% |
| CLB | 5,381 | 41,460 | 12.98% |
| CARRY8 | 204 | 41,460 | 0.49% |
| Block RAM Tile | 12 | 1,080 | 1.11% |
| RAMB36 | 11 | 1,080 | 1.02% |
| RAMB18 | 2 | 2,160 | 0.09% |
| DSP48E2 | 0 | 2,760 | 0.00% |
| Bonded IOB | 0 | 520 | 0.00% * |
| BUFG | 0 | 624 | 0.00% * |

\* 当前 checkpoint 为 out-of-context 的 `sm3_accel_top` 实现：顶层端口没有 I/O buffer，时钟是带 `HD.CLK_SRC BUFGCTRL_X0Y0` 的输入端口，因此 I/O/BUFG 资源为 0；这里的资源数字是内部逻辑资源。

补充：

- CLB 中 `CLBL=2,501`、`CLBM=2,880`；FF 中 `FDCE=28,732`、`FDPE=274`、`FDRE=9`。
- CLB Registers 有 **1 个 Fixed**，就是 ECO 固定到 `SLICE_X4Y152/SLICEM.AFF2` 的 `tj_rot_q_reg[9]`。
- 设计没有 DSP；BRAM 只用了 12 个 tile，远低于器件容量。资源不是当前瓶颈，瓶颈是核心 hash 组合路径的布线延迟。

### 8.2 最差路径与逻辑级数

最终最差路径：

```text
Source:      u_engine/g_core[5].u_core/a_reg[27]/C   (SLICE_X18Y208)
Destination: u_engine/g_core[5].u_core/hash_out_reg[235]/D (SLICE_X15Y187)
Slack:       +0.001 ns (MET)
Data:        3.853 ns  (logic 1.378 / route 2.475，route 占 64.2%)
Logic:       9 levels (CARRY8=5, LUT2=1, LUT3=1, LUT5=1, LUT6=1)
Skew:        -0.120 ns
Uncertainty: 0.085 ns
```

**最差路径逻辑级数 = 9**。但设计里还有级数更多、只是裕量稍大的近临界路径：

| 路径 | Logic Levels | Slack |
|---|---:|---:|
| `core[9].tj_rot_q_reg[1] -> core[9].hash_out_reg[246]` | 11 | +0.002 ns |
| `core[1].a_reg[28] -> core[1].hash_out_reg[251]` | 11 | +0.010 ns |
| `core[14].a_reg[24] -> core[14].a_reg[30]` | 12 | +0.025 ns |
| `core[4].a_reg[21] -> core[4].hash_out_reg[234]` | 10 | +0.025 ns |

对最差 10,000 条路径做 logic-level 分布：

| Logic Levels | 8 | 9 | 10 | 11 | 12 |
|---|---:|---:|---:|---:|---:|
| Paths | 755 | 557 | 524 | 462 | 206 |

因此：

- **关键路径本身是 9 级**；
- **最差 10,000 条路径中的最大逻辑级数是 12 级**（206 条），12 级路径仍有 +0.025 ns 裕量；
- 当前关键路径是**布线主导**（route 2.475 ns，64%），不是逻辑级数主导；单纯再压逻辑级数不一定能增加裕量。

### 8.3 扇出

| 范围 | 最大扇出 | 说明 |
|---|---:|---|
| 全设计时钟 | **29,864** | `clk` 输入端口；全局时钟 |
| 全设计非时钟 | **29,015** | `rst_n`；29,006 个 FF reset + 8 data + 1 BRAM |
| 全设计数据 | **1,199** | `u_engine/g_core[14].u_core/D[0]`，LUT6；worst slack +0.127 ns |
| 最差路径内部 | **9** | `core[5].a_reg_n_0_[27]`，路径上其余 net 扇出 1/2/4/6 |

主要数据高扇出 net：

- `core[*].h` / `round_idx[5]`：每个 core 806；
- `fast_wr_ptr[*]`：633–637；`fast_rd_ptr[*]`：553–557；
- `u_block_builder/E[0]`、`block_valid_reg_0`：553；
- `launch_fast_block`：517；
- `core[*].out_valid`、`hash_out[255]`：约 296；
- `digest_out[255]`：295。

判断：

- 全局最大扇出是时钟和复位，属于正常的全局控制网；`rst_n` 的 29,015 与寄存器数量一致。
- 真正需要关注的数据扇出最大为 1,199（`D[0]`），其 worst slack 仍有 +0.127 ns；当前没有因为数据扇出导致失败。
- 最差路径的最大扇出只有 9，说明这条 1 ps 路径不是扇出问题，而是**跨 core 的 route + clock skew** 问题。

### 8.4 资源/时序判断

- **资源充足**：LUT 8.74%、FF 4.37%、BRAM 1.11%、DSP 0%，没有资源压力。
- **时序极限**：WNS +0.001 ns，且 11/12 级路径的裕量只有 2–25 ps；当前设计已经是 250 MHz 的边界。
- **优化方向**：如果还要增加裕量，优先做核心 hash 路径的局部 placement/route 优化或 post-route ECO，而不是增加流水级数或改分组；此前 v48–v52 的结构改动都因 floorplan 变化而失败。

### 8.5 本节报告

```text
work/vivado/timing_v1/route_v42_eco1_physopt/final_utilization.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/final_high_fanout_nets.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/final_high_fanout_loads.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/final_logic_level_distribution.rpt
work/vivado/timing_v1/route_v42_eco1_physopt/final_timing_max20.rpt
```
