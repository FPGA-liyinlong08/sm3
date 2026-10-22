"""Small dependency-free SM3 reference model used by RTL tests."""
from __future__ import annotations

IV = (
    0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
    0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
)
MASK32 = 0xFFFFFFFF


def rotl32(x: int, n: int) -> int:
    n &= 31
    x &= MASK32
    return ((x << n) | (x >> ((32 - n) & 31))) & MASK32


def p0(x: int) -> int:
    return (x ^ rotl32(x, 9) ^ rotl32(x, 17)) & MASK32


def p1(x: int) -> int:
    return (x ^ rotl32(x, 15) ^ rotl32(x, 23)) & MASK32


def ff(a: int, b: int, c: int, j: int) -> int:
    if j < 16:
        return a ^ b ^ c
    return (a & b) | (a & c) | (b & c)


def gg(e: int, f: int, g: int, j: int) -> int:
    if j < 16:
        return e ^ f ^ g
    return (e & f) | ((~e) & g)


def expand_block(block: bytes) -> tuple[list[int], list[int]]:
    if len(block) != 64:
        raise ValueError("SM3 compression block must be 64 bytes")
    w = [int.from_bytes(block[i:i+4], "big") for i in range(0, 64, 4)]
    for j in range(16, 68):
        x = w[j - 16] ^ w[j - 9] ^ rotl32(w[j - 3], 15)
        w.append((p1(x) ^ rotl32(w[j - 13], 7) ^ w[j - 6]) & MASK32)
    wp = [(w[j] ^ w[j + 4]) & MASK32 for j in range(64)]
    return w, wp


def compress(state: tuple[int, ...], block: bytes, trace: bool = False):
    if len(state) != 8:
        raise ValueError("state must contain 8 words")
    w, wp = expand_block(block)
    a, b, c, d, e, f, g, h = state
    rounds = []
    for j in range(64):
        tj = 0x79CC4519 if j < 16 else 0x7A879D8A
        a12 = rotl32(a, 12)
        ss1 = rotl32((a12 + e + rotl32(tj, j)) & MASK32, 7)
        ss2 = ss1 ^ a12
        tt1 = (ff(a, b, c, j) + d + ss2 + wp[j]) & MASK32
        tt2 = (gg(e, f, g, j) + h + ss1 + w[j]) & MASK32
        d = c
        c = rotl32(b, 9)
        b = a
        a = tt1
        h = g
        g = rotl32(f, 19)
        f = e
        e = p0(tt2)
        if trace:
            rounds.append((a, b, c, d, e, f, g, h))
    out = tuple((x ^ y) & MASK32 for x, y in zip(state, (a, b, c, d, e, f, g, h)))
    return (out, rounds) if trace else out


def pad(data: bytes) -> bytes:
    bit_len = len(data) * 8
    out = bytearray(data)
    out.append(0x80)
    while (len(out) % 64) != 56:
        out.append(0)
    out += bit_len.to_bytes(8, "big")
    return bytes(out)


def hash_bytes(data: bytes) -> bytes:
    state = IV
    padded = pad(data)
    for off in range(0, len(padded), 64):
        state = compress(state, padded[off:off+64])
    return b"".join(x.to_bytes(4, "big") for x in state)


def hash_hex(data: bytes) -> str:
    return hash_bytes(data).hex()


def state_to_int(state: tuple[int, ...]) -> int:
    v = 0
    for word in state:
        v = (v << 32) | (word & MASK32)
    return v


def int_to_state(v: int) -> tuple[int, ...]:
    return tuple((v >> (32 * (7-i))) & MASK32 for i in range(8))


if __name__ == "__main__":
    vectors = {
        b"abc": "66c7f0f462eeedd9d1f2d46bdc10e4e2"
                "4167c4875cf2f7a2297da02b8f4ba8e0",
        b"abcd" * 16: "debe9ff92275b8a138604889c18e5a4"
                       "d6fdb70e5387e5765293dcba39c0c5732",
    }
    for msg, expected in vectors.items():
        got = hash_hex(msg)
        print(len(msg), got)
        assert got == expected, (got, expected)
    print("SM3 reference vectors PASS")
