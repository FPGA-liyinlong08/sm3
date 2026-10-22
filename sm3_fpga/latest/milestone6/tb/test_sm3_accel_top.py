import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "model"))
from sm3_ref import hash_hex


def ival(sig):
    return int(sig.value)


def keep_mask(n):
    if n >= 16:
        return 0xFFFF
    return ((1 << n) - 1) << (16 - n) if n else 0


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.desc_valid.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_keep.value = 0
    dut.result_ready.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    # The global block-pool free list is initialized once after reset.
    # Start workload accounting only after the engine advertises ready.
    if hasattr(dut, "dbg_pool_init_done"):
        while not ival(dut.dbg_pool_init_done):
            await RisingEdge(dut.clk)


@cocotb.test()
async def end_to_end_raw_messages(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(0xE2E5_2026)
    nmsg = int(os.environ.get("NMSG", "300"))
    profile = os.environ.get("PROFILE", "short_heavy")
    pool_depth = int(os.environ.get("POOL_DEPTH", "256"))
    drive_prob = int(os.environ.get("DRIVE_PROB", "96"))
    ready_prob = int(os.environ.get("READY_PROB", "94"))

    boundaries = [0, 1, 3, 15, 16, 31, 32, 55, 56, 63, 64, 65,
                  119, 120, 127, 128, 200, 511, 512, 513, 1024, 2048, 4095, 4096]
    lengths = boundaries[:]
    while len(lengths) < nmsg:
        p = rng.randrange(100)
        if profile == "single":
            lengths.append(rng.randrange(0, 56))
        elif profile == "mixed":
            if p < 35:
                lengths.append(rng.randrange(0, 56))
            elif p < 65:
                lengths.append(rng.randrange(56, 513))
            else:
                lengths.append(rng.randrange(513, 4097))
        else:  # short_heavy
            if p < 80:
                lengths.append(rng.randrange(0, 56))
            elif p < 95:
                lengths.append(rng.randrange(56, 513))
            else:
                lengths.append(rng.randrange(513, 4097))
    lengths = lengths[:nmsg]

    messages = []
    expected = {}
    for mid, n in enumerate(lengths):
        payload = bytes(rng.getrandbits(8) for _ in range(n))
        messages.append((mid, payload))
        expected[mid] = int(hash_hex(payload), 16)

    driver_done = False
    drive_mid = -1
    drive_off = 0
    drive_phase = "idle"
    received = {}
    cycles = 0
    max_core = 0
    core_occ_sum = 0
    ready_ctx_sum = 0
    max_ready_ctx = 0
    max_ctx = 0
    max_fast = 0
    min_pool_free = None
    payload_beats = sum((len(p) + 15) // 16 for _, p in messages)
    # The frontend intentionally serializes descriptors/payloads; derive the
    # timeout from actual input volume rather than using a fixed cycle cap.
    max_cycles = max(250000, payload_beats * 10 + nmsg * 400 + 100000)

    async def drive():
        nonlocal driver_done, drive_mid, drive_off, drive_phase
        for mid, payload in messages:
            drive_mid = mid
            drive_off = 0
            drive_phase = "descriptor"
            # Descriptor.
            sent = False
            while not sent:
                await FallingEdge(dut.clk)
                dut.desc_valid.value = 1 if rng.randrange(100) < drive_prob else 0
                dut.desc_msg_id.value = mid
                dut.desc_len_bytes.value = len(payload)
                dut.s_valid.value = 0
                await Timer(1, unit="ps")
                sent = bool(ival(dut.desc_valid) and ival(dut.desc_ready))
                await RisingEdge(dut.clk)
            dut.desc_valid.value = 0

            # Payload.
            drive_phase = "payload"
            off = 0
            while off < len(payload):
                n = min(16, len(payload) - off)
                word = int.from_bytes(payload[off:off+n] + bytes(16-n), "big")
                accepted = False
                while not accepted:
                    await FallingEdge(dut.clk)
                    dut.s_valid.value = 1 if rng.randrange(100) < drive_prob else 0
                    dut.s_data.value = word
                    dut.s_keep.value = keep_mask(n)
                    await Timer(1, unit="ps")
                    accepted = bool(ival(dut.s_valid) and ival(dut.s_ready))
                    await RisingEdge(dut.clk)
                off += n
                drive_off = off
                dut.s_valid.value = 0

        drive_phase = "done"
        driver_done = True
        dut.desc_valid.value = 0
        dut.s_valid.value = 0

    cocotb.start_soon(drive())

    held = None
    while (not driver_done or len(received) < nmsg) and cycles < max_cycles:
        await FallingEdge(dut.clk)

        if cycles % 401 in range(0, 11):
            dut.result_ready.value = 0
        else:
            dut.result_ready.value = 1 if rng.randrange(100) < ready_prob else 0
        await Timer(1, unit="ps")

        valid = bool(ival(dut.result_valid))
        ready = bool(ival(dut.result_ready))
        current = None
        if valid:
            current = (ival(dut.result_msg_id), ival(dut.digest_out))

        if held is not None:
            assert valid, "result_valid dropped under backpressure"
            assert current == held, "result changed while stalled"

        if valid and not ready:
            held = current
        else:
            held = None

        if valid and ready:
            mid, digest = current
            assert mid in expected, f"unknown result msg_id={mid}"
            assert mid not in received, f"duplicate result msg_id={mid}"
            assert digest == expected[mid], f"digest mismatch msg_id={mid}"
            received[mid] = digest

        occ = ival(dut.dbg_core_occupied).bit_count()
        max_core = max(max_core, occ)
        core_occ_sum += occ
        try:
            pend = ival(dut.u_engine.ctx_pending_valid)
            infl = ival(dut.u_engine.ctx_inflight)
            ready_ctx = (pend & ~infl).bit_count()
            ready_ctx_sum += ready_ctx
            max_ready_ctx = max(max_ready_ctx, ready_ctx)
        except Exception:
            pass
        max_ctx = max(max_ctx, ival(dut.dbg_ctx_allocated).bit_count())
        max_fast = max(max_fast, ival(dut.dbg_fast_level))
        try:
            pf = ival(dut.dbg_pool_free)
            min_pool_free = pf if min_pool_free is None else min(min_pool_free, pf)
        except Exception:
            pass

        await RisingEdge(dut.clk)
        cycles += 1

    if not driver_done or len(received) != nmsg:
        dut._log.error(
            "E2E timeout diag: driver_done=%s phase=%s mid=%d off=%d received=%d/%d "
            "desc_ready=%d s_ready=%d core_occ=%d ctx_alloc=%d fast=%d",
            driver_done, drive_phase, drive_mid, drive_off, len(received), nmsg,
            ival(dut.desc_ready), ival(dut.s_ready),
            ival(dut.dbg_core_occupied).bit_count(),
            ival(dut.dbg_ctx_allocated).bit_count(), ival(dut.dbg_fast_level),
        )
        # Hierarchical state is available under Verilator public-flat-rw.
        for name in ["stream_ctx_valid", "stream_ctx_id", "bb_valid", "bb_ready",
                     "bb_first", "bb_last", "eng_block_valid", "eng_block_ready"]:
            try:
                dut._log.error("  %s=%d", name, ival(getattr(dut, name)))
            except Exception:
                pass

        try:
            ctx = ival(dut.stream_ctx_id)
            dut._log.error(
                "  engine ctx%d: valid=%d pending=%d inflight=%d lastacc=%d msg=%d launch_valid=%d core_reserved=0x%x",
                ctx,
                (ival(dut.u_engine.ctx_valid) >> ctx) & 1,
                (ival(dut.u_engine.ctx_pending_valid) >> ctx) & 1,
                (ival(dut.u_engine.ctx_inflight) >> ctx) & 1,
                (ival(dut.u_engine.ctx_last_accepted) >> ctx) & 1,
                ival(dut.u_engine.ctx_msg_id[ctx]),
                ival(dut.u_engine.launch_valid),
                ival(dut.u_engine.core_reserved),
            )
        except Exception as e:
            dut._log.error("  hierarchical context diag unavailable: %s", e)

        try:
            dut._log.error("  result_valid=%d result_ready=%d", ival(dut.result_valid), ival(dut.result_ready))
            for k in range(len(dut.dbg_core_occupied)):
                core = dut.u_engine.g_core[k].u_core
                if ival(dut.dbg_core_occupied) & (1 << k) or ival(core.out_valid):
                    dut._log.error(
                        "  core%d: busy=%d round=%d in_ready=%d out_valid=%d out_ready=%d tag=0x%x last=%d",
                        k, ival(core.busy), ival(core.round_idx), ival(core.in_ready),
                        ival(core.out_valid), ival(core.out_ready), ival(core.msg_id_out),
                        ival(core.block_last_out),
                    )
        except Exception as e:
            dut._log.error("  hierarchical core diag unavailable: %s", e)

    # RisingEdge resumes before all NBA-updated state is necessarily visible
    # through VPI; settle once before checking resource reclamation.
    await Timer(1, unit="ps")
    assert driver_done, "input driver did not finish"
    assert len(received) == nmsg, f"completed {len(received)}/{nmsg}"
    # By the time every digest has retired, all multi-block payload slots and
    # message contexts must have returned to their free pools.
    assert ival(dut.dbg_ctx_allocated) == 0, f"context leak: 0x{ival(dut.dbg_ctx_allocated):x}"
    assert ival(dut.dbg_fast_level) == 0, f"fast FIFO leak: {ival(dut.dbg_fast_level)}"
    assert ival(dut.dbg_pool_free) == pool_depth, (
        f"block-pool leak/double-accounting: free={ival(dut.dbg_pool_free)} expected={pool_depth}"
    )

    payload_bytes = sum(len(p) for _, p in messages)
    total_blocks = sum((len(p) + 9 + 63) // 64 for _, p in messages)
    sim_seconds_at_250mhz = cycles * 4e-9
    payload_gbps = (payload_bytes * 8) / sim_seconds_at_250mhz / 1e9
    mmsg_s = nmsg / sim_seconds_at_250mhz / 1e6
    block_per_cycle = total_blocks / cycles
    avg_core_occ = core_occ_sum / cycles
    avg_ready_ctx = ready_ctx_sum / cycles
    dut._log.info(
        "SM3 E2E PASS: messages=%d payload_bytes=%d cycles=%d max_core=%d max_ctx=%d "
        "max_fast=%d min_pool_free=%s blocks=%d block/cycle=%.5f avg_core=%.2f avg_ready_ctx=%.2f max_ready_ctx=%d payload=%.3fGbps rate=%.3fMmsg/s",
        nmsg, payload_bytes, cycles, max_core, max_ctx, max_fast, str(min_pool_free), total_blocks, block_per_cycle, avg_core_occ, avg_ready_ctx, max_ready_ctx, payload_gbps, mmsg_s,
    )
