# SM3 FPGA Vivado 2021.2 综合与实现报告

- 日期：2026-10-22
- 工具：Vivado 2021.2（lin64, Build 3367213）
- 器件：XCKU060-FFVA1156-2-E（-2 speed grade）
- 目标时钟：250 MHz / 4.000 ns
- RTL：`sm3_fpga/latest/milestone6`
- 工作目录：`work/vivado`

---

## 0. 结论摘要

| 验证项 | 结果 | 结论 |
|---|---|---|
| 单核 250 MHz（原始 RTL，默认 OOC 流程） | 内部 WNS **-0.288 ns**，124/2418 端点失败 | 不收敛 |
| 单核 250 MHz（原始 RTL，真实 BUFG + Explore/fanout 优化） | 内部 WNS **+0.009 ns** | 临界通过，几乎没有余量 |
| 单核 250 MHz（Tj 预旋转 + 高扇出复制） | 内部 WNS **+0.226 ns**，round 路径 **+0.681 ns** | 通过，建议采用 |
| 16C/32ctx/512pool 资源 | 27,976 LUT / 26,044 FF / 11 RAMB36 + 1 RAMB18 / 0 DSP | 资源充足（LUT 8.65%，FF 3.93%，BRAM 1.06%） |
| Block Pool RAM 推断 | 512×514 → 7 RAMB36 + 1 RAMB18 | 正确推断为 BRAM，位利用率高 |
| Context Hash RAM 推断 | 32×256 → 4 RAMB36 | 正确推断为 BRAM，但深度利用率仅 6.25% |
| 16C 全 Top 250 MHz | 默认 OOC WNS **-5.566 ns**；优化流程 route 中间 WNS **-5.016 ns** | **不收敛**，属于架构/流水线问题 |
| 顶层 I/O | **569 bit**，FFVA1156 仅 520 个 bonded I/O | 超 49 bit；去掉 65 bit 调试口后为 504 bit，可放下 |

**核心判断：**

1. 单个 SM3 core 的组合 round 路径在 250 MHz 下是**临界可收敛**的：原始 RTL 在默认 OOC 流程下差 0.288 ns，主要来自未缓冲时钟的悲观 skew；换成真实 BUFG、Explore 布局和 fanout 优化后原始 RTL 为 +0.009 ns。把 `Tj <<< j` 提前一拍寄存后，round 路径余量提升到 +0.681 ns，整体 WNS +0.226 ns。
2. 16C/32ctx/512pool 的**面积和 BRAM 推断没有问题**，KU060 资源余量很大。
3. 16C 全 Top 在 250 MHz 下**远未收敛**（-5.566 ns）。关键路径是 core 完成输出 → sticky commit/pop → `ctx_head` → 异步 `next_mem` LUTRAM → `ctx_head` 写回，22 级逻辑、9.497 ns 数据路径，其中 6.710 ns 是布线。这不是单纯换布局 directive 能解决的，需要给提交/弹出通路加流水线。
4. 顶层 569 bit I/O 超过 FFVA1156 的 520 个 bonded I/O。调试口共 65 bit，去掉后 504 bit 可以放下；若保留调试口，必须做时间复用或换更大封装。

---

## 1. 环境与方法

### 1.1 工具与目标

```text
Vivado       : /home/Xilinx/Vivado/2021.2/bin/vivado
Part         : xcku060-ffva1156-2-e
Clock        : create_clock -period 4.000 -name clk
Uncertainty  : 0.050 ns setup / 0.050 ns hold
I/O budget   : 1.000 ns input delay, 1.000 ns output delay
```

### 1.2 OOC 流程说明

全 Top 的用户 I/O 为 569 bit，超过 FFVA1156 封装可用的 520 个 bonded I/O，因此全 Top 采用 `-mode out_of_context` 综合/实现，避免 pad placement 直接失败。OOC 结果用于**资源、RAM 推断和内部 reg-to-reg 时序**评估，不代表最终板级 I/O 时序。

单核 OOC 的时钟处理有两种：

