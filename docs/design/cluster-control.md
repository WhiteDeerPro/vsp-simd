# SIMD4 cluster control

This page separates vector width from command issue bandwidth.  That distinction
is the basis of the current one-PC/one-slot architecture.

## Current profile

| Quantity | Implemented | Parameterized bound | Meaning |
|---|---:|---:|---|
| physical lanes per group | 4 | 4 in product wrapper | one SIMD4 RF/execution fragment |
| groups | 4 | 16 | 16-byte actual vector, 64-byte maximum profile |
| architectural PCs | 1 | 1 | one ordered program stream |
| execution contexts | 1 | 1 in product wrapper | owner/completion identity, not a thread |
| issue slots | 1 | generic lower blocks still parameterized | actions admitted to engines per cycle |
| fetch words | 4 | parameterized | control-stream bandwidth, not issue count |

One vector parent command carries a group mask.  A single slot can therefore
start one operation across all four current groups, or across sixteen groups in
the scale-limit profile.  Increasing group count increases the data width of a
command; it does not create independent operations.

## What a slot is

An issue slot is a transient arbitration result:

```text
selected action + resolved group mask + resource grant
                  │ one atomic accept
                  ▼
       selected engine / group ingress
```

It is not:

- a hardware thread;
- an independent PC;
- a SIMD4 group;
- a register-file bank;
- a long-lived execution context.

The generic dispatcher represents each selected command with a slot number so
each target group can select the same payload.  Queue pop, tracker allocation
and every selected group ingress fire on the same acceptance edge.  If one
required target cannot accept, none of the group children fire.

## Why one slot is sufficient now

The executable controller is globally single-active: it waits for an action's
completion to retire before accepting the next action.  More physical slots
would therefore add mux, tracker and dependency state without increasing
program throughput.

Four groups and four VRF fragments do not imply four simultaneous operations.
They mean one command may process sixteen bytes at once.  Likewise, a future
sixteen-group cluster can process 64 bytes with the same one-slot contract.

A second slot becomes useful only if all of these are true:

1. the controller permits multiple active actions;
2. their group/resource masks are proven independent;
3. RF and shared engines have the required ports or arbitration;
4. completion tracking can distinguish both actions;
5. measured kernels show the one-slot admission point is a bottleneck.

Do not choose slot count from group count alone.  Start at one; if profiling
justifies overlap, compare two slots before considering larger values.

## EXEC dispatch

`simd_cluster_exec` is the reusable decoded execution integration.  It contains:

- issue queue/frontend experiments;
- atomic group-mask dispatch;
- per-group one-entry ingress;
- SIMD4 transaction wrappers;
- completion tracker, reject buffer and result collector;
- VRF state-read/state-write endpoints for parent engines.

The lower modules retain multi-slot and multi-context parameter tests to keep
their handshakes general.  The product wrappers instantiate the single-slot,
single-context profile.  These generic parameters are not a commitment to
multi-PC execution.

Ordinary vector arithmetic is independently executed by each selected group.
Group-local route and boundary slide remain datapath features.  There is no
product cross-group register-route action.

## MEMORY dispatch

The MEMORY class sends one parent descriptor to
`vsp_vector_memory_engine`.  The engine owns its command until completion and
serializes child work:

```text
parent MEMORY action
      ├── VRF row read/write subrequests
      └── ordinary aligned D-side beats
```

For `UNIT_STRIDE`, each selected group transfers one four-byte row, with an
optional final low-byte tail.  Encoded span code zero means all selected rows
(`4 * popcount(group_mask)` bytes); codes 1 through 31 give an explicit span.
For `INDEX_U8`, each selected lane supplies an unsigned byte offset; LOAD is
gather and STORE is scatter, and the decoded span remains zero.

Per-group/per-lane requests are internal microsequence steps, not issue slots.
The current engine has one active parent and one outstanding memory beat.

`vsp_cluster_vrf_arbiter` currently serves one MEMORY client.  Its parameterized
client interface remains a reusable implementation boundary, but the former
register-route client is no longer instantiated in the product wrapper.

## CONTROL dispatch

CONTROL state actions operate on sequencer address state.  `END` waits for the
integrated EXEC/MEMORY boundary to become strongly quiescent, then retires
through the common completion path.  The sequencer state engine has no PC,
branch unit or scalar load/store port; the program source owns the single PC.

## Ownership, legality and backpressure

Before any child side effect, the controller checks class, context, group mask,
owner snapshot and class-specific decode.  An invalid action becomes an ordered
reject with the original identity; it does not partially fire selected groups.

Under `valid && !ready`, payload and identity remain stable.  Accepted child
completions must match the active context/tag.  Unexpected or mismatched
completions set sticky protocol error and are handled through the ordered active
action rather than silently reassigned.

EXEC data results and command completion are separate channels.  Completion
may retire after the internal collector has accepted a result even while the
external result consumer is backpressured; bounded collector capacity still
indirectly prevents unlimited progress.

## Retired route-wave direction

The former register VROUTE path required source/destination masks,
rendezvous fragments, participant retirement barriers and multi-slot fan-out.
It is no longer connected to the controller, memory wrapper or EXEC expander.
Format `0xd` is undefined in the current uword stream.

The isolated route engine, Bênes/Omega/crossbar and route-wave tests are kept as
experimental design records and run only via the optional experimental-routing
Make targets.  They do not define current scheduling behavior.

## Next control work

1. Keep the single-slot baseline and finish representative indexed-memory
   programs.
2. Add loop/redirect with explicit younger-record flush semantics.
3. Measure EXEC utilization, VRF contention and memory wait time.
4. If one-slot admission is visible in those traces, add a two-action window
   and exact ordinary EXEC/MEMORY hazard metadata.
5. Scale from four to sixteen groups without changing the one-parent command
   semantics; only then reconsider additional issue bandwidth.
