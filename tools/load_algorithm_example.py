#!/usr/bin/env python3
"""
示例：如何在Python中加载和分析VSP算法机器码
"""

import pathlib
import json

def load_algorithm(base_name: str, algorithms_dir: str = "build/algorithms"):
    """加载算法的所有文件"""
    base_path = pathlib.Path(algorithms_dir) / base_name

    # 读取机器码
    hex_path = base_path.with_suffix('.hex')
    with open(hex_path) as f:
        machine_code = [line.strip() for line in f if line.strip()]

    # 读取符号表
    json_path = base_path.with_suffix('.json')
    with open(json_path) as f:
        symbols = json.load(f)

    # 读取列表
    lst_path = base_path.with_suffix('.lst')
    with open(lst_path) as f:
        listing = f.read()

    return {
        'machine_code': machine_code,
        'symbols': symbols,
        'listing': listing,
        'word_count': len(machine_code)
    }

def analyze_instruction_types(machine_code: list) -> dict:
    """分析指令类型分布"""
    stats = {
        'EXEC': 0,
        'MEMORY': 0,
        'CONTROL': 0,
        'UNKNOWN': 0
    }

    for word in machine_code:
        # 获取高4位（主类型）
        major = int(word[0], 16)

        if 0x1 <= major <= 0xa:
            stats['EXEC'] += 1
        elif major == 0xb:
            stats['MEMORY'] += 1
        elif major == 0xc:
            stats['CONTROL'] += 1
        else:
            stats['UNKNOWN'] += 1

    return stats

def main():
    print("VSP算法加载示例")
    print("=" * 60)
    print()

    # 示例：加载亮度调整算法
    algorithm_name = "algorithm_brightness_adjust"
    print(f"加载算法: {algorithm_name}")

    try:
        algo = load_algorithm(algorithm_name)

        print(f"✓ 成功加载")
        print(f"  指令数: {algo['word_count']}")
        print(f"  符号表: {list(algo['symbols'].keys())}")
        print()

        # 分析指令类型
        stats = analyze_instruction_types(algo['machine_code'])
        print("指令类型分布:")
        for itype, count in stats.items():
            if count > 0:
                percentage = (count / algo['word_count']) * 100
                print(f"  {itype}: {count} ({percentage:.1f}%)")
        print()

        # 显示前几条机器码
        print("机器码片段 (前10条):")
        for i, word in enumerate(algo['machine_code'][:10]):
            addr = algo['symbols'].get('entry', 0) + i * 4
            print(f"  0x{addr:08x}: {word}")
        print()

        # 显示如何在SystemVerilog中使用
        print("在SystemVerilog仿真中使用:")
        print(f'''
// 声明程序存储器
logic [31:0] program_memory [0:255];

// 加载机器码
initial begin
    $readmemh("build/algorithms/{algorithm_name}.hex", program_memory);

    // 验证加载
    $display("Loaded %0d words", {algo['word_count']});
    $display("Entry point: 0x%08x", {algo['symbols'].get('entry', 0)});
end
''')

    except FileNotFoundError as e:
        print(f"✗ 错误: 文件不存在 - {e}")
        print("  请先运行 ./build_algorithms.sh")
    except Exception as e:
        print(f"✗ 错误: {e}")

if __name__ == "__main__":
    main()
