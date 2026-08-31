#!/usr/bin/env python3
"""Build current-syntax VSP uword source from static algorithm schedules.

This module deliberately stops at readable ``.uasm``.  The exact assembler
in :mod:`vsp_uword_asm` remains responsible for labels, legality and encoding;
an RTL harness remains responsible for proving that an assembled program
actually produces the expected result.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List


STATE_REGS = 32
MEMORY_VRF_ROWS = 16
MEMORY_MAX_EXPLICIT_SPAN_BYTES = 31


@dataclass
class VRFAllocation:
    """VRF寄存器分配管理"""
    num_rows: int = 16
    allocated: set[int] = field(default_factory=set)

    def alloc(self, name: str) -> int:
        """分配一个VRF行"""
        for i in range(self.num_rows):
            if i not in self.allocated:
                self.allocated.add(i)
                return i
        raise RuntimeError(f"No free VRF rows for {name}")

    def alloc_range(self, count: int, base_name: str) -> List[int]:
        """分配连续的VRF行"""
        if count <= 0:
            raise ValueError("VRF range count must be positive")
        for start in range(self.num_rows - count + 1):
            rows = range(start, start + count)
            if all(row not in self.allocated for row in rows):
                self.allocated.update(rows)
                return list(rows)
        raise RuntimeError(
            f"No contiguous range of {count} VRF rows for {base_name}"
        )

    def free(self, row: int):
        """释放VRF行"""
        self.allocated.discard(row)


class VSPAsmBuilder:
    """VSP汇编程序构建器"""

    def __init__(self, *, state_regs: int = STATE_REGS,
                 vrf_rows: int = MEMORY_VRF_ROWS):
        self.lines: List[str] = []
        self.labels: set[str] = set()
        self.state_regs = state_regs
        self.vrf_alloc = VRFAllocation(vrf_rows)
        self.state_regs_used: set[int] = set()

    def _state_reg(self, reg: int) -> int:
        if reg < 0 or reg >= self.state_regs:
            raise ValueError(
                f"state register {reg} is outside 0..{self.state_regs - 1}"
            )
        return reg

    def _vrf_row(self, row: int) -> int:
        if row < 0 or row >= self.vrf_alloc.num_rows:
            raise ValueError(
                f"VRF row {row} is outside 0..{self.vrf_alloc.num_rows - 1}"
            )
        return row

    @staticmethod
    def _span_bytes(span_bytes: int) -> int:
        if span_bytes < 0 or span_bytes > MEMORY_MAX_EXPLICIT_SPAN_BYTES:
            raise ValueError(
                "unit-stride span must be 0 (all selected groups) or "
                f"1..{MEMORY_MAX_EXPLICIT_SPAN_BYTES} bytes"
            )
        return span_bytes

    def comment(self, text: str):
        """添加注释"""
        self.lines.append(f"# {text}")
        return self

    def blank(self):
        """添加空行"""
        self.lines.append("")
        return self

    def label(self, name: str):
        """添加标签"""
        if name in self.labels:
            raise ValueError(f"Label {name} already defined")
        self.labels.add(name)
        self.lines.append(f"{name}:")
        return self

    def emit(self, instruction: str):
        """直接添加指令"""
        self.lines.append(instruction)
        return self

    # === State操作 ===

    def smovi(self, reg: int, imm: int):
        """加载立即数到状态寄存器"""
        self._state_reg(reg)
        self.state_regs_used.add(reg)
        self.lines.append(f"SMOVI rd={reg} imm={imm:#x}")
        return self

    def li(self, reg: int, imm: int):
        """Readable alias for :meth:`smovi`."""
        return self.smovi(reg, imm)

    def sadd(self, dst: int, src1: int, src2: int):
        """状态寄存器加法"""
        for r in [dst, src1, src2]:
            self._state_reg(r)
            self.state_regs_used.add(r)
        self.lines.append(f"SADD rd={dst} rs1={src1} rs2={src2}")
        return self

    def saddi(self, dst: int, src: int, imm: int):
        """状态寄存器立即数加法"""
        for r in [dst, src]:
            self._state_reg(r)
            self.state_regs_used.add(r)
        self.lines.append(f"SADDI rd={dst} rs1={src} imm={imm}")
        return self

    # === Memory操作 ===

    def vload(self, vd: int, base_reg: int, offset: int = 0,
              span_bytes: int = 16, addr_space: str = "local",
              addr_context: int = 0):
        """向量加载"""
        self._vrf_row(vd)
        self._state_reg(base_reg)
        self._span_bytes(span_bytes)
        self.lines.append(
            f"VLOAD space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vrf={vd} span={span_bytes} offset={offset}")
        return self

    def vstore(self, vs: int, base_reg: int, offset: int = 0,
               span_bytes: int = 16, addr_space: str = "local",
               addr_context: int = 0):
        """向量存储"""
        self._vrf_row(vs)
        self._state_reg(base_reg)
        self._span_bytes(span_bytes)
        self.lines.append(
            f"VSTORE space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vrf={vs} span={span_bytes} offset={offset}")
        return self

    def vgather(self, vd: int, vi: int, base_reg: int, offset: int = 0,
                addr_space: str = "local", addr_context: int = 0):
        """按VRF索引行中的unsigned byte offset执行memory gather。"""
        self._vrf_row(vd)
        self._vrf_row(vi)
        self._state_reg(base_reg)
        self.lines.append(
            f"VGATHER space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vd={vd} vi={vi} offset={offset}")
        return self

    def vscatter(self, vs: int, vi: int, base_reg: int, offset: int = 0,
                 addr_space: str = "local", addr_context: int = 0):
        """按VRF索引行中的unsigned byte offset执行有序memory scatter。"""
        self._vrf_row(vs)
        self._vrf_row(vi)
        self._state_reg(base_reg)
        self.lines.append(
            f"VSCATTER space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vs={vs} vi={vi} offset={offset}")
        return self

    # === EXEC ALU操作 ===

    def alu(self, op: str, vd: int, va: int, vb: int,
            mode: str = "byte", mask: str = "none", reduce: str = "none"):
        """通用ALU操作"""
        for row in [vd, va, vb]:
            self._vrf_row(row)
        inst = f"EXEC_ALU_RR op={op} mode={mode} va={va} vb={vb} vd={vd}"
        if mask != "none":
            inst += f" mask={mask}"
        if reduce != "none":
            inst += f" reduce={reduce}"
        self.lines.append(inst)
        return self

    def alu_imm(self, op: str, vd: int, va: int, imm: int,
                mode: str = "byte", mask: str = "none"):
        """带立即数的ALU操作"""
        for row in [vd, va]:
            self._vrf_row(row)
        inst = f"EXEC_ALU_RI op={op} mode={mode} va={va} vd={vd} imm={imm}"
        if mask != "none":
            inst += f" mask={mask}"
        self.lines.append(inst)
        return self

    def add(self, vd: int, va: int, vb: int, mode: str = "byte"):
        """向量加法"""
        return self.alu("add", vd, va, vb, mode)

    def sub(self, vd: int, va: int, vb: int, mode: str = "byte"):
        """向量减法"""
        return self.alu("sub", vd, va, vb, mode)

    def absdiff(self, vd: int, va: int, vb: int):
        """绝对差值（无符号）"""
        return self.alu("absdiff_u", vd, va, vb)

    def min_u(self, vd: int, va: int, vb: int, mode: str = "byte"):
        """无符号最小值"""
        return self.alu("min_u", vd, va, vb, mode)

    def max_u(self, vd: int, va: int, vb: int, mode: str = "byte"):
        """无符号最大值"""
        return self.alu("max_u", vd, va, vb, mode)

    # === Reduction操作 ===

    def reduce(self, op: str, va: int):
        """Reduction操作（返回标量结果）"""
        self._vrf_row(va)
        self.lines.append(f"EXEC_REDUCE op={op} va={va}")
        return self

    # === 控制操作 ===

    def jump(self, target: str):
        """Unconditional PC-relative jump to a source label."""
        self.lines.append(f"J target={target}")
        return self

    def branch(self, condition: str, src1: int, src2: int,
               target: str):
        """Two-register conditional branch.

        The exact assembler checks the condition name and resolves ``target``.
        """
        self._state_reg(src1)
        self._state_reg(src2)
        self.lines.append(
            f"{condition.upper()} rs1={src1} rs2={src2} target={target}"
        )
        return self

    def bltu(self, src1: int, src2: int, target: str):
        """Branch when ``src1`` is unsigned-less-than ``src2``."""
        return self.branch("bltu", src1, src2, target)

    def end(self):
        """程序结束"""
        self.lines.append("CONTROL_END")
        return self

    # === 输出 ===

    def to_string(self) -> str:
        """生成汇编代码"""
        return "\n".join(self.lines)

    def save(self, filepath: str):
        """保存到文件"""
        Path(filepath).write_text(self.to_string() + "\n", encoding="utf-8")


class ImageProcessingPatterns:
    """常见图像处理模式的高级封装"""

    @staticmethod
    def box_blur_3x3_separable(builder: VSPAsmBuilder,
                               src_base: int, dst_base: int,
                               width: int, height: int,
                               temp_vrf: int):
        """3x3 box blur的可分离实现（水平+垂直）

        使用[1,1,1]内核，需要归一化
        """
        builder.comment("=== 3x3 Box Blur (Separable) ===")
        builder.comment(f"Input: s{src_base}, Output: s{dst_base}")
        builder.comment(f"Temp VRF: v{temp_vrf}")
        builder.blank()

        # 实现简化版：加载3行，做水平模糊，再做垂直模糊
        # 这里只给出框架，完整实现需要循环展开

        builder.comment("TODO: 完整的可分离卷积实现")
        builder.comment("需要：行缓冲、滑动窗口、归一化")

        return builder

    @staticmethod
    def sad_block(builder: VSPAsmBuilder,
                  va_base: int, vb_base: int,
                  num_vectors: int) -> VSPAsmBuilder:
        """SAD块计算（Sum of Absolute Differences）

        Args:
            va_base: 第一组向量起始行
            vb_base: 第二组向量起始行
            num_vectors: 向量数量
        """
        builder.comment(f"=== SAD Block: v{va_base}..v{va_base+num_vectors-1} "
                       f"vs v{vb_base}..v{vb_base+num_vectors-1} ===")

        vtemp = builder.vrf_alloc.alloc("sad_temp")

        for i in range(num_vectors):
            va = va_base + i
            vb = vb_base + i

            # ABSDIFF_U
            builder.absdiff(vtemp, va, vb)

            # REDUCE_SUM_U
            builder.reduce("sum_u", vtemp)

        builder.vrf_alloc.free(vtemp)
        return builder

    @staticmethod
    def histogram_atomic_update(builder: VSPAsmBuilder,
                                input_vrf: int,
                                hist_base_reg: int):
        """直方图原子更新的基本框架

        VSP已有有序byte scatter，但没有原子read-modify-write。
        这里展示为什么直方图仍需专用原子或软件合并。
        """
        builder.comment("=== Histogram Update (Conceptual) ===")
        builder.comment("原子直方图更新需要特殊处理：")
        builder.comment("1. 提取每个lane的像素值作为索引")
        builder.comment("2. 对每个索引，原子地增加计数")
        builder.comment("3. VSCATTER可写回，但重复地址只是later-lane-wins，不是原子加")
        builder.blank()

        builder.comment("建议方案：")
        builder.comment("A. 同组内先合并重复 index，再提交唯一更新")
        builder.comment("B. 使用不会冲突的更小私有域，最后归并")
        builder.comment("C. 使用 predicate/reduction 并由上级累加")
        builder.blank()

        return builder


def generate_brightness_loop(*, input_base: int = 0x40,
                             output_offset: int = 0x100,
                             byte_count: int = 48,
                             increment: int = 40,
                             vector_bytes: int = 16) -> VSPAsmBuilder:
    """Generate a closed unit-stride saturating-brightness program.

    ``vector_bytes=16`` is the current four-SIMD4 product profile.  The launch
    side must select all four groups; the uword stream itself intentionally
    does not own the launch mask.
    """
    if vector_bytes <= 0 or vector_bytes > MEMORY_MAX_EXPLICIT_SPAN_BYTES:
        raise ValueError("vector_bytes must fit the explicit span field")
    if byte_count <= 0 or byte_count % vector_bytes:
        raise ValueError("byte_count must be a positive whole-vector multiple")
    if increment < 0 or increment > 0xFF:
        raise ValueError("byte increment must fit one unsigned byte")

    pointer = 1
    limit = 2
    source = 0
    result = 1
    builder = VSPAsmBuilder()

    builder.comment(f"{byte_count}-byte saturating brightness loop")
    builder.comment("Launch requirement: four groups selected (group_mask=0xf)")
    builder.comment(
        f"dst[p] = min(255, src[p] + {increment}), {byte_count} bytes"
    )
    builder.li(pointer, input_base)
    builder.li(limit, input_base + byte_count)
    builder.blank()

    builder.label("loop")
    builder.vload(source, pointer, span_bytes=vector_bytes)
    builder.alu_imm("add_sat_u", result, source, increment, mode="byte")
    builder.vstore(result, pointer, offset=output_offset,
                   span_bytes=vector_bytes)
    builder.saddi(pointer, pointer, vector_bytes)
    builder.bltu(pointer, limit, "loop")
    builder.end()
    return builder


def generate_checkerboard_test():
    """生成棋盘图测试程序"""
    builder = VSPAsmBuilder()

    builder.comment("Checkerboard Pattern Test")
    builder.comment("Load checkerboard, apply simple filter, store result")
    builder.blank()

    # 状态寄存器设置
    builder.comment("Setup base addresses")
    builder.smovi(1, 0x1000)  # 输入地址
    builder.smovi(2, 0x2000)  # 输出地址
    builder.blank()

    # 加载数据
    builder.label("load_data")
    v_in = 0
    v_out = 1

    builder.comment("Load 16 bytes from input")
    builder.vload(v_in, base_reg=1, offset=0, span_bytes=16)
    builder.blank()

    # 反相要做 255 - input；RI sub 的语义是 va - imm，
    # 所以先构造常数 255，再使用 RR sub。
    builder.comment("Invert: 255 - input")
    builder.alu("xor", v_out, v_in, v_in, mode="byte")
    builder.alu_imm("add", v_out, v_out, 255, mode="byte")
    builder.sub(v_out, v_out, v_in, mode="byte")
    builder.blank()

    # 存储结果
    builder.comment("Store result")
    builder.vstore(v_out, base_reg=2, offset=0, span_bytes=16)
    builder.blank()

    builder.end()

    return builder


def generate_reduction_test():
    """生成reduction测试程序（用于直方图等）"""
    builder = VSPAsmBuilder()

    builder.comment("Reduction Operations Test")
    builder.comment("Compute min, max, sum of loaded data")
    builder.blank()

    # 加载数据
    builder.smovi(1, 0x1000)
    v_data = 0
    builder.vload(v_data, base_reg=1)
    builder.blank()

    # 各种reduction
    builder.comment("Find minimum value")
    builder.reduce("min_u", v_data)
    builder.blank()

    builder.comment("Find maximum value")
    builder.reduce("max_u", v_data)
    builder.blank()

    builder.comment("Compute sum")
    builder.reduce("sum_u", v_data)
    builder.blank()

    builder.end()

    return builder


def generate_sliding_window_test():
    """生成滑动窗口测试（用于卷积等）"""
    builder = VSPAsmBuilder()

    builder.comment("Sliding Window Test - indexed-memory 3-tap filter")
    builder.comment("Compute wrapped_byte_sum(left, center, right) >> 2")
    builder.comment("This is a quarter-scaled example, not an exact divide-by-3 mean")
    builder.blank()

    # 分配VRF
    v_left = 0
    v_center = 1
    v_right = 2
    v_sum = 3
    v_result = 4
    v_index_left = 5
    v_index_right = 6

    builder.smovi(1, 0x1000)
    builder.blank()

    # 加载中心数据
    builder.comment("Load center window")
    builder.vload(v_center, base_reg=1, offset=0)
    builder.blank()

    # 通过VRF索引向量从同一256-byte memory window提取左右邻居。
    # 索引行由调用者/加载阶段准备。
    builder.comment("VRF5/VRF6 contain unsigned memory byte offsets")
    builder.comment("Gather the left neighbor from the input memory window")
    builder.vgather(v_left, v_index_left, base_reg=1)
    builder.blank()

    builder.comment("Gather the right neighbor from the input memory window")
    builder.vgather(v_right, v_index_right, base_reg=1)
    builder.blank()

    # 三路加法
    builder.comment("Sum three taps")
    builder.add(v_sum, v_left, v_center, mode="byte")
    builder.add(v_sum, v_sum, v_right, mode="byte")
    builder.blank()

    # RI shift 的立即数是每个 byte lane 的移位量。
    builder.comment("Scale by 1/4 with an unsigned right shift of two bits")
    builder.alu_imm("shr_u", v_result, v_sum, 2, mode="byte")
    builder.blank()

    # 存储
    builder.smovi(2, 0x2000)
    builder.vstore(v_result, base_reg=2)
    builder.blank()

    builder.end()

    return builder


PROGRAMS: dict[str, Callable[[], VSPAsmBuilder]] = {
    "brightness_loop": generate_brightness_loop,
    "checkerboard": generate_checkerboard_test,
    "reduction": generate_reduction_test,
    "sliding_window": generate_sliding_window_test,
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="generate and validate current-syntax algorithm uasm"
    )
    parser.add_argument(
        "--program", action="append", choices=sorted(PROGRAMS),
        help="program to generate; repeat as needed (default: all)",
    )
    parser.add_argument(
        "--output-dir", type=Path,
        default=Path(__file__).resolve().parents[1] / "build/generated/uword",
        help="generated source directory (default: build/generated/uword)",
    )
    parser.add_argument(
        "--base-pc", type=lambda value: int(value, 0), default=0,
        help="base PC used for validation (default: 0)",
    )
    args = parser.parse_args(argv)

    # The source builder and exact encoder remain separate modules.  Running
    # the generator validates their boundary without teaching this layer any
    # binary encoding details.
    import vsp_uword_asm as exact_asm

    selected = args.program or list(PROGRAMS)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name in selected:
        builder = PROGRAMS[name]()
        source = builder.to_string() + "\n"
        assembly = exact_asm.assemble_text(source, args.base_pc)
        path = args.output_dir / f"{name}.uasm"
        path.write_text(source, encoding="utf-8")
        print(f"Generated {path} ({len(assembly.words)} words)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
