# Internal EXEC uword profile v0

This is a compact internal control-store profile: a 32-bit base word plus an
optional 32-bit scalar-immediate extension.  It is executable and tested, but
it is not a public ISA or an RVV binary-compatible encoding.

## Scope

The profile targets the current canonical EXEC capacities:

```text
physical narrow lane width = 8 bits
accumulator width          = 32 bits
VRF rows                   = 16
ARF rows                   = 8
MRF rows                   = 4
```

It covers vector ALU/compare/select, byte multiply/MAC, wide/narrow conversion,
shifted WADD/WSUB, compact/expand, MRF logic and reduction/export controls.
MEMORY and CONTROL use their own semantic decoders.

Cross-group register routing is no longer part of EXEC profile v0.  `fmt=0xd`
is undefined and is structurally consumed as one word so it can retire as an
ordered `BAD_FORMAT` decode error without losing PC synchronization.

## Action envelope

An EXEC action is formed from:

```text
encoded packet     = base word + optional extension word
resolved sideband  = target group mask and sequencer-derived state
issue envelope     = context + tag
```

Group masks do not consume base-word bits because their width follows the
cluster configuration.  RF data and boundary data use operand/state channels,
not the instruction queue.

## Common format

```text
31          28 27                                  0
+--------------+------------------------------------+
| fmt[3:0]     | format-specific payload[27:0]      |
+--------------+------------------------------------+
```

| `fmt` | family | extension rule |
|---:|---|---|
| `0x1` | ALU | scalar-immediate form requires extension |
| `0x2` | CMP | scalar-immediate form requires extension |
| `0x3` | SELECT | scalar-immediate form requires extension |
| `0x4` | MUL | scalar-immediate form requires extension |
| `0x5` | MAC register form | forbidden |
| `0x6` | MAC immediate form | required |
| `0x7` | wide/narrow conversion | scalar-immediate form requires extension |
| `0x8` | WADD/WSUB | forbidden; align is in base word |
| `0x9` | COMPACT/EXPAND | forbidden |
| `0xa` | MRF logic | forbidden |
| `0xb` | outer MEMORY record | not an EXEC format |
| `0xc` | outer CONTROL record | not an EXEC format |
| `0x0,0xd..0xf` | undefined/reserved | not applicable |

The package function `vsp_exec_uword_extension_required()` is the single
source of structural EXEC length for the framer and expander.  A recognized
format consumes its extension according to structure even if a sub-op or
reserved field is later illegal.

## Canonical expansion

`vsp_exec_uword_expander` maps each format-local sub-op to the existing
`simd_op_e` function and fills the complete canonical bundle.  Fields not used
by a format are zero; they never inherit an older action.  Expansion derives:

- VRF/ARF/MRF source and destination rows;
- element mode and mask selector;
- scalar-immediate selection and sign/zero representation;
- writeback target and narrow export;
- reduction enable/op;
- operation-specific alignment, rounding and saturation controls;
- legality and a deterministic decode cause.

The 6-bit `simd_op_e` is a canonical execution function, not the full opcode.
Format-local sub-op values must pass through the mapping table and cannot drive
the datapath directly.

For illegal input the expander:

- reports `legal=0` and a profile-local cause;
- emits no RF write, result obligation, reduction or other side effect;
- preserves enough envelope identity for ordered rejection.

## MRF logic

The MRF family reuses the normal EXEC path rather than defining independent
MAND/MOR/MXOR/MNOT instruction classes.  Its sub-op selects the canonical MRF
function; sources are MRF rows, element mode is BYTE and masking is disabled.
The result may write MRF and, where encoded, materialize all-zero/all-one bytes
to VRF or the narrow result channel.

## WADD/WSUB

This family forms the three-input wide operation:

```text
ARF + (VRF-A << align) + (± VRF-B << align)
```

Signed/unsigned interpretation and add/subtract variant are format-local.  The
operation writes one ARF destination.  It does not require the accumulator to
be encoded as an ordinary third VRF operand.

## Assembler multiply/MAC spellings

The engineering assembler exposes the byte-only multiply formats directly:

```text
EXEC_MUL_RR op=mul_u|mul_s va=<VRF> vb=<VRF> [vd=<VRF>] [dst_arf=<ARF>]
EXEC_MUL_RI op=mul_u|mul_s va=<VRF> imm=<byte> [vd=<VRF>] [dst_arf=<ARF>]
EXEC_MAC_RR op=mac_u|mac_s va=<VRF> vb=<VRF> src_arf=<ARF> [dst_arf=<ARF>]
EXEC_MAC_RI op=mac_u|mac_s va=<VRF> imm=<byte> src_arf=<ARF> [dst_arf=<ARF>]
```

All four accept `mask`, `write_vrf`, `write_arf`, `export` and `reduce`.
Naming a destination enables its write by default.  MAC defaults `dst_arf` to
`src_arf` and enables the in-place ARF write; `as`/`ad` are accepted as short
aliases for `src_arf`/`dst_arf`.  The older `EXEC_ALU_RR/RI` spelling with a
`mul_*` or `mac_*` operation remains a source compatibility alias, but the
assembler emits the dedicated `fmt=4/5/6` encoding rather than an ALU sub-op.

## Relationship to MEMORY

The mixed stream uses major `0xb` for a structurally framed MEMORY record.
Current semantic decoding supports:

- `VLOAD/VSTORE`: unit-stride with span code zero for all selected groups or
  an explicit 1..31-byte span;
- `VGATHER/VSCATTER`: `base + unsigned 8-bit index VRF lane`, with decoded
  span zero and one transfer for every lane in the selected groups.

These are not EXEC formats and do not enter `vsp_exec_uword_expander`.

## Admission rule

Base and required extension must be associated before `action_valid`.  The
extension-required diagnostic is not a request to submit the second word on a
later cycle.  Under backpressure the entire encoded packet and resolved
sideband remain stable.

The strict product path expands one selected record at a time.  Generic
multi-slot decode holding RTL remains available for experiments, but profile
v0 does not imply multiple PCs or threads.

## Evolution

If future RF capacities or lane widths exceed this profile, create a versioned
profile instead of silently reinterpreting existing bit patterns.  A future
software ISA may decode into the same canonical bundle without exposing this
uword encoding.

Exact bit fields and legality tables are maintained with the executable sources
in `rtl/pkg/vsp_exec_uword_pkg.sv`, `rtl/cluster/vsp_exec_uword_expander.sv` and
their self-checking tests.
