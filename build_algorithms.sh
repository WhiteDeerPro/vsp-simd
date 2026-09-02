#!/bin/bash
# VSP算法汇编自动构建脚本
# 用途：批量汇编所有算法程序并生成机器码文件用于VCS仿真

set -e  # 遇到错误立即退出

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置
TOOLS_DIR="tools"
EXAMPLES_DIR="examples/uword"
OUTPUT_DIR="build/algorithms"
ASSEMBLER="$TOOLS_DIR/vsp_uword_asm.py"

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}VSP算法汇编构建系统${NC}"
echo "================================"
echo ""

# 检查汇编器是否存在
if [ ! -f "$ASSEMBLER" ]; then
    echo -e "${RED}错误: 找不到汇编器 $ASSEMBLER${NC}"
    exit 1
fi

# 统计变量
total_count=0
success_count=0
fail_count=0

# 汇编所有算法文件
for asm_file in "$EXAMPLES_DIR"/algorithm_*.uasm; do
    if [ -f "$asm_file" ]; then
        total_count=$((total_count + 1))

        # 提取文件名（不含路径和扩展名）
        basename=$(basename "$asm_file" .uasm)

        # 定义输出文件路径
        hex_file="$OUTPUT_DIR/${basename}.hex"
        lst_file="$OUTPUT_DIR/${basename}.lst"
        json_file="$OUTPUT_DIR/${basename}.json"

        echo -ne "汇编 ${YELLOW}${basename}${NC} ... "

        # 执行汇编
        if python3 "$ASSEMBLER" "$asm_file" \
            -o "$hex_file" \
            --listing "$lst_file" \
            --symbols "$json_file"; then
            # 验证输出文件是否生成
            if [ -f "$hex_file" ] && [ -f "$lst_file" ] && [ -f "$json_file" ]; then
                # 统计指令数
                instr_count=$(wc -l < "$hex_file")
                echo -e "${GREEN}成功${NC} ($instr_count words)"
                success_count=$((success_count + 1))
            else
                echo -e "${RED}失败 (输出文件缺失)${NC}"
                fail_count=$((fail_count + 1))
            fi
        else
            echo -e "${RED}失败${NC}"
            fail_count=$((fail_count + 1))
        fi
    fi
done

echo ""
echo "================================"
echo "构建完成"
echo "  总计: $total_count"
echo -e "  ${GREEN}成功: $success_count${NC}"
if [ $fail_count -gt 0 ]; then
    echo -e "  ${RED}失败: $fail_count${NC}"
fi
echo ""

# 生成摘要报告
echo "生成的机器码文件:"
echo ""
printf "%-40s %10s %10s\n" "文件名" "大小(字节)" "指令数"
echo "----------------------------------------------------------------"
for hex_file in "$OUTPUT_DIR"/algorithm_*.hex; do
    if [ -f "$hex_file" ]; then
        basename=$(basename "$hex_file")
        size=$(stat -f%z "$hex_file" 2>/dev/null || stat -c%s "$hex_file" 2>/dev/null)
        word_count=$(wc -l < "$hex_file")
        printf "%-40s %10d %10d\n" "$basename" "$size" "$word_count"
    fi
done

echo ""
echo "输出目录: $OUTPUT_DIR"
echo "README文档: $OUTPUT_DIR/README.md"
echo ""

# 验证机器码格式
echo "验证机器码格式..."
format_ok=true
for hex_file in "$OUTPUT_DIR"/algorithm_*.hex; do
    if [ -f "$hex_file" ]; then
        # 检查每行是否是8位十六进制数
        if ! grep -E '^[0-9a-f]{8}$' "$hex_file" > /dev/null; then
            echo -e "${RED}警告: $hex_file 格式可能不正确${NC}"
            format_ok=false
        fi
    fi
done

if $format_ok; then
    echo -e "${GREEN}所有机器码文件格式正确${NC}"
fi

echo ""
if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}✓ 所有算法汇编成功！${NC}"
    exit 0
else
    echo -e "${RED}✗ 有 $fail_count 个算法汇编失败${NC}"
    exit 1
fi
