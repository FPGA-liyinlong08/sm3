import random, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'model'))
from sm3_ref import IV, compress, pad, state_to_int

out = ROOT / 'sim' / 'sm3_core_vectors.txt'
rng = random.Random(0x5A3C2026)
rows = []

def add(block, state, msg_id, last):
    exp = compress(tuple(state), block)
    rows.append((block.hex(), f'{state_to_int(tuple(state)):064x}', f'{state_to_int(exp):064x}', msg_id, int(last)))
    return exp

# Known-message blocks, including chaining into a second block.
for mid, msg in [(1, b'abc'), (2, b'abcd' * 16)]:
    st = IV
    pdata = pad(msg)
    for off in range(0, len(pdata), 64):
        st = add(pdata[off:off+64], st, mid, off + 64 == len(pdata))

# Boundary lengths, converted to independent compression vectors.
for mid, n in enumerate([0,1,32,55,56,63,64,65,119,120,128,1024,4096], 100):
    msg = bytes(rng.getrandbits(8) for _ in range(n))
    st = IV
    pdata = pad(msg)
    for off in range(0, len(pdata), 64):
        st = add(pdata[off:off+64], st, mid, off + 64 == len(pdata))

# Random compression-state tests.
for i in range(200):
    block = bytes(rng.getrandbits(8) for _ in range(64))
    st = tuple(rng.getrandbits(32) for _ in range(8))
    add(block, st, 0x1000 + i, bool(i & 1))

out.write_text('\n'.join(' '.join(map(str, r)) for r in rows) + '\n')
print(f'wrote {len(rows)} vectors to {out}')
