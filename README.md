# VSP SIMD Core

VSP is a programmable vector/SIMD RTL research project.  Image, video and
signal processing are representative workloads, not hard-coded hardware
semantics.  The current implementation is a sequencer-driven execution
cluster, not a standalone CPU: SIMD groups do not fetch, branch or handle
exceptions by themselves.

The canonical vocabulary is in
[terminology.md](docs/architecture/terminology.md).

## Current executable profile

```text
single byte PC / program source
        │ 4 × 32-bit fetch bundle
        ▼
record framing + class predecode
        │ one active action
        ▼
strict action controller
  ├── EXEC    → SIMD4 cluster
  ├── MEMORY  → vector memory engine → D-side logical port
  └── CONTROL → sequencer state / branch / END
                       │
                       ▼
               ordered completion
```

The product wrapper currently uses:

- one architectural PC;
- one issue slot and one execution context;
- four SIMD4 groups, or 16 physical byte lanes;
- a parameterized scale limit of sixteen groups, or 64 bytes per vector
  action;
- four fetched 32-bit words per bundle.  Fetch width and issue width are
  independent: framing may inspect several mixed records while the strict
  controller issues one action at a time.

An issue slot is a transient command-admission port.  It is not a thread, a
register bank, an execution context or a PC.  One slot may issue one parent
vector action to all selected groups; the engine's per-group/per-lane child
requests do not consume more slots.  Generic multi-queue/multi-slot RTL remains
as a research component, but it is not the current program profile.

## Execution features

Each physical lane is 8 bits.  Adjacent lanes may be interpreted as BYTE,
HALF or WORD elements where the operation defines that behavior.  Current RTL
includes:

- dynamic-boundary add/subtract and shifts;
- byte saturating arithmetic, multiply and MAC;
- compare, min/max, absolute difference and conditional selection;
- VRF/ARF/MRF state, widening into 32-bit accumulators, shifted three-input
  `ARF + VRF-A ± VRF-B`, `NSLICE` and `NCLIP` narrowing;
- group-local lane route/broadcast and adjacent-group slide facilities;
- mask-aware sum/min/max reduction and winning-lane reporting;
- Gaussian, separable Gaussian, Sobel, SAD and median-filter verification
  workloads;
- a decoded EXEC cluster with queueing, atomic group-mask dispatch, completion
  tracking, result collection and state read/write endpoints.

Arithmetic overflow follows the selected fixed-width operation unless an
explicit saturating instruction is used.  Wider interpretations are primarily
compiler/microcode composition, not a promise of separate wide functional
units.

## Data movement

The active vector memory engine is blocking and has one outstanding D-side beat.
It supports two address modes:

```text
UNIT_STRIDE: address(k)    = base + signed_offset + k
INDEX_U8:   address(lane) = base + signed_offset + uint8(index_vrf[lane])
```

`VLOAD/VSTORE` use unit stride.  `VGATHER/VSCATTER` use an index VRF row.  In
the four-group profile, sixteen bytes may select sixteen positions anywhere in
a 256-byte window.  The scale-limit profile moves up to 64 selected bytes in
the same window; neither form transfers all 256 bytes in one command.

For unit stride, encoded span code zero means four bytes for every selected
group and is resolved before issue; codes 1 through 31 are explicit byte
spans.  Indexed mode instead keeps a decoded span of zero and visits all four
lanes of every selected group.

The engine visits group then lane in ascending order.  Repeated gather indices
broadcast a memory byte; repeated scatter indices are deterministic and the
later lane wins.  Scatter is not atomic.  The first fault stops the command and
completion reports exact fault byte address, committed byte count and partial
group state.

Indexed bytes are lowered to ordinary aligned 4-byte D-side loads/stores with
byte selection or one-hot write strobe.  A future TLB/MMU/cache/local-memory
adapter therefore sees ordinary effective-address traffic.  Physical SRAM,
cache, MMU/TLB/PTW, DMA and coherence are not implemented yet.

Cross-group register-to-register routing and its former multi-slot route-wave
protocol have been removed from the product path.  Bênes/Omega/crossbar,
four-pass gather and rendezvous modules remain isolated research assets only.
See [routing.md](docs/architecture/routing.md).

## Control and program delivery

The strict reference path accepts a mixed stream of:

- `EXEC` records expanded to canonical SIMD controls;
- `MEMORY` records decoded as unit-stride or indexed transfers;
- `CONTROL` state operations `SMOVI`, `SADD`, `SADDI`, single-PC
  `J/BEQ/BNE/BLT/BGE/BLTU/BGEU`, and `END`.

The sequencer state engine provides 32-bit base-address state.  It is a small
control/address facility, not a general scalar CPU: it has no scalar memory
port, call/return, interrupts, privilege state or independent PC.  Branches
compare two state registers (the `*Z` pseudo-ops use the constant-zero
register) and redirect the same program PC; they do not create a scalar
execution thread.
`END` waits for the integrated execution/memory boundary to become quiescent
and produces an ordered completion; `program_done` means that completion was
accepted, not that all earlier actions necessarily succeeded.

The uword assembler and behavioral control store form a development format,
not a frozen public ISA.  Current pseudo-ops include vector ALU/reduction,
sequencer state, direct-comparison branches, `VLOAD/VSTORE`,
`VGATHER/VSCATTER` and `CONTROL_END`.

## Repository layout

```text
rtl/
├── pkg/            common types and operation definitions
├── units/          arithmetic, shift, mask and reduction units
├── permute/        group-local route/compact and isolated experiments
├── group/          RF and SIMD4 execution datapaths
├── interconnect/   experimental exchange networks
├── cluster/        multi-group execution and integration wrappers
├── control/        uword source, framing, decode and action control
├── memory/         vector memory engine
└── files.mk        ordered RTL source closures for verification
sim/                Verilator self-checking testbenches and memory models
tools/              uword assembler and development utilities
examples/uword/     short program streams
docs/               architecture, design, verification and workload notes
```

## Build and verification

Requirements are Verilator, GNU Make and a C++17 compiler.  Graphviz is only
needed to regenerate diagrams.

```bash
make lint
make test
```

Focused control/memory tests:

```bash
make test-vsp-uword-asm test-vsp-memory-uword-decoder
make test-cluster-memory-wrapper test-vsp-uword-cluster-program
```

Run the small datapath algorithm examples on their own:

```bash
make test-simple-algorithms
```

Generate viewable PGM inputs and checked brightness/threshold outputs:

```bash
make dump-simple-algorithm-images
# Files are written under build/simple_algorithm_images/ by default.
```

Generated artifacts default to `build/`.  To keep the workspace small, use an
external build directory and remove it after verification:

```bash
make -s BUILD_DIR=/tmp/vsp-build lint
make -s BUILD_DIR=/tmp/vsp-build test
make BUILD_DIR=/tmp/vsp-build clean
```

The clean target refuses broad unsafe paths.

## Documentation

- [Current integration](docs/architecture/current-integration.md)
- [Terminology](docs/architecture/terminology.md)
- [Indexed routing boundary](docs/architecture/routing.md)
- [Memory hierarchy](docs/architecture/memory-hierarchy.md)
- [Cluster control](docs/design/cluster-control.md)
- [Instruction delivery](docs/design/instruction-delivery.md)
- [Data movement](docs/design/data-movement.md)
- [Development roadmap](docs/design/development-roadmap.md)
- [Verification harness](docs/verification/harness.md)