- **无 BUFG**：`set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]`，把时钟端口当作已缓冲的时钟根。此时 clock insertion delay 约 3.1 ns，端口路径的 WNS 会被严重悲观化（原始 raw WNS -0.511 ns），必须用 false path 隔离端口后看内部 reg-to-reg。
- **真实 BUFG 包装**：`rtl_opt/sm3_core_bufg.sv` 在 core 外例化 `BUFG`，布局布线看到真实全局时钟树。这个结果更接近 in-context，本文的单核 sign-off 结论以该流程为准。

内部时序报告均先对以下端口路径加 false path，只保留寄存器到寄存器路径：

```tcl
set_false_path -from [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}] \
               -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
               -to [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]
```

### 1.3 复现命令

```bash
# 单核基线（无 BUFG，默认实现）
vivado -mode batch -source work/vivado/core_ooc/run_core_ooc.tcl

# 单核 Explore 复跑（无 BUFG）
vivado -mode batch -source work/vivado/core_ooc_explore/run_core_explore.tcl

# 单核真实 BUFG + Explore + AggressiveFanoutOpt
vivado -mode batch -source work/vivado/rtl_opt/run_core_bufg_synth.tcl \
  -tclargs <core.sv> <outdir> <tag>
vivado -mode batch -source work/vivado/rtl_opt/run_core_bufg_impl2.tcl \
  -tclargs <post_synth.dcp> <outdir> <tag>

# 16C/32ctx/512pool 综合（in-context）
vivado -mode batch -source work/vivado/top_16c_32ctx/run_top_synth.tcl

# 16C/32ctx/512pool 默认 OOC 实现
vivado -mode batch -source work/vivado/top_16c_32ctx_ooc/run_top_ooc.tcl
```

---

## 2. 单核 sm3_core 结果

### 2.1 时序汇总

所有 WNS/TNS 均为 **内部 reg-to-reg**（已排除端口路径）。

| # | RTL / 流程 | 时钟 | WNS (ns) | TNS (ns) | 失败端点 | LUT | FF | 结论 |
|---|---|---|---:|---:|---:|---:|---:|---|
| A | 原始 RTL，综合 default | 无 BUFG | +0.166 | 0.000 | 0 / 2418 | 1106 | 1354 | 仅综合估计 |
| B | 原始 RTL，实现 default | 无 BUFG | **-0.288** | -14.925 | 124 / 2418 | 1127 | 1354 | 不收敛 |
| C | 原始 RTL，place/route Explore | 无 BUFG | **-0.289** | -37.374 | 348 / 2442 | 1129 | 1366 | 不收敛，directive 无效 |
| D | 原始 RTL，PerformanceOptimized | 无 BUFG | -0.288 | — | — | 1127 | 1354 | 与 B 完全相同 |
| E | 原始 RTL，实现 default | 真实 BUFG | -0.084 | -0.332 | 6 / 2419 | 1124 | 1355 | 临界失败（高扇出 CE） |
| F | 原始 RTL，Explore + AggressiveFanoutOpt | 真实 BUFG | **+0.009** | 0.000 | 0 / 2419 | 1126 | 1355 | 临界通过，余量 9 ps |
| G | Tj 预旋转 + 高扇出复制，Explore + AggressiveFanoutOpt | 真实 BUFG | **+0.226** | 0.000 | 0 / 2483 | 1181 | 1387 | 通过 |
| H | G 的 round 路径单独报告 | 真实 BUFG | **+0.681** | — | — | — | — | 组合 round 逻辑有余量 |

说明：

- B/C/D 的 -0.288 ns 是未缓冲时钟下的结果，且 C 的 Explore 让失败端点数从 124 增加到 348，说明默认 OOC 流程对布局 directive 不敏感，瓶颈是逻辑深度。
- E 的 -0.084 ns 不是 round 逻辑，而是 `out_valid → busy0` 这条 **1065 扇出** 的使能网络，单条 net 布线 3.184 ns。F 通过 fanout 优化后该问题消失，但整体只剩 9 ps 余量，不能作为可靠 sign-off。
- G 在 F 的基础上把 `Tj <<< j` 从组合路径移到寄存器，并给 `busy`/`load_en` 加 `max_fanout=32`。整体 WNS +0.226 ns，round 路径 +0.681 ns。

