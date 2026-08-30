#!/usr/bin/env python3
"""VSP 宿主侧 fixture 示例生成器。

它生成输入、软件参考结果和验证草案；它尚未连接 RTL
回归环境，也不会运行 VSP 程序。
"""

import sys
from pathlib import Path

# 添加tools目录到路径
sys.path.insert(0, str(Path(__file__).parent))

from generate_test_data import SimpleImageGenerator, SimpleDataDumper


def create_simple_filter_test(output_dir=None):
    """创建一个简单的3x3均值滤波宿主侧 fixture。"""

    print("=" * 60)
    print("VSP 宿主侧 fixture：3x3均值滤波")
    print("=" * 60)

    # 步骤1：生成测试输入
    print("\n步骤1：生成测试输入图像...")
    gen = SimpleImageGenerator()
    dumper = SimpleDataDumper()

    # 创建一个简单的测试图像（16x16足够演示）
    # 中心有一个亮块
    h, w = 16, 16
    img = [[0 for _ in range(w)] for _ in range(h)]

    # 在中心放置一个4x4的亮块
    for i in range(6, 10):
        for j in range(6, 10):
            img[i][j] = 255

    if output_dir is None:
        output_dir = Path(__file__).parent.parent / 'test_data' / 'examples'
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # 保存输入
    dumper.save_hex_dump(img, output_dir / 'filter_input.hex')
    dumper.save_pgm(img, output_dir / 'filter_input.pgm')

    print(f"  输入图像: {h}x{w}, 中心有4x4亮块")
    print(f"  已保存到: {output_dir}/filter_input.*")

    # 步骤2：计算参考结果（软件实现）
    print("\n步骤2：计算参考结果（软件模拟）...")

    def apply_mean_filter_3x3(img):
        """软件实现的3x3均值滤波"""
        h, w = len(img), len(img[0])
        result = [[0 for _ in range(w)] for _ in range(h)]

        for i in range(1, h - 1):
            for j in range(1, w - 1):
                sum_val = 0
                count = 0
                for di in range(-1, 2):
                    for dj in range(-1, 2):
                        sum_val += img[i + di][j + dj]
                        count += 1
                result[i][j] = sum_val // count

        return result

    reference = apply_mean_filter_3x3(img)
    dumper.save_hex_dump(reference, output_dir / 'filter_reference.hex')
    dumper.save_pgm(reference, output_dir / 'filter_reference.pgm')

    print(f"  参考结果已计算并保存")

    # 步骤3：生成统计信息
    print("\n步骤3：生成测试统计...")

    def compute_stats(img):
        flat = []
        for row in img:
            flat.extend(row)
        return {
            'min': min(flat),
            'max': max(flat),
            'mean': sum(flat) // len(flat),
            'nonzero': sum(1 for v in flat if v > 0)
        }

    input_stats = compute_stats(img)
    output_stats = compute_stats(reference)

    print(f"  输入统计: min={input_stats['min']}, max={input_stats['max']}, "
          f"mean={input_stats['mean']}, 非零像素={input_stats['nonzero']}")
    print(f"  输出统计: min={output_stats['min']}, max={output_stats['max']}, "
          f"mean={output_stats['mean']}, 非零像素={output_stats['nonzero']}")

    # 步骤4：生成验证脚本
    print("\n步骤4：生成验证脚本...")

    verification_code = f"""# VSP 3x3均值滤波验证草案

## 测试配置
- 输入尺寸: {h}x{w} = {h*w} bytes
- 滤波器: 3x3均值滤波
- 边界处理: 零填充（边界像素不处理）

## 预期结果
输入统计:
  - Min: {input_stats['min']}
  - Max: {input_stats['max']}
  - Mean: {input_stats['mean']}
  - 非零像素: {input_stats['nonzero']}

输出统计:
  - Min: {output_stats['min']}
  - Max: {output_stats['max']}
  - Mean: {output_stats['mean']}
  - 非零像素: {output_stats['nonzero']}

## 验证检查点
1. 边界像素应为0（未处理）
2. 亮块中心应变模糊（值在0-255之间）
3. 总体亮度保持（均值接近）
4. 非零像素数量增加（模糊扩散效果）

## 验证方法

### 在 SystemVerilog 环境中接入（草案）
```systemverilog
// .hex 每行是一个 32-bit word，不能直接加载到 byte 数组。
logic [31:0] input_words [0:{h*w//4 - 1}];
logic [31:0] output_words [0:{h*w//4 - 1}];
logic [31:0] reference_words [0:{h*w//4 - 1}];
integer errors;

initial begin
  $readmemh("test_data/examples/filter_input.hex", input_words);

  // TODO: 通过仿真环境的 init/peek 接口搬入、运行和取回数据。

  // 加载参考结果
  $readmemh("test_data/examples/filter_reference.hex", reference_words);

  // 对比 32-bit words
  errors = 0;
  for (int i = 0; i < {h*w//4}; i++) begin
    if (output_words[i] != reference_words[i]) begin
      $display("Mismatch at word [%0d]: got %08x, expected %08x",
               i, output_words[i], reference_words[i]);
      errors++;
    end
  end

  if (errors == 0) begin
    $display("PASS: All pixels match reference");
  end else begin
    $display("FAIL: %0d pixels differ", errors);
  end
end
```

### 使用Python验证
```python
from tools.generate_test_data import SimpleDataDumper

dumper = SimpleDataDumper()

# 加载结果
result = dumper.load_hex_dump('output.hex', shape=({h}, {w}))
reference = dumper.load_hex_dump(
    'test_data/examples/filter_reference.hex', shape=({h}, {w}))

# 对比
diff = [
    abs(a - b)
    for result_row, reference_row in zip(result, reference)
    for a, b in zip(result_row, reference_row)
]
max_error = max(diff)
num_errors = sum(1 for d in diff if d > 0)

print(f"Max error: {{max_error}}")
print(f"Pixels with errors: {{num_errors}}")

if max_error == 0:
    print("PASS: Exact match")
elif max_error <= 1:
    print("PASS: Within tolerance (±1)")
else:
    print("FAIL: Errors exceed tolerance")
```

## 文件清单
- filter_input.hex      - 测试输入（hex格式）
- filter_input.pgm      - 测试输入（可视化）
- filter_reference.hex  - 参考输出（hex格式）
- filter_reference.pgm  - 参考输出（可视化）
"""

    with open(output_dir / 'filter_test_verification.md', 'w') as f:
        f.write(verification_code)

    print(f"  验证脚本已保存到: {output_dir}/filter_test_verification.md")

    # 步骤5：生成简化的汇编示例（伪代码）
    print("\n步骤5：生成汇编伪代码...")

    asm_pseudocode = """# 3x3均值滤波程序草案（不是 RTL 回归程序）
# 完整实现需要循环展开、边界处理和宽累加/精确归一化。

entry:
    SMOVI rd=1 imm=0x1000
    SMOVI rd=2 imm=0x2000

    # 对于每个内部像素 (i, j)：
    # 需要加载3行数据，每行3个像素的邻域

process_center_region:
    # 示例：处理位置(8, 0..15)的一行
    # 需要行7、8、9的数据

    # 加载行7及其左右邻居；VRF12/VRF13 由加载阶段预先准备为
    # 同一256-byte memory window内的unsigned byte offsets。
    SADDI rd=4 rs1=1 imm=112
    VLOAD space=local addr_context=0 sbase=4 vrf=0 span=16 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=3 vi=12 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=6 vi=13 offset=0

    # 加载行8
    SADDI rd=4 rs1=1 imm=128
    VLOAD space=local addr_context=0 sbase=4 vrf=1 span=16 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=4 vi=12 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=7 vi=13 offset=0

    # 加载行9
    SADDI rd=4 rs1=1 imm=144
    VLOAD space=local addr_context=0 sbase=4 vrf=2 span=16 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=5 vi=12 offset=0
    VGATHER space=local addr_context=0 sbase=4 vd=8 vi=13 offset=0

    # 九路加法（行7的三个位置）
    EXEC_ALU_RR op=add mode=byte va=3 vb=0 vd=10
    EXEC_ALU_RR op=add mode=byte va=10 vb=6 vd=10

    # 行8的三个位置
    EXEC_ALU_RR op=add mode=byte va=10 vb=4 vd=10
    EXEC_ALU_RR op=add mode=byte va=10 vb=1 vd=10
    EXEC_ALU_RR op=add mode=byte va=10 vb=7 vd=10

    # 行9的三个位置
    EXEC_ALU_RR op=add mode=byte va=10 vb=5 vd=10
    EXEC_ALU_RR op=add mode=byte va=10 vb=2 vd=10
    EXEC_ALU_RR op=add mode=byte va=10 vb=8 vd=10

    # 除以9（近似：右移3位≈除以8）
    # 精确除法需要乘以倒数或查找表
    EXEC_ALU_RI op=shr_u mode=byte va=10 vd=11 imm=3

    # 存储结果
    SADDI rd=4 rs1=2 imm=128
    VSTORE space=local addr_context=0 sbase=4 vrf=11 span=16 offset=0

    # ... 循环处理其他行 ...

CONTROL_END

# 注意：
# 1. 完整实现需要循环展开或外部控制器
# 2. 边界处理需要特殊逻辑
# 3. byte add 会回绕，上述累加不等价于精确 3x3 均值滤波
# 4. 这里只展示当前语法下的数据运动草案
"""

    with open(output_dir / 'filter_asm_pseudocode.txt', 'w') as f:
        f.write(asm_pseudocode)

    print(f"  汇编伪代码已保存")

    print("\n" + "=" * 60)
    print("测试数据生成完成！")
    print("=" * 60)
    print(f"\n输出目录: {output_dir}")
    print("\n生成的文件:")
    print("  - filter_input.hex/pgm          - 测试输入")
    print("  - filter_reference.hex/pgm      - 参考输出")
    print("  - filter_test_verification.md   - 验证指南")
    print("  - filter_asm_pseudocode.txt     - 汇编示例")
    print("\n下一步:")
    print("  1. 查看PGM文件可视化图像")
    print("  2. 在现有仿真 harness 中接入 hex 文件")
    print("  3. 实现并运行 VSP 处理（本脚本未提供）")
    print("  4. 对比结果与参考输出")


