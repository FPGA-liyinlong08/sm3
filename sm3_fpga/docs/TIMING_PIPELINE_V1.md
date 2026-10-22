# SM3 16-Core 时序优化 V1（实验分支）

> 分支：`opt/timing-pipeline-v1`  
> 基线：`main` 的 Milestone 6  
> 器件目标：XCKU060-FFVA1156-2-E / Vivado 2021.2 / 250 MHz  
> 状态：**待 RTL 功能回归、Vivado 综合与布局布线验证，不可合并作为 sign-off。**

## 1. 目标与范围

当前 main 版 Top OOC route 报告 WNS -5.566 ns，最差路径：
`core[11].out_valid -> commit/sticky -> ctx_head -> next_mem LUTRAM -> ctx_head[D]`。
已测得单核优化版 `work/vivado/rtl_opt/sm3_core_opt2.sv` 的独立 OOC WNS +0.226 ns（与 Top 不同的约束/优化条件）。

V1 的目标是先切开 `next_mem` 异步读及 `ctx_head` 同周期写回链路，而不是声称一次性实现 Top 250 MHz 收敛。

## 2. 修改内容

1. **Core**：将既有 `sm3_core_opt2.sv` 集成到正式 `rtl/core/sm3_core.sv`，保留 65 cycles/block 的原协议和 `Tj` 预旋转、`max_fanout` 提示。
2. **Block Pool**：增加 `link_rd_en`，将原 `assign link_rd_next = next_mem[link_rd_slot]` 改为两拍路径：先锁存 slot 地址，再在下一时钟沿读 `next_mem` 到输出寄存器。
3. **Pool Engine**：对非单节点 Pop 在两个流水阶段后提交 `ctx_head`；所有已 Pop 的 Slot 均延迟两拍释放，防止在读取旧链指针之前被复用。
4. 不改动 `main`、不改变外部 Top 接口或 Block Pool 容量。

## 3. 时序与协议关系

| 相位 | 动作 | 关键状态 |
|---|---|---|
| E0 | 选中 Pop，启动 payload BRAM 同步读，锁存 link slot / ctx / free slot | head 尚未更新，context inflight |
| E1 | 同步读取 `next_mem[slot]`，缓存 successor | 旧 slot 尚未释放 |
| E2 | 非单节点的 `ctx_head` 使用缓存 successor 更新；旧 slot 返回 Free List | 链表指针安全退休 |

只有 `head != tail` 时读取 successor；单节点 Pop 仍在 E0 更新 `ctx_pending_valid`，与同 Context 的 Push 同拍逻辑保留。

### 必须复验的边界场景

- 同 Context 同周期 Push+Pop（旧队列 1、2、3 节点分别测试）。
- 连续多个不同 Context 的 Pop；所有 Slot 最终回收到 Pool。
- `POOL_DEPTH` 接近满载、空闲 Slot 数量为 0～2 时的背压。
- Sticky continuation：禁止同 Context 在 `ctx_head` 的延迟更新完成前重复 Pop。
- `result_ready` 长时间拉低、Context 重用、复位中断初始化。
- `next_mem` 同一地址读写的时序和 RAM 推断；验证不存在旧 slot 过早复用。

## 4. 验证现状

本次仅完成了：与已验证 Core 版本逐字比对、RTL 结构检查、`begin/end` 和模块关键标志静态检查，以及基于同 Context 至少相隔 65 周期 Pop 的抽象队列模型随机实验。

**未执行** Verilator lint、cocotb 功能回归、Yosys 或 Vivado；当前执行环境未安装这些 EDA 工具。抽象模型不能代替 RTL 时钟级仿真。

在已有 Verilator + cocotb 环境中执行：

```bash
cd sm3_fpga/latest/milestone6
bash scripts/check_timing_v1.sh
```

完成后使用 Vivado 重跑：

```bash
vivado -mode batch -source work/vivado/top_16c_32ctx_ooc/run_top_ooc.tcl
```

**注意：** 上述 Vivado 脚本中的绝对目录为原作者本地路径，需先调整 `root/out` 后再运行。报告中 OOC 端口/时钟限制需与板级 in-context 复验区分。

## 5. 继续优化条件

V1 功能回归通过后，比较同一约束下 16C/32CTX/512Pool 的 post-route WNS/TNS、关键路径、LUT、FF、BRAM 和 Mixed/Short-heavy throughput。如果关键路径转向 `core_out_valid -> commit/sticky -> pool_rd_slot`，V2 再将 16:1 Commit 仲裁寄存器化，并补全 out_ready、Sticky 同核续算和结果背压逻辑。

在完成 cocotb、时序收敛与物理检查之前，**不要合并到 main**。
