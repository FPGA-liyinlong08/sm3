import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "model"))
from sm3_ref import pad


def ival(sig):
    return int(sig.value)


def keep_mask(n):
    if n >= 16:
        return 0xFFFF
    if n == 0:
        return 0
    return ((1 << n) - 1) << (16 - n)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.desc_valid.value = 0
    dut.desc_msg_id.value = 0
    dut.desc_len_bytes.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_keep.value = 0
    dut.block_ready.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def random_messages_padding(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(0xB10C_2026)
    nmsg = int(os.environ.get("NMSG", "400"))
    boundaries = [0, 1, 3, 15, 16, 17, 31, 32, 47, 48, 55, 56, 63, 64, 65,
                  119, 120, 127, 128, 129, 255, 256, 511, 512, 513, 1024, 4095, 4096]
    lengths = boundaries[:]
    while len(lengths) < nmsg:
        p = rng.randrange(100)
        if p < 60:
            lengths.append(rng.randrange(0, 129))
        elif p < 90:
            lengths.append(rng.randrange(129, 1025))
        else:
            lengths.append(rng.randrange(1025, 4097))
    lengths = lengths[:nmsg]

    messages = []
    expected = []
    for mid, n in enumerate(lengths):
        payload = bytes(rng.getrandbits(8) for _ in range(n))
        messages.append((mid, payload))
        padded = pad(payload)
        blocks = [padded[i:i+64] for i in range(0, len(padded), 64)]
        for bi, blk in enumerate(blocks):
            expected.append((mid, int.from_bytes(blk, "big"), bi == 0, bi == len(blocks)-1))

    seen = []
    driver_done = False
    cycles = 0
    max_cycles = sum((len(p)+15)//16 for _, p in messages) * 4 + len(expected)*20 + 50000

    async def drive():
        nonlocal driver_done
        for mid, payload in messages:
            # Descriptor handshake.
            sent = False
            while not sent:
                await FallingEdge(dut.clk)
                dut.desc_valid.value = 1 if rng.randrange(100) < 94 else 0
                dut.desc_msg_id.value = mid
                dut.desc_len_bytes.value = len(payload)
                dut.s_valid.value = 0
                await Timer(1, unit="ps")
                sent = bool(ival(dut.desc_valid) and ival(dut.desc_ready))
                await RisingEdge(dut.clk)
            dut.desc_valid.value = 0

            # Payload is packed MSB-first into 128-bit beats.
            off = 0
            while off < len(payload):
                n = min(16, len(payload) - off)
                chunk = payload[off:off+n]
                word = int.from_bytes(chunk + bytes(16-n), "big")
                accepted = False
                while not accepted:
                    await FallingEdge(dut.clk)
                    dut.s_valid.value = 1 if rng.randrange(100) < 93 else 0
                    dut.s_data.value = word
                    dut.s_keep.value = keep_mask(n)
                    await Timer(1, unit="ps")
                    accepted = bool(ival(dut.s_valid) and ival(dut.s_ready))
                    await RisingEdge(dut.clk)
                off += n
                dut.s_valid.value = 0

            # Frontend intentionally accepts the next descriptor only after its
            # final block has retired, so desc_ready provides the serialization.
        driver_done = True
        dut.desc_valid.value = 0
        dut.s_valid.value = 0

    cocotb.start_soon(drive())

    held = None
    while (not driver_done or len(seen) < len(expected)) and cycles < max_cycles:
        await FallingEdge(dut.clk)
        if cycles % 251 in range(0, 9):
            dut.block_ready.value = 0
        else:
            dut.block_ready.value = 1 if rng.randrange(100) < 90 else 0
        await Timer(1, unit="ps")

        valid = bool(ival(dut.block_valid))
        ready = bool(ival(dut.block_ready))
        current = None
        if valid:
            current = (
                ival(dut.block_msg_id),
                ival(dut.block_data),
                bool(ival(dut.block_first)),
                bool(ival(dut.block_last)),
            )

        if held is not None:
            assert valid, "block_valid dropped under backpressure"
            assert current == held, "block output changed while stalled"

        if valid and not ready:
            held = current
        else:
            held = None

        if valid and ready:
            idx = len(seen)
            assert idx < len(expected), "frontend emitted extra block"
            assert current == expected[idx], (
                f"block mismatch idx={idx}: got msg={current[0]} first={current[2]} last={current[3]} "
                f"expected msg={expected[idx][0]} first={expected[idx][2]} last={expected[idx][3]}"
            )
            seen.append(current)

        await RisingEdge(dut.clk)
        cycles += 1

    assert driver_done
    assert len(seen) == len(expected), f"got {len(seen)}/{len(expected)} blocks"
    dut._log.info(
        "SM3 block builder PASS: messages=%d blocks=%d cycles=%d",
        len(messages), len(expected), cycles,
    )
