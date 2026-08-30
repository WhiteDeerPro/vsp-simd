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


def expect_error(source: str) -> None:
    try:
        asm.assemble_text(source, 0)
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

    route_and_reduce = asm.assemble_text(
        """
        EXEC_ROUTE vs=1 vi=3 vd=2
        EXEC_ROUTE vs=3 vi=4 vd=5 io=local
        EXEC_ROUTE va=4 vi=6 vd=7 io=in
        EXEC_ROUTE vs=1 vi=3 vd=2 io=out
        EXEC_ROUTE vs=1 vi=3 vd=2 io=inout
        EXEC_ROUTE vs=1 vi=3 vd=2 io=3
        EXEC_REDUCE op=min_u va=1
        EXEC_REDUCE op=max_u va=1
        """,
        0,
    )
    assert [word.value for word in route_and_reduce.words] == [
        0xD04800C0,
        0xD0D40100,
        0xD51C0180,
        0xD84800C0,
        0xDC4800C0,
        0xDC4800C0,
        0x1A020003,
        0x1A020005,
    ]
    numeric_route_io = asm.assemble_text(
        "\n".join(
            f"EXEC_ROUTE vs=1 vi=3 vd=2 io={mode}"
            for mode in range(4)
        ),
        0,
    )
    assert [word.value for word in numeric_route_io.words] == [
        0xD04800C0,
        0xD44800C0,
        0xD84800C0,
        0xDC4800C0,
    ]
    route_pc = asm.assemble_text(
        "route: EXEC_ROUTE vs=1 vi=0 vd=2\n"
        "next: CONTROL_END\n",
        0x100,
    )
    assert route_pc.symbols == {"route": 0x100, "next": 0x104}

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
        "VLOAD sbase=0 vrf=0 span=1\n"
        "VSTORE space=physical addr_context=255 sbase=31 vrf=15 "
        "span=16 offset=-32768\n",
        0,
    )
    assert [word.value for word in memory_defaults.words] == [
        0xB4000002,
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
    expect_error("EXEC_ROUTE vs=1 vd=2")
    expect_error("EXEC_ROUTE vi=1 vd=2")
    expect_error("EXEC_ROUTE vs=1 vi=2")
    expect_error("EXEC_ROUTE vs=16 vi=1 vd=2")
    expect_error("EXEC_ROUTE vs=1 vi=16 vd=2")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=16")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3 io=-1")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3 io=4")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3 io=dependent")
    expect_error("EXEC_ROUTE vs=1 va=1 vi=2 vd=3")
    expect_error("EXEC_ROUTE op=gather vs=1 vi=2 vd=3")
    expect_error("EXEC_ROUTE op=broadcast va=1 vd=2 lane=0")
    expect_error("EXEC_ROUTE op=slide_down va=1 vd=2 amount=1")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3 mask=m0")
    expect_error("EXEC_ROUTE vs=1 vi=2 vd=3 write=0")
    expect_error("EXEC_REDUCE op=none va=1")
    expect_error("EXEC_REDUCE op=min_u va=1 export=1")
    expect_error("MEMORY 0 1 2 3")
    expect_error("EXEC_ALU_RR op=add va=0 vb=1 vd=2 mystery=1")
    expect_error("SMOVI imm=1")
    expect_error("SMOVI rd=32 imm=1")
    expect_error("SMOVI rd=1 imm=0x100000000")
    expect_error("SMOVI rd=1 imm=-2147483649")
    expect_error("SMOVI rd=1 rs1=0 imm=1")
    expect_error("SADD rd=1 rs1=2")
    expect_error("SADD rd=1 rs1=2 rs2=3 imm=0")
    expect_error("SADDI rd=1 rs1=2")
    expect_error("SADDI rd=1 rs1=2 rs2=0 imm=3")
    expect_error("VLOAD vrf=1 span=4")
    expect_error("VLOAD sbase=1 span=4")
    expect_error("VLOAD sbase=1 vrf=1")
    expect_error("VLOAD space=reserved sbase=1 vrf=1 span=4")
    expect_error("VLOAD sbase=32 vrf=1 span=4")
    expect_error("VLOAD sbase=1 vrf=16 span=4")
    expect_error("VLOAD sbase=1 vrf=1 span=0")
    expect_error("VLOAD sbase=1 vrf=1 span=17")
    expect_error("VLOAD sbase=1 vrf=1 span=4 addr_context=256")
    expect_error("VLOAD sbase=1 vrf=1 span=4 offset=-32769")
    expect_error("VSTORE sbase=1 vrf=1 span=4 offset=32768")
    expect_error("VSTORE sbase=1 vrf=1 span=4 mystery=1")
    try:
        asm.assemble_text("CONTROL_END", 2)
    except asm.AssemblyError:
        pass
    else:
        raise AssertionError("unaligned base PC unexpectedly accepted")

    print(
        "vsp_uword_asm_tb: exact EXEC, state, MEMORY images and rejection "
        "checks passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
