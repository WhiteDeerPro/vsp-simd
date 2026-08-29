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
        EXEC_ROUTE op=gather va=1 vd=2 i0=3 i1=2 i2=1 i3=0
        EXEC_ROUTE op=broadcast va=3 vd=4 lane=2 mask=m0
        EXEC_ROUTE op=slide_up va=4 vd=5 amount=4
        EXEC_REDUCE op=min_u va=1
        EXEC_REDUCE op=max_u va=1
        """,
        0,
    )
    assert [word.value for word in route_and_reduce.words] == [
        0xD048406C,
        0xD4D0C008,
        0xD9144010,
        0x1A020003,
        0x1A020005,
    ]
    route_pc = asm.assemble_text(
        "route: EXEC_ROUTE op=broadcast va=1 vd=2 lane=0\n"
        "next: CONTROL_END\n",
        0x100,
    )
    assert route_pc.symbols == {"route": 0x100, "next": 0x104}

    expect_error("EXEC_ALU_RI op=add mode=byte va=0 vd=1 imm=256")
    expect_error("EXEC_ALU_RI op=pass_a mode=byte va=0 vd=1 imm=0")
    expect_error("EXEC_ALU_RR op=pass_a mode=byte va=0 vb=1 vd=1")
    expect_error("EXEC_ALU_RR op=avg_u mode=word va=0 vb=1 vd=2")
    expect_error(
        "EXEC_ALU_RR op=add mode=half va=0 vb=1 vd=2 reduce=sum_u"
    )
    expect_error("EXEC_ALU_RR op=add va=0 vb=1 vd=2 write=0")
    expect_error("EXEC_ROUTE op=gather va=1 vd=2 i0=0 i1=1 i2=2")
    expect_error("EXEC_ROUTE op=gather va=1 vd=2 i0=0 i1=1 i2=2 i3=4")
    expect_error("EXEC_ROUTE op=broadcast va=1 vd=2 lane=4")
    expect_error("EXEC_ROUTE op=slide_down va=1 vd=2 amount=5")
    expect_error("EXEC_ROUTE op=broadcast va=1 vd=2 lane=0 write=0")
    expect_error("EXEC_REDUCE op=none va=1")
    expect_error("EXEC_REDUCE op=min_u va=1 export=1")
    expect_error("MEMORY 0 1 2 3")
    expect_error("EXEC_ALU_RR op=add va=0 vb=1 vd=2 mystery=1")
    try:
        asm.assemble_text("CONTROL_END", 2)
    except asm.AssemblyError:
        pass
    else:
        raise AssertionError("unaligned base PC unexpectedly accepted")

    print("vsp_uword_asm_tb: exact smoke image and rejection checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
