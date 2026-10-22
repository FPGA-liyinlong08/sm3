# SM3 FPGA Multi-Channel / Multi-Message Accelerator — Complete Logic Framework

## 1. Target scenario

The architecture targets a large number of independent SM3 messages, typically tens of bytes to several KiB, where the main goal is high aggregate Hash throughput rather than accelerating a single dependent long stream.

The core architectural rule is:

> Message ownership and Core ownership are decoupled. The scheduler dynamically binds an eligible 512-bit compression block to any free iterative SM3 Core.

Current preferred implementation point:

- 16 SM3 iterative cores
- 32 Message Contexts
- 512 Global Block Pool slots
- 128-bit input payload datapath
- 1 Round/Cycle core
- Single-block Fast Path
- Multi-block Context + linked Block Pool
- Round-Robin Context selection
- Adaptive Sticky scheduling
- out-of-order digest completion with Message ID

## 2. Top-level data/control architecture

```text
Host / DMA / AXI-style source
          |
          | descriptor + raw payload
          v
+-------------------------------+
| Message Frontend              |
| - descriptor                  |
| - 128-bit payload assembly    |
| - SM3 padding                 |
| - 512-bit block generation    |
+---------------+---------------+
                |
      +---------+---------+
      |                   |
      | single block      | multi block
      v                   v
+------------+     +---------------------+
| Fast FIFO  |     | Message Context Mgr |
| block/tag  |     | hash/head/tail/...  |
+------+-----+     +----------+----------+
       |                      |
       |               +------v----------+
       |               | Global Block    |
       |               | Pool + FreeList |
       |               | linked slots    |
       |               +------+----------+
       |                      |
       +-----------+----------+
                   v
          +------------------+
          | Dynamic Scheduler|
          | - Fast/Context   |
          | - Round-Robin    |
          | - Sticky policy  |
          | - Core allocator |
          +--------+---------+
                   |
         +---------+---------+---- ...
         v         v              v
      Core0      Core1          Core15
         |         |              |
         +---------+------+-------+
                        v
              +-------------------+
              | Completion Manager|
              | - commit hash     |
              | - free slot       |
              | - release context |
              | - digest output   |
              +---------+---------+
                        |
                        v
                  msg_id + digest
```

The system should be understood as two interacting planes:

- Data plane: raw payload -> 512-bit blocks -> Block RAM -> Core -> Digest.
- Control plane: Message ID, Context ID, Slot ID, Core ID, head/tail, valid, inflight, last, counters and arbitration.

The control plane should pass pointers/tags rather than unnecessarily muxing 512-bit payloads.

## 3. Message lifecycle

A multi-block Message moves through the following logical lifecycle:

```text
ALLOC
  -> BUFFERING
  -> READY
  -> INFLIGHT
  -> COMMIT
  -> READY
  -> ...
  -> DONE
  -> FREE
```

BUFFERING and INFLIGHT may overlap. While block B0 is being compressed, later blocks B1/B2/... may continue entering the Global Block Pool. This is critical for exposing enough independent Message Contexts to keep many iterative cores busy.

## 4. Frontend

The Frontend converts arbitrary-length raw messages into normalized SM3 compression blocks. The backend never needs to know the original byte length except through generated control metadata.

Input concept:

- `msg_id`
- original `msg_len`
- 128-bit payload beat
- valid/ready
- byte-valid/last semantics as required by the integration interface

Internally the optimized structure uses four fixed 128-bit lanes to build a 512-bit block. It avoids a general 512-bit dynamic byte-insertion network, which synthesized very poorly in Yosys.

Output concept:

- `block_data[511:0]`
- `msg_id`
- `block_first`
- `block_last`
- valid/ready

## 5. SM3 padding boundary

Padding belongs entirely to the Frontend. Important byte-length boundaries include 55/56, 63/64 and 119/120 bytes.

For an integer number of input bytes L:

`Nblocks = ceil((L + 9) / 64)`

Examples:

- 0..55 bytes -> 1 compression block
- 56..119 bytes -> 2 blocks
- 64 bytes -> 2 blocks
- 4096 bytes -> 65 blocks

## 6. Single-block Fast Path

When `block_first && block_last`, the message needs exactly one compression operation and the input chaining state is the fixed SM3 IV.

