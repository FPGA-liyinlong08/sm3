# SM3 FPGA 高资源密度下的时序与架构优化建议

> **状态**：工程分析 / 建议方案（未执行新的高密度综合和 P&R）  
> **基线**：`opt/timing-pipeline-v1`，v42 RTL + ECO1，Vivado 2021.2  
> **器件**：`xcku060-ffva1156-2-e`；250 MHz / 4.000 ns  
> **目标**：分析资源利用率由当前较低水平提高到 80%～90% 时，应该优先局部物理 ECO，还是 RTL/系统架构改造。

## 1. 结论：按扩容原因分开决策

**场景 A：资源提高主要来自增加 SM3 Core 数量，并要求实际吞吐随之提高。**  
优先走 **RTL 架构实验 → Cluster 分层 → 多路输入/Block Builder → 高密度 P&R → 局部 ECO**。当前 16 Core 以单寄存器位置 ECO 收敛的 +1 ps WNS，不足以证明未来数倍扩核后仍能跑 250 MHz。

**场景 B：SM3 保持 16 Core，其他 IP（PCIe、XDMA、DDR、其他算法）使整卡占用达 80%～90%。**  
优先 **系统集成 floorplan + 寄存器化接口 + 完整系统 P&R**，尽量复用现有 SM3 RTL；如果布线后只剩少量临界路径，再考虑 ECO。此时不能机械地要求重构 SM3 Scheduler。

**场景 C：只想增强当前 16 Core 的 OOC 250 MHz 时序余量。**  
保留现有 RTL，用当前最终 DCP 的副本做 ECO2 局部物理实验，具备低成本试验价值；但它不是高密度架构可扩展性的证据。

**明确资源口径**：LUT、FF、CLB、BRAM、DSP 和各 Clock Region 的利用率须分别给出。“总体资源占用 80%～90%”不等同于 LUT/CLB/FF 全部都占 90%；决策必须结合局部拥塞和时序报告。

## 2. 最终 v42 + ECO1 实测基线

### 2.1 资源（最终 DCP）

| 模块 | LUT | FF | LUTRAM | CARRY8 | BRAM Tile |
|---|---:|---:|---:|---:|---:|
| 16 × SM3 Core | **23,596** | **22,384** | 0 | 192 | 0 |
| Block Builder | 2,132 | 1,198 | 0 | 10 | 0 |
| Engine glue / Context / Commit | 1,638 | 4,234 | 316 | 0 | 4 |
| Block Pool | 1,574 | 47 | 192 | 2 | 8 |
| Top glue / 输入 FIFO | 63 | 1,152 | 0 | 0 | 0 |
| **全设计** | **29,000** | **29,015** | **508** | **204** | **12** |

子模块 LUT 相加与顶层差 3 个，是 Vivado 跨层级合并结果。Core 阵列占设计 81.4% LUT、77.2% FF；每核 1,399 FF、12 CARRY8。Core[14] 单核占 2,483 LUT（多数其他核 1,343～1,453），存在 Fanout=1,199 的数据网，是值得调查的离群点，但不代表每核扩容都必然消耗 2,483 LUT。

| 资源 | 使用 / 器件可用 | 利用率 |
|---|---:|---:|
| LUT | 29,000 / 331,680 | 8.74% |
| FF | 29,015 / 663,360 | 4.37% |
| CLB | 5,381 / 41,460 | 12.98% |
| BRAM Tile | 12 / 1,080 | 1.11% |
| DSP48E2 | 0 / 2,760 | 0% |

### 2.2 时序

- **Setup WNS +0.001 ns，Hold WHS +0.015 ns；TNS/THS 均 0，失败端点为 0**。
- 最差路径：`core[5].a_reg[27] -> core[5].hash_out_reg[235]`；Data 3.853 ns = Logic 1.378 + Route 2.475（布线占 **64.2%**）；逻辑级数 9、Clock Skew -0.120 ns。
- 近临界 Core：Core[9] +0.002 ns、Core[12] +0.005 ns、Core[1] +0.010 ns、Core[4]/[14] +0.025 ns。
- 主要模块 Overall WNS：Core array +0.001；Engine glue +0.052；Top glue +0.092；Block Pool +0.139；Block Builder +0.342 ns。
- 高扇出：`rst_n` 29,015；数据 `core[14].D[0]` 1,199（该网 Worst Slack +0.127 ns）；每个 Core 的某些 CE 网扇出约 806。**真正最差路径的数据网最大扇出只有 9**，不能据扇出高低判断现有关键路径成因。

### 2.3 约束及可复现性限制

