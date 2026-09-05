# VSP host MMIO control

This integration provides a passive control-register target around the current
single-PC memory-system wrapper. Instruction/data requests still use the
existing active ordered lower-memory port. Main memory remains a simulation
model for this stage; AXI, DMA and a DRAM controller are external.

## Register transport

`mmio_req_valid/ready`, `mmio_req_write`, `mmio_req_addr[11:0]`,
`mmio_req_wdata[31:0]`, `mmio_req_wstrb[3:0]` accept a word-aligned byte offset
within a 4 KiB control aperture. The SoC or simulation host selects the aperture;
the VSP MMU does not translate this incoming register offset.
`mmio_rsp_valid/ready`, `mmio_rsp_rdata[31:0]`, `mmio_rsp_error` return one held
response per accepted request. Reads snapshot at acceptance. Writes have their
effect once at acceptance, regardless of response backpressure. One transaction
is outstanding; reset cancels both sides in the shared reset epoch.

Unaligned/unmapped accesses and writes to read-only registers return error with
zero data and no side effect. Ordinary RW registers support byte strobes; a
zero-strobe ordinary write is a no-op. COMMAND requires all four strobes.
Reserved configuration bits can be stored but are validated when submitting a
command; IRQ_ENABLE and IRQ_PENDING expose only bits 2:0.

## Initial register map

This is an integration ABI version, independent of the uword instruction format.

| Offset | Register | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | 0x56535031 |
| 0x004 | VERSION | RO | 0x00010000 |
| 0x008 | STATUS | RO | [0] system ready, [1] system quiescent, [2] host/core busy, [3] program active, [4] result valid, [5] launch pending, [6] management busy |
| 0x00c | COMMAND | WO, reads zero | 1 START, 2 ACK_RESULT, 3 MMU_READ, 4 MMU_WRITE, 5 MAINTENANCE, 6 CLEAR_PROTOCOL |
| 0x010 | START_PC | RW | byte PC, reset zero |
| 0x014 | END_PC | RW | exclusive byte PC, reset zero |
| 0x018 | GROUP_MASK | RW | selected groups; reset all implemented groups |
| 0x01c | FETCH_CONTEXT | RW | space [1:0], opaque context [15:8]; reset PHYSICAL=1 |
| 0x020 | TAG_SEED | RW | low TAG_W bits; reset zero |
| 0x024 | IRQ_ENABLE | RW | [0] job complete, [1] job error, [2] management complete |
| 0x028 | IRQ_PENDING | W1C | same events; events latch even if masked |
| 0x02c | FETCH_PC | RO | live fetch PC |
| 0x030 | RESULT_STATUS | RO | [0] valid, [1] done, [2] failed, [3] error |
| 0x034 | TERMINAL_PC | RO | program terminal-PC snapshot (use IFETCH_EADDR for fetch faults) |
| 0x038 | ACTION_COUNT | RO | accepted action completions, modulo 2^32 |
| 0x03c | FIRST_ERROR_INFO | RO | valid [0], class [15:8], action status [23:16], decode error [31:24] |
| 0x040 | FIRST_ERROR_TAG | RO | first erroneous action tag |
| 0x044 | MEM_FAULT_INFO | RO | valid [0], partial [1], op [15:8], memory status [23:16], memory cause [31:24] |
| 0x048 | MEM_FAULT_EADDR | RO | first failed MEMORY action's address |
| 0x04c | MEM_MASKS | RO | requested mask [15:0], completed mask [31:16] |
| 0x050 | MEM_FAILED_MASK | RO | failed group mask |
| 0x054 | MEM_BYTES | RO | bytes committed by that MEMORY action |
| 0x058 | IFETCH_INFO | RO | valid [0], cause [6:4], space [9:8], context [23:16] |
| 0x05c | IFETCH_EADDR | RO | failed requested word's effective byte address |
| 0x060 | IFETCH_PADDR_LO | RO | raw physical diagnostic bits [31:0] |
| 0x064 | IFETCH_PADDR_HI | RO | remaining physical diagnostic bits, zero extended |
| 0x070 | MMU_CONTEXT | RW | opaque context in low 8 bits |
| 0x074 | MMU_FIELD | RW | field code in low 4 bits |
| 0x078 | MMU_WDATA | RW | configuration payload |
| 0x07c | MMU_RDATA | RO | most recent completed MMU command readback |
| 0x080 | MGMT_STATUS | RO | valid [0], error [1], kind [9:8] (1 MMU, 2 maintenance), downstream status [18:16], fault [26:24] |
| 0x084 | MAINT_OP | RW | COMMON maintenance op 0..10 |
| 0x088 | MAINT_EADDR | RW | effective byte address |
| 0x08c | MAINT_PADDR_LO | RW | physical address low word |
| 0x090 | MAINT_PADDR_HI | RW | physical address high word |
| 0x094 | MAINT_CONTEXT | RW | opaque context in low 8 bits |
| 0x098 | MAINT_ASID | RW | low ASID_W bits |