按 WNS 线性估算的等效 Fmax（仅作量级参考，布线延迟并不完全随周期线性缩放）：

| 流程 | 等效 Fmax |
|---|---:|
| B：原始 RTL，无 BUFG，默认实现 | ≈ 233 MHz |
| F：原始 RTL，BUFG + Explore/fanout | ≈ 250.6 MHz |
| G：Tj 预旋转 + fanout，BUFG + Explore/fanout | ≈ 265 MHz |
| 16C Top 默认实现 | ≈ 104.5 MHz |

### 2.2 关键路径

**原始 RTL（B，最差内部路径）：**

```text
Source      : round_idx_reg[3]/C
Destination : hash_out_reg[124]/D
Data Path   : 4.029 ns  (logic 1.878 ns + route 2.151 ns)
Logic Levels: 11  (CARRY8=6, LUT3=1, LUT4=1, LUT6=3)
Slack       : -0.288 ns
```

路径包含：`Tj` 选择 + 32-bit 变量循环左移 → `a12 + e + tj_rot` → `<<<7` → `ss1/ss2` → `tt1` → `tt2` 加法链 → `p0(tt2)` → round 63 的 `hash_base` 异或。`Tj` 的变量旋转直接挂在 `round_idx` 上，是 4 ns 路径里可以无损去掉的一段。

**优化后（G，round 路径单独报告）：**

```text
Source      : round_idx_reg[5]/C
Destination : hash_out_reg[124]/D
Data Path   : 3.017 ns  (logic 1.098 ns + route 1.919 ns)
Logic Levels: 7  (CARRY8=3, LUT4=1, LUT5=1, LUT6=2)
Slack       : +0.681 ns
```

**优化后（G，整体最差路径）：**

```text
Source      : out_valid_reg/C
Destination : w_reg[15][5]/D
Data Path   : 3.497 ns  (logic 0.339 ns + route 3.158 ns)
Logic Levels: 2  (LUT4=1, LUT6=1)
Slack       : +0.226 ns
```

这条最差路径仍然是高扇出的 load-enable 网络（`w[15]` 装载选择），但已经为正。继续做 fanout 复制或把 load enable 分级可以再增加余量。

### 2.3 RTL 改动（建议采纳）

文件：`work/vivado/rtl_opt/sm3_core_opt2.sv`（相对原始 `sm3_core.sv`）

1. **`Tj <<< j` 提前一拍寄存**

   ```systemverilog
   logic [31:0] tj_rot_q;

   // 组合路径中使用寄存器输出，不再用 round_idx 做变量旋转
   ss1 = rol32(a12 + e + tj_rot_q, 7);

   // 每个 busy 周期预计算下一轮的 Tj <<< (j+1)
   tj_rot_q <= rol32(((round_idx + 6'd1) < 16) ? 32'h79cc4519
                                              : 32'h7a879d8a,
                     int'(round_idx + 6'd1));
   ```

   代价：+32 FF；不增加每 block 周期数（仍是 load + 64 rounds = 65 cycle service interval）。

2. **高扇出使能复制**

   ```systemverilog
   (* max_fanout = 32 *) logic busy;
   (* max_fanout = 32 *) logic load_en;
   assign load_en = in_valid && in_ready;

   if (load_en) begin ... end
   ```

   避免单个 LUT/FF 驱动 1000+ 个 CE 引脚，导致 3 ns 以上的单网布线。

### 2.4 功能验证

使用 Vivado xsim 对 `sm3_core_opt2.sv` 跑原始 core 向量测试：

```text
SM3 CORE PASS: 305 compression vectors
```

覆盖已知消息、边界长度、随机状态和随机 block；与原始 core 的 305 个向量结果一致。Tj 预旋转没有改变功能。