上述时序来自 **Out-of-Context 内部 reg-to-reg**；对数据/I/O 路径采用 false path，尚未建模实际整卡 I/O delay、真实接口和外设时钟。最终物理收敛依赖已有 v42 布线结果上的 ECO1（移动 `core[9].tj_rot_q_reg[9]` 到 `SLICE_X4Y152`）和再次 physopt。**从 RTL 重新跑布局不保证复现 +1 ps 结果**。冻结最终 DCP、脚本、XDC、SHA256 和 Git SHA，任何实验使用独立 checkpoint/目录。

### 2.4 带宽与实际计算需求

Top 目前仅有 **一路 128-bit @ 250 MHz 输入**，理想 Stream 带宽上限 **32 Gbps**，未计协议空泡和背压。

最终 v42 cocotb + Verilator 回归（16C/32Context/512Pool）：

| 场景 | NMSG | 仿真有效 Payload |
|---|---:|---:|
| Mixed | 1,000 | 27.580 Gbps |
| Mixed | 10,000 | **28.384 Gbps** |
| Short-heavy + 背压 | 3,000 | 21.530 Gbps |
| Single-biased + 背压 | 3,000 | 12.620 Gbps |

全部 PASS。10,000 条 Mixed 消息平均 Core 占用 15.73/16，Block/Cycle 0.23138，约为 16 Core、65 cycles/block 理论 Block 速率的 94%。**28.384 Gbps 已是输入 32 Gbps 理论上限的 88.7%**。单纯扩核而不扩输入、前端与结果处理，实际 Payload 吞吐不会线性增长。

## 3. 高利用率会恶化时序吗？

**更有可能带来显著时序收敛风险，但不能直接断言 WNS 会恶化多少或 250 MHz 一定失败。** 必须在目标架构和真实系统模块上实测。

主要因素：

1. **拥塞/布线绕行**：当前关键路径已 64.2% Route Delay，密度增加可能使 LUT/CARRY8/FF 不再邻近。
2. **Clock/Reset/CE 和全局控制网**：增加负载和物理跨度，时钟插入延迟及负偏斜可能变化。
3. **宽数据路径**：512-bit Block、256-bit Hash/State、跨核仲裁和结果回传可能形成局部路由热点。
4. **控制集、LUTRAM、BRAM 布局约束**：器件全局资源富余不代表局部区域可布线。
5. **关键路径转移**：从 +1 ps 修复 Core[5] 后，还会出现 Core[9] +2 ps、Core[12] +5 ps、Engine/Top 边界等次临界路径。
6. **I/O/系统集成**：OOC 的输入/输出 false path 不能代表板级时序签核。

### 3.1 占用率与 Packing：数量级示例

目前 29,000 LUT / 5,381 个已用 CLB ≈ **5.39 LUT/CLB**。KU060 共 41,460 CLB、331,680 LUT。如果目标 **80% / 90% 是全器件 LUT 利用率**：

| 指标 | 80% LUT | 90% LUT |
|---|---:|---:|
| LUT 数量 | 265,344 | 298,512 |
| 即使使用全部 CLB，平均每 CLB 至少需 | **6.40 LUT** | **7.20 LUT** |
| 以当前 5.39 LUT/已用 CLB 外推，所需 CLB 占器件比例 | 118.8% | 133.6% |

此表只是**固定当前装箱密度的数学示例，不是未来的工具预测**：架构、控制集、复制、LUTRAM 和物理优化都会改变装箱密度。它说明 80%～90% LUT 目标不只是“复制更多 Core”，还要求更高 Packing 与更复杂的布线规划。

如果所谓 80%～90% 指 **CLB 占用率**，应按 CLB/Clock Region 另做分析，而非套用这张 LUT 表。

## 4. 推荐的 RTL Cluster 架构（场景 A）

```text
多个 AXI-Stream / DMA 输入（可先从 1 路升级到 2 路）
                      |
       Block Builder / 输入分发（可复制）
                      |
       全局 Cluster Allocator（寄存边界）
             +--------+--------+
             |                 |
         Cluster 0          Cluster 1 ... Cluster N
        Local Context      Local Context
        Local Pool         Local Pool
        Local Scheduler    Local Scheduler
          4/8 Core          4/8 Core
        Result FIFO        Result FIFO
             |                 |
             +-----分层 Result Merge-----+
```

实施原则：

