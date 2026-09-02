# Instruction delivery and decode boundary

This document describes the current internal program path.  The 32-bit uword
format is a development control-store format, not a frozen software ISA.

## Implemented path

```text
[behavioral control store | external IFetch provider]
        │ byte PC, request up to 4 consecutive words
        ▼
program source
        │ ready/valid bundle
        ▼
multi-record framer + class predecode
        │ complete oldest record
        ▼
raw record holding
        ▼
action adapter / class semantic decoder
        │ resolved canonical fields
        ▼
decoded-action holding
        │ canonical action
        ▼
strict single-active controller
        ├── EXEC
        ├── MEMORY
        └── CONTROL
```

There is one PC, one execution context and one issue slot in the executable
profile.  The PC advances by four bytes for every stream word, including an
extension/body word.  `J` and direct-comparison branches may redirect that
single PC; there is no second PC, prediction, delay slot, CALL/RET or exception
restart.

Provider selection is an elaboration-time wrapper profile.  The external path
uses a redirect-aware request bridge before shared iMMU/I-region/I-cache; it
does not change the program source, framer or two-stage decode contracts.  The
behavioral control store remains the focused control-path verification source.

`FETCH_WORDS=4` means that the I-side can return four consecutive 32-bit stream
words in one bundle.  It does not mean four instructions are issued.  A bundle
may contain four one-word records, one four-word record, or a tail plus other
records.  Fetch width is kept wider than issue width so framing and memory
latency do not unnecessarily starve the single action port.

## Slot vocabulary

Three names must remain separate:

| Name | Meaning |
|---|---|
| fetch word position | one of the four words returned from the program source |
| framer admission slot | one complete record exposed by the framing block in a cycle |
| issue slot | one transient action-to-engine admission port |

The generic framer can expose several complete records and generic EXEC blocks
can model several issue slots.  The current product wrapper consumes only the
oldest framer record and provides one issue slot.  Neither kind of slot is a
thread, PC or register file.

## Record framing

The high nibble selects the structural record family:

| header `[31:28]` | class | structural length |
|---|---|---:|
| `0x1..0xa` | EXEC | one or two words, according to EXEC format |
| `0xb` | MEMORY | `1 + header[27:26]` words |
| `0xc` | CONTROL | `1 + header[27:26]` words |
| `0x0, 0xd..0xf` | undefined | one word, later retired as decode error |

Once a header declares body words, their high nibble is opaque to the framer.
An illegal class-specific field does not change structural length.  This keeps
the PC synchronized and allows an ordered error record.

The predecoder answers only:

- where each complete record begins and ends;
- its tentative `EXEC/MEMORY/CONTROL` dispatch class;
- whether the bundle ends with a partial record;
- whether a canonical `CONTROL.END` terminates younger fetch.

It does not decode operands, compute addresses or infer dependencies.

CONTROL branch is a fixed two-word record.  The semantic decoder identifies
the condition/registers and a signed byte displacement relative to the header
PC.  Redirect is resolved only at the oldest-action boundary.  On every legal
branch, the source discards/poisons younger fetch state and the framer clears
its tail, EOF, continuity and prefetched-END state before refetching the chosen
target or fall-through PC.  The redirect also clears a younger record that may
already have crossed the framer into the raw-record holding register.

## Two-stage decode

Decode is intentionally split by responsibility:

1. structural predecode/framing operates on fetched words;
2. class semantic decode converts the selected complete record into a
   canonical action.

MEMORY uses `vsp_memory_uword_decoder`; CONTROL uses
`vsp_control_uword_decoder`.  The action adapter combines their decoded payload
and the collected EXEC base/extension packet with launch sideband such as group
mask, context and tag.  `vsp_exec_uword_expander` performs final EXEC expansion
and legality before class routing.  Illegal records produce canonical
no-side-effect actions and retire through the normal ordered completion path.

The raw record and class-semantic result both have explicit one-entry holding
registers.  A third, cluster-local canonical-action holding captures final EXEC
expansion/legality and the common identity/payload for every cluster-bound
class.  The class router and child engines therefore never consume a live
instruction word or a live expander result.  Neither decoded holding is
replaced in its consume cycle; this deliberately accepts bubbles in exchange
for small, unambiguous ready/valid boundaries.  They are timing/ownership
boundaries, not additional issue slots or an out-of-order window.

This differs from a general CPU decoder in an important way: the output is not
a scalar instruction for a self-fetching pipeline.  It is a command descriptor
for one of three engines.  Bulk vector data never enters the instruction FIFO.

## MEMORY record subset

The current MEMORY semantic record is two words.  It carries:

- LOAD or STORE;
- `UNIT_STRIDE` or `INDEX_U8` address mode;
- sequencer base-state register and signed offset;
- address space/context;
- data VRF row;
- index VRF row for indexed mode;
- five-bit span code for unit-stride mode.

Assembler pseudo-ops are `VLOAD`, `VSTORE`, `VGATHER` and `VSCATTER`.
For `UNIT_STRIDE`, span code zero means all selected rows and is resolved to
`4 * popcount(group_mask)` bytes; codes 1 through 31 are explicit spans.
`INDEX_U8` decodes span zero with a separate address-mode bit, and the group
mask fixes the number of active SIMD4 rows.  The scalar base value and resolved
MEMORY descriptor are snapshotted when the semantic result enters the decoded
holding stage.  Conditional branches instead read the latest committed scalar
state when the ordered decoded entry is dispatched.

## Queue representation

Three implementation choices remain valid:

| Queue form | Advantage | Cost |
|---|---|---|
| fully decoded | simple issue end | very wide entries and high switching |
| encoded, decode at head | compact storage | replicated/late critical decode |
| compact + cached predecode + head expansion | useful scheduling fields remain cheap | requires one source of truth between both decode stages |

The repository contains parameterized queue, locked-head and late-decode
holding blocks to explore these choices.  They are not on the strict program
path today.  Current correctness comes from one active action at a time, not
from a multi-entry dependency scheduler.

A future compact entry should hold only encoded words or a reference, tag,
resolved group mask and coarse resource/order metadata.  RF contents, memory
beats and boundary data belong to operand/staging channels.

## Dependencies and retirement

For the current profile, program order is simple:

- frame and hold the oldest raw record;
- admit one decoded action only after older state/branch/cluster activity is
  quiescent;
- wait for its child engine completion;
- hold the unified completion stable under backpressure;
- retire it before accepting the next action.

`END` waits for the integrated EXEC queue/ingress/tracker/reject/completion,
MEMORY engine and VRF arbiter to become quiescent.  A successful END retirement
raises `program_done`; it does not aggregate all older statuses into a kernel
success bit.

The standalone ordered-action-window and generic multi-slot scheduler remain
throughput experiments.  The retired register-route rendezvous/barrier metadata
is not emitted by the current predecoder and is not part of the active record
format.

## Next useful work

1. Measure the cost of the conservative decode interlock and branch refetch
   rule before adding same-cycle stage replacement or a not-taken fast path.
2. Preserve the one-PC/one-slot executable baseline while adding directed
   indexed-memory and branch-loop programs.
3. Run synthesis with a modern SystemVerilog front end and a target Liberty
   library before assigning an MHz claim to this pipeline.
4. Measure whether one action slot starves the four-group EXEC cluster before
   adding a second slot.
5. If overlap is justified, introduce a small dependency window for ordinary
   EXEC/MEMORY hazards; do not reinterpret slots as threads.
6. Version any future software-visible ISA separately from the internal uword
   profile.