> 本机 Verilator 5.020 与默认 g++ 9.4 缺少 `<coroutine>` 头文件，无法直接跑仓库的 Verilator 流程；因此功能验证改用 Vivado xsim 2021.2。仓库 `scripts/env.sh` 指向的 `/mnt/data/sm3_dev_env` 在本机不存在，说明本地仿真环境与归档环境存在版本差异，但这不影响综合/实现结论。

---

## 3. 16C / 32ctx / 512pool 资源

配置：`CORE_NUM=16`, `CTX_NUM=32`, `FAST_DEPTH=32`, `POOL_DEPTH=512`, `MSG_ID_W=32`。

### 3.1 总量

| 阶段 | Total LUT | Logic LUT | LUTRAM | FF | RAMB36 | RAMB18 | DSP | CLB | LUT% | FF% | BRAM% |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 综合（in-context） | 27,976 | 27,372 | 604 | 26,044 | 11 | 1 | 0 | — | 8.43% | 3.93% | 1.06% |
| 实现（默认 OOC） | **28,693** | 28,089 | 604 | **26,096** | **11** | **1** | **0** | 5,845 | **8.65%** | **3.93%** | **1.06%** |

KU060 资源：331,680 LUT、663,360 FF、1,080 RAMB36（2,160 RAMB18）、2,760 DSP。当前设计只用了不到 9% LUT 和 4% FF，**面积不是瓶颈**。

### 3.2 层次分解（实现后）

| 实例 | 模块 | LUT | LUTRAM | FF | RAMB36 | RAMB18 |
|---|---|---:|---:|---:|---:|---:|
| `sm3_accel_top` | top | 28,693 | 604 | 26,096 | 11 | 1 |
| `u_block_builder` | sm3_block_builder | 1,637 | 0 | 1,167 | 0 | 0 |
| `u_engine` | sm3_pool_engine | 27,034 | 604 | 24,890 | 11 | 1 |
| `u_engine`（自身逻辑） | sm3_pool_engine | 1,737 | 316 | 2,996 | 4 | 0 |
| 16 × `g_core[*].u_core` | sm3_core | 21,395 | 0 | 21,856 | 0 | 0 |
| `u_block_pool` | sm3_block_pool | 3,930 | 288 | 38 | 7 | 1 |

> 16 个 core 的 LUT 在 681～2,176 之间不等，是跨层次 LUT combining 和共享逻辑造成的，不能按单核 1,127 LUT 简单乘 16。总计约 21.4k LUT 用于 16 个 core，单核平均约 1,337 LUT。

### 3.3 与 Yosys 估算对比

| 指标 | Yosys 0.52 估算 | Vivado 2021.2 实现 |
|---|---:|---:|
| LUT / LC | 32,812 LC | 28,693 LUT |
| FF | 26,043 | 26,096 |
| BRAM | 15 RAMB18 + 4 RAMB36（=11.5 tile） | 11 RAMB36 + 1 RAMB18（=11.5 tile） |
| DSP | 0 | 0 |

FF 几乎完全一致（+0.2%），BRAM 总 tile 数一致（11.5），Vivado 的 LUT 映射更省（-12.6%）。Yosys 把 Block Pool 拆成更多 RAMB18，Vivado 用 7 个 RAMB36 + 1 个 RAMB18，位利用率更高。

---

## 4. RAM 推断

### 4.1 Block RAM

| 逻辑存储 | 逻辑尺寸 | 推断原语 | 说明 |
|---|---|---|---|
| `u_engine/u_block_pool/block_mem` | 512 × 514 | **7 × RAMB36 + 1 × RAMB18** | 7 个 512×72（504 bit）+ 1 个 512×10；RAMB36 位利用率 100%，RAMB18 27.78% |
| `u_engine/hash_mem` | 32 × 256 | **4 × RAMB36** | 3 个 32×72 + 1 个 32×40；深度利用率 32/512 = 6.25%，位利用率 6.25% / 3.47% |

Block Pool 的 512×514 推断是本次验证的重点，结果正确：512 深度完整用满，514 bit 宽度拆成 7×72 + 1×10，总物理位 7×36,864 + 18,432 = 276,480 bit，逻辑位 512×514 = 263,168 bit，**位利用率 95.2%**（按 RAMB36 等效 tile 计算）。

