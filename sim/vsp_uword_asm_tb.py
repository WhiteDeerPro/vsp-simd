#!/usr/bin/env python3
"""Independent checks for the internal uword assembly helper."""

from __future__ import annotations

import pathlib
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import vsp_uword_asm as asm  # noqa: E402


EXPECTED = [
    0x17822210,
    0x10020430,
    0x00000007,
    0xB8000015,
    0x60000000,
    0xC0000000,
    0x10046810,
    0x18080A30,
    0x00000003,
    0xC0000000,
]


def expect_error(source: str, base_pc: int = 0) -> None:
    try:
        asm.assemble_text(source, base_pc)
    except asm.AssemblyError:
        return
    raise AssertionError(f"source unexpectedly assembled: {source!r}")


def main() -> int:
    source = (REPO_ROOT / "examples/uword/pc_smoke.uasm").read_text(
        encoding="utf-8"
    )
    program = asm.assemble_text(source, 0x20)
    assert [word.value for word in program.words] == EXPECTED
    assert program.symbols == {
        "entry": 0x20,
        "cross_bundle_memory": 0x2C,
        "cross_bundle_exec": 0x3C,
        "program_end": 0x44,
    }

    negative = asm.assemble_text(
        "EXEC_ALU_RI op=add mode=byte va=0 vd=1 imm=-1", 0
    )
    assert [word.value for word in negative.words] == [0x10000230, 0xFF]

    reductions = asm.assemble_text(
        """
        EXEC_REDUCE op=min_u va=1
        EXEC_REDUCE op=max_u va=1
        """,
        0,
    )
    assert [word.value for word in reductions.words] == [
        0x1A020003,
        0x1A020005,
    ]

    multiply_accumulate = asm.assemble_text(
        """
        EXEC_MUL_RR op=mul_s va=2 vb=3 vd=4 dst_arf=5 mask=m0 \
                    write_vrf=1 write_arf=1 export=1 reduce=sum_s
        EXEC_MUL_RI op=mul_u va=15 imm=-1 dst_arf=7 mask=m3
        EXEC_MAC_RR op=mac_u va=1 vb=2 src_arf=3 dst_arf=4 vd=5 \
                    mask=m3 write_vrf=1 write_arf=1 reduce=sum_u
        EXEC_MAC_RI op=mac_s va=6 imm=0xa5 src_arf=2 dst_arf=7 vd=9 \
                    write_vrf=1 write_arf=1 export=1
        """,
        0,
    )
    assert [word.value for word in multiply_accumulate.words] == [
        0x491A52E8,
        0x47807940,
        0x000000FF,
        0x50938B31,
        0x6B02F238,
        0x000000A5,
    ]

    # The former ALU spelling remains a source-level compatibility alias, but
    # it must still select the dedicated profile-v0 MUL/MAC formats.
    compatibility_mul = asm.assemble_text(
        "EXEC_ALU_RR op=mul_u mode=byte va=2 vb=4 vd=6\n"
        "EXEC_ALU_RI op=mac_u va=3 imm=7 src_arf=1 dst_arf=1\n",
        0,
    )
    canonical_mul = asm.assemble_text(
        "EXEC_MUL_RR op=mul_u mode=byte va=2 vb=4 vd=6\n"
        "EXEC_MAC_RI op=mac_u va=3 imm=7 src_arf=1 dst_arf=1\n",
        0,
    )
    assert [word.value for word in compatibility_mul.words] == [
        word.value for word in canonical_mul.words
    ]
    assert [word.value for word in canonical_mul.words] == [
        0x41230080,
        0x61812010,
        0x00000007,
    ]

    wide_narrow = asm.assemble_text(
        "EXEC_WIDE_RI op=nslice arf=0 shift=0 vd=2\n"
        "EXEC_WIDE_RI op=nslice arf=0 shift=8 vd=3\n"
        "EXEC_WIDE_RI op=nslice arf=1 shift=16 vd=4\n"
        "EXEC_WIDE_RI op=nclip_u arf=0 shift=4 vd=5\n"
        "EXEC_WIDE_RI op=nclip_s arf=1 shift=8 vd=6\n"
        "EXEC_WIDE_RR op=nslice arf=2 vb=0 vd=7\n"
        "EXEC_WIDE_RI op=widen_u va=0 shift=0 dst_arf=3\n"
        "EXEC_WIDE_RI op=widen_s va=1 shift=2 dst_arf=4\n",
        0,
    )
    wide_words = [word.value for word in wide_narrow.words]
    assert wide_words == [
        0x7C004300,
        0x00000000,
        0x7C006300,
        0x00000008,
        0x7C208300,
        0x00000010,
        0x7800A300,
        0x00000004,
        0x7A20C300,
        0x00000008,
        0x7C40E100,
        0x70006300,
        0x00000000,
        0x72208300,
        0x00000002,
    ]
    # Format 0x7 bit 9 is the packet-length contract shared by the stream
    # framer and RTL expander: every RI base owns one extension; RR does not.
    for base_index in (0, 2, 4, 6, 8, 11, 13):
        assert wide_words[base_index] & (1 << 9)
    assert not wide_words[10] & (1 << 9)

    wide_boundaries = asm.assemble_text(
        "EXEC_WIDE_RI op=rshift_rnd_u arf=7 shift=31 dst_arf=7\n"
        "EXEC_WIDE_RR op=rshift_rnd_s arf=0 vb=15 dst_arf=0\n",
        0,
    )
    assert [word.value for word in wide_boundaries.words] == [
        0x74E0E300,
        0x0000001F,
        0x761E0100,
    ]

    wide_addsub = asm.assemble_text(
        "EXEC_WADD op=wadd_s va=3 vb=11 src_arf=0 dst_arf=0 align=6\n"
        "EXEC_WADD op=wsub_u va=15 vb=0 as=7 ad=6 align=31 mask=m3\n",
        0,
    )
    assert [word.value for word in wide_addsub.words] == [
        0x84EC0068,
        0x8BC3E9F8,
    ]

    state_and_memory = asm.assemble_text(
        """
        move: SMOVI rd=1 imm=0x100
        add: SADD rd=3 rs1=1 rs2=2
        addi: SADDI rd=4 rs1=3 imm=-8
        load: VLOAD sbase=4 vrf=1 span=4 offset=4
        store: VSTORE space=translated addr_context=0x12 sbase=3 \
                      vrf=2 span=4 offset=-8
        end: CONTROL_END
        """,
        0x100,
    )
    assert [word.value for word in state_and_memory.words] == [
        0xC4080000,
        0x00000100,
        0xC1184400,
        0xC620C000,
        0xFFFFFFF8,
        0xB4001048,
        0x00000004,
        0xB7090C88,
        0xFFFFFFF8,
        0xC0000000,
    ]
    assert state_and_memory.symbols == {
        "move": 0x100,
        "add": 0x108,
        "addi": 0x10C,
        "load": 0x114,
        "store": 0x11C,
        "end": 0x124,
    }

    indexed_memory = asm.assemble_text(
        """
        gather: VGATHER sbase=5 vd=6 vi=7 offset=12
        scatter: VSCATTER space=translated addr_context=0x12 sbase=3 \
                          vs=2 vi=4 offset=-8
        """,
        0x200,
    )
    assert [word.value for word in indexed_memory.words] == [
        0xB400159D,
        0x0000000C,
        0xB7090C91,
        0xFFFFFFF8,
    ]
    assert indexed_memory.symbols == {
        "gather": 0x200,
        "scatter": 0x208,
    }

    branches = asm.assemble_text(
        """
        entry: J target=forward
        back: BEQ rs1=3 rs2=4 target=entry
        forward: BNE rs1=31 rs2=1 target=back
        BEQZ rs1=5 target=done
        BNEZ rs1=6 target=forward
        done: CONTROL_END
        """,
        0x100,
    )
    assert [word.value for word in branches.words] == [
        0xC7000000,
        0x00000010,
        0xC7232000,
        0xFFFFFFF8,
        0xC75F0800,
        0xFFFFFFF8,
        0xC7250000,
        0x00000010,
        0xC7460000,
        0xFFFFFFF0,
        0xC0000000,
    ]
    assert branches.symbols == {
        "entry": 0x100,
        "back": 0x108,
        "forward": 0x110,
        "done": 0x128,
    }

    absolute_branches = asm.assemble_text(
        "J target=0x100\n"
        "BEQZ rs1=0 target=0x208\n",
        0x200,
    )
    assert [word.value for word in absolute_branches.words] == [
        0xC7000000,
        0xFFFFFF00,
        0xC7200000,
        0x00000000,
    ]

    relational_branches = asm.assemble_text(
        "BLT rs1=1 rs2=2 target=0\n"
        "BGE rs1=2 rs2=1 target=0\n"
        "BLTU rs1=1 rs2=2 target=0\n"
        "BGEU rs1=2 rs2=1 target=0\n"
        "BLTZ rs1=3 target=0\n"
        "BGEZ rs1=4 target=0\n",
        0,
    )
    assert [word.value for word in relational_branches.words] == [
        0xC7611000, 0x00000000,
        0xC7820800, 0xFFFFFFF8,
        0xC7A11000, 0xFFFFFFF0,
        0xC7C20800, 0xFFFFFFE8,
        0xC7630000, 0xFFFFFFE0,
        0xC7840000, 0xFFFFFFD8,
    ]

    source_aliases = asm.assemble_text(
        "LI rd=1 imm=3\n"
        "ADD rd=2 rs1=1 rs2=1\n"
        "ADDI rd=2 rs1=2 imm=-1\n"
        "END\n",
        0,
    )
    canonical_source = asm.assemble_text(
        "SMOVI rd=1 imm=3\n"
        "SADD rd=2 rs1=1 rs2=1\n"
        "SADDI rd=2 rs1=2 imm=-1\n"
        "CONTROL_END\n",
        0,
    )
    assert [word.value for word in source_aliases.words] == [
        word.value for word in canonical_source.words
    ]

    assert [word.value for word in asm.assemble_text(
        "BGTZ rs1=5 target=0", 0
    ).words] == [word.value for word in asm.assemble_text(
        "BLT rs1=0 rs2=5 target=0", 0
    ).words]
    assert [word.value for word in asm.assemble_text(
        "BLEZ rs1=6 target=0", 0
    ).words] == [word.value for word in asm.assemble_text(
        "BGE rs1=0 rs2=6 target=0", 0
    ).words]

    displacement_boundaries = asm.assemble_text(
        "J target=0x7ffffffc", 0
    )
    assert [word.value for word in displacement_boundaries.words] == [
        0xC7000000,
        0x7FFFFFFC,
    ]
    negative_displacement_boundary = asm.assemble_text(
        "J target=0", 0x80000000
    )
    assert [word.value for word in negative_displacement_boundary.words] == [
        0xC7000000,
        0x80000000,
    ]

    state_word_boundaries = asm.assemble_text(
        "SMOVI rd=0 imm=0xffffffff\n"
        "SADDI rd=31 rs1=31 imm=-2147483648\n",
        0,
    )
    assert [word.value for word in state_word_boundaries.words] == [
        0xC4000000,
        0xFFFFFFFF,
        0xC6FFC000,
        0x80000000,
    ]

    memory_defaults = asm.assemble_text(
        "VLOAD sbase=0 vrf=0 span=0\n"
        "VLOAD sbase=1 vrf=2 span=31\n"
        "VSTORE space=physical addr_context=255 sbase=31 vrf=15 "
        "span=16 offset=-32768\n",
        0,
    )
    assert [word.value for word in memory_defaults.words] == [
        0xB4000000,
        0x00000000,
        0xB40004BE,
        0x00000000,
        0xB6FFFFE0,
        0xFFFF8000,
    ]

    expect_error("EXEC_ALU_RI op=add mode=byte va=0 vd=1 imm=256")
    expect_error("EXEC_ALU_RI op=pass_a mode=byte va=0 vd=1 imm=0")
    expect_error("EXEC_ALU_RR op=pass_a mode=byte va=0 vb=1 vd=1")
    expect_error("EXEC_ALU_RR op=avg_u mode=word va=0 vb=1 vd=2")
    expect_error(
        "EXEC_ALU_RR op=add mode=half va=0 vb=1 vd=2 reduce=sum_u"
    )
    expect_error("EXEC_ALU_RR op=add va=0 vb=1 vd=2 write=0")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3")
    expect_error("EXEC_REDUCE op=none va=1")
    expect_error("EXEC_REDUCE op=min_u va=1 export=1")
    expect_error("MEMORY 0 1 2 3")
    expect_error("EXEC_ALU_RR op=add va=0 vb=1 vd=2 mystery=1")
    expect_error("EXEC_MUL_RR op=mac_u va=0 vb=1 dst_arf=0")
    expect_error("EXEC_MAC_RR op=mul_u va=0 vb=1 src_arf=0")
    expect_error("EXEC_MUL_RR op=mul_u mode=half va=0 vb=1 dst_arf=0")
    expect_error("EXEC_MAC_RR op=mac_u va=0 vb=1")
    expect_error("EXEC_MAC_RR op=mac_u va=0 vb=1 src_arf=8")
    expect_error("EXEC_MAC_RI op=mac_s va=0 src_arf=0 imm=256")
    expect_error("EXEC_MAC_RI op=mac_s va=0 src_arf=0")
    expect_error("EXEC_MAC_RR op=mac_s va=0 vb=1 src_arf=0 imm=1")
    expect_error(
        "EXEC_MAC_RR op=mac_u va=0 vb=1 src_arf=0 dst_arf=1 write_arf=0"
    )
    expect_error(
        "EXEC_MAC_RR op=mac_u va=0 vb=1 src_arf=0 vd=1 write_vrf=0"
    )
    expect_error(
        "EXEC_MAC_RR op=mac_u va=0 vb=1 src_arf=0 as=0"
    )
    expect_error("EXEC_WIDE_RI op=nslice arf=0 shift=-1 vd=0")
    expect_error("EXEC_WIDE_RI op=nslice arf=0 shift=32 vd=0")
    expect_error("EXEC_WIDE_RI op=nslice arf=0 shift=1 vb=0 vd=0")
    expect_error("EXEC_WIDE_RR op=nslice arf=0 vd=0")
    expect_error("EXEC_WIDE_RR op=nslice arf=0 vb=16 vd=0")
    expect_error("EXEC_WIDE_RI op=nslice arf=8 shift=1 vd=0")
    expect_error("EXEC_WIDE_RI op=nslice arf=0 shift=1 vd=16")
    expect_error("EXEC_WIDE_RI op=widen_u va=16 shift=1 dst_arf=0")
    expect_error("EXEC_WIDE_RI op=widen_u va=0 shift=1 dst_arf=8")
    expect_error(
        "EXEC_WIDE_RI op=nslice arf=0 shift=1 vd=1 write=0"
    )
    expect_error(
        "EXEC_WIDE_RI op=widen_u va=0 shift=1 dst_arf=1 write=0"
    )
    expect_error(
        "EXEC_WIDE_RI op=widen_u va=0 shift=1 dst_arf=1 export=1"
    )
    expect_error("EXEC_WADD op=bad va=0 vb=0 as=0 ad=0 align=0")
    expect_error("EXEC_WADD op=wadd_s va=16 vb=0 as=0 ad=0 align=0")
    expect_error("EXEC_WADD op=wadd_s va=0 vb=16 as=0 ad=0 align=0")
    expect_error("EXEC_WADD op=wadd_s va=0 vb=0 as=8 ad=0 align=0")
    expect_error("EXEC_WADD op=wadd_s va=0 vb=0 as=0 ad=8 align=0")
    expect_error("EXEC_WADD op=wadd_s va=0 vb=0 as=0 ad=0 align=32")
    expect_error(
        "EXEC_WADD op=wadd_s va=0 vb=0 as=0 ad=1 align=0 write=0"
    )
    expect_error("SMOVI imm=1")
    expect_error("SMOVI rd=32 imm=1")
    expect_error("SMOVI rd=1 imm=0x100000000")
    expect_error("SMOVI rd=1 imm=-2147483649")
    expect_error("SMOVI rd=1 rs1=0 imm=1")
    expect_error("SADD rd=1 rs1=2")
    expect_error("SADD rd=1 rs1=2 rs2=3 imm=0")
    expect_error("SADDI rd=1 rs1=2")
    expect_error("SADDI rd=1 rs1=2 rs2=0 imm=3")
    expect_error("J")
    expect_error("J target=missing")
    expect_error("J target=2")
    expect_error("J target=-4")
    expect_error("J target=0 target=4")
    expect_error("J rs1=0 target=0")
    expect_error("J somewhere")
    expect_error("BEQ rs1=1 target=0")
    expect_error("BEQ rs1=1 rs2=32 target=0")
    expect_error("BNE rs1=-1 rs2=0 target=0")
    expect_error("BEQZ target=0")
    expect_error("BEQZ rs1=1 rs2=0 target=0")
    expect_error("BNEZ rs1=1 mystery=0 target=0")
    expect_error("BLT rs1=1 target=0")
    expect_error("BGEU rs1=1 rs2=32 target=0")
    expect_error("BLTZ rs1=1 rs2=0 target=0")
    expect_error("BGTZ target=0")
    expect_error("END extra=1")
    expect_error("J target=0x80000000", 0)
    expect_error("J target=0", 0x80000004)
    expect_error("again: J target=again\nagain: CONTROL_END")
    expect_error("VLOAD vrf=1 span=4")
    expect_error("VLOAD sbase=1 span=4")
    expect_error("VLOAD sbase=1 vrf=1")
    expect_error("VLOAD space=reserved sbase=1 vrf=1 span=4")
    expect_error("VLOAD sbase=32 vrf=1 span=4")
    expect_error("VLOAD sbase=1 vrf=16 span=4")
    expect_error("VLOAD sbase=1 vrf=1 span=32")
    expect_error("VLOAD sbase=1 vrf=1 span=64")
    expect_error("VLOAD sbase=1 vrf=1 span=4 addr_context=256")
    expect_error("VLOAD sbase=1 vrf=1 span=4 offset=-32769")
    expect_error("VLOAD sbase=1 vrf=1 span=4 index=0")
    expect_error("VSTORE sbase=1 vrf=1 span=4 offset=32768")
    expect_error("VSTORE sbase=1 vrf=1 span=4 mystery=1")
    expect_error("VGATHER vd=1 vi=0")
    expect_error("VGATHER sbase=1 vi=0")
    expect_error("VGATHER sbase=1 vd=1")
    expect_error("VGATHER sbase=1 vd=1 vi=16")
    expect_error("VGATHER sbase=1 vd=1 vi=0 span=4")
    expect_error("VGATHER sbase=1 vrf=1 vi=0")
    expect_error("VSCATTER sbase=1 vs=1 vi=-1")
    expect_error("VSCATTER sbase=1 vs=1 vi=0 offset=32768")
    expect_error("VSCATTER sbase=1 vd=1 vi=0")
    try:
        asm.assemble_text("CONTROL_END", 2)
    except asm.AssemblyError:
        pass
    else:
        raise AssertionError("unaligned base PC unexpectedly accepted")

    print(
        "vsp_uword_asm_tb: exact ALU/MUL/MAC/WIDE, state, branch, "
        "sequential/indexed MEMORY images and rejection checks passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
