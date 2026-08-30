# Scatter operations and histogram sketches

> **Status — architecture/program draft.** This document records mappings to
> currently available primitives and possible future extensions. It is not an
> ISA promise, an executable RTL regression, or evidence that indexed memory
> gather/scatter is connected. Current route truth lives in
> [architecture/routing.md](architecture/routing.md).

## Keep three operations separate

1. `EXEC_ROUTE` is a VRF-indexed **register gather** over one route domain.
   Each destination byte reads its source index from another VRF row;
   duplicate source indices are legal and mean multicast. It does not form
   memory addresses. Its blocking cluster capture/commit path is connected;
   the current engine executes only complete `INOUT` route mode.
2. The current vector memory path moves a contiguous span from
   `sbase + offset`. It does not consume a vector of addresses.
3. Scatter writes `value[i]` to an address selected by `index[i]`. Equal
   indices create a write conflict and require an ordering, merge, atomic, or
   rejection rule. No current VSP instruction provides that contract.

The standalone wider gather RTL is a routing experiment and is not connected
to the cluster command/writeback path. It must not be used as evidence for a
callable memory gather operation.

## Mapping a small histogram today

For a four-bin byte histogram, avoid scatter entirely. Turn each lane into a
0/1 equality predicate and reduce it:

```text
SMOVI rd=1 imm=0x1000
VLOAD space=local addr_context=0 sbase=1 vrf=0 span=16 offset=0

# bin_id = pixel >> 6; v2 = all ones
EXEC_ALU_RI op=shr_u mode=byte va=0 vd=1 imm=6
EXEC_ALU_RR op=xor mode=byte va=1 vb=1 vd=2
EXEC_ALU_RI op=add mode=byte va=2 vd=2 imm=1

# Predicate for bin k=0. Repeat with immediates 1, 2 and 3.
EXEC_ALU_RI op=absdiff_u mode=byte va=1 vd=3 imm=0
EXEC_ALU_RI op=min_u mode=byte va=3 vd=4 imm=1
EXEC_ALU_RR op=sub mode=byte va=2 vb=4 vd=5
EXEC_REDUCE op=sum_u va=5
```

The full assemblable example is
[`examples/uword/histogram_4bin_test.uasm`](../examples/uword/histogram_4bin_test.uasm).
`EXEC_REDUCE` produces a completion for each selected SIMD4 group. A host or
sequencer still has to aggregate those partial counts across groups and input
tiles. That aggregation/storage path is not supplied by the example.

This technique costs work proportional to the number of bins. It is useful for
small fixed classifications; it is not a good general replacement for a
256-bin atomic histogram.

## Program-level fallbacks

- **Tile then merge:** compute small local histograms or other partial results,
  then merge them at a level with suitable scalar/atomic support.
- **Serialize explicit stores:** when the program can enumerate destinations,
  issue ordinary `VSTORE` transactions in a defined order. This preserves
  semantics but gives up scatter parallelism.
- **Transform the algorithm:** sorting/grouping indices before updates can turn
  conflicting random writes into runs and reductions, but the transformation
  itself needs a proven mapping and is workload-dependent.

Register routing can rearrange values after they are loaded. It cannot reduce
the number of random memory transactions when the addresses themselves are
data-dependent, and it cannot define the winner for duplicate scatter indices.

## Boundary for a future indexed-memory engine

If workloads justify an indexed memory path, treat it as a separate address and
request engine beside the current contiguous path. Its contract must state at
least:

- index element width, scale, base address and address-space/context source;
- active-lane and out-of-range/fault behavior;
- maximum outstanding requests and response reordering tags;
- coalescing and cache-line split rules;
- duplicate-address behavior for scatter (ordered last-writer, atomic merge,
  serialized lanes, or illegal);
- cancellation, fault completion and backpressure stability;
- how returned lanes commit atomically or partially to VRF.

The existing contiguous memory command boundary should remain usable without
this engine. Indexed requests can share the downstream D-side translation and
cache interfaces once those interfaces exist, but should not be hidden inside
the register-route engine.

## What is intentionally not claimed

- cooperative OUT-only/IN-only route-wave rendezvous is not connected;
- no current indexed load/store command;
- no current atomic histogram update;
- no current automatic 16-lane count collection;
- no measured performance advantage for the sketches above.