Context Hash RAM 的 32×256 也正确推断为 BRAM，但每个 RAMB36 只用了 32/512 深度，4 个 tile 只存 8,192 bit，**资源效率很低**。由于全设计只用了 11.5/1,080 个 BRAM tile（1.06%），这不影响当前配置；如果后续要压缩 BRAM 数量，可以把 4 个 RAMB36 换成 8 个 RAMB18（等效 4 tile，数量不变）或改用分布式 RAM，但会牺牲时序/布线。

### 4.2 LUTRAM / 分布式 RAM

| 逻辑存储 | 逻辑尺寸 | 推断原语 | LUTRAM 数 |
|---|---|---|---:|
| `u_engine/fast_block_mem` | 32 × 512 | 36 × RAM32M16 | 288 |
| `u_engine/fast_msg_mem` | 32 × 32 | 2 × RAM32M16 + 1 × RAM32M | 20 |
| `u_engine/fast_ctx_mem` | 32 × 5 | 1 × RAM32M16 | 8 |
| `u_engine/u_block_pool/free_fifo` | 512 × 9，2 读口 | 16 × RAM64M8 + 16 × RAM64M | 192 |
| `u_engine/u_block_pool/next_mem` | 512 × 9，1 读口 | 8 × RAM64M8 + 8 × RAM64M | 96 |
| **合计** | | | **604** |

原语统计：

```text
RAM32M16 : 39 个（312 LUT）
RAM32M   :  1 个（4 LUT）
RAM64M8  : 24 个（192 LUT）
RAM64M   : 24 个（96 LUT）
总计     : 604 LUTRAM
```

结论：

- Block Pool、Context Hash、Fast FIFO、free list、next pointer **全部按预期推断为片上存储**，没有退化成 FF 阵列。
- `free_fifo` 因为是双读口（r1/r2），LUTRAM 开销 192 LUT，是 604 LUTRAM 中最大的一块；如果改成单读口或真双口 BRAM，可以进一步省 LUT，但当前 604 LUT 只占全设计 2.1%，不值得为它改架构。
- `next_mem` 是**异步读 LUTRAM**，它出现在 Top 关键路径上（见 §6），这是后续流水线优化的重点。

---

## 5. 顶层 I/O

FFVA1156 封装可用 bonded I/O：**520**。

当前 `sm3_accel_top` 端口位宽：

| 组 | 信号 | bit |
|---|---|---:|
| 时钟/复位 | `clk`, `rst_n` | 2 |
| 描述符 | `desc_valid`, `desc_ready`, `desc_msg_id[31:0]`, `desc_len_bytes[31:0]` | 66 |
| 输入流 | `s_valid`, `s_ready`, `s_data[127:0]`, `s_keep[15:0]` | 146 |
| 结果 | `result_valid`, `result_ready`, `digest_out[255:0]`, `result_msg_id[31:0]` | 290 |
| 调试 | `dbg_core_occupied[15:0]`, `dbg_ctx_allocated[31:0]`, `dbg_fast_level[5:0]`, `dbg_pool_free[9:0]`, `dbg_pool_init_done` | 65 |
| **合计** | | **569** |

- 超封装 **49 bit**（569 - 520）。
- 去掉全部调试口后为 **504 bit**，可以放进 520 个 bonded I/O，只剩 16 bit 余量。
- 若不删除调试口，需要把 `digest_out`/`result_msg_id` 做 2:1 时间复用（例如 128 bit 半字输出），或换更大的 FFVA1156 以上封装。

> 之前的记录中出现过 553 bit，那是漏算 `dbg_core_occupied[15:0]` 的结果；按当前 RTL 端口逐位统计为 569 bit。

---

## 6. 16C 全 Top 时序

### 6.1 默认 OOC 实现

```text
WNS  : -5.566 ns
TNS  : -108,989.641 ns
失败 : 47,172 / 59,971 端点（78.7%）
WHS  : -2.232 ns（OOC 时钟 hold 伪失败，2973 端点）
```

