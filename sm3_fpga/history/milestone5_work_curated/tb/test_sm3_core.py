import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "model"))
from sm3_ref import IV, compress, hash_hex, int_to_state, pad, state_to_int


def ival(sig):
    return int(sig.value)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.out_ready.value = 1
    dut.block_data.value = 0
    dut.hash_in.value = 0
    dut.msg_id_in.value = 0
    dut.block_last_in.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, block: bytes, state, msg_id=1, last=False, hold_result_cycles=0):
    assert len(block) == 64
    while not ival(dut.in_ready):
        await RisingEdge(dut.clk)

    dut.block_data.value = int.from_bytes(block, "big")
    dut.hash_in.value = state_to_int(tuple(state))
    dut.msg_id_in.value = msg_id
    dut.block_last_in.value = int(last)
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0

    # For an explicit backpressure test, deassert ready before the result
    # arrives so the producer must hold valid/data until ready returns.
    if hold_result_cycles:
        dut.out_ready.value = 0

    for _ in range(80):
        await RisingEdge(dut.clk)
        if ival(dut.out_valid):
            break
    else:
        raise AssertionError("Timeout waiting for sm3_core result")

    if hold_result_cycles:
        stable_hash = ival(dut.hash_out)
        stable_id = ival(dut.msg_id_out)
        stable_last = ival(dut.block_last_out)
        for _ in range(hold_result_cycles):
            await RisingEdge(dut.clk)
            assert ival(dut.out_valid) == 1
            assert ival(dut.hash_out) == stable_hash
            assert ival(dut.msg_id_out) == stable_id
            assert ival(dut.block_last_out) == stable_last
        dut.out_ready.value = 1

    got = int_to_state(ival(dut.hash_out))
    assert ival(dut.msg_id_out) == msg_id
    assert ival(dut.block_last_out) == int(last)
    await RisingEdge(dut.clk)
    return got


@cocotb.test()
async def known_vectors(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)

    cases = [
        (b"abc", "66c7f0f462eeedd9d1f2d46bdc10e4e2"
                 "4167c4875cf2f7a2297da02b8f4ba8e0"),
        (b"abcd" * 16, "debe9ff92275b8a138604889c18e5a4"
                        "d6fdb70e5387e5765293dcba39c0c5732"),
    ]
    for msg_idx, (msg, expected_hex) in enumerate(cases, 1):
        state = IV
        pdata = pad(msg)
        for bi in range(0, len(pdata), 64):
            block = pdata[bi:bi+64]
            expected_state = compress(state, block)
            state = await run_block(
                dut, block, state, msg_id=msg_idx,
                last=(bi + 64 == len(pdata)),
                hold_result_cycles=3 if (msg_idx == 1 and bi == 0) else 0,
            )
            assert state == expected_state
        got_hex = "".join(f"{x:08x}" for x in state)
        assert got_hex == expected_hex
        assert got_hex == hash_hex(msg)


@cocotb.test()
async def random_compression_blocks(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)
    rng = random.Random(0x5A3C2026)

    for idx in range(100):
        block = bytes(rng.getrandbits(8) for _ in range(64))
        state = tuple(rng.getrandbits(32) for _ in range(8))
        expected = compress(state, block)
        got = await run_block(dut, block, state, msg_id=0x1000 + idx, last=bool(idx & 1))
        assert got == expected, f"compression mismatch at random case {idx}"


@cocotb.test()
async def random_messages_0_to_4096(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)
    rng = random.Random(0x20261022)

    lengths = [0, 1, 3, 32, 55, 56, 63, 64, 65, 119, 120, 128, 1024, 4096]
    lengths += [rng.randrange(0, 4097) for _ in range(40)]

    for msg_idx, n in enumerate(lengths):
        msg = bytes(rng.getrandbits(8) for _ in range(n))
        pdata = pad(msg)
        state = IV
        for bi in range(0, len(pdata), 64):
            block = pdata[bi:bi+64]
            state = await run_block(
                dut, block, state, msg_id=0x20000 + msg_idx,
                last=(bi + 64 == len(pdata)),
            )
        got = "".join(f"{x:08x}" for x in state)
        assert got == hash_hex(msg), f"message mismatch len={n}"
