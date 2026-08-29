#!/usr/bin/env python3
"""VSP测试数据生成器 - 纯Python版本（无外部依赖）

生成用于VSP测试的图像数据，输出为hex格式供SystemVerilog加载。
"""

from pathlib import Path


class SimpleImageGenerator:
    """简单图像生成器（纯Python实现）"""

    @staticmethod
    def checkerboard(height, width, block_size=8):
        """生成棋盘图案"""
        img = []
        for i in range(height):
            row = []
            for j in range(width):
                if ((i // block_size) + (j // block_size)) % 2 == 0:
                    row.append(255)
                else:
                    row.append(0)
            img.append(row)
        return img

    @staticmethod
    def gradient_horizontal(height, width):
        """生成水平渐变"""
        img = []
        for i in range(height):
            row = []
            for j in range(width):
                value = int(255 * j / (width - 1))
                row.append(value)
            img.append(row)
        return img

    @staticmethod
    def gradient_vertical(height, width):
        """生成垂直渐变"""
        img = []
        for i in range(height):
            row = []
            value = int(255 * i / (height - 1))
            for j in range(width):
                row.append(value)
            img.append(row)
        return img

    @staticmethod
    def stripes_vertical(height, width, stripe_width=16):
        """生成垂直条纹"""
        img = []
        for i in range(height):
            row = []
            for j in range(width):
                if (j // stripe_width) % 2 == 0:
                    row.append(255)
                else:
                    row.append(0)
            img.append(row)
        return img

    @staticmethod
    def blocks_4x4(height, width):
        """生成4个不同灰度的块（用于直方图测试）"""
        img = []
        h2, w2 = height // 2, width // 2
        for i in range(height):
            row = []
            for j in range(width):
                if i < h2 and j < w2:
                    row.append(0)      # 左上：黑色
                elif i < h2 and j >= w2:
                    row.append(85)     # 右上：暗灰
                elif i >= h2 and j < w2:
                    row.append(170)    # 左下：亮灰
                else:
                    row.append(255)    # 右下：白色
            img.append(row)
        return img


class SimpleDataDumper:
    """数据转储工具"""

    @staticmethod
    def flatten_image(img):
        """将2D图像展平为1D列表"""
        flat = []
        for row in img:
            flat.extend(row)
        return flat

    @staticmethod
    def save_hex_dump(img, filepath, bytes_per_line=4):
        """保存为hex格式（适合SystemVerilog $readmemh）

        每行包含bytes_per_line个字节，小端序组装
        """
        if bytes_per_line <= 0:
            raise ValueError("bytes_per_line must be positive")

        flat_data = SimpleDataDumper.flatten_image(img)
        if any(not 0 <= byte <= 0xff for byte in flat_data):
            raise ValueError("hex dumps accept only byte values in range 0..255")

        with open(filepath, 'w') as f:
            f.write("// VSP Test Data - Hex Format\n")
            f.write(f"// Size: {len(img)}x{len(img[0])} = {len(flat_data)} bytes\n")
            f.write(f"// Format: {bytes_per_line} bytes per line (little-endian)\n")
            f.write("\n")

            for i in range(0, len(flat_data), bytes_per_line):
                chunk = flat_data[i:i+bytes_per_line]
                # Missing high-address bytes are zero.  Pad the byte sequence
                # before reversing it into the textual little-endian word.
                chunk = chunk + [0] * (bytes_per_line - len(chunk))
                hex_word = ''.join(f'{b:02x}' for b in reversed(chunk))
                f.write(f"{hex_word}\n")

    @staticmethod
    def load_hex_dump(filepath, shape=None, byte_count=None):
        """Load a word-oriented little-endian hex dump.

        Both ``//`` and ``#`` comments are accepted, including comments after
        a data word.  When the final word was padded by :meth:`save_hex_dump`,
        pass either ``shape=(height, width)`` or ``byte_count`` to discard the
        padding bytes deterministically.
        """
        if shape is not None:
            if len(shape) != 2 or shape[0] < 0 or shape[1] < 0:
                raise ValueError("shape must be a non-negative (height, width) pair")
            shape_bytes = shape[0] * shape[1]
            if byte_count is not None and byte_count != shape_bytes:
                raise ValueError("shape and byte_count describe different sizes")
            byte_count = shape_bytes
        elif byte_count is not None and byte_count < 0:
            raise ValueError("byte_count must be non-negative")

        data = []
        with open(filepath, 'r') as f:
            for line_number, raw_line in enumerate(f, start=1):
                line = raw_line.split('//', 1)[0].split('#', 1)[0].strip()
                if not line:
                    continue
                if len(line) % 2:
                    raise ValueError(
                        f"{filepath}:{line_number}: hex word must contain whole bytes")
                try:
                    word = int(line, 16)
                except ValueError as exc:
                    raise ValueError(
                        f"{filepath}:{line_number}: invalid hex word {line!r}") from exc

                for _ in range(len(line) // 2):
                    data.append(word & 0xff)
                    word >>= 8

        if byte_count is not None:
            if len(data) < byte_count:
                raise ValueError(
                    f"hex dump contains {len(data)} bytes, expected {byte_count}")
            data = data[:byte_count]

        if shape is None:
            return data
        height, width = shape
        return [data[row * width:(row + 1) * width] for row in range(height)]

    @staticmethod
    def save_binary_dump(img, filepath):
        """保存为二进制格式"""
        flat_data = SimpleDataDumper.flatten_image(img)
        with open(filepath, 'wb') as f:
            f.write(bytes(flat_data))

    @staticmethod
    def save_pgm(img, filepath):
        """保存为PGM格式（ASCII，便于查看）"""
        height = len(img)
        width = len(img[0])

        with open(filepath, 'w') as f:
            f.write(f"P2\n")
            f.write(f"# VSP Test Image\n")
            f.write(f"{width} {height}\n")
            f.write(f"255\n")

            for row in img:
                line = ' '.join(str(pixel) for pixel in row)
                f.write(f"{line}\n")

    @staticmethod
    def save_c_array(img, filepath, array_name="test_image"):
        """保存为C数组格式"""
        flat_data = SimpleDataDumper.flatten_image(img)
        height = len(img)
        width = len(img[0])

        with open(filepath, 'w') as f:
            f.write(f"// VSP Test Image: {height}x{width}\n")
            f.write(f"const unsigned char {array_name}[{len(flat_data)}] = {{\n")

            for i in range(0, len(flat_data), 16):
                chunk = flat_data[i:i+16]
                line = '    ' + ', '.join(f'0x{b:02x}' for b in chunk)
                if i + 16 < len(flat_data):
                    line += ','
                f.write(line + '\n')

            f.write("};\n")


def create_test_dataset(output_dir):
    """创建测试数据集"""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    gen = SimpleImageGenerator()
    dumper = SimpleDataDumper()

    # 标准测试尺寸（适合4组SIMD4 = 16 lanes）
    h, w = 64, 64

    print(f"Generating test images ({h}x{w})...")

    examples = {
        'checkerboard': gen.checkerboard(h, w, 8),
        'gradient_h': gen.gradient_horizontal(h, w),
        'gradient_v': gen.gradient_vertical(h, w),
        'stripes_v': gen.stripes_vertical(h, w, 8),
        'blocks_4x4': gen.blocks_4x4(h, w),
    }

    for name, img in examples.items():
        print(f"  Creating {name}...")

        # 保存hex格式（用于SV加载）
        dumper.save_hex_dump(img, output_dir / f'{name}.hex')

        # 保存PGM格式（用于查看）
        dumper.save_pgm(img, output_dir / f'{name}.pgm')

        # 保存二进制格式
        dumper.save_binary_dump(img, output_dir / f'{name}.bin')

        # 保存C数组格式
        dumper.save_c_array(img, output_dir / f'{name}.h', f'{name}_data')

    # 创建元数据文件
    with open(output_dir / 'README.txt', 'w') as f:
        f.write("VSP Test Dataset\n")
        f.write("=" * 50 + "\n\n")
        f.write(f"Image dimensions: {h} x {w} pixels\n")
        f.write(f"Format: 8-bit grayscale\n")
        f.write(f"Total size per image: {h * w} bytes\n\n")
        f.write("Files:\n")
        for name in examples.keys():
            f.write(
                f"  {name}.hex  - 32-bit words for $readmemh "
                "(4 address-ordered bytes per little-endian word)\n")
            f.write(f"  {name}.pgm  - PGM format for viewing\n")
            f.write(f"  {name}.bin  - Raw binary\n")
            f.write(f"  {name}.h    - C array format\n")

        f.write("\n")
        f.write("Memory Layout (for VSP):\n")
        f.write(f"  Base address: 0x1000 (configurable)\n")
        f.write(f"  Stride: {w} bytes (row-major)\n")
        f.write(f"  Each row: {w} consecutive bytes\n")
        f.write(f"  VRF access: 16 bytes per load (1 row spans {w//16} VRF loads)\n")

    print(f"\nCreated {len(examples)} test images in: {output_dir}")
    print(f"  Formats: .hex (SV), .pgm (viewing), .bin (binary), .h (C array)")


def compute_histogram_4bin(img):
    """计算4-bin直方图"""
    bins = [0, 0, 0, 0]  # [0,64), [64,128), [128,192), [192,256)

    for row in img:
        for pixel in row:
            if pixel < 64:
                bins[0] += 1
            elif pixel < 128:
                bins[1] += 1
            elif pixel < 192:
                bins[2] += 1
            else:
                bins[3] += 1

    return bins


def create_histogram_test_data(output_dir):
    """创建直方图测试数据"""
    output_dir = Path(output_dir)

    gen = SimpleImageGenerator()
    dumper = SimpleDataDumper()

    # 生成具有已知分布的图像
    img = gen.blocks_4x4(64, 64)

    # 计算预期直方图
    hist = compute_histogram_4bin(img)

    # 保存图像
    dumper.save_hex_dump(img, output_dir / 'histogram_test.hex')
    dumper.save_pgm(img, output_dir / 'histogram_test.pgm')

    # 保存预期结果
    with open(output_dir / 'histogram_expected.txt', 'w') as f:
        f.write("Expected 4-bin histogram for histogram_test image\n")
        f.write("Bins: [0,64), [64,128), [128,192), [192,256)\n\n")
        f.write(f"Bin 0 [  0- 63]: {hist[0]:5d} pixels\n")
        f.write(f"Bin 1 [ 64-127]: {hist[1]:5d} pixels\n")
        f.write(f"Bin 2 [128-191]: {hist[2]:5d} pixels\n")
        f.write(f"Bin 3 [192-255]: {hist[3]:5d} pixels\n")
        f.write(f"\nTotal: {sum(hist)} pixels\n")

    print(f"\nHistogram test data created:")
    print(f"  Expected distribution: {hist}")


if __name__ == '__main__':
    # 创建测试数据集
    output_dir = Path(__file__).parent.parent / 'test_data'
    create_test_dataset(output_dir)
    create_histogram_test_data(output_dir)

    print("\n" + "=" * 60)
    print("Test data generation complete!")
    print("=" * 60)
    print("\nUsage in SystemVerilog (one 32-bit word per input line):")
    print('  logic [31:0] fixture_words [0:1023];')
    print('  initial begin')
    print('    $readmemh("test_data/checkerboard.hex", fixture_words);')
    print('  end')
    print("\nTo view images:")
    print('  Use any PGM viewer, or convert to PNG:')
    print('    convert test_data/checkerboard.pgm checkerboard.png')