Such a message bypasses Multi-block Context allocation and linked Block Pool management:

```text
single block -> Fast FIFO -> Scheduler -> free Core -> Digest
```

Its main benefit is reduced control/context pressure rather than increasing the mathematical capacity of the Core Pool.

## 7. Multi-block Message Context

A Context represents one independent message chain. Essential fields are conceptually:

- valid
- msg_id
- current `hash_state[255:0]`
- `head_ptr`
- `tail_ptr`
- queued block count / pointer-valid state
- `inflight`
- end-of-message/final metadata as needed

The most important correctness invariant is:

> A Message Context may have at most one compression block inflight at any time.

This preserves SM3 block chaining:

`V(i+1) = CF(V(i), B(i))`

Later blocks may be buffered, but they cannot execute until the previous block has committed its hash state or a Sticky bypass explicitly forwards that new state.

## 8. Global Block Pool

The Global Block Pool decouples input acceptance from dependent compression execution.

Recommended first implementation:

- 512 slots
- one 512-bit block payload per slot
- per-slot control metadata including next pointer and last information
- per-Context head/tail pointer
- shared Free List

Logical example:

```text
Context 3: slot17 -> slot83 -> slot101 -> slot7
Context 8: slot31 -> slot210 -> slot55
```

The scheduler scans Contexts, not all 512 Block slots. After choosing a Context, it follows the Context's head pointer to obtain the next block.

## 9. Free List / slot lifecycle

Each Block slot follows:

```text
FREE -> QUEUED -> INFLIGHT -> FREE
```

The Free List initializes after reset and then supports continuous allocation/release. One allocation and one return may occur in the same cycle if implemented carefully.

Critical verification properties:

- no double allocation
- no double free
- no lost slot
- full `POOL_DEPTH` recovery after all messages complete

## 10. Scheduler

The Scheduler performs four conceptually separate choices:

1. choose task class: Fast Path or Multi-block Context;
2. choose an eligible Context;
3. choose Sticky continuation or normal re-dispatch policy;
4. choose a free Core.

A Context is eligible when, conceptually:

`ctx_valid && queued_block_available && !ctx_inflight`

### Round-Robin Context selection

A rotating pointer avoids systematic starvation of high Context IDs. After dispatching Context N, the next scan begins from N+1 modulo Context count.

### Core allocator

Maintain a free/busy vector across `CORE_NUM`. Core identity is not tied to Message or Context identity.

Because each Core consumes a new block roughly once per 65 cycles, a single centralized dispatcher capable of one launch per cycle is more than adequate for 8-16 cores.

## 11. Sticky Core and adaptive quantum

Without Sticky execution, every multi-block message performs:

```text
Core done -> Context writeback -> requeue -> Context read -> dispatch next block
```

Sticky execution permits the same Core to continue directly on the next block, retaining the new hash state locally and bypassing unnecessary Context RAM traffic.

To prevent long messages from monopolizing cores, use a quantum. Current policy concept:

- high/recent Fast traffic pressure -> quantum 2
- no short-message pressure -> quantum 8
- a pressure-hold window prevents oscillation between the two modes

## 12. Iterative SM3 Core

Each Core is intentionally independent of DMA, Context, Buffer Pool and Padding.

Input concept:

- 512-bit block
- 256-bit chaining state
- tag / Message or Context identity
- last/control bit

Output concept:

- 256-bit new chaining state/digest
- same tag
- last/control bit

Internal state:

- A..H: 256 bits
- original block input state used for final XOR
- 16 x 32-bit W sliding window
- round counter
- control/tag state

The message expansion and compression round operate concurrently. The design computes the required W/W' values from the 16-word rolling window rather than precomputing/storing all W0..W67.

Current service model:

- load cycle
- 64 SM3 rounds
- zero-bubble output/input handoff where possible
- sustained interval approximately 65 cycles/block

## 13. Completion Manager

Completion classifies the returned result:

### Fast message

- result is final digest
- emit `msg_id + digest`

### Multi-block, non-final

- update Context hash state unless Sticky bypass continues locally
- advance Context head pointer
- free consumed Block slot
- clear/transition inflight state
- make Context eligible again when appropriate

