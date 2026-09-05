# VSP development roadmap

The roadmap follows the current one-PC/one-slot architecture.  It does not use
register routing or multi-PC synchronization as prerequisites.

## Baseline now implemented

### SIMD4 datapath

- 4×8-bit physical lanes with VRF/ARF/MRF state;
- BYTE/HALF/WORD partitioned add/subtract, shift and compare where defined;
- byte multiply/MAC, wide accumulate, WADD/WSUB, NSLICE/NCLIP;
- mask, select, compact/expand, local route/slide and reductions;
- stateful group wrapper with ready/valid command, state-transfer and result
  channels;
- Gaussian, Sobel, SAD, median and microcode regressions.

### Cluster execution

- decoded group-mask command integration;
- atomic multicast to selected SIMD4 groups;
- ingress buffering, completion tracking, reject path and result collection;
- VRF state-read/write endpoints;
- generic multi-slot blocks retained for unit-level exploration.

### Program/control closure

- one byte PC with behavioral control-store and external-provider profiles;
- up-to-four-word fetch bundle and cross-bundle record framing;
- mixed EXEC/MEMORY/CONTROL structural predecode;
- EXEC expander, MEMORY/CONTROL semantic decode and action adapter;
- one-entry raw-record and decoded-action holding boundaries, including
  resolved MEMORY-base snapshot;
- single-context sequencer address state (`SMOVI/SADD/SADDI`);
- PC-relative `J/BEQ/BNE/BLT/BGE/BLTU/BGEU`, source redirect and younger-state
  flush across source, framer and raw-record holding;
- strict one-active-action class controller and ordered completion;
- `CONTROL.END` and `program_done` reference behavior;
- executable cached-program wrapper with a D-side launch/quiescence gate, plus
  a combined external-IFetch memory-system wrapper with an independent I-side
  launch envelope and global maintenance controller.

### Data movement

- unit-stride `VLOAD/VSTORE`;
- unit-stride span code zero expands to all selected groups, while 1..31 is an
  explicit byte span;
- indexed `VGATHER/VSCATTER` using `base + uint8(index_vrf[lane])`;
- actual four-group/16-byte profile, parameterized to sixteen groups/64 bytes;
- one active MEMORY parent and one outstanding D-side beat;
- exact stop-on-first fault/partial completion state;
- ordered D-side simulation model and independent I-side simulation model;
- product D-side closure through LSU, address routers, shared MMU/TLB/PTW,
  writable D-cache, private local SRAM, uncached/device endpoint and physical
  fabric to a generic ordered lower port;
- product I-side closure through a redirect-aware provider bridge, shared iMMU,
  independent instruction-region policy and read-only I-cache into the same
  ordered physical fabric;
- executable physical/cacheable load/compute/store program through that product
  D-side, with detailed MEMORY completion metadata preserved;
- combined external-IFetch I/D program regression through one ordered physical
  fabric, including startup quarantine, branch/END, active-program maintenance
  interlock, serialized MMU configuration, full host `FENCE_I` and rerun;
- real two-level Sv32 instruction walks, warm iTLB reuse, detailed host IFetch
  diagnosis and recovery, with a focused client test for response holding and
  redirect poison qualification.

## Profile constraints

These are current design choices, not incidental test values:

- one architectural PC;
- one issue slot;
- one execution context in the executable product wrapper;
- four SIMD4 groups implemented, sixteen groups the profile bound;
- no cross-group register-to-register route instruction;
- no thread-like slot behavior;
- behavioral-fetch wrapper 与 external-IFetch combined wrapper 均保留；后者已接入
  shared MMU/PTW、独立 I/D cache/region 和 physical fabric，但 DMA、AXI/NoC、真实 SoC
  target decode 及 CSR/MMIO fault-register mapping 仍不在当前闭环中；host RTL 端口已
  导出有效路径的 IFetch 诊断，程序 active 时可被 committed redirect 撤销；
- no branch prediction or exception machinery.

Experimental Bênes/Omega/crossbar, wide gather, route rendezvous and route-wave
RTL stays outside the default product lint/test and may be run through the
optional experimental-routing targets.

## M1 — Indexed-memory program coverage

Goal: make gather/scatter a dependable semantic baseline.

Acceptance:

- end-to-end uword programs initialize index rows, gather, compute, scatter and
  end without direct testbench RF edits;
- duplicate gather and scatter indices have deterministic checked behavior;
- unaligned indexed byte locations correctly align/select D-side beats;
- overflow, memory fault, VRF fault, partial progress and completion
  backpressure are covered;
- four-group integration and sixteen-group elaboration both pass.

## M2 — Address-system boundary (I/D product wiring baseline implemented)

Goal: preserve a clean insertion point for real memory hierarchy work.

Implemented baseline:

- D-side request 经 LSU、address-space router、MMU 和 physical-region router；
- static region policy 选择 cacheable/local/uncached/device endpoint；
- cacheable 接真实 D-cache adapter/`param_cache`，LOCAL 接 private SRAM，
  UNCACHED/DEVICE 通过 owner-preserving merge 接 fixed-beat adapter；
- external provider 经 redirect bridge、共享 iMMU、独立 I-region 和 read-only I-cache；
- I-cache、D-cache、PTW 和 uncached/device traffic 经 physical fabric 到 generic ordered
  lower port；
