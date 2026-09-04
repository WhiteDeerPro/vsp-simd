# VSP SIMD Core

VSP is a programmable vector/SIMD RTL research project.  Image, video and
signal processing are representative workloads, not hard-coded hardware
semantics.  The current implementation is a sequencer-driven execution
cluster, not a standalone CPU: SIMD groups do not fetch, branch or handle
exceptions by themselves.

This repository is scoped to the soft-core architecture, RTL, and the
regressions needed to verify its hardware contracts.  Standalone algorithm
programs, host-side generators, image fixtures, and workbench reports are
maintained separately.  Workload documents and tests remain here only when
they serve as evidence for a hardware contract.

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
byte selection or one-hot write strobe.  A downstream
TLB/MMU/cache/local-memory adapter therefore sees ordinary effective-address
traffic.  Physical SRAM, cache, MMU/TLB/PTW, DMA and coherence are not part of
the vector memory engine.  The VSP-owned product wrapper now connects that
logical port through the sibling LSU, address routers and shared MMU to a
writable D-cache, private local SRAM, uncached/device endpoint and physical
fabric.  It terminates at a generic ordered physical lower port; SoC target
decode/bus adaptation, DMA, the I-cache path and global maintenance policy
remain separate integration layers.

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

The behavioral store remains the focused verification source.  A separate
product wrapper can select the external provider seam and fetch the same uword
stream through a redirect-aware bridge, shared iMMU, independent I-region and
read-only I-cache; I/D cache and PTW traffic then share one ordered physical
fabric.  AXI/NoC, DMA, SoC target decode and precise IFetch fault export remain
outside that wrapper.

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
├── integration/    VSP-owned external-IP composition and source manifest
└── files.mk        ordered RTL source closures for verification
sim/                Verilator self-checking testbenches and memory models
tools/              uword assembler and development utilities
examples/uword/     short program streams
docs/               architecture, design, verification and workload notes
```

## Build and verification

Requirements are Verilator, GNU Make and a C++17 compiler.  Graphviz is only
needed to regenerate diagrams or render FFT spectrum plots; the plotting path
uses Graphviz `neato` directly and does not require Matplotlib or NumPy.

```bash
make lint
make test
make test-vsp-bfp test-vsp-m8e8
```

`test-vsp-m8e8`验证逐元素8-bit补码M、8-bit补码E的精确数值oracle和SoA ABI；
它不是M8E8 RTL/微码已经完成的声明。

Focused control/memory tests:

```bash
make test-vsp-uword-asm test-vsp-memory-uword-decoder
make test-cluster-memory-wrapper test-vsp-uword-cluster-program
```

The first D-side external-IP closure is opt-in because its sources are owned by
sibling projects in the containing workspace:

```bash
make check-memory-ip-lock
make lint-memory-integration
make test-memory-integration
make lint-memory-product-integration test-memory-product-integration
make test-vsp-uncached-device-merge
make lint-vsp-uword-cached-program test-vsp-uword-cached-program
make lint-ifetch-product-integration lint-vsp-uword-memory-system
make test-vsp-uword-memory-system
```

64点FFT有独立的真实RTL/memory-system回归。它会生成静态BFP8微码和SRAM镜像，
通过backing初始化端口安装镜像，再经正常I-cache/D-cache路径执行；输入指数从
SRAM加载，输出指数也由EXEC计算并写回SRAM：

```bash
make test-fft64-vsp          # Verilator，自检并生成 build/fft64_vsp/fft64_vsp.vcd
make test-vcs-fft64-vsp      # VCS，自检并生成 build/vcs_fft64_vsp/fft64_vsp.vpd
make plot-fft64-vsp          # Verilator结果 -> CSV/DOT/SVG/PNG
make plot-vcs-fft64-vsp      # VCS结果 -> CSV/DOT/SVG/PNG
make prepare-verdi-fft64-vsp # VPD -> VCD -> FSDB
make view-verdi-fft64-vsp    # 在nWave中预置FFT/cache/RAM/频谱扫描信号

# 三余弦混合波：q/127输入、独立DFT校验、时域图及三种频谱视图
make test-fft64-mixed-vsp
make verify-fft64-mixed-vsp
make plot-fft64-mixed-time-domain # 只生成输入时域DOT/SVG/PNG
make plot-fft64-mixed-vsp        # 同时生成时域图和三种频谱图
make test-vcs-fft64-mixed-vsp
make plot-vcs-fft64-mixed-vsp
make compare-fft64-mixed-vsp
make view-verdi-fft64-mixed-vsp
```

绘图目标调用Graphviz `neato -n2`生成CSV/DOT/SVG/PNG；混合波导出64点输入时域
波形，以及复分量、单边幅度和相对dB三种频谱视图，无需安装Matplotlib。VCS testbench会在workload完成
且memory system静默后自动逐周期扫描
64个bin并写CSV；Verdi预置脚本同时暴露`real`观察信号和Q16.16整数观察信号，
因此仿真结束后的查看与绘图均不需要手工控制testbench。

算法、内存布局和查看波形命令见
[64点原生lane静态BFP8 FFT](docs/workloads/fft64-q7.md)；新增的
[64点q/127三音混合FFT](docs/workloads/fft64-mixed-s8.md)使用5/13/23号频点，
并由直接`O(N^2)` DFT独立校验。2026-09-04的Verilator与VCS实测均已通过，
64个输出字节和频谱CSV在两套仿真器间逐字节一致。VCS仍是需要Synopsys许可证的
可选回归。

See [Memory subsystem integration](docs/integration/memory-subsystem.md) for
the exact boundary, dependency baseline and remaining product-level work.

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
- [Memory subsystem integration](docs/integration/memory-subsystem.md)
- [Cluster control](docs/design/cluster-control.md)
- [Instruction delivery](docs/design/instruction-delivery.md)
- [Data movement](docs/design/data-movement.md)
- [64-point native-lane static-BFP8 FFT](docs/workloads/fft64-q7.md)
- [64-point q/127 three-tone FFT](docs/workloads/fft64-mixed-s8.md)
- [Development roadmap](docs/design/development-roadmap.md)
- [Verification harness](docs/verification/harness.md)
