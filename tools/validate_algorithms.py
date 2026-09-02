#!/usr/bin/env python3
"""
VSP算法机器码验证工具
验证生成的机器码文件的完整性和格式正确性
"""

import sys
import pathlib
import json
from typing import Dict, List, Tuple

def validate_hex_file(hex_path: pathlib.Path) -> Tuple[bool, str, int]:
    """验证十六进制机器码文件格式

    Returns:
        (is_valid, message, word_count)
    """
    try:
        lines = hex_path.read_text().strip().split('\n')
        word_count = 0

        for line_num, line in enumerate(lines, 1):
            line = line.strip()
            if not line:
                continue

            # 检查是否为8位十六进制
            if len(line) != 8:
                return False, f"Line {line_num}: 期望8个字符，实际{len(line)}", 0

            try:
                int(line, 16)
                word_count += 1
            except ValueError:
                return False, f"Line {line_num}: 不是有效的十六进制数: {line}", 0

        return True, f"格式正确，共{word_count}条指令", word_count

    except Exception as e:
        return False, f"读取错误: {e}", 0

def validate_listing_file(lst_path: pathlib.Path) -> Tuple[bool, str]:
    """验证列表文件格式"""
    try:
        content = lst_path.read_text()
        lines = [l for l in content.split('\n') if l.strip()]

        if len(lines) == 0:
            return False, "列表文件为空"

        # 检查格式: PC: WORD line ...
        for line in lines[:5]:  # 检查前5行
            if ':' not in line:
                return False, f"格式错误: {line}"

        return True, f"格式正确，共{len(lines)}行"

    except Exception as e:
        return False, f"读取错误: {e}"

def validate_symbol_file(json_path: pathlib.Path) -> Tuple[bool, str, Dict]:
    """验证符号表文件"""
    try:
        symbols = json.loads(json_path.read_text())

        if not isinstance(symbols, dict):
            return False, "符号表不是字典类型", {}

        # 验证所有值都是整数地址
        for label, addr in symbols.items():
            if not isinstance(addr, int):
                return False, f"标签 {label} 的地址不是整数", {}
            if addr < 0 or addr % 4 != 0:
                return False, f"标签 {label} 的地址无效: {addr}", {}

        return True, f"格式正确，共{len(symbols)}个符号", symbols

    except json.JSONDecodeError as e:
        return False, f"JSON解析错误: {e}", {}
    except Exception as e:
        return False, f"读取错误: {e}", {}

def analyze_algorithm(base_name: str, output_dir: pathlib.Path) -> Dict:
    """分析单个算法的所有输出文件"""
    result = {
        'name': base_name,
        'hex_valid': False,
        'lst_valid': False,
        'json_valid': False,
        'word_count': 0,
        'symbols': {},
        'messages': []
    }

    hex_path = output_dir / f"{base_name}.hex"
    lst_path = output_dir / f"{base_name}.lst"
    json_path = output_dir / f"{base_name}.json"

    # 验证hex文件
    if hex_path.exists():
        valid, msg, count = validate_hex_file(hex_path)
        result['hex_valid'] = valid
        result['word_count'] = count
        result['messages'].append(f"HEX: {msg}")
    else:
        result['messages'].append("HEX: 文件不存在")

    # 验证lst文件
    if lst_path.exists():
        valid, msg = validate_listing_file(lst_path)
        result['lst_valid'] = valid
        result['messages'].append(f"LST: {msg}")
    else:
        result['messages'].append("LST: 文件不存在")

    # 验证json文件
    if json_path.exists():
        valid, msg, symbols = validate_symbol_file(json_path)
        result['json_valid'] = valid
        result['symbols'] = symbols
        result['messages'].append(f"JSON: {msg}")
    else:
        result['messages'].append("JSON: 文件不存在")

    return result

def main():
    output_dir = pathlib.Path("build/algorithms")

    if not output_dir.exists():
        print(f"错误: 输出目录不存在: {output_dir}")
        return 1

    print("VSP算法机器码验证")
    print("=" * 70)
    print()

    # 查找所有算法hex文件
    algorithm_files = sorted(output_dir.glob("algorithm_*.hex"))

    if not algorithm_files:
        print("未找到算法机器码文件")
        return 1

    results = []
    for hex_file in algorithm_files:
        base_name = hex_file.stem
        result = analyze_algorithm(base_name, output_dir)
        results.append(result)

    # 打印结果
    all_valid = True
    for result in results:
        status = "✓" if (result['hex_valid'] and result['lst_valid'] and result['json_valid']) else "✗"
        print(f"{status} {result['name']}")
        print(f"  指令数: {result['word_count']}")
        print(f"  符号数: {len(result['symbols'])}")
        if result['symbols']:
            print(f"  标签: {', '.join(result['symbols'].keys())}")
        for msg in result['messages']:
            print(f"  {msg}")
        print()

        if not (result['hex_valid'] and result['lst_valid'] and result['json_valid']):
            all_valid = False

    # 统计总结
    print("=" * 70)
    print(f"总计: {len(results)} 个算法")
    print(f"有效: {sum(1 for r in results if r['hex_valid'])} 个")
    print(f"总指令数: {sum(r['word_count'] for r in results)}")
    print()

    if all_valid:
        print("✓ 所有文件验证通过")
        return 0
    else:
        print("✗ 部分文件验证失败")
        return 1

if __name__ == "__main__":
    sys.exit(main())
