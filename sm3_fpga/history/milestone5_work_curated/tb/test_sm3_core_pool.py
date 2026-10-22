import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "model"))
from sm3_ref import hash_hex, pad


def ival(sig):
    return int(sig.value)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.block_valid.value = 0
    dut.block_data.value = 0
    dut.msg_id_in.value = 0
    dut.result_ready.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def eight_core_single_block_stress(dut):
    """Randomized 0..55-byte messages with input gaps and output backpressure."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(0x8C0E2026)
    core_num = len(dut.core_occupied)
    nmsg = int(os.environ.get("NMSG", "1000"))
    msgs = []
    expected = {}
    for msg_id in range(nmsg):
        n = rng.randrange(0, 56)
        msg = bytes(rng.getrandbits(8) for _ in range(n))
        block = pad(msg)
        assert len(block) == 64
        msgs.append((msg_id, block))
        expected[msg_id] = int(hash_hex(msg), 16)

    send_idx = 0
    received = {}
    accepted = 0
    cycles = 0
    max_occupied = 0

    # Drive on falling edges so AXI-style ready/valid is stable well before
    # the active rising edge. Record the handshake that will occur on that edge.
    while len(received) < nmsg and cycles < 20000:
        await FallingEdge(dut.clk)

        if cycles % 211 in range(0, 9):
            dut.result_ready.value = 0
        else:
            dut.result_ready.value = 1 if rng.randrange(100) < 88 else 0

        drive = send_idx < nmsg and rng.randrange(100) < 92
        if drive:
            msg_id, block = msgs[send_idx]
            dut.block_valid.value = 1
            dut.block_data.value = int.from_bytes(block, "big")
            dut.msg_id_in.value = msg_id
        else:
            dut.block_valid.value = 0

        # Let combinational dispatch/arbitration settle before deciding what
        # will handshake at the next active edge.
        await Timer(1, unit="ps")

        in_fire = bool(ival(dut.block_valid) and ival(dut.block_ready))
        out_fire = bool(ival(dut.result_valid) and ival(dut.result_ready))
        out_id = ival(dut.msg_id_out) if out_fire else None
        out_digest = ival(dut.digest_out) if out_fire else None

        occ = ival(dut.core_occupied).bit_count()
        max_occupied = max(max_occupied, occ)

        await RisingEdge(dut.clk)
        cycles += 1

        if in_fire:
            send_idx += 1
            accepted += 1

        if out_fire:
            assert out_id in expected, f"unknown msg_id {out_id}"
            assert out_id not in received, f"duplicate completion msg_id {out_id}"
            assert out_digest == expected[out_id], f"digest mismatch msg_id {out_id}"
            received[out_id] = out_digest

    dut.block_valid.value = 0
    dut.result_ready.value = 1

    assert accepted == nmsg
    assert len(received) == nmsg, f"only {len(received)}/{nmsg} completed"
    assert max_occupied == core_num, (
        f"pool never filled all {core_num} cores, max={max_occupied}"
    )

    dut._log.info(
        "%d-core stress PASS: messages=%d cycles=%d max_occupied=%d avg_msg/cycle=%.6f",
        core_num, nmsg, cycles, max_occupied, nmsg / cycles,
    )
