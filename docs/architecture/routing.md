# Indexed memory movement and routing boundary

This page records the current product-path decision.  It supersedes the older
cluster register-route and multi-slot route-wave experiment.  The experimental
crossbar/Bênes/Omega RTL may remain in the repository for comparison, but it is
not reachable from the program wrapper or the decoded cluster wrapper.

## Current profile

| Property | Implemented profile | Scaling bound |
|---|---:|---:|
| SIMD4 groups | 4 | 16 |
| maximum bytes selected by one vector action | 16 | 64 |
| architectural PC | 1 | 1 |
| issue slots | 1 | not coupled to group count |
| index element | unsigned 8-bit byte offset | unsigned 8-bit byte offset |
| address window | `base + 0..255` | `base + 0..255` |

A group contains four 8-bit physical lanes.  One parent command may select any
group mask and is internally decomposed into group/lane requests.  Those child
requests are not issue slots and do not create threads or additional PCs.

The product path deliberately has no cross-group register-to-register route
instruction.  Group-local ALU routing needed by an operation remains part of a
SIMD4 datapath, while data-dependent cross-group selection is expressed at the
memory boundary.

## Programming semantics

The MEMORY class has two address modes:

```text
UNIT_STRIDE:
    address(byte k) = base + signed_offset + k

INDEX_U8:
    address(lane i) = base + signed_offset + uint8(index_vrf[i])
```

The encoded `UNIT_STRIDE` span field is a five-bit code.  Code zero means four
bytes for every selected group and is resolved to `4 * popcount(group_mask)`
before the memory engine sees the command; codes 1 through 31 are explicit byte
spans.  This lets the sixteen-group profile express a full 64-byte linear
transfer without widening the record.  An explicit partial-tail span above 31
bytes is split into more than one command.

`INDEX_U8 + LOAD` is gather and `INDEX_U8 + STORE` is scatter.  The assembler
spellings are:

```text
VGATHER  sbase=1 vd=3 vi=2 offset=0
VSCATTER sbase=1 vs=3 vi=2 offset=0
```

`sbase` names sequencer address state.  `vi` is a distributed VRF row holding
one unsigned byte offset per active physical lane.  `vd` receives gathered
bytes; `vs` supplies scattered bytes.  Indexed commands use all four lanes of
every selected SIMD4 group and decode an actual span of zero; the group mask
determines the vector length in the present whole-group profile.  This zero is
distinguished by `INDEX_U8` mode and is not the full-span sentinel used by
`UNIT_STRIDE`.

For the four-group implementation, sixteen data bytes may select sixteen
positions anywhere in a 256-byte window.  This is often summarized as
“16 Byte fan-out into 256 Byte” or “256 Byte gather into 16 Byte”; it does not
mean one command transfers all 256 bytes.  At the sixteen-group scale, a
command transfers up to 64 selected bytes from the same 256-byte window.

## Deterministic ordering and faults

The reference engine is blocking and single-outstanding.  It visits selected
groups in increasing group number, and lanes within a group in increasing lane
number.

- Repeated gather indices are legal and replicate one memory byte into several
  destination lanes.
- Repeated scatter indices are legal.  Later lanes issue later, so the highest
  active `(group, lane)` in traversal order wins.
- The engine stops at the first memory or VRF fault.  Earlier scatter writes are
  not rolled back; completion reports committed byte count, completed/failed
  group masks, partial status and the exact faulting byte address.
- A gathered group is written to VRF only after all four of its byte reads have
  succeeded.  Thus a fault does not partially update that group.
- Scatter is ordered but not atomic.  It is not an atomic histogram primitive.
- `bytes_committed` counts successful lane transfers; duplicate scatter
  addresses are not deduplicated.

The D-side request remains an ordinary aligned 4-byte load/store beat.  The
indexed engine aligns each byte address down, selects the returned byte for a
gather, or emits one-hot byte strobe/data for a scatter.  Consequently a future
TLB, MMU, cache or local-memory adapter does not need a special “route packet”
protocol.  Translation and protection still occur on each emitted effective
address.

## Why routing moved to memory

The previous register-route direction attempted to combine several concerns:
cross-group permutation, broadcast, multiple independent masks, multiple issue
slots, rendezvous, retirement barriers and eventual 256-byte reach.  Once
multiple PCs or independent slot ownership are admitted, a cooperative route
also becomes a synchronization protocol.  Its state and deadlock surface grow
faster than the data network itself.

The new boundary makes a narrower trade-off:

| Mechanism | Strength | Cost/limitation |
|---|---|---|
| group-local route | cheap byte permutation inside one SIMD4 | cannot move data between groups |
| indexed memory gather/scatter | arbitrary byte selection in a 256-byte window; simple single-PC ordering | one memory transaction per active lane in the reference engine; latency varies with memory/backpressure |
| fixed crossbar/Omega/Bênes | predictable network stages and high on-chip bandwidth | substantial wiring/control; register ownership and multi-slot synchronization remain unsolved |
| software staging through memory | scales beyond the hardware vector width | consumes memory bandwidth and has longer latency |

The indexed engine is therefore a semantic baseline, not a claim of optimal
throughput.  A cache-side coalescer may later merge lanes hitting the same beat
or line without changing `base + u8 index`.  Additional outstanding requests
would require request IDs, a response-to-lane table, ordered fault rules and a
commit buffer.  Those are performance extensions, not prerequisites for the
current model.

## Latency and throughput

The operation count is bounded and data-independent for a fixed group mask,
but wall-clock latency is not fixed: VRF and memory ready/valid backpressure and
faults can change it.  The current blocking engine cannot accept one new gather
or scatter per cycle.  Claiming fixed latency or initiation interval 1 would
require a banked/coalesced memory path and enough outstanding/commit state.

This is intentional for the first executable profile.  Measure real kernels
before choosing coalescing width, cache banking, outstanding depth or a
dedicated on-chip permutation fabric.

## Experimental network RTL

`benes_network`, `vsp_lane_gather`, the word-first/four-pass gather modules and
the route-wave/rendezvous modules are retained only as isolated research and
regression assets.  They must not be used as evidence that the current program
path supports `EXEC_ROUTE`, cross-PC collaboration, fixed four-pass register
gather or a 256-byte register permutation.

If a future workload proves that memory traffic dominates and its working set
is already resident in VRF, a register network can be reconsidered as a new
feature with an explicit single-PC resource contract.  It should not revive
slot-as-thread semantics.
