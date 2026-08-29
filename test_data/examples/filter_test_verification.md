# VSP 3x3均值滤波验证草案

## 测试配置
- 输入尺寸: 16x16 = 256 bytes
- 滤波器: 3x3均值滤波
- 边界处理: 零填充（边界像素不处理）

## 预期结果
输入统计:
  - Min: 0
  - Max: 255
  - Mean: 15
  - 非零像素: 16

输出统计:
  - Min: 0
  - Max: 255
  - Mean: 15
  - 非零像素: 36

## 验证检查点
1. 边界像素应为0（未处理）
2. 亮块中心应变模糊（值在0-255之间）
3. 总体亮度保持（均值接近）
4. 非零像素数量增加（模糊扩散效果）

## 验证方法

### 在 SystemVerilog 环境中接入（草案）
```systemverilog
// .hex 每行是一个 32-bit word，不能直接加载到 byte 数组。
logic [31:0] input_words [0:63];
logic [31:0] output_words [0:63];
logic [31:0] reference_words [0:63];
integer errors;

initial begin
  $readmemh("test_data/examples/filter_input.hex", input_words);

  // TODO: 通过仿真环境的 init/peek 接口搬入、运行和取回数据。

  // 加载参考结果
  $readmemh("test_data/examples/filter_reference.hex", reference_words);

  // 对比 32-bit words
  errors = 0;
  for (int i = 0; i < 64; i++) begin
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
result = dumper.load_hex_dump('output.hex', shape=(16, 16))
reference = dumper.load_hex_dump(
    'test_data/examples/filter_reference.hex', shape=(16, 16))

# 对比
diff = [
    abs(a - b)
    for result_row, reference_row in zip(result, reference)
    for a, b in zip(result_row, reference_row)
]
max_error = max(diff)
num_errors = sum(1 for d in diff if d > 0)

print(f"Max error: {max_error}")
print(f"Pixels with errors: {num_errors}")

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