失败端点的平均 slack 约 -2.31 ns（TNS / 失败端点数），说明不是个别路径，而是大量控制路径同时超周期。

### 6.2 关键路径

```text
Source      : u_engine/g_core[11].u_core/out_valid_reg/C
Destination : u_engine/ctx_head_reg[19][3]/D
Data Path   : 9.497 ns  (logic 2.787 ns + route 6.710 ns)
Logic Levels: 22  (LUT2=1, LUT3=3, LUT5=4, LUT6=12, MUXF7=1, RAMD64E=1)
Slack       : -5.566 ns
```

路径的 RTL 语义：

```text
core[11].out_valid + tag
  → 16:1 commit 仲裁（commit_core_sel / commit_ctx_id）
  → sticky_issue / ctx_pop
  → ctx_head[pop_ctx_idx] 32:1 读
  → next_mem[pop_slot] 异步 LUTRAM 读（RAMD64E）
  → ctx_head[pop_ctx_idx] 写回
```

对应 `rtl/context/sm3_pool_engine.sv`：

- `commit_core_sel` 由 16 个 core 的 `out_valid`/tag 组合选出；
- `sticky_issue` 依赖 `commit_fire`、`commit_ctx_id`、`ctx_pending_valid[commit_ctx_id]`、`core_quantum[...]`；
- `pop_slot = ctx_head[pop_ctx_idx]`，`ctx_head` 更新又依赖 `pool_link_rd_next`（来自 `next_mem` 异步读）。

这条通路在一个 4 ns 周期内串了 **16:1 仲裁 + 32:1 表项选择 + 512×9 异步 LUTRAM 读 + 写回**，逻辑级数 22，即使布线完美也需要 ~3 ns 以上；6.710 ns 的布线是因为 16 个 core 和调度器分散在 die 上，commit mux 的 net 跨越多个 clock region。

### 6.3 拥塞

```text
Direction : South
Type      : Global
Level     : 5
Congestion: 110%
Window    : (CLE_M_X11Y187, CLEL_R_X26Y218)
Cells     : u_engine (100%)
LUT 64%, FF 24%, CARRY 7%
```

拥塞集中在 `u_engine` 南侧，与 commit mux / ctx_head / next_mem 的跨区布线一致。全设计 CLB 利用率只有 14.1%，所以不是全局资源不够，而是**局部控制逻辑过度集中**。

### 6.4 优化流程复跑

对同一个 post-synth checkpoint 使用：

```tcl
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveFanoutOpt
route_design -directive Explore
```

结果见 `top_16c_32ctx_ooc2/`。该复跑在 route 的 **Phase 6.2 Additional Hold Fix** 阶段记录到：

```text
WNS : -5.016 ns
TNS : -92,205.490 ns
WHS : -1.919 ns
```

相比默认流程的 -5.566 ns 仅改善约 **0.55 ns**，仍远离 250 MHz。该 OOC 运行在 hold-fix 阶段长时间无进展（超过 15 分钟），已终止，因此没有生成最终 routed checkpoint 和 timing report；默认流程的完整 routed 数据保留在 `top_16c_32ctx_ooc/`。这个中间结果足以说明：**布局/扇出 directive 只能带来约 0.5 ns 的改善，不能弥补 5 ns 的逻辑深度缺口。**


### 6.5 结论

Top 不收敛的主要原因是**调度器提交/弹出通路的组合逻辑太深**，不是 core 的 round 逻辑（core 已单独验证可通过）。在 16 core 配置下，commit 仲裁、context 链表弹出和异步 LUTRAM 读被放在同一拍，形成了 9.5 ns 的组合路径；47,172 个失败端点也说明大量控制路径同样超周期，属于系统性问题。

---

## 7. 建议的下一步 RTL 修改

### 7.1 Core（低风险，已在本报告验证）

1. 采用 `sm3_core_opt2.sv` 的两项改动：
   - `tj_rot_q` 预旋转寄存器；
   - `busy` / `load_en` 的 `max_fanout=32`。
