# Timing Pipeline V1 — 综合时序门控结果

> **2026-10-23 更新**：本文是初始综合门控记录（当时 V1 综合为负）。后续 v42 已完成布局布线和 post-route ECO，最终结果为内部 WNS `+0.001 ns`、WHS `+0.015 ns`，所有约束满足。基线 `main` 综合 `-4.548 ns` -> 最终 `+0.001 ns`，提升 `4.549 ns`。最终报告见 `TIMING_V1_FINAL_RESULT.md`。

- 日期：2026-10-22
- Vivado：2021.2
- 器件：`xcku060-ffva1156-2-e`
- 目标：250 MHz / 4.000 ns
- 配置：`CORE_NUM=16`、`CTX_NUM=32`、`FAST_DEPTH=32`、`POOL_DEPTH=512`
- 流程：`synth_design -mode out_of_context -flatten_hierarchy rebuilt`，综合后立即 `report_timing_summary`
- 结论：**综合 WNS 已明显为负，未进入 opt/place/route。**

## 1. 对比对象

| 版本 | 分支/提交 | 说明 |
|---|---|---|
| 基线 | `main` / `4fcec67` | 最新 main；该提交仅新增优化建议文档，RTL 与初始版本一致 |
| 优化 | `opt/timing-pipeline-v1` / `782a099` | Core Tj 预旋转、`next_mem` 同步读流水、`ctx_head` 延迟退休 |

两次综合使用同一 TCL、同一 XDC、同一 part 和同一综合参数，仅切换 RTL。

## 2. 综合后 WNS/TNS

| 指标 | 基线 main | Timing V1 | 变化 |
|---|---:|---:|---:|
| WNS | **-4.548 ns** | **-5.319 ns** | **-0.771 ns（变差）** |
| TNS | -14,970.275 ns | -14,918.685 ns | +51.59 ns（几乎不变） |
| 失败端点 | 6,856 / 59,866 | 23,880 / 60,267 | +17,024 |
| WHS | +0.034 ns | +0.034 ns | 0 |
| LUT | 27,812 | 28,641 | +829 |
| LUTRAM | 604 | 508 | -96 |
| FF | 26,043 | 26,615 | +572 |
| BRAM | 11 RAMB36 + 1 RAMB18 | 11 RAMB36 + 2 RAMB18 | +0.5 Tile |

结论：综合阶段 WNS 没有改善，反而变差 0.771 ns；距离 250 MHz 的 0 ns 仍有 5.319 ns 缺口。按“综合发现时序问题就不做布局布线”的约定，未运行 `opt_design/place_design/route_design`。

## 3. 关键路径变化

### 基线 main

```text
u_engine/g_core[1].u_core/out_valid_reg/C
  -> u_engine/ctx_head_reg[15][3]/D
```

- Slack：**-4.548 ns**
- Data Path Delay：8.522 ns（logic 1.816 / route 6.706）
- Logic Levels：25，含 `RAMD64E`
- 旧路径仍是 Core 完成 -> Commit/Sticky -> `ctx_head` 动态写回

### Timing V1

```text
u_engine/g_core[4].u_core/out_valid_reg/C
  -> u_engine/u_block_pool/next_mem_reg_bram_0/WEBWE[0]
```

- Slack：**-5.319 ns**
- Data Path Delay：8.645 ns（logic 1.806 / route 6.839）
- Logic Levels：24
- 目标变为 `next_mem` 的 BRAM 写使能，`RAMB18E2` 的 setup 要求使 required time 降到 3.326 ns
- 路径仍串联 Commit 仲裁、`core_out_ready`、`core_quantum`、`fast_count`、`ctx_head` 和 `link_wr_en`

## 4. 判断

1. V1 确实切断了原来的 `next_mem` 异步读 -> `ctx_head` 同周期写回路径，旧关键路径消失。
2. 但关键路径转移到 **Core `out_valid` -> Commit/Sticky -> `ctx_head` -> `next_mem` 写使能**，本质仍是同一段提交/弹出现有组合链。
3. V1 将 `next_mem` 推断为 `RAMB18`（因为读地址已寄存），写使能路径需要满足 BRAM setup；其数据延迟与基线接近，但 required time 更紧，导致 WNS 反而变差。
4. 因此，V1 不能作为 250 MHz 的收敛版本，也不需要继续布局布线。

## 5. 下一步建议

按优先级：

1. **寄存器化 Commit 接收与写侧**：把 Core `out_valid/out_data` 先锁存到 Commit 寄存器或小 FIFO，再由寄存后的信号产生 `link_wr_en/link_wr_slot/link_wr_next`，彻底切断 `out_valid -> BRAM WEBWE` 的组合路径。
2. **拆分 16:1 Commit 仲裁和 32 Context 扫描**：分组仲裁、one-hot/掩码 RR、分段寄存，避免 24 级逻辑集中在同一周期。
3. **评估 `next_mem` 的实现方式**：若保留 BRAM，写侧必须寄存；若改回 LUTRAM，读侧仍需保持同步读，并比较两种实现的 setup 代价。
4. **在综合门控通过后再做 P&R**：建议先达到 post-synth WNS >= 0（最好 >= +0.3 ns），再进入 opt/place/route；否则 P&R 只会进一步恶化。
5. **功能回归**：V1 分支文档明确标注 cocotb/Verilator 回归尚未完成；本次仅做时序综合，不代表功能正确。

## 6. 产物

- 基线综合报告：`work/vivado/timing_v1/baseline_synth/`
- V1 综合报告：`work/vivado/timing_v1/synth/`
- 综合脚本：`work/vivado/timing_v1/run_synth.tcl`、`run_synth_baseline.tcl`

注意：综合后时序未设置 `HD.CLK_SRC`，报告中的时钟延迟/偏斜为理想估计；实际布局布线只会更差。因此 -5.319 ns 的结论是保守成立的。
