# Indexed gather/scatter guide

The current MEMORY engine supports data-dependent byte addressing directly.
This is the active replacement for the retired cluster register-route path.

## Operations

```text
VGATHER  sbase=B vd=D vi=I [offset=K]
    D[lane] = MEM[state[B] + signed(K) + uint8(I[lane])]

VSCATTER sbase=B vs=S vi=I [offset=K]
    MEM[state[B] + signed(K) + uint8(I[lane])] = S[lane]
```

The actual four-group profile operates on 16 byte lanes.  Each index is an
unsigned byte offset, so the sixteen lanes may select sixteen positions in a
256-byte window.  The parameterized scaling limit is sixteen groups (64 byte
lanes) using the same window.

Every selected group activates all four of its lanes.  There is not yet an
independent per-byte predicate for indexed memory.  Use the group mask to
select whole SIMD4 groups.

## Ordering

The reference engine serializes lanes in `(group number, lane number)` order.
This makes behavior reproducible:

- duplicate gather offsets broadcast the same memory byte;
- duplicate scatter offsets are permitted and the later lane wins;
- only one memory request is outstanding;
- the first fault terminates the parent command;
- completed scatter bytes remain visible after a later fault.

This ordered scatter is not an atomic read-modify-write.  A histogram increment
still needs a dedicated atomic operation, a private-bin algorithm, or a
software merge phase.

## Example

```text
SMOVI rd=1 imm=0x1000

# VRF row 2 must already contain sixteen byte offsets.
VGATHER  space=local addr_context=0 sbase=1 vd=3 vi=2

# Perform ordinary vector work on row 3, then place the results back at the
# indexed positions.  Equal indices are resolved by the deterministic order.
VSCATTER space=local addr_context=0 sbase=1 vs=3 vi=2
```

Both pseudo-ops are two-word MEMORY records.  They share the normal address
space/context, signed offset, action tag and completion path with `VLOAD` and
`VSTORE`.  Indexed mode decodes an actual span of zero; the selected group mask
sets its transfer count.  In unit-stride mode, encoded span code zero instead
means all selected groups (`4 * popcount(group_mask)` bytes), while codes 1
through 31 are explicit byte spans.  The address-mode bit keeps these two zero
meanings unambiguous.

## Memory-system boundary

Internally, each indexed byte becomes an aligned 4-byte D-side request:

- gather aligns down and selects one byte from the returned beat;
- scatter aligns down and emits one-hot byte write strobe/data.

Thus cache, MMU/TLB and local-memory adapters continue to see ordinary
effective-address loads/stores.  Future coalescing may merge lanes that hit one
beat or cache line without changing the programming semantics.

See [routing.md](architecture/routing.md) for the architectural trade-off and
[data-movement.md](design/data-movement.md) for the full memory pipeline.
