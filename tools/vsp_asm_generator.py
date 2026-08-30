#!/usr/bin/env python3
"""VSP汇编生成辅助工具

提供高级API来生成VSP uword汇编程序，简化常见图像处理算法的编写。
"""

from typing import List
from dataclasses import dataclass


@dataclass
class VRFAllocation:
    """VRF寄存器分配管理"""
    num_rows: int = 16
    allocated: set = None

    def __post_init__(self):
        if self.allocated is None:
            self.allocated = set()

    def alloc(self, name: str) -> int:
        """分配一个VRF行"""
        for i in range(self.num_rows):
            if i not in self.allocated:
                self.allocated.add(i)
                return i
        raise RuntimeError(f"No free VRF rows for {name}")

    def alloc_range(self, count: int, base_name: str) -> List[int]:
        """分配连续的VRF行"""
        return [self.alloc(f"{base_name}{i}") for i in range(count)]

    def free(self, row: int):
        """释放VRF行"""
        self.allocated.discard(row)


class VSPAsmBuilder:
    """VSP汇编程序构建器"""

    def __init__(self):
        self.lines: List[str] = []
        self.labels: set = set()
        self.vrf_alloc = VRFAllocation()
        self.state_regs_used: set = set()

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
        self.state_regs_used.add(reg)
        self.lines.append(f"SMOVI rd={reg} imm={imm:#x}")
        return self

    def sadd(self, dst: int, src1: int, src2: int):
        """状态寄存器加法"""
        for r in [dst, src1, src2]:
            self.state_regs_used.add(r)
        self.lines.append(f"SADD rd={dst} rs1={src1} rs2={src2}")
        return self

    def saddi(self, dst: int, src: int, imm: int):
        """状态寄存器立即数加法"""
        for r in [dst, src]:
            self.state_regs_used.add(r)
        self.lines.append(f"SADDI rd={dst} rs1={src} imm={imm}")
        return self

    # === Memory操作 ===

    def vload(self, vd: int, base_reg: int, offset: int = 0,
              span_bytes: int = 16, addr_space: str = "local",
              addr_context: int = 0):
        """向量加载"""
        self.lines.append(
            f"VLOAD space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vrf={vd} span={span_bytes} offset={offset}")
        return self

    def vstore(self, vs: int, base_reg: int, offset: int = 0,
               span_bytes: int = 16, addr_space: str = "local",
               addr_context: int = 0):
        """向量存储"""
        self.lines.append(
            f"VSTORE space={addr_space} addr_context={addr_context} "
            f"sbase={base_reg} vrf={vs} span={span_bytes} offset={offset}")
        return self

    # === EXEC ALU操作 ===

    def alu(self, op: str, vd: int, va: int, vb: int,
            mode: str = "byte", mask: str = "none", reduce: str = "none"):
        """通用ALU操作"""
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

    # === Vector route操作 ===

    def vroute(self, vd: int, vs: int, vi: int, io_mode: int = 3):
        """用VRF索引行vi路由vs；io_mode[1:0]分别使能OUT/IN。"""
        self.lines.append(
            f"EXEC_ROUTE vs={vs} vi={vi} vd={vd} io={io_mode}"
        )
        return self

    # === Reduction操作 ===

    def reduce(self, op: str, va: int):
        """Reduction操作（返回标量结果）"""
        self.lines.append(f"EXEC_REDUCE op={op} va={va}")
        return self

    # === 控制操作 ===

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
        with open(filepath, 'w') as f:
            f.write(self.to_string())


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

        注意：真正的scatter需要特殊硬件支持或软件模拟
        这里展示概念性流程
        """
        builder.comment("=== Histogram Update (Conceptual) ===")
        builder.comment("Scatter操作需要特殊处理：")
        builder.comment("1. 提取每个lane的像素值作为索引")
        builder.comment("2. 对每个索引，原子地增加计数")
        builder.comment("3. VSP当前不直接支持scatter写入")
        builder.blank()

        builder.comment("建议方案：")
        builder.comment("A. 使用gather读取 + 增量 + 条件写回")
        builder.comment("B. 软件展开：顺序处理每个lane")
        builder.comment("C. 使用reduction + 外部累加器")
        builder.blank()

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

    builder.comment("Sliding Window Test - group-local 3-tap filter")
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

    # 通过VRF索引向量创建左右邻居。索引行由调用者/加载阶段准备；
    # 广播和slide不再占用立即数route编码。
    builder.comment("VRF5/VRF6 contain the left/right gather indices")
    builder.comment("Create left neighbor via the VRF5 index vector")
    builder.vroute(v_left, v_center, v_index_left)
    builder.blank()

    builder.comment("Create right neighbor via the VRF6 index vector")
    builder.vroute(v_right, v_center, v_index_right)
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


if __name__ == '__main__':
    from pathlib import Path

    output_dir = Path(__file__).parent.parent / 'examples' / 'uword'

    # 生成测试程序
    tests = {
        'checkerboard_test.uasm': generate_checkerboard_test(),
        'reduction_test.uasm': generate_reduction_test(),
        'sliding_window_test.uasm': generate_sliding_window_test(),
    }

    for filename, builder in tests.items():
        filepath = output_dir / filename
        builder.save(filepath)
        print(f"Generated: {filepath}")

    print(f"\nGenerated {len(tests)} test programs")
