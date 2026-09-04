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
    "math_bfp8_static_scale"
)

# math_fp16_add.uasm remains a conceptual sketch.  It is intentionally absent
# from MATH_SOURCES because successful assembly is not functional FP16 proof.

mkdir -p build/algorithms

# Do not leave an old successfully-assembled sketch looking like a verified
# FP16/BF16 deliverable after the validation set has moved to static BFP8.
for stale_fp16_artifact in \
    build/algorithms/math_fp16_add.hex \
    build/algorithms/math_fp16_add.lst \
    build/algorithms/math_fp16_add.json; do
    if [ -e "$stale_fp16_artifact" ]; then
        rm -- "$stale_fp16_artifact"
    fi
done

success=0
assembly_failed=0
numeric_failed=0
BUILT_SOURCES=()

for name in "${MATH_SOURCES[@]}"; do
    src="examples/uword/${name}.uasm"

    if [ ! -f "$src" ]; then
        echo "⚠ 源文件不存在: $src"
        assembly_failed=$((assembly_failed + 1))
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
        BUILT_SOURCES+=("$name")
    else
        echo "✗ 失败"
        assembly_failed=$((assembly_failed + 1))
    fi
done

echo ""
# 生成摘要
echo "本次成功汇编的数学库模块:"
echo ""
printf "%-30s %10s %15s\n" "模块" "指令数" "功能"
echo "----------------------------------------------------------------"

for name in "${BUILT_SOURCES[@]}"; do
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
            math_bfp8_static_scale) func="静态BFP8缩放" ;;
            *)                     func="未知" ;;
        esac

        printf "%-30s %10d %15s\n" "$name" "$words" "$func"
    fi
done

echo ""
echo "运行静态BFP8纯数值测试 ..."
if python3 sim/vsp_bfp_tb.py; then
    echo "✓ 静态BFP8数值测试通过"
else
    echo "✗ 静态BFP8数值测试失败"
    numeric_failed=1
fi

echo ""
echo "运行M8E8精确数值oracle测试 ..."
if python3 sim/vsp_m8e8_tb.py; then
    echo "✓ M8E8数值oracle测试通过"
else
    echo "✗ M8E8数值oracle测试失败"
    numeric_failed=1
fi

echo ""
echo "概念示例（未验证、未纳入构建）: math_fp16_add.uasm"
echo "其陈旧build产物已清理，防止被误认为已验证BF16。"

echo ""
echo "===================="
echo "汇编模块总计: ${#MATH_SOURCES[@]}"
echo "汇编成功: $success"
echo "汇编失败或缺失: $assembly_failed"
if [ "$numeric_failed" -eq 0 ]; then
    echo "BFP8/M8E8数值测试: 通过"
else
    echo "BFP8/M8E8数值测试: 失败"
fi

echo ""
echo "输出目录: build/algorithms/"
echo "文档: docs/delivery/MATH_LIBRARY_REPORT.md"

exit $((assembly_failed + numeric_failed))