All unspecified reset values are zero. Execution context is the current single
context zero. GROUP_COUNT supports 1..16, PADDR_W is 32 or 40, TAG_W is 1..8,
and ASID_W is 1..9 in this initial host profile.

## Submission, ownership and result publication

START, MMU_READ/WRITE and MAINTENANCE require the host command engine to be idle
and the memory system ready and quiescent. Otherwise COMMAND returns a bus error
immediately without starting work; STATUS reads remain available. START also
requires the previous job result to have been acknowledged. Configuration RW
registers remain writable while busy, but an accepted command owns a snapshot
and its downstream request/payload must remain stable until handshake.

START validates aligned START_PC < END_PC, a nonzero implemented group mask,
PHYSICAL or TRANSLATED fetch, and the widths/reserved fields of its envelope.
MMU commands check context/field widths and field code 0..9; the MMU checks
context existence and field payload semantics. Maintenance checks op/field
widths, including high physical-address bits. A successful MMIO COMMAND response
means submitted, not completed. No command queue or preemption is introduced.

The host controller continuously consumes action completions and EXEC debug
results. Vector results intended for software remain program STOREs to memory;
EXEC result observations are not a second software result FIFO. It counts
retired actions and records the first action error plus the first MEMORY
completion with a non-OK memory status (separate records). A MEMORY decode
rejection without a memory-engine completion belongs only to FIRST_ERROR_*.
It does not accumulate speculative live
`program_error` or IFetch faults as permanent errors while the program runs.

The one-cycle `program_done`/`program_failed` pulse is retained as terminal
pending. After `system_quiescent`, the controller publishes a frozen job result,
including final program error and IFetch diagnosis, and raises pending events.
DONE can coexist with ERROR; successful execution means DONE && !ERROR.
Transient IFetch faults discarded by a committed redirect do not become an IRQ.
Before RESULT_STATUS.valid, result registers read zero. After publication they
are unchanged until ACK_RESULT, which clears their visibility. START cannot
overwrite an unread result. ACK_RESULT is idempotent when idle and is rejected
while a command/job is owned. CLEAR_PROTOCOL is likewise idle-only and does not
clear the frozen job result or IRQ pending bits.

MMU and maintenance responses are automatically consumed and saved in
MGMT_STATUS (and MMU_RDATA). The next accepted management command clears the
previous management-result validity; software must read it before resubmission.
A completed job result does not prevent subsequent maintenance/configuration.
Job/management completions publish independently of MMIO response consumption.

`irq_o = |(IRQ_PENDING & IRQ_ENABLE)`. Job publication sets COMPLETE and, if
needed, ERROR; management publication sets MANAGEMENT. W1C clears the selected
enabled byte lanes, with new events winning simultaneous clears. ACK_RESULT and
IRQ acknowledge are independent. Neither requires VSP interrupt handlers.

The lower-memory provider must honor its visibility/quiescence contract. Current
D-cache policy is write-through/write-no-allocate; completion requires draining
accepted traffic, not an invented dirty-cache clean. Host-updated input/code
buffers still need appropriate D/I invalidation before reuse because cache
coherence is not provided. The host MMIO aperture is device register storage;
bulk program/data storage is the shared memory model, not the control aperture.

An external host prepares shared code/input memory, performs any required
visibility and cache maintenance, writes the launch registers, then submits
START. It polls RESULT_STATUS.valid or waits for IRQ, reads the frozen result
and stored output, acknowledges the IRQ bits, and issues ACK_RESULT before the
next START. The host must order its MMIO and shared-memory accesses according to
its platform; this target does not supply CPU-side cache coherence or barriers.

## Integration and verification

`vsp_host_control` implements this register target and existing-management
handshakes. `vsp_mmio_system_wrapper` composes it with
`vsp_uword_memory_system_wrapper`, leaving the generic lower-memory interface
exposed. The integration test drives actual MMIO transactions, not direct
`start_*`/MMU/maintenance pins, and uses modeled shared main memory.

Run `make lint-vsp-host-control lint-vsp-mmio-system` for default and alternate
parameter elaboration, `make test-vsp-host-control` for register/ownership
handshakes, and `make test-vsp-mmio-system` for physical/Sv32 jobs, vector
load/store, maintenance, IRQ, fault publication and restart through the full
I/D system. The latter's C++ host sequence is in
[`vsp_mmio_system_tb.cpp`](../../sim/integration/vsp_mmio_system_tb.cpp).