- **先比较 4 Core/Cluster 与 8 Core/Cluster**，不预先认定较小 Cluster 一定更快。
- 按消息为 Cluster 分配 Context，**同一消息的连续 Block 固定在原 Cluster**，避免 256-bit Hash State 跨区迁移。
- Cluster 内本地 Block Pool、Hash State/Context RAM、调度与结果 FIFO；全局优先传较窄的 ID/流控，降低大总线跨度。
- Cluster 入口/出口采用寄存/Elastic FIFO，避免 Ready/Valid 形成跨区域组合环；保持多条消息并发、背压数据稳定与顺序约束。
- 新消息按 Cluster 空闲容量分配并统计负载；关注长消息与短消息混合时的局部 Pool 用尽、Context 资源倾斜和 HOL blocking。
- **多路输入应和 Core 增长同步规划**；短消息也需要核对 Result Mmsg/s 与输出带宽，不能只看 Gbps。
- 可以探索柔性 pblock / Clock Region 亲和布局，但不要过早固定物理边界而限制 Router。

**先做 4×4 与 2×8 的 16 Core 原型对比**（不增加 Core），只改变层级并行性和分发路径。若与当前单 Engine 版本相比，吞吐无退化、跨模块 WNS/拥塞更好，再扩 32/64 Core；否则先修架构，不直接暴力扩核。

## 5. 何时优先 ECO，何时优先 RTL/物理架构？

| 观察到的真实实现问题 | 优先措施 |
|---|---|
| v42 16C OOC 仅余少量近临界路径，布局固定 | **局部 post-route ECO**（独立 DCP 副本） |
| 高密度后 WNS 大幅为负、失败端点很多、TNS 很大 | **RTL 分层/寄存边界/减少跨区域宽总线** |
| 单 Engine、跨 Cluster Ready/Commit/Hash 总线成为长路径 | **架构重分区** |
| 高密度后仅 1～10 条孤立略负路径且拥塞不严重 | **尝试 ECO + 增量布线/physopt** |
| SM3 不扩核、周围 IP 带来 80%～90% 资源压力 | **整卡 floorplan + 接口隔离 + 完整 P&R** |
| Core 利用率下降、输入/结果吞吐先到顶 | **优先扩 I/O、Builder/Result 通道**，不是再复制 Core |

现有 Core 的单点移动可以在保留签核版本的前提下用于 **ECO2 探索**，但不能把它当作全局扩容方法。若目标是 WNS ≥ +0.10 ns，除了多个 Core，Engine 边界 +0.052 ns、Top glue +0.092 ns 也会成为限制，不能只修 Core[5]。

## 6. 密度递增 P&R 实验矩阵（推荐）

以下百分比主要以 **CLB 占用率观察点**表示，不代表强制项目验收目标，也不要求无意义地填满资源。

| 阶段 | 结构/负载 | 必须验证的结论 |
|---|---|---|
| M0 | 冻结 v42 16C + ECO1 | 保存 DCP SHA256、Git SHA、XDC、Tcl 和基准报告 |
| M1 | 4×4 vs 2×8 Cluster，16C 不变 | 同 Core 数下功能、吞吐、WNS、LUT/FF、拥塞 |
| M2 | 32C/64C，多路输入与 Builder | 数据入口是否随 Core 扩容，调度/结果通道是否伸缩 |
| M3 | 真实 IP/Cluster 负载，约 25%、45%、60% CLB | 各密度 post-synth/place/route WNS、局部拥塞 |
| M4 | 约 70%～75% CLB（确有需求且物理可行） | 分析物理收敛、吞吐、BRAM/控制集/功耗 |
| M5 | 探索 80%～90% 密度（独立风险实验） | 找出可实现边界，不预先保证 250 MHz |

每个候选都需要相同器件、时钟、约束口径与同一 Vivado 版本；存档 RTL SHA、参数、P&R directive、策略/seed。至少比较两种布局方案，避免单次布线偶然性。

### 必须记录的度量

- **物理**：Post-synth、Post-place、Post-route 的 WNS/WHS/TNS/THS、失败端点、Logic Delay/Route Delay、最差 100 条路径、Clock Skew。
- **资源**：LUT/FF/CLB/BRAM、层级统计、Control Sets、各 Clock Region 局部占用和 Congestion。
- **扇出**：高扇出信号的 Driver/Load Type、Worst Slack，不能把 CLK/RESET/CE 混成普通 Data Fanout。
- **性能**：Payload Gbps、Block/Cycle、Mmsg/s、平均/峰值 Core 利用率、Pool/Context/FIFO 最小空闲数。
- **准确性**：cocotb Golden Digest、Message ID、重复/丢失、背压稳定、全部资源最终释放。
- **签核口径**：明确是 OOC 内部 reg-to-reg 还是整卡 I/O 已建模的完整约束；两者不能混用。