### Multi-block, final

- emit final digest
- free consumed slot
- release Context

Output completion is allowed to be out of order. Message ID is the reorder key at software/system level. If strict in-order completion is ever required, add a sequence number and Reorder Buffer rather than crippling Scheduler freedom.

## 14. Backpressure

Backpressure must be lossless from result output all the way back to message input:

```text
Result sink stalls
 -> Completion stalls
 -> Core result held stable
 -> fewer/free cores
 -> Scheduler slows
 -> Pool occupancy rises
 -> Pool full
 -> Frontend ready deasserts
 -> Host/DMA source stalls
```

All valid/ready interfaces must hold payload/control stable when `valid && !ready`.

## 15. Reset and engine-ready sequencing

Block Pool Free List requires initialization after reset. Therefore top-level acceptance should be gated by an explicit `engine_ready` condition. Multi-block and Fast-path behavior should not expose inconsistent post-reset acceptance semantics.

## 16. Core correctness invariants

The verification environment should permanently enforce at least:

1. one inflight block maximum per Message Context;
2. blocks execute in strict message order;
3. every submitted message produces exactly one digest;
4. a block slot exists in exactly one lifecycle state;
5. no slot is freed twice;
6. a Context cannot be freed while blocks remain queued/inflight;
7. output payload stays stable under output backpressure;
8. all slots return to Free List after workload completion;
9. all Contexts are released after workload completion;
10. every digest equals the Python SM3 Golden Model.

## 17. Recommended RTL hierarchy

```text
sm3_accel_top
|
+-- sm3_frontend / sm3_block_builder
|   +-- descriptor handling
|   +-- 128-bit block assembler
|   +-- padding
|
+-- sm3_resource_manager
|   +-- context state
|   +-- global block pool
|   +-- free list
|   +-- fast FIFO
|
+-- sm3_scheduler
|   +-- fast/context arbitration
|   +-- context round-robin
|   +-- sticky policy
|   +-- core allocator
|
+-- sm3_core_pool
|   +-- sm3_core[0..CORE_NUM-1]
|
+-- sm3_completion
|   +-- result arbitration
|   +-- context commit
|   +-- slot/context release
|
+-- result interface / FIFO
```

Inside each `sm3_core`:

```text
sm3_core
+-- A..H state registers
+-- W sliding window
+-- message expansion
+-- FF/GG boolean functions
+-- P0/P1 transforms
+-- TT1/TT2 arithmetic
+-- round controller
+-- final XOR / handoff
```

## 18. Storage hierarchy

Current intent:

- 512-bit Block Pool payload -> BRAM
- 256-bit Context hash state -> BRAM
- slot next pointers / free list -> LUTRAM or compact RAM
- Fast FIFO -> LUTRAM
- small valid/inflight/counters -> FF/LUTRAM

Yosys synthesis-driven refactoring already moved the large payload memories away from register/mux expansion toward RAM inference.

## 19. Performance model

For 16 cores with approximately 65 cycles per compression block:

`Rmax = 16 / 65 = 0.24615 block/cycle`

At 250 MHz, the theoretical compression traffic ceiling is roughly:

`0.24615 * 512 * 250e6 ~= 31.5 Gbps`

The 1000-message preferred-config stress result is around 0.22978 block/cycle, or ~93.35% of this block-rate ceiling. Original payload throughput is lower than compression traffic because padding consumes compression capacity.

## 20. Current synthesis point

Preferred 16-Core/32-Context/512-Pool Yosys UltraScale estimate:

- 32,812 LC
- 26,043 FF
- 551 CARRY4
- 15 RAMB18E2
- 4 RAMB36E2
- 0 DSP

This is suitable for architecture comparison. Vivado implementation is still required for exact target-device resource use and timing closure.

## 21. Next implementation phase

Architecture exploration is largely complete. The next phase is timing/physical implementation:

- synthesize/place/route in Vivado for target device;
- identify real critical paths in TT1/TT2, W expansion and scheduler fanout;
- verify 250 MHz timing;
- evaluate floorplanning/logic duplication/register placement;
- only add pipeline stages if timing data requires them;
- compare 8/12/16-core implementations on real target device with throughput/LUT, routing and power considerations.
