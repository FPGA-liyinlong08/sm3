# SM3 FPGA 多核加速器综合与时序优化建议

> 仓库：[FPGA-liyinlong08/sm3](https://github.com/FPGA-liyinlong08/sm3)  
> 基线：`main` / `sm3_fpga/latest/milestone6`（依据 2026-10-22 仓库已有 RTL 与报告）  
> 目标器件：`XCKU060-FFVA1156-2-E`；Vivado 2021.2；目标时钟 **250 MHz（4.000 ns）**  
> 基线配置：`CORE_NUM=16`、`CTX_NUM=32`、`FAST_DEPTH=32`、`POOL_DEPTH=512`  
> 文档性质：针对仓库现有报告的分析与**待实施**优化方案；本文未运行新的综合、布局布线或仿真。

## 1. 结论与优化目标

**当前首要瓶颈是 16 Core 顶层的控制路径时序，而不是 FPGA 资源容量。** 单核可以通过优化达到 250 MHz，但顶层在 250 MHz 下尚未收敛。建议保留“迭代 Core + Context + Block Pool + 动态调度”主体架构，重点重构 `Commit → Sticky → Context Queue Pop → next_mem → ctx_head` 的同周期组合链。

近期工程目标：

1. 在不降低功能正确性的前提下，消除 Top 关键路径中的异步指针读取和超长组合仲裁。
2. 在**相同器件、相同约束、相同实现阶段**下，实现 `WNS >= 0 ns`、`TNS = 0`；工程上建议争取 `WNS >= +0.3 ns` 的余量。
3. 保持 Block Pool/Context Hash RAM 正确推断为片上存储，避免因改 RTL 导致大规模 FF 化。
4. 使用相同混合消息工作负载测量吞吐、Core 利用率、延迟分位数和回压下的稳定性；不能只比较无背压的理想测试。
5. 最终采用板级/系统级 Wrapper 进行 **in-context** 时序评估；OOC 的结果仅作为阶段性参考。

## 2. 已有综合/实现数据

来源：[Vivado 2021.2 实现报告](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/VIVADO_2021_2_REPORT.md)、[全 Top post-route 时序报告](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_timing_max_routed.rpt)。

| 项目 | 已有结果 | 判断 |
|---|---:|---|
| 原始 Core，真实 BUFG + Explore/fanout，内部 WNS | `+0.009 ns` | 临界通过，余量很小 |
| 优化 Core（Tj 预旋转 + 扇出控制），内部 WNS | `+0.226 ns` | 单核 OOC 通过，仍需 Top 复验 |
| 16 Core / 32 Context / Pool512，全 Top OOC post-route WNS | **`-5.566 ns`** | 严重不收敛 |
| 全 Top TNS | `-108,989.641 ns` | 多个端点失败 |
| 全 Top失败端点 | `47,172 / 59,971` | 非单条孤立失败路径 |
| 最差 reg-to-reg 数据路径延迟 | `9.497 ns` | 远超 4 ns 时钟周期 |
| 最差路径逻辑 / 布线延迟 | `2.787 / 6.710 ns` | 布线约占 70.7% |
| LUT | `28,693` | KU060 使用约 8.65% |
| FF | `26,096` | KU060 使用约 3.93% |
| BRAM | `11 RAMB36 + 1 RAMB18` | 约 11.5 个 BRAM36 等效 Tile |
| DSP | `0` | 无 DSP 压力 |

注意：`28,693` 是 Vivado 的 LUT 使用量，不应与 Yosys `32,812` LC 估算直接当成同口径指标。原始 Core 的 `+0.009 ns` 与优化 Core 的 `+0.226 ns` 来自报告中的对应单核 BUFG 优化流程；Top 的综合脚本仍读原始 Core。

**典型最差路径：**

```text
core[11].out_valid_reg
  -> 16:1 Commit 优先级仲裁 / 结果选择
  -> Sticky 判定、Context 选择
  -> ctx_head[pop_ctx_idx] 动态索引
  -> next_mem[pop_slot] 异步 LUTRAM 读取
  -> ctx_head 寄存器写回
```

相关 RTL：[`sm3_pool_engine.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/context/sm3_pool_engine.sv)、[`sm3_block_pool.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/context/sm3_block_pool.sv)。

已有 Explore + AggressiveFanoutOpt 的第二次 OOC 尝试，在未完成 route 收尾时记录的 WNS 为约 `-5.016 ns`；这是**中间结果**，不能与完整 post-route sign-off 混为一谈。说明仅靠实现指令微调难以弥补当前组合链延迟。

## 3. 优化优先级总表

| 优先级 | 模块/问题 | 建议改动 | 核心收益 | 验证重点 |
|---|---|---|---|---|
| **P0** | Top 仍实例化原始 Core | 将已验证的 `sm3_core_opt2.sv` 集成至正式 RTL | 移除已知 Core round 路径压力 | Core 305 向量、Top 功能回归 |
| **P0** | Core 输出直接驱动 Commit/Pop | Commit 接收握手 + 寄存器/小 FIFO，切分阶段 | 切断 Core 到 Context 写回的长组合路径 | 多 Core 同时完成、结果背压 |
| **P0** | `next_mem` 异步读串在 ctx_head 写回前 | 改同步读并设置 Pop 阶段状态机 | 打断动态索引 + 异步 RAM + 更新的同周期路径 | Push/Pop 同 Context、指针一致性 |
| **P0** | Queue 状态与发射重叠 | 每 Context pending-pop/reservation 标记及旁路 | 保证流水线改造不重复派发 | Sticky/普通派发竞争 |
| **P1** | 16:1 Commit 和 32 Context 线性扫描 | 分组仲裁、掩码/one-hot RR、分段寄存 | 缩短逻辑层级与跨区布线 | 仲裁公平性、持续吞吐 |
| **P1** | 结果口回压引起队头阻塞 | 独立 Result FIFO；可提交 Core 仲裁 | 避免最终结果堵塞中间块提交 | 随机 `result_ready` |
| **P1** | 高扇出控制、跨区宽总线 | 明确扇出分级、局部注册、优化物理聚集 | 降低布线延迟 | Post-route 最差路径/拥塞 |
| **P2** | 调试口及板级集成 | Debug CSR/ILA 化，系统 Wrapper 统一接口 | 消除顶层 I/O 超限、获得可信 in-context 结果 | Pin/Clock/CDC/复位约束 |

## 4. 分项详细建议

### 4.1 将已验证的优化 Core 纳入 Top（P0，低风险）

现状：仓库有 `work/vivado/rtl_opt/sm3_core_opt2.sv`，其中增加了 `tj_rot_q` 预旋转寄存器与 `busy/load_en` 的 `max_fanout` 控制；单核 xsim 记录验证了 305 个压缩向量。但是当前 Top 综合脚本 `work/vivado/top_16c_32ctx_ooc/run_top_ooc.tcl` 仍读取：

```tcl
$root/rtl/core/sm3_core.sv
```

建议操作：

1. 在独立分支中将优化逻辑合入正式 `rtl/core/sm3_core.sv`，避免长期维护两个同名 `module sm3_core` 的源文件。
2. 保留 `load + 64 rounds` 的功能与现有 `in_valid/in_ready/out_valid/out_ready` 协议。
3. 先运行单核已知向量、随机 Hash 初态、复位与连续块握手测试，再运行 Top cocotb 回归。
4. 单独做一次 **只替换 Core、不调整 Scheduler** 的对照综合与实现，以隔离优化收益；预期无法单独修复 Top 控制路径。

### 4.2 Commit 接收通道寄存器化（P0，核心改造）

**现状：** Commit 的 `commit_core_sel / commit_ctx_id / commit_hash` 组合逻辑在一个周期内继续驱动 `sticky_issue`、`ctx_pop`、`ctx_head`，导致路径串联。

**建议分阶段：**

```text
Core[n].out_valid/out_data
       |
       v
[Stage C0] 分组仲裁 + Commit 接收
  - 仅在存储空间可用时 assert core_out_ready[n]
  - 将 {core_id, ctx_id, msg_id, hash, last, is_fast} 锁存
       |
       v
[Stage C1] 提交状态更新与 Sticky 决策
  - hash commit / digest enqueue
  - Context inflight/ownership 更新
  - 决定后续 Queue Pop 请求
       |
       v
[Stage P0/P1] Queue Pop / next 指针同步读 / ctx_head 更新
       |
       v
[Launch] 下一块数据读取 + Hash bypass + Core 发射
```

**必要协议约束：**

- `core_out_ready[n]` 必须以 **Commit 接收能力**为条件，不能在无空位时先 ACK 后丢数据。
- Commit 管线或 FIFO 满时允许对 Core 反压；同一 Core 尚未完成提交或尚未安全解除 reservation 时不得被重新分配。
- 保持每个消息最多一个压缩块在执行的顺序约束；最终 Digest 对 `result_ready` 保持稳定。
- 若多 Core 同时完成，保证每条结果恰好进入一次 Commit；不允许覆盖正在排队的 `commit_hash`。
- **不要假定增加 1 个流水级就一定使单核 service interval 从 65 变 66 周期**：真实变化取决于 ACK、Core 重用、Sticky bypass 和流水重叠，应通过仿真测得。

建议先采用 **单入口 Commit pipeline + 一个小型接收缓冲**，验证正确性，再决定是否增加吞吐深度或分组并发提交。

### 4.3 `next_mem` 改同步读 + Queue Pop 状态机（P0，核心改造）

当前异步读：

```systemverilog
assign link_rd_next = next_mem[link_rd_slot];
```

建议使用时钟同步读的存储过程（以下仅表示设计方向，**不能直接替换且不处理接口时序**）：

```systemverilog
always_ff @(posedge clk) begin
    if (link_rd_en)
        link_rd_next_q <= next_mem[link_rd_slot];
end
```

需增加 `link_rd_en / link_rd_valid` 或明确的定长流水控制，并重新组织 `sm3_pool_engine` 的 Pop：

1. **P0**：锁存 `pop_ctx_idx`、`pop_slot=ctx_head[ctx]`、`pop_single_old`，设置此 Context 的 Pop reservation。
2. **P1**：执行 `next_mem` 同步读（若非单元素队列）；同时保证 payload BRAM 的读取地址和数据有效性与 Pop token 对齐。
3. **P2**：获取 `next_slot`，原子更新 `ctx_head/ctx_pending_valid`；按实际消耗时刻安全返还空闲 Slot，清除 Pop reservation。

必须显式定义以下情况的状态更新优先级：

- 同一 Context 同周期 `push` 与 `pop`；
- 只有 1 个 Slot 时 `pop + push`；
- 队列已有多个 Slot，Pop 期间又追加尾部节点；
- `next_mem` 读写同地址、旧 Slot 释放后很快被重新分配；
- Sticky 延续使用前一块完成的 `hash_out`，而下一块 payload 尚在 BRAM read pipeline 中；
- `ctx_valid` 释放、Message ID 复用、Reset/初始化与未完成 Pop 的边界。

**推荐实现方式：** 将 queue metadata 的“读—修改—写”当作一笔带有效位的事务处理；一个 Context 在 Pop 更新完成之前不得再次被普通 Scheduler 选中。只有验证同 Context 操作可以旁路合并后，才开放完全重叠的读写，以免产生难复现的链表破坏。

### 4.4 重构 Core/Context 仲裁（P1）

现状：

- `for (k=0; k<CORE_NUM; k++)` 逐项寻找第一个完成 Core；
- Context 轮询包含 32 次动态索引与比较；
- `commit_core_sel` 后面还有宽 `hash`/`tag` 选择和 Sticky 判断。

建议：

- Core 采用 `4 × 4` 分组仲裁，必要时在组内/组间加入流水寄存器。
- Context 先组合生成 `eligible[31:0] = valid & pending & ~inflight & ~reserved`，再用**位图 + RR mask**寻找下一个可执行 Context，避免逐项动态读取并累计加减。
- 对优先级选择的 `grant` 使用 one-hot 表示，在需要的时候才编码成 Core/Context ID。
- 为分组 Core 的宽 Hash 输出做局部寄存或按组汇聚，避免 16 个 256-bit 结果贯穿整个控制区域。
- 如果有结果背压，不应始终让一个不可提交的低编号 Core 阻塞所有其他完成 Core；为合法可提交项单独产生 `eligible_commit`。

### 4.5 结果缓冲和 Sticky 策略（P1）

- 建议在外部 `result_valid/result_ready` 之前加入小型 Digest FIFO，隔离外部消费背压与内部 Commit（容量应按系统最大回压突发决定）。
- 保留 `msg_id + digest` 一一对应，结果可乱序但不能丢失或重复。
- Sticky 续算仅能在上一块 Hash 已提交/已安全旁路、下一块已取到且 Core 可复用时发起。
- 重新评估 Sticky quantum、`FAST_QUOTA` 与 P99 延迟；改善 Fmax 不应以短消息长期饥饿为代价。

### 4.6 BRAM/LUTRAM、Debug 及物理实现（P1/P2）

- **保留** Block Pool `512 × 514` 的宽 BRAM 组织：Vivado 已映射 `7 RAMB36 + 1 RAMB18`，逻辑位利用率较好。
- `hash_mem` 使用 `4 RAMB36`，容量效率虽然低，但全器件 BRAM 占用极低，当前没有必要为了减少 BRAM 而冒着将读数据路径变慢的风险改 FF。
- `free_fifo/next_mem` 的存储原语、读口数可能随 RTL 优化改变；每次应检查 `report_ram_utilization`，不能仅看总 LUT。
- **输入/输出端口风险**：现有算法 Top 的 I/O 合计 `569 bit`，超过器件封装 `520` 个 bonded I/O；去掉 65 bit debug 后为 `504 bit`。但即使数字上够用，也必须核对真实 I/O bank、电压和引脚分配。建议通过 AXI/内部流接口 Wrapper 接入系统，Debug 改为 CSR/ILA 或压缩接口。
- 先解决 RTL 长组合路径，再考虑 `phys_opt_design -directive AggressiveFanoutOpt`、局部分组布局和多实现策略；不要提前依赖手工 floorplan 掩盖结构问题。

## 5. 建议实施里程碑

### M0：冻结基线 / 可复现环境

- 固定 Git commit、Vivado 版本、Part、XDC、Core/Context/Pool 参数和仿真种子。
- 收集 Baseline：`report_timing_summary`、`report_timing -max_paths 50`、层次资源、RAM 映射、拥塞、Clock/Control Set 报告。
- 对 8 Core 和 16 Core 建立一致的混合消息 benchmark，并保留随机背压用例。

**交付**：baseline 资源和时序汇总、Top 性能统计、功能通过日志。

### M1：集成优化版 Core

- 合并 `sm3_core_opt2` 的预旋转和扇出相关改动。
- 跑 305 向量单核验证、Top smoke/mixed/stress 测试。
- 对照测量顶层 WNS 和资源变化，明确改善发生在 Core 还是控制路径。

**交付**：可回退提交、完整仿真日志、对照报表。

### M2：Commit/Queue Pop 流水线

- Commit FIFO / 寄存器化，建立 ACK 与数据捕获的一致性。
- `next_mem` 同步读，按 token 跟踪 Queue Pop 事务。
- 增加 Context reservation/hazard/bypass；覆盖同步 push/pop、Sticky 和背压场景。
- 先跑 8 Core 回归，再跑 16 Core 回归；每个阶段重新综合和报告 Top 最差 20 条路径。

**交付**：关键路径从 Core 输出至 ctx_head 写回链路上消失；零功能回归失败。

### M3：仲裁与吞吐优化

- 若 Top 仍无法收敛，分组 Core/Context 仲裁并分级注册。
- 增加 Result FIFO、修复不可提交 Core 引发的队头阻塞。
- 依据仿真计算吞吐、Core Busy 比例、Context 峰值、Block Pool 峰值、P50/P99 延迟。
- 16 Core / 32 Context 测试中曾观察到峰值 Context 占用 `29/32`；修改延迟后需要重新确认 32 Context 是否仍足够，不要仅凭旧数据锁定容量。

**交付**：与 baseline 相同负载下的资源/时序/吞吐对照。

### M4：in-context 板级时序与验收

- 添加真实 clock/reset、内部 stream/AXI Wrapper，检查端口与引脚约束、时钟树和 CDC。
- 进行完整 post-route sign-off，不能用 post-synth WNS、尚未完成的 route 中间 WNS 替代。
- 如果布局结果对 seed/directive 敏感，应保留至少两组可复现实现作为稳定性比较。

**交付**：带 commit ID、约束版本的最终时序报告与性能报告。

## 6. 仿真回归清单（必须覆盖）

- [ ] 单核 SM3 标准向量、随机压缩块、初始 Hash 自定义向量（不低于已有 305 向量覆盖）。
- [ ] 0B、1B、55B、56B、63B、64B、65B、127B、128B、数 KiB 消息，尤其是 padding 两块边界。
- [ ] 单块 Fast FIFO、多块 Context、短消息密集、长短混合、连续输入。
- [ ] 多个 Core 同一周期完成与高负载下长时间 Commit 排队。
- [ ] `result_ready` 随机阻塞、持续阻塞后恢复；输出在 `valid && !ready` 时稳定。
- [ ] 同 Context Push/Pop：单节点与多节点；队尾链接更新；Free List wraparound。
- [ ] Sticky 续算、Hash bypass 与非 Sticky Hash RAM 写回/读出一致。
- [ ] 每 Context 至多一个压缩块 in-flight；Pop pending 时不可重复 dispatch。
- [ ] Slot 不得双重释放/重复分配；所有请求完成后 Pool 空闲数恢复初值。
- [ ] 每个 Message ID 恰好输出一次 Digest，允许跨消息乱序但 Hash 与参考模型一致。
- [ ] 复位、复位后的 Pool init 时长与 ready 行为。
- [ ] 8/12/16 Core、32/48 Context 的参数组合至少做 elaboration/lint，关键配置完成功能回归。

## 7. 验收指标与报表模板

### 7.1 时序/资源

| 指标 | Baseline | 优化目标 / 验收条件 |
|---|---:|---|
| Top post-route WNS @ 250 MHz | `-5.566 ns` | **>= 0 ns**；建议 >= `+0.3 ns` |
| Top post-route TNS | `-108,989.641 ns` | `0 ns` |
| Top Worst Data Path | `9.497 ns` | 不再超越目标时钟对应的内部时序预算 |
| LUT | `28,693` | 记录变化；以收敛为先，不硬设比例目标 |
| FF | `26,096` | 记录流水级代价，避免意外暴涨 |
| RAMB36/RAMB18 | `11 / 1` | Pool/Hash 映射按预期，记录改动 |
| Core Round II | `64 rounds + load` | 核心算法协议不变；额外握手开销另统计 |

### 7.2 实际负载性能

仓库此前混合负载仿真报告过 **16C/32ctx：25.394 Gbps @ 250 MHz**；1000 消息压力测试报告 **28.270 Gbps @ 250 MHz**。这些属于 RTL 在指定模拟时钟下的结果，**不能称为已实现硬件吞吐**。

建议每次版本的性能记录包含：

```text
Git SHA / Vivado / Part / Clock / Constraints
CORE_NUM / CTX_NUM / FAST_DEPTH / POOL_DEPTH
Workload profile / random seed / NMSG / input-ready model
Compression Block/Cycle / original payload Gbps / Mmsg/s
Avg / Peak Core occupancy, Context occupancy, Pool occupancy
Digest latency P50 / P95 / P99
WNS / TNS / WHS / THS (post-route)
LUT / FF / BRAM18 / BRAM36 / DSP
Top-20 critical paths and congestion hot spots
```

### 7.3 对照矩阵

| 构建 | RTL 变更 | 主要用途 |
|---|---|---|
| A | 当前 main | 固定 baseline |
| B | A + 优化 Core | 测试单核优化是否影响 Top |
| C | B + Commit Register/FIFO | 观察 Core→Commit 长路径是否断开 |
| D | C + Queue Pop 同步读 | 观察 next_mem→ctx_head 长路径是否断开 |
| E | D + RR/结果队列/物理优化 | 争取 250 MHz 稳定收敛与吞吐恢复 |

## 8. 关键工程风险

1. **流水级不等于功能保持。** Commit 和 Queue Pop 不是普通数据通路，必须配合事务状态、冲突处理和握手修改。
2. **同步 RAM 读时延。** 地址、payload、Hash、last/tag 必须随同一事务对齐；不能仍在原周期读取 `link_rd_next`。
3. **队列数据一致性。** Slot 释放与再分配时序、同 Context 同周期 Push/Pop、next 指针尚未产生的边界最易出错。
4. **输出回压。** 不能因为 Digest FIFO 满就错误 ACK Core；要避免数据丢失和系统死锁。
5. **OOC 与 in-context 口径。** OOC 约束、BUFG/HD.CLK_SRC、端口 false path 可能影响时序判读；最终依照真实系统的受约束寄存器路径 sign-off。
6. **性能估算不可替代测量。** 流水化新增若干周期不必然线性降低 block/cycle，具体取决于并行重叠、Sticky 和调度等待。

## 9. 推荐起步修改文件

| 文件 | 建议 |
|---|---|
| [`rtl/core/sm3_core.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/core/sm3_core.sv) | 合并已验证的 Tj 预旋转与扇出优化 |
| [`rtl/context/sm3_pool_engine.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/context/sm3_pool_engine.sv) | Commit pipeline、Pop token、Context reservation、RR 与 Sticky 旁路 |
| [`rtl/context/sm3_block_pool.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/context/sm3_block_pool.sv) | `next_mem` 同步读、读请求/结果对齐、Slot 生命周期约束 |
| [`rtl/top/sm3_accel_top.sv`](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/latest/milestone6/rtl/top/sm3_accel_top.sv) | 保持接口兼容，系统级 Wrapper / Debug 处理 |
| `tb/test_sm3_accel_top.py`、`tb/test_sm3_core.py` | 新增背压、同 Context Push/Pop、流水冲突检查 |
| `work/vivado/top_16c_32ctx_ooc/*.tcl` | 固定对照综合实现流程及报告导出 |

## 10. 最终建议

**先修改 Commit/Pop 时序结构，再做仲裁和物理优化。** 当前 LUT、FF、BRAM 余量充足，可以有意识地用少量额外寄存器与缓冲换取确定的组合路径切分。不要为了减少几个 BRAM/LUT 而引入新的高扇出或异步存储长路径。第一轮应以**功能正确 + 关键路径迁移 + 可复现 post-route 数据**为标准，之后再优化短消息时延和整体 Gbps/LUT。

---

### 资料索引

- [项目仓库](https://github.com/FPGA-liyinlong08/sm3)
- [Vivado 2021.2 综合与实现报告](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/VIVADO_2021_2_REPORT.md)
- [16C/32ctx Top post-route 最差时序路径](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_timing_max_routed.rpt)
- [16C/32ctx Top post-route 层次资源](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_utilization_routed.rpt)
- [优化单核 RTL](https://github.com/FPGA-liyinlong08/sm3/blob/main/work/vivado/rtl_opt/sm3_core_opt2.sv)
- [Yosys UltraScale 资源分析](https://github.com/FPGA-liyinlong08/sm3/blob/main/sm3_fpga/docs/SYNTHESIS_REPORT.md)