def create_reduction_test(output_dir=None):
    """创建reduction操作测试（用于直方图等）"""

    print("\n" + "=" * 60)
    print("VSP Reduction测试示例")
    print("=" * 60)

    gen = SimpleImageGenerator()
    dumper = SimpleDataDumper()

    # 创建包含已知值的测试向量
    test_vectors = {
        'all_zeros': [[0] * 16 for _ in range(1)],
        'all_ones': [[1] * 16 for _ in range(1)],
        'all_255': [[255] * 16 for _ in range(1)],
        'sequential': [[i for i in range(16)] for _ in range(1)],
        'alternating': [[0 if i % 2 == 0 else 255 for i in range(16)] for _ in range(1)],
    }

    if output_dir is None:
        output_dir = Path(__file__).parent.parent / 'test_data' / 'reduction_tests'
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("\n生成reduction测试向量...")

    results = {}
    for name, vec in test_vectors.items():
        # 保存向量
        dumper.save_hex_dump(vec, output_dir / f'{name}.hex')

        # 计算预期结果
        flat = vec[0]
        results[name] = {
            'sum': sum(flat),
            'min': min(flat),
            'max': max(flat),
            'count': len(flat),
        }

        print(f"  {name:15s}: sum={results[name]['sum']:4d}, "
              f"min={results[name]['min']:3d}, max={results[name]['max']:3d}")

    # 保存预期结果
    with open(output_dir / 'expected_results.txt', 'w') as f:
        f.write("VSP Reduction测试 - 预期结果\n")
        f.write("=" * 60 + "\n\n")

        for index, (name, res) in enumerate(results.items()):
            f.write(f"{name}:\n")
            f.write(f"  REDUCE_SUM_U:  {res['sum']}\n")
            f.write(f"  REDUCE_MIN_U:  {res['min']}\n")
            f.write(f"  REDUCE_MAX_U:  {res['max']}\n")
            f.write(f"  Vector count:  {res['count']}\n")
            if index + 1 != len(results):
                f.write("\n")

    print(f"\n测试向量已保存到: {output_dir}")
    print(f"预期结果: {output_dir}/expected_results.txt")


if __name__ == '__main__':
    # 创建测试示例
    create_simple_filter_test()
    create_reduction_test()

    print("\n" + "=" * 60)
    print("所有测试数据生成完成！")
    print("=" * 60)