- executable uword program 的 MEMORY request/response 已直接接入该 D-side，完整
  physical/cacheable load/compute/store loop 已通过动态回归；
- shared-reset cancellation 和外部不可取消 transport 的 quarantine 责任已经写入合同；
- host global maintenance 只在 program inactive 时接受，并组合 I/D quiesce、I/D cache、
  unified TLB 与 fabric drain；
- VSP-owned registered endpoint/PTW harness 覆盖 route、fault、stall 和 reset；
- keep indexed requests lowered to ordinary effective-address byte operations.

The combined-wrapper dynamic baseline covers PHYSICAL and real Sv32 instruction
fetch, warm iTLB/I-cache reuse, seven context/PTE/region/lower fault cases and
repair followed by restart.  Full product-program redirect during an outstanding
I-cache miss remains to be verified.  Host IFetch diagnosis has an explicit
[fault contract](../integration/memory-subsystem.md#ifetch-fault-contract);
CSR/MMIO mapping, external SoC target decode/bus adaptation and the LSU-barrier
to global-maintenance policy bridge remain.  AXI, DMA and coherence are not
implemented by this milestone.  Before exposing the uword stream to untrusted
software, resolve direct-LOCAL address representation, PHYSICAL/address-context
authority and real DEVICE/MMIO semantics.

## M3 — Loop and redirect (baseline implemented)

Goal: run useful kernels without unrolling every iteration.

Required contract:

- PC target calculation and range checks;
- framer-tail and younger-record invalidation;
- state/count update ordering;
- fetch request/response epoch or drain rule;
- precise END and restart behavior.

No branch prediction is required for the first loop profile.

Current acceptance evidence includes a three-iteration `SADDI+BNEZ` loop where
the branch shares a fetch bundle with the final END, forward `J` skipping a
prefetched EXEC record, completion backpressure, and invalid-target rejection.
Performance optimization of not-taken fall-through remains optional follow-up.

## M4 — Measure one-slot utilization

Goal: decide whether more issue bandwidth is justified.

Collect, per representative kernel:

- cycles waiting for EXEC acceptance/completion;
- cycles waiting for VRF child traffic;
- cycles waiting for D-side request/response;
- fetched words, framed records and issued actions;
- selected-group occupancy and vector utilization.

If one-slot issue is not the dominant stall, keep it.  If it is, compare a
two-action window with exact group/RF/MEMORY dependencies.  Do not infer slot
count from group count and do not add PCs as a throughput shortcut.

## M5 — Scale to sixteen groups

Goal: validate the 64-byte profile without changing command semantics.

Tasks:

- elaborate `GROUP_COUNT=16`, `LANES=4` product closures;
- review masks, group IDs, span counters and completion payload widths;
- measure RF arbiter and indexed-memory serialization;
- decide whether group-local banking or limited request coalescing is needed.

The scale limit is 64 bytes per vector action.  Larger reshaping belongs to
software tiling/memory, not a 256-byte register network.

## M6 — Physicalization (started)

Implemented structural baseline:

- one-entry elastic RF-read operand stage in each SIMD4 group wrapper;
- one-entry elastic execute-result stage after route/main execution;
- reduction, architectural RF writeback and completion/result generation moved
  behind the registered execute result;
- same-cycle masked RAW forwarding from both the older registered result and
  the newer operation leaving the operand stage, with newer data taking
  priority;
- completion/result backpressure stalls execute-result retirement and then the
  operand stage without replaying architectural writes;
- state-transfer traffic remains serialized until both execute stages are
  empty;
- registered semantic-decode output in the program wrapper; engines consume a
  stable class descriptor rather than a live instruction record;
- one-entry non-flow-through canonical-action holding after final EXEC
  expansion/legality; the strict class controller consumes only registered
  canonical payload and the holding participates in busy/END quiescence.

The execution cut is structure-driven.  Without it, a legal command could
compose local route, MAC or another primary operation, result selection and a
reduction tree in one combinational cycle.  The current uniform
`O -> X -> RED/WB` path isolates reduction without introducing operation-specific
latency.  This is not a frequency claim; target-library timing, placement and
FPGA DSP/carry mapping can rank the remaining X paths differently.

The control cut is likewise structural: encoded EXEC base/extension no longer
feeds the large profile expander, legality/error-priority logic and class
controller in one register-to-register cone.  The added stage does not admit a
second parent and does not change the single-PC ordering model.

Remaining work should be guided by workload traces and target implementation
evidence:

- compare the remaining X candidates—`route+MAC`, dynamic WORD shift,
  WADD/WSUB and NCLIP—and split only a demonstrated path at a natural
  intermediate value;
- choose RF port/bank organization and resolve bank conflicts;
- select SRAM/cache/DMA widths;
- add clock/power gating;
- run synthesis/PPA and update frequency assumptions;
- define software-visible driver/ABI boundaries if desired.

Structural lint or generic synthesis remains useful for finding malformed RTL,
but it is not the acceptance criterion for a MHz target.  Any frequency claim
requires a selected implementation technology, timing constraints and static
timing analysis.

## Explicitly deferred

- full RVV compatibility or binary encoding;
- IEEE-754 floating point;
- 64-bit arithmetic path;
- multi-PC/multi-thread scheduling;
- register VROUTE and cooperative route waves;
- arbitrary memory scatter atomics;
- multi-outstanding or out-of-order D-side responses;
- coherent cache policy.
