# Verification harness and design drift

Tests are evidence for explicit claims; they do not choose the architecture.
A passing regression only says that no disagreement was observed under the
listed assumptions and oracle.

## Avoiding self-reinforcing design

A harness cannot automatically determine whether:

- its oracle copied the RTL's mistaken assumption;
- a tested behavior is architecture, temporary implementation or convenience;
- more random samples add new evidence;
- a workaround is causing another workaround;
- an experimental feature deserves product integration.

Use this evidence direction:

```text
workload/question
      ↓
candidate + falsifiable condition
      ↓
behavioral claim
      ↓
independent oracle/invariant
      ↓
testbench checks RTL
```

When documents, RTL and tests disagree, classify the conflict as an RTL defect,
stale/isomorphic oracle, ambiguous document, intentional architecture change or
open question.  No layer wins automatically.

## Product-path regression

The default `make lint` and `make test` cover the current one-PC/one-slot path:

| Area | Main evidence | Supported claim |
|---|---|---|
| lane/datapath arithmetic | `simd_exec_tb`, dynamic ALU, mask, reduction, compact, datapath and workload tests | checked fixed-width operation and RF/writeback semantics |
| group/EXEC protocol | group wrapper, queue, dispatcher, tracker, result collector and cluster EXEC tests | elastic operand-stage ready/valid, VRF/ARF/MRF RAW forwarding, atomic group-mask issue, child/completion conservation and ordered reject |
| uword framing/decode | predecoder, bundle assembler, multi-framer, EXEC expander and assembler tests | mixed record boundaries, `fmt=0xd` undefined behavior, extension rules and illegal no-side-effect decode |
| program delivery | program source/frontend and uword cluster program test | byte PC `+4` per word, cross-bundle records, strict single action, state/MEMORY/EXEC/END ordering |
| program dataflow closure | fetched 48-byte vector-memory loop in the uword cluster program test | four-group load/compute/store loop, scalar address update, backward branch, END and final D-memory bytes against an independent oracle |
| MEMORY semantic decode | `vsp_memory_uword_decoder_tb` and assembler test | UNIT_STRIDE versus INDEX_U8 fields, index row, code-zero full-selected span, explicit 1..31 span and signed offset |
| vector memory engine | four-group and sixteen-group `vsp_vector_memory_engine` tests | unit-stride transfers; 16/64-byte indexed gather/scatter; duplicate ordering; exact byte fault; partial progress; random channel stalls |
| decoded memory integration | `vsp_cluster_memory_wrapper_tb` | linear LOAD→EXEC→STORE plus indexed gather/scatter through real VRF state endpoints |
| strict controller integration | decoded controller, cluster controller and uword program tests | single-active class routing, ordered errors/completions, indexed programs and END quiescence |
| I/D simulation endpoints | ordered IFetch and dmem model tests | byte-addressed ordered models with backpressure/fault/reset behavior |

Recent indexed-memory directed regressions specifically cover:

- non-aligned byte indices lowered to aligned 4-byte beats;
- duplicate gather offsets;
- one-hot scatter strobe/data placement;
- duplicate scatter address with group/lane-order last writer;
- a third-lane scatter fault with exact byte address and two committed bytes;
- `base + uint8(index)` overflow;
- held-channel stability under randomized ready/valid stalls;
- end-to-end gather and scatter from uword streams.
- a full sixteen-group gather and scatter with 64 byte-lane requests, including
  an index reaching offset 255 and duplicate-scatter last-writer behavior.

These tests do not prove a physical SRAM/cache/MMU/DMA exists, that the new
pipeline meets a target-process frequency/PPA point, that the memory engine has
more than one outstanding beat, or that the internal uword encoding is a final
ISA.

## Experimental routing regression

The repository retains Bênes, lane gather, word-first/four-pass gather,
register-route, rendezvous and route-wave tests as historical design evidence.
They are intentionally outside default product regression:

```bash
make lint-experimental-routing
make test-experimental-routing
```

Passing them only proves the isolated module contracts.  It does not imply
that `EXEC_ROUTE/VROUTE`, multi-slot rendezvous, fixed-latency routing or a
256-byte register network is available to the current program path.

Group-local `simd_route` remains part of ordinary datapath verification because
it is still an active SIMD4 feature.

## Admission checklist for a new test

Before adding a persistent test, answer:

1. What unique claim or failure class does it verify?
2. Does the claim come from current semantics, an invariant, a bug or an
   exploration hypothesis?
3. Is the oracle independent?  If it copies the algorithm, call it a drift
   detector.
4. What is the lowest observable layer that can detect the error?
5. Which assumptions and non-claims must be stated?
6. Which older test does it replace, merge or overlap?
7. Under what architecture/harness change can it retire?

Suggested manifest:

```text
CLASS:
CLAIM:
SOURCE / QUESTION:
ORACLE:
ASSUMPTIONS:
NON_CLAIMS:
RETIRE_WHEN:
```

## Avoiding test growth for its own sake

Prefer a small invariant at the lowest useful boundary.  Add an integration
test only when the failure cannot be observed below that boundary or the wiring
itself is the claim.  Add workload evidence only when it checks an algorithmic
mapping or a system-level dataflow question.

Random tests need a stated input domain and property.  More seeds are useful
only when they expand coverage of a meaningful state/relationship.  Keep at
least one directed case for every important failure mode so regressions remain
diagnosable.

## Handling architecture pivots

When a feature leaves the product path:

- remove it from default integration source closures and aggregate tests;
- keep isolated RTL/tests only if they remain useful research evidence;
- put them behind an explicit optional target;
- update program examples and semantic decoders so the old encoding is an
  ordered error;
- replace current-state documentation rather than accumulating contradictory
  caveats.

This is the policy applied to the register-route/route-wave experiment.

## Evidence needed for future trade-offs

Before adding a second issue slot, collect action-accept wait cycles, EXEC
utilization, VRF contention and memory wait time.  Before adding coalescing or
outstanding indexed requests, collect address locality, duplicate indices,
beat/cache-line hit grouping and fault frequency.  Before adding a physical
permutation network, compare its traffic/latency/energy with indexed memory on
representative traces.

Do not infer any of these choices from test count or parameterized elaboration
alone.

## Collaborative review

For each substantial change, a separate audit should check:

- every new field reaches decoder, adapter, wrapper and engine;
- ready/valid outputs remain stable while stalled;
- faults and resets cannot orphan an outstanding child;
- parameter bounds match the documented profile;
- examples assemble and current docs do not advertise retired behavior;
- generated build artifacts are cleaned before handoff.