2. 在板级/in-context 流程中显式例化 `BUFG`（或让综合自动插入），不要用 `HD.CLK_SRC` 的 OOC 结果做 250 MHz sign-off。
3. 用多个 placement seed / directive 复跑，确认 WNS 稳定为正；当前 +0.226 ns 余量仍偏小，建议目标 ≥ +0.3 ns。

### 7.2 Top（必须做，否则 250 MHz 无法收敛）

按优先级：

1. **给 commit 仲裁加一拍寄存器**
   - 当任意 core `out_valid` 时，把 `commit_core_sel`、`commit_ctx_id`、`commit_hash`、`commit_last`、`commit_is_fast` 打入一个 commit 寄存器组；
   - 下一拍再用寄存后的 metadata 做 `sticky_issue` 和 `ctx_pop`。
   - 代价：每 block +1 cycle；16 core 的 service interval 从 65 变 66，理论 block 率从 0.246 降到 0.242（-1.5%），远小于时序收益。

2. **把 context 链表弹出拆成两级**
   - Stage 1：读 `ctx_head[pop_ctx_idx]`，比较 `ctx_tail`，把 `pop_slot`、`pop_single_old` 寄存；
   - Stage 2：用寄存后的 `pop_slot` 读 `next_mem`（建议改成同步读 RAM 或 BRAM），再更新 `ctx_head`。
   - 这样把 512×9 异步 LUTRAM 从“组合读+写回同一拍”变成“地址寄存 → 同步读 → 下一拍写回”，切断 9.5 ns 路径。
   - 代价：pop 延迟 +1～2 cycle；对 16 core 的吞吐影响约 2%～3%，可接受。

3. **把 16:1 / 32:1 线性优先级扫描改成流水化轮询**
   - 当前 `for` 循环综合出多级优先编码器 + 宽 mux；
   - 改成 one-hot grant 寄存器 + 两级仲裁（4×4 或 8×2），或按 core 分组做两级 mux，可以显著降低逻辑级数和跨区布线。

4. **给调度器高扇出控制网加复制约束**
   - `commit_fire`、`ctx_pop`、`sched_fire`、`launch_valid`、`core_out_ready[*]` 等加 `max_fanout` 或手动复制；
   - 这些网在 16 core 下扇出大，容易产生 3 ns 以上的单网延迟。

5. **调试口寄存器化 / 删除**
   - `dbg_*` 目前是组合输出，部分逻辑与 commit 路径共享 LUT；建议先打一拍再输出，或在板级 wrapper 中删除。
   - 删除后 I/O 从 569 降到 504，解决封装超限。

6. **布局/floorplan**
   - 把 16 个 core 按 4×4 或 8+8 分组摆放在 `u_engine` 两侧，commit/ctx 逻辑放中间；
   - 在逻辑深度降下来之后，再用 `place_design -directive Explore` / `phys_opt_design -directive AggressiveFanoutOpt` 复跑；
   - 当前直接对深逻辑用 Explore 收效有限。

### 7.3 不建议的做法

- 不要用综合 WNS（-8.970 或 +0.166）直接判断 250 MHz；必须看 post-route 内部 reg-to-reg。
- 不要为了 BRAM 数量把 `hash_mem` 改成 FF；当前 BRAM 只占 1.06%，改成 FF 反而增加 8k FF 和布线压力。
- 不要在 16C Top 还没做 commit/pop 流水线之前继续增加 core 数；调度器已经是瓶颈。

---

## 8. 文件索引

### 单核

