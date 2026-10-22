import os
import random
import sys
from dataclasses import dataclass

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "model"))
from sm3_ref import hash_hex, pad


def ival(sig):
    return int(sig.value)


@dataclass
class Msg:
    msg_id: int
    payload: bytes
    blocks: list[bytes]
    expected: int


def make_messages(rng: random.Random, nmsg: int) -> list[Msg]:
    # Keep this workload identical to test_sm3_multiblock.py so baseline and
    # Fast-Path numbers are directly comparable for a fixed NMSG.
    boundary_lengths = [
        0, 1, 3, 31, 32, 55, 56, 63, 64, 65,
        119, 120, 127, 128, 200, 511, 512, 513,
        1024, 2048, 4095, 4096,
    ]
    profile = os.environ.get("PROFILE", "mixed")
    if profile == "single":
        lengths = []
        while len(lengths) < nmsg:
            lengths.append(rng.randrange(0, 56))
    elif profile == "short_heavy":
        lengths = boundary_lengths[:]
        while len(lengths) < nmsg:
            pick = rng.randrange(100)
            if pick < 80:
                lengths.append(rng.randrange(0, 56))
            elif pick < 95:
                lengths.append(rng.randrange(56, 513))
            else:
                lengths.append(rng.randrange(513, 4097))
        lengths = lengths[:nmsg]
    elif profile == "multi":
        lengths = []
        while len(lengths) < nmsg:
            lengths.append(rng.randrange(56, 4097))
    else:
        lengths = boundary_lengths[:]
        while len(lengths) < nmsg:
            # Mix many short messages with enough long messages to exercise
            # context switching and 65-block chains.
            pick = rng.randrange(100)
            if pick < 35:
                lengths.append(rng.randrange(0, 56))
            elif pick < 65:
                lengths.append(rng.randrange(56, 513))
            else:
                lengths.append(rng.randrange(513, 4097))
        lengths = lengths[:nmsg]

    msgs = []
    for msg_id, n in enumerate(lengths):
        payload = bytes(rng.getrandbits(8) for _ in range(n))
        padded = pad(payload)
        blocks = [padded[i:i + 64] for i in range(0, len(padded), 64)]
        msgs.append(Msg(msg_id, payload, blocks, int(hash_hex(payload), 16)))
    return msgs


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.block_valid.value = 0
    dut.block_data.value = 0
    dut.block_ctx_id_in.value = 0
    dut.msg_id_in.value = 0
    dut.block_first_in.value = 0
    dut.block_last_in.value = 0
    dut.result_ready.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def hybrid_fastpath_stress(dut):
    """Fast single-block bypass + Context RAM multi-block sharing one core pool."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(0xC07E_2026)
    nmsg = int(os.environ.get("NMSG", "160"))
    msgs = make_messages(rng, nmsg)
    msg_by_id = {m.msg_id: m for m in msgs}

    core_num = len(dut.core_occupied)
    ctx_num = len(dut.ctx_valid_bitmap)
    fast_msgs = {m.msg_id for m in msgs if len(m.blocks) == 1}
    multi_msgs = set(msg_by_id) - fast_msgs

    unstarted = list(range(nmsg))
    active: dict[int, dict[str, int]] = {}  # multi-block contexts only
    msg_to_ctx: dict[int, int] = {}
    free_ctx = set(range(ctx_num))
    received: dict[int, int] = {}
    inflight_dbg: set[int] = set()

    cycles = 0
    accepted_blocks = 0
    dispatches = 0
    commits = 0
    fast_dispatches = 0
    fast_commits = 0
    sticky_issues = 0
    max_core_occupied = 0
    max_ctx_active = 0
    max_ctx_pending = 0
    max_fast_level = 0
    core_occupied_sum = 0
    total_blocks = sum(len(m.blocks) for m in msgs)

    max_cycles = max(50000, total_blocks * 100 // max(core_num, 1) + 25000)

    while len(received) < nmsg and cycles < max_cycles:
        await FallingEdge(dut.clk)

        # Randomized result backpressure with deterministic bursts.
        if cycles % 337 in range(0, 13):
            dut.result_ready.value = 0
        else:
            dut.result_ready.value = 1 if rng.randrange(100) < 91 else 0

        dut.block_valid.value = 0
        dut.block_first_in.value = 0
        dut.block_last_in.value = 0

        await Timer(1, unit="ps")
        pending_bm = ival(dut.ctx_pending_bitmap)

        # Existing multi-block messages whose next block can enter the one-slot
        # context prefetch window.
        ready_active = [
            ctx for ctx, st in active.items()
            if st["next_send"] < len(msg_by_id[st["msg_id"]].blocks)
            and ((pending_bm >> ctx) & 1) == 0
        ]

        # Scan unstarted messages for something admissible. Single-block
        # messages require no context; multi-block messages require a free one.
        start_candidates = []
        for mid in unstarted[: max(16, ctx_num)]:
            if mid in fast_msgs or free_ctx:
                start_candidates.append(mid)

        candidate = None
        if start_candidates and (not ready_active or rng.randrange(100) < 48):
            mid = rng.choice(start_candidates)
            msg = msg_by_id[mid]
            if mid in fast_msgs:
                # ctx_id is only an opaque return tag on the fast path.
                ctx = mid % ctx_num
                candidate = (ctx, mid, 0, True, True)
            else:
                ctx = min(free_ctx)
                candidate = (ctx, mid, 0, True, False)
        elif ready_active:
            ctx = rng.choice(ready_active)
            st = active[ctx]
            candidate = (ctx, st["msg_id"], st["next_send"], False, False)
        elif start_candidates:
            mid = start_candidates[0]
            if mid in fast_msgs:
                candidate = (mid % ctx_num, mid, 0, True, True)
            else:
                candidate = (min(free_ctx), mid, 0, True, False)

        if candidate is not None and rng.randrange(100) < 95:
            ctx, msg_id, bidx, first, is_fast = candidate
            msg = msg_by_id[msg_id]
            dut.block_valid.value = 1
            dut.block_ctx_id_in.value = ctx
            dut.msg_id_in.value = msg_id
            dut.block_data.value = int.from_bytes(msg.blocks[bidx], "big")
            dut.block_first_in.value = 1 if first else 0
            dut.block_last_in.value = 1 if bidx == len(msg.blocks) - 1 else 0

        await Timer(1, unit="ps")

        in_fire = bool(ival(dut.block_valid) and ival(dut.block_ready))
        if in_fire:
            in_ctx = ival(dut.block_ctx_id_in)
            in_msg = ival(dut.msg_id_in)
            in_first = bool(ival(dut.block_first_in))
            in_last = bool(ival(dut.block_last_in))
        else:
            in_ctx = in_msg = None
            in_first = in_last = False

        out_fire = bool(ival(dut.result_valid) and ival(dut.result_ready))
        if out_fire:
            out_msg = ival(dut.msg_id_out)
            out_ctx = ival(dut.ctx_id_out)
            out_digest = ival(dut.digest_out)
        else:
            out_msg = out_ctx = out_digest = None

        disp_fire = bool(ival(dut.dbg_dispatch_valid))
        disp_fast = bool(ival(dut.dbg_dispatch_fast)) if disp_fire else False
        disp_ctx = ival(dut.dbg_dispatch_ctx_id) if disp_fire else None
        commit_fire = bool(ival(dut.dbg_commit_valid))
        commit_fast = bool(ival(dut.dbg_commit_fast)) if commit_fire else False
        commit_ctx = ival(dut.dbg_commit_ctx_id) if commit_fire else None
        if hasattr(dut, "dbg_sticky_valid") and bool(ival(dut.dbg_sticky_valid)):
            sticky_issues += 1

        occ = ival(dut.core_occupied).bit_count()
        valid_count = ival(dut.ctx_valid_bitmap).bit_count()
        pending_count = pending_bm.bit_count()
        fast_level = ival(dut.fast_level)
        max_core_occupied = max(max_core_occupied, occ)
        core_occupied_sum += occ
        max_ctx_active = max(max_ctx_active, valid_count)
        max_ctx_pending = max(max_ctx_pending, pending_count)
        max_fast_level = max(max_fast_level, fast_level)

        if disp_fire:
            dispatches += 1
            if disp_fast:
                fast_dispatches += 1
            else:
                assert disp_ctx not in inflight_dbg, (
                    f"ctx {disp_ctx} dispatched while already inflight"
                )
                assert disp_ctx in active, f"dispatch on unallocated ctx {disp_ctx}"
                inflight_dbg.add(disp_ctx)
                active[disp_ctx]["dispatch_count"] += 1

        if commit_fire:
            commits += 1
            if commit_fast:
                fast_commits += 1
            else:
                assert commit_ctx in inflight_dbg, (
                    f"commit ctx {commit_ctx} without matching dispatch"
                )
                inflight_dbg.remove(commit_ctx)

        await RisingEdge(dut.clk)
        cycles += 1

        if in_fire:
            assert in_msg in unstarted or not in_first
            if in_first and in_last:
                assert in_msg in fast_msgs
                unstarted.remove(in_msg)
            elif in_first:
                assert in_msg in multi_msgs
                assert in_ctx in free_ctx
                free_ctx.remove(in_ctx)
                unstarted.remove(in_msg)
                active[in_ctx] = {
                    "msg_id": in_msg,
                    "next_send": 1,
                    "dispatch_count": 0,
                }
                msg_to_ctx[in_msg] = in_ctx
            else:
                assert in_ctx in active
                assert active[in_ctx]["msg_id"] == in_msg
                active[in_ctx]["next_send"] += 1
            accepted_blocks += 1

        if out_fire:
            assert out_msg in msg_by_id, f"unknown completed msg_id={out_msg}"
            assert out_msg not in received, f"duplicate completion msg_id={out_msg}"
            msg = msg_by_id[out_msg]
            assert out_digest == msg.expected, f"digest mismatch msg_id={out_msg}"

            if out_msg in fast_msgs:
                assert out_ctx == out_msg % ctx_num, (
                    f"fast result opaque ctx tag mismatch msg={out_msg} ctx={out_ctx}"
                )
            else:
                assert out_msg in msg_to_ctx
                exp_ctx = msg_to_ctx[out_msg]
                assert out_ctx == exp_ctx
                assert out_ctx in active
                assert active[out_ctx]["msg_id"] == out_msg
                assert active[out_ctx]["next_send"] == len(msg.blocks)
                assert active[out_ctx]["dispatch_count"] == len(msg.blocks)
                del active[out_ctx]
                del msg_to_ctx[out_msg]
                free_ctx.add(out_ctx)

            received[out_msg] = out_digest

    dut.block_valid.value = 0
    dut.result_ready.value = 1

    assert len(received) == nmsg, (
        f"timeout completed={len(received)}/{nmsg} blocks={accepted_blocks}/{total_blocks} "
        f"active={len(active)} unstarted={len(unstarted)} fast_level={ival(dut.fast_level)}"
    )
    assert accepted_blocks == total_blocks
    assert dispatches == total_blocks
    assert commits == total_blocks
    assert fast_dispatches == len(fast_msgs)
    assert fast_commits == len(fast_msgs)
    assert not inflight_dbg
    assert max_core_occupied == core_num

    dut._log.info(
        "%d-core/%d-context HYBRID PASS: messages=%d fast_msgs=%d multi_msgs=%d "
        "blocks=%d cycles=%d max_core=%d max_ctx=%d max_pending=%d max_fast=%d "
        "sticky=%d blocks/cycle=%.6f avg_core_util=%.2f%%",
        core_num, ctx_num, nmsg, len(fast_msgs), len(multi_msgs),
        total_blocks, cycles, max_core_occupied, max_ctx_active,
        max_ctx_pending, max_fast_level, sticky_issues, total_blocks / cycles,
        100.0 * core_occupied_sum / (cycles * core_num),
    )