建议按实验生成：`manifest.md`、`utilization_hier.rpt`、`timing_summary.rpt`、`timing_max100.rpt`、`high_fanout.rpt`、`route_status.rpt`、`congestion.rpt`、`cocotb_summary.txt` 与独立归档的 `routed.dcp`（记录 SHA256）。

## 7. RTL 改动优先级与验证要求

| 候选改动 | 潜在收益 | 主要风险 |
|---|---|---|
| Local Scheduler（4/8 Core） | 减少全局仲裁与扇出 | Context 倾斜、局部空转 |
| Context/Pool 分区 | 512/256-bit 数据局部化 | 分区 Pool/Context 提前耗尽 |
| 多 Builder/多 Stream | 突破单输入 32 Gbps 理论上限 | 描述符/数据归属错位 |
| 分层 Result FIFO / Merge | 切断全局回压链 | 消息乱序关联、输出瓶颈 |
| 最后一轮 Hash Output Pipeline | 缩短 TT/Hash 同周期逻辑 | 结果延迟、Commit 协议改变、全新 P&R |
| Core CE/数据网复制 | 控制局部扇出与路由 | 增资源、改变已收敛布局 |

针对新 RTL 必须重跑 Core Known Vectors、随机压缩块、长度 0～4096B、55/56/63/64/65B 边界，以及 Top mixed 1k/10k、short-heavy、single-biased、**long-heavy**、多种随机种子与长期 Ready/Valid 背压；检查所有 Message Digest、Context/Pool/Result FIFO 回收和 Reset 恢复。现有 v42 的测试 PASS 不能替代新架构的回归。

**物理验收**：确保所有实际要求约束的 Setup/Hold 满足、0 失败端点，检查 Unconstrained Paths、DRC 和实际时钟/I/O；争取 Post-route WNS +0.10～+0.20 ns 作为实验工程余量目标，**不保证此余量能实现**。如果高密度使多数路径同时失败，优先返回 RTL/系统架构，不进入无休止的单点 ECO。

可在已有 routed checkpoint 上读取：

```tcl
report_utilization -hierarchical -hierarchical_depth 6 -file final_utilization_hier.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file final_timing_summary.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 -file final_timing_max100.rpt
report_high_fanout_nets -fanout_greater_than 100 -max_nets 100 -timing -file final_high_fanout.rpt
report_route_status -file final_route_status.rpt
```

## 8. 建议的具体行动

1. **不修改现有 v42/ECO1 签核 RTL 和 DCP**；先冻结可复现资料。
2. 对目标容量写出明确拆分：最终占比主要是新 SM3 Core 还是外部系统 IP？分别给出 LUT、CLB、FF、BRAM 与输入带宽预算。
3. 新开 `experiment/sm3-cluster-scaling` 分支实现 4×4、2×8 两套 Cluster 版本，先在 16 Core 上对照功能和时序。
4. 建立至少双输入通道的供数可行性对照，避免计算资源增加后单路输入饱和。
5. 对真实 32/64 Core 或系统 IP 组合进行密度阶梯 P&R，而非用会被综合优化掉的填充逻辑得出结论。
6. 高密度架构收敛到少量最差路径后，再对**该高密度 DCP**做局部 ECO；不要求复用原 ECO1 的相同 Cell LOC。

**最终建议**：增加 SM3 Core、追求 80%～90% 器件利用率时，选择 **RTL/系统架构实验为主，ECO 为辅**；若只是将现有 16 Core 放入资源很满的系统，则选择 **系统级物理规划优先，在失败路径定位后再决定是否修改 RTL**。决策依据必须是吞吐和完整 P&R，而不是仅凭当前 16 Core 的 +1 ps WNS。

## 9. 源报告

- [最终 250 MHz 时序、资源与模块级分析（第 8～9 节）](./TIMING_V1_FINAL_RESULT.md)
- [v42 cocotb 压力回归](./TIMING_V1_COCOTB_STRESS_RESULT.md)
- [最终层级资源报告](./route_v42_eco1_physopt/final_utilization_hier.rpt)
- [模块级 Setup 最差路径](./route_v42_eco1_physopt/final_module_timing_fixed2.out)
- [高扇出及负载](./route_v42_eco1_physopt/final_high_fanout_nets.rpt)
- [前 20 条 Setup 路径](./route_v42_eco1_physopt/final_timing_max20.rpt)

> 本次提交只增加 Markdown 建议文档；**没有更改 RTL、约束、Tcl、综合/P&R 结果或已经签核的 ECO checkpoint**。