| 路径 | 内容 |
|---|---|
| `work/vivado/core_ooc/` | 原始 RTL 默认 OOC 综合/实现、时序、利用率 |
| `work/vivado/core_ooc/core_ooc_timing_summary_internal.rpt` | 原始内部 WNS -0.288 |
| `work/vivado/core_ooc/core_ooc_timing_internal_max.rpt` | 原始关键路径 4.029 ns |
| `work/vivado/core_ooc_explore/` | place/route Explore 复跑（-0.289） |
| `work/vivado/core_ooc_perf/` | PerformanceOptimized 复跑（-0.288，无改善） |
| `work/vivado/core_bufg_base/` | 原始 RTL + 真实 BUFG，默认实现（-0.084） |
| `work/vivado/core_bufg_base2/` | 原始 RTL + BUFG + Explore/fanout（+0.009） |
| `work/vivado/core_bufg_opt2v_routed/` | Tj 预旋转 + fanout 复制（+0.226） |
| `work/vivado/core_bufg_opt2v_routed/round_path.rpt` | round 路径 +0.681 |
| `work/vivado/core_bufg_opt2v_routed/high_fanout.rpt` | 高扇出网列表 |
| `work/vivado/rtl_opt/sm3_core_bufg.sv` | BUFG 测试 wrapper |
| `work/vivado/rtl_opt/sm3_core_fanout.sv` | 仅 fanout 复制版本 |
| `work/vivado/rtl_opt/sm3_core_opt.sv` | 仅 Tj 预旋转版本 |
| `work/vivado/rtl_opt/sm3_core_opt2.sv` | **推荐版本：Tj 预旋转 + fanout 复制** |
| `work/vivado/sim_xsim/` | xsim 305 向量功能验证 |

### 全 Top

| 路径 | 内容 |
|---|---|
| `work/vivado/top_16c_32ctx/` | in-context 综合、利用率、RAM 推断 |
| `work/vivado/top_16c_32ctx/top_16c_32ctx_utilization_synth.rpt` | 层次化 LUT/FF/BRAM |
| `work/vivado/top_16c_32ctx/top_16c_32ctx_ram_utilization_synth.rpt` | BRAM/LUTRAM 详细推断 |
| `work/vivado/top_16c_32ctx/top_16c_32ctx_memory_cells_synth.rpt` | 存储原语清单 |
| `work/vivado/top_16c_32ctx_ooc/` | 默认 OOC 实现（WNS -5.566） |
| `work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_timing_max_routed.rpt` | Top 关键路径 9.497 ns |
| `work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_congestion.rpt` | 拥塞报告 |
| `work/vivado/top_16c_32ctx_ooc2/` | Explore/fanout 复跑（hold-fix 阶段终止，中间 WNS -5.016，见 run.log） |
| `sm3_fpga/latest/milestone6/rtl/core/sm3_core.sv` | 原始 core RTL |
| `sm3_fpga/latest/milestone6/rtl/context/sm3_pool_engine.sv` | 调度/context/pool engine |
| `sm3_fpga/latest/milestone6/rtl/context/sm3_block_pool.sv` | Block Pool RAM |
| `sm3_fpga/latest/milestone6/rtl/top/sm3_accel_top.sv` | Top 集成 |

---

## 9. 最终判定

| 目标 | 判定 | 说明 |
|---|---|---|
| 单核 250 MHz | **有条件通过** | 原始 RTL 临界 +0.009 ns；推荐 RTL 改动后 +0.226 ns，round 路径 +0.681 ns；需 in-context 复验 |
| 16C/32ctx/512pool 资源 | **通过** | 28,693 LUT / 26,096 FF / 11.5 BRAM tile / 0 DSP；KU060 余量充足 |
| Block Pool BRAM 推断 | **通过** | 512×514 → 7 RAMB36 + 1 RAMB18，位利用率 95.2% |
| Context RAM BRAM 推断 | **通过（低效）** | 32×256 → 4 RAMB36，深度利用率 6.25%，但 BRAM 总量不紧张 |
| Fast FIFO / free list / next LUTRAM | **通过** | 全部推断为 RAM32M/RAM64M 系列，604 LUTRAM |
| 16C Top 250 MHz | **不通过** | 默认 WNS -5.566 ns，优化流程中间结果 -5.016 ns；需 commit/pop 流水线、仲裁改造和 floorplan |
| 顶层 I/O 可布性 | **不通过（当前）** | 569 bit > 520；删除 65 bit 调试口后 504 bit 可通过 |
