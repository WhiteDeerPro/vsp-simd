#!/bin/bash
# 数学库构建和验证脚本

set -e

echo "VSP数学工具库构建"
echo "===================="
echo ""

# 数学库源文件列表
MATH_SOURCES=(
    "math_add16_fixed"
    "math_sub16_fixed"
    "math_compare16"
    "math_div"
    "math_mul16_shiftadd"
    "math_mul16_booth"
    "math_mul8_table"
    "math_reciprocal_lut"
    "math_fp16_add"
)

mkdir -p build/algorithms

success=0
failed=0

for name in "${MATH_SOURCES[@]}"; do
    src="examples/uword/${name}.uasm"

    if [ ! -f "$src" ]; then
        echo "⚠ 源文件不存在: $src"
        continue
    fi

    echo -n "汇编 $name ... "

    if python3 tools/vsp_uword_asm.py "$src" \
        -o "build/algorithms/${name}.hex" \
        --listing "build/algorithms/${name}.lst" \
        --symbols "build/algorithms/${name}.json"; then
        words=$(wc -l < "build/algorithms/${name}.hex")
        echo "✓ 成功 ($words words)"
        success=$((success + 1))
    else
        echo "✗ 失败"
        failed=$((failed + 1))
    fi
done

echo ""
echo "===================="
echo "总计: $((success + failed))"
echo "成功: $success"
echo "失败: $failed"
echo ""

# 生成摘要
echo "数学库模块摘要:"
echo ""
printf "%-30s %10s %15s\n" "模块" "指令数" "功能"
echo "----------------------------------------------------------------"

for name in "${MATH_SOURCES[@]}"; do
    hex="build/algorithms/${name}.hex"
    if [ -f "$hex" ]; then
        words=$(wc -l < "$hex")

        case $name in
            math_add16_fixed)      func="16位加法" ;;
            math_sub16_fixed)      func="16位减法" ;;
            math_compare16)        func="16位比较" ;;
            math_div)              func="2^n除法" ;;
            math_mul16_shiftadd)   func="移位加乘法" ;;
            math_mul16_booth)      func="Booth乘法" ;;
            math_mul8_table)       func="查表乘法" ;;
            math_reciprocal_lut)   func="倒数查表" ;;
            math_fp16_add)         func="FP16加法" ;;
            *)                     func="未知" ;;
        esac

        printf "%-30s %10d %15s\n" "$name" "$words" "$func"
    fi
done

echo ""
echo "输出目录: build/algorithms/"
echo "文档: MATH_LIBRARY_REPORT.md"

exit $failed
