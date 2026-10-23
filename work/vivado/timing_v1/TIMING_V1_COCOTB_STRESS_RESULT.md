# Timing Pipeline V1 — v42 最终 RTL 的 cocotb 压力回归

- 日期：2026-10-23
- DUT：`sm3_fpga/latest/milestone6` 的最终 v42 RTL（源代码提交 `a893fc93a3eb1040501e5139ae787036a4cfbe55`）
- 验证提交：`eabafc05e57beb47651f4efa2416806f1df89341`（只增加 GitHub Actions 测试流程，不更改 RTL）
- GitHub Actions 运行：[39885836839](https://github.com/FPGA-liyinlong08/sm3/actions/runs/39885836839)
- 环境：GitHub Actions ubuntu-24.04 / Verilator 5.048 / cocotb 2.1.0
- 配置：`CORE_NUM=16`、`CTX_NUM=32`、`FAST_DEPTH=32`、`POOL_DEPTH=512`
- 仿真时钟：4ns (250MHz)，吞吐量由有效 payload bytes / 仿真周期计算，**不代表板级实测吞吐**。

## 1. 验证结果

| 测试 | NMSG | DRIVE_PROB | READY_PROB | Payload Bytes | Blocks | Cycles | Block/Cycle | Payload Gbps | Mmsg/s | 结果 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| mixed | 1,000 | 96 | 94 | 981,523 | 15,956 | 71,176 | 0.22418 | 27.580 | 3.512 | PASS |
| mixed | 10,000 | 96 | 94 | 9,054,250 | 147,618 | 637,979 | 0.23138 | 28.384 | 3.919 | PASS |
| short_heavy | 3,000 | 85 | 60 | 586,061 | 10,935 | 54,441 | 0.20086 | 21.530 | 13.776 | PASS |
| single | 3,000 | 90 | 75 | 94,615 | 3,214 | 14,994 | 0.21435 | 12.620 | 50.020 | PASS |

所有 4 个测试均报告 `TESTS=1 PASS=1 FAIL=0 SKIP=0`。

| 场景 | max_core | avg_core | max_ctx | min_pool_free | max_fast | avg_ready_ctx |
|---|---:|---:|---:|---:|---:|---:|
| mixed 1000 | 16 | 15.24 | 32 | 0 | 5 | 7.74 |
| mixed 10000 | 16 | 15.73 | 32 | 0 | 6 | 9.86 |
| short_heavy 3000 | 16 | 13.67 | 31 | 250 | 10 | 3.35 |
| single 3000 | 16 | 14.61 | 10 | 368 | 32 | 0.14 |

## 2. 覆盖与断言

测试平台：`tb/test_sm3_accel_top.py`，固定 PRNG 种子 `0xE2E52026`。

- Python Golden Model SM3 Digest 对比。
- 无未知 Message ID、无重复结果、所有消息完成。
- `result_valid && !result_ready` 时输出 Digest/Message ID 保持稳定。
- 输出端随机背压，并每 401 周期强制拉低 `result_ready` 11 个周期。
- Context、Fast FIFO 与 Block Pool 资源全部回收：最后要求 `dbg_ctx_allocated == 0`、`dbg_fast_level == 0`、`dbg_pool_free == POOL_DEPTH`。
- mixed 10000 压力测试达到 32/32 Context 分配和 Block Pool 空闲数 0，覆盖满资源背压。
- 单块偏重 profile 的开头仍包含边界长度样本，故表中 3,214 blocks 大于 3,000 messages。

## 3. 性能解释

16 核迭代 SM3、单 Core 65 cycles/block 的理论上限是 `16/65 ≈ 0.24615 block/cycle`；mixed 10000 实测 `0.23138` 约为该上限的 **94.0%**。因此平均 Core 占用达到 15.73/16 的结果与吞吐量相符。

`min_pool_free=0` 是测试过程中的最小值，并不代表测试结束时 Pool 泄漏；最终 `dbg_pool_free == 512` 断言通过。

## 4. 执行命令与复现

CI workflow：`.github/workflows/sm3-timing-v1-regression.yml`，按下面参数执行同一 Makefile：

```bash
cd sm3_fpga/latest/milestone6
# 要求 Verilator >= 5.036，推荐 5.048；cocotb 2.1.0
NMSG=1000  PROFILE=mixed       DRIVE_PROB=96 READY_PROB=94 make -f Makefile.top SIM=verilator CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512
NMSG=10000 PROFILE=mixed       DRIVE_PROB=96 READY_PROB=94 make -f Makefile.top SIM=verilator CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512
NMSG=3000  PROFILE=short_heavy DRIVE_PROB=85 READY_PROB=60 make -f Makefile.top SIM=verilator CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512
NMSG=3000  PROFILE=single      DRIVE_PROB=90 READY_PROB=75 make -f Makefile.top SIM=verilator CORE_NUM=16 CTX_NUM=32 FAST_DEPTH=32 POOL_DEPTH=512
```

原始作业日志和 XML 已由 workflow 上传至 artifacts（`sm3-timing-v1-simulation-logs`）。

## 5. 未覆盖事项

- 当前只有单个固定随机种子，尚未执行多种子/故障注入回归。
- 未单独设置 long-heavy profile（mixed 包含最长 4096B 的测试样本）。
- 这些是 RTL 功能和仿真吞吐测试，不验证 Vivado 物理时序；后者仍应依据现有 v42 + post-route ECO DCP 与内部路径报告。
- 物理报告当前仅使用内部 reg-to-reg 签核口径，不代表顶层 I/O 已建模或板级已 sign-off。
