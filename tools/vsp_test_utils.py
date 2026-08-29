#!/usr/bin/env python3
"""VSP测试工具集 - 数据生成、可视化和汇编辅助

提供用于VSP项目的测试数据生成、图像可视化、汇编生成等功能。
这是可选的宿主侧工具，需要 NumPy：``python3 -m pip install numpy``。
"""

try:
    import numpy as np
except ModuleNotFoundError as exc:
    raise ModuleNotFoundError(
        "tools/vsp_test_utils.py is an optional host utility and requires "
        "NumPy; install it with: python3 -m pip install numpy") from exc
from typing import Optional, Tuple, List
import json
from pathlib import Path


class ImageGenerator:
    """生成测试图像数据"""

    @staticmethod
    def checkerboard(height: int, width: int, block_size: int = 8) -> np.ndarray:
        """生成棋盘图案

        Args:
            height: 图像高度
            width: 图像宽度
            block_size: 棋盘格子大小

        Returns:
            8-bit灰度图像 (height, width)
        """
        img = np.zeros((height, width), dtype=np.uint8)
        for i in range(0, height, block_size):
            for j in range(0, width, block_size):
                if ((i // block_size) + (j // block_size)) % 2 == 0:
                    img[i:i+block_size, j:j+block_size] = 255
        return img

    @staticmethod
    def gradient_horizontal(height: int, width: int) -> np.ndarray:
        """生成水平渐变图"""
        img = np.zeros((height, width), dtype=np.uint8)
        for j in range(width):
            img[:, j] = int(255 * j / (width - 1))
        return img

    @staticmethod
    def gradient_vertical(height: int, width: int) -> np.ndarray:
        """生成垂直渐变图"""
        img = np.zeros((height, width), dtype=np.uint8)
        for i in range(height):
            img[i, :] = int(255 * i / (height - 1))
        return img

    @staticmethod
    def stripes(height: int, width: int, stripe_width: int = 16,
                vertical: bool = True) -> np.ndarray:
        """生成条纹图案"""
        img = np.zeros((height, width), dtype=np.uint8)
        if vertical:
            for j in range(width):
                if (j // stripe_width) % 2 == 0:
                    img[:, j] = 255
        else:
            for i in range(height):
                if (i // stripe_width) % 2 == 0:
                    img[i, :] = 255
        return img

    @staticmethod
    def random_noise(height: int, width: int, seed: int = 42) -> np.ndarray:
        """生成随机噪声"""
        np.random.seed(seed)
        return np.random.randint(0, 256, (height, width), dtype=np.uint8)

    @staticmethod
    def blocks_pattern(height: int, width: int, block_size: int = 32) -> np.ndarray:
        """生成不同灰度的块状图案（用于测试块处理）"""
        img = np.zeros((height, width), dtype=np.uint8)
        num_blocks_h = height // block_size
        num_blocks_w = width // block_size

        for i in range(num_blocks_h):
            for j in range(num_blocks_w):
                intensity = int(255 * ((i * num_blocks_w + j) /
                                       (num_blocks_h * num_blocks_w)))
                img[i*block_size:(i+1)*block_size,
                    j*block_size:(j+1)*block_size] = intensity
        return img


class DataDumper:
    """数据转储工具 - 用于保存和加载仿真数据"""

    @staticmethod
    def save_hex_dump(data: np.ndarray, filepath: Path,
                     bytes_per_line: int = 4) -> None:
        """保存为hex格式（适合SystemVerilog $readmemh）

        Args:
            data: 要保存的数据（1D或2D uint8数组）
            filepath: 输出文件路径
            bytes_per_line: 每行字节数（对应内存beat宽度）
        """
        if bytes_per_line <= 0:
            raise ValueError("bytes_per_line must be positive")

        flat_data = data.flatten()

        with open(filepath, 'w') as f:
            for i in range(0, len(flat_data), bytes_per_line):
                chunk = flat_data[i:i+bytes_per_line].tolist()
                chunk.extend([0] * (bytes_per_line - len(chunk)))
                hex_word = ''.join(f'{b:02x}' for b in reversed(chunk))
                f.write(f"{hex_word}\n")

    @staticmethod
    def save_binary_dump(data: np.ndarray, filepath: Path) -> None:
        """保存为二进制格式"""
        with open(filepath, 'wb') as f:
            data.flatten().tofile(f)

    @staticmethod
    def load_hex_dump(filepath: Path, shape: Optional[Tuple] = None,
                      byte_count: Optional[int] = None) -> np.ndarray:
        """从 little-endian word hex 文件加载数据。

        支持 ``//`` 和 ``#`` 整行或行尾注释。对非整 word 的数据，
        传入 ``shape`` 或 ``byte_count`` 以去掉最后一个 word 的补零。
        """
        if shape is not None:
            if len(shape) == 0 or any(dimension < 0 for dimension in shape):
                raise ValueError("shape dimensions must be non-negative")
            shape_bytes = int(np.prod(shape))
            if byte_count is not None and byte_count != shape_bytes:
                raise ValueError("shape and byte_count describe different sizes")
            byte_count = shape_bytes
        elif byte_count is not None and byte_count < 0:
            raise ValueError("byte_count must be non-negative")

        data = []
        with open(filepath, 'r') as f:
            for line_number, raw_line in enumerate(f, start=1):
                line = raw_line.split('//', 1)[0].split('#', 1)[0].strip()
                if line:
                    if len(line) % 2:
                        raise ValueError(
                            f"{filepath}:{line_number}: hex word must contain whole bytes")
                    word = int(line, 16)
                    for _ in range(len(line) // 2):
                        data.append(word & 0xFF)
                        word >>= 8

        if byte_count is not None:
            if len(data) < byte_count:
                raise ValueError(
                    f"hex dump contains {len(data)} bytes, expected {byte_count}")
            data = data[:byte_count]

        arr = np.array(data, dtype=np.uint8)
        if shape is not None:
            arr = arr.reshape(shape)
        return arr

    @staticmethod
    def save_pgm(image: np.ndarray, filepath: Path) -> None:
        """保存为PGM格式（便于人工查看）"""
        height, width = image.shape
        with open(filepath, 'wb') as f:
            f.write(f'P5\n{width} {height}\n255\n'.encode())
            image.tobytes('C')  # C-order
            f.write(image.tobytes())

    @staticmethod
    def load_pgm(filepath: Path) -> np.ndarray:
        """从PGM文件加载"""
        with open(filepath, 'rb') as f:
            magic = f.readline().decode().strip()
            assert magic == 'P5', "Only P5 PGM supported"

            # Skip comments
            line = f.readline().decode().strip()
            while line.startswith('#'):
                line = f.readline().decode().strip()

            width, height = map(int, line.split())
            maxval = int(f.readline().decode().strip())
            assert maxval == 255

            data = np.frombuffer(f.read(), dtype=np.uint8)
            return data.reshape((height, width))


class MemoryLayoutHelper:
    """内存布局辅助 - 用于生成VSP内存访问模式"""

    @staticmethod
    def image_to_memory_layout(image: np.ndarray,
                              base_addr: int = 0x1000) -> dict:
        """将图像转换为内存布局信息

        Returns:
            包含地址映射和元数据的字典
        """
        height, width = image.shape
        return {
            'base_addr': base_addr,
            'width': width,
            'height': height,
            'stride': width,  # 行跨度（字节）
            'total_bytes': height * width,
            # Keep metadata JSON-serializable; callers needing ndarray
            # semantics can reconstruct it using width/height/dtype.
            'data': image.flatten().tolist()
        }

    @staticmethod
    def generate_vrf_layout(num_rows: int = 16, row_bytes: int = 16) -> dict:
        """生成VRF布局信息"""
        return {
            'num_rows': num_rows,
            'row_bytes': row_bytes,
            'total_capacity': num_rows * row_bytes,
            'row_addresses': list(range(num_rows))
        }


class HistogramHelper:
    """直方图和scatter类操作的辅助工具"""

    @staticmethod
    def compute_histogram(image: np.ndarray, bins: int = 256) -> np.ndarray:
        """计算图像直方图"""
        hist, _ = np.histogram(image.flatten(), bins=bins, range=(0, 256))
        return hist.astype(np.uint32)

    @staticmethod
    def generate_histogram_test_data(height: int = 64, width: int = 64) -> dict:
        """生成用于测试直方图的数据

        Returns:
            包含输入图像和预期直方图的字典
        """
        # 生成具有已知分布的图像
        img = np.zeros((height, width), dtype=np.uint8)

        # 四个区域不同灰度
        h2, w2 = height // 2, width // 2
        img[:h2, :w2] = 0      # 左上：黑色
        img[:h2, w2:] = 85     # 右上：暗灰
        img[h2:, :w2] = 170    # 左下：亮灰
        img[h2:, w2:] = 255    # 右下：白色

        hist = HistogramHelper.compute_histogram(img)

        return {
            'image': img,
            'histogram': hist,
            'expected_peaks': [0, 85, 170, 255],
            'expected_counts': [h2*w2, h2*w2, h2*w2, h2*w2]
        }

    @staticmethod
    def histogram_to_bar_data(hist: np.ndarray,
                             normalize: bool = True) -> np.ndarray:
        """将直方图转换为适合可视化的条形图数据

        Args:
            hist: 直方图数据
            normalize: 是否归一化到0-255范围

        Returns:
            归一化后的条形高度
        """
        if normalize and hist.max() > 0:
            return (hist * 255 // hist.max()).astype(np.uint8)
        return hist.astype(np.uint8)


def create_example_dataset(output_dir: Path):
    """创建一套完整的示例数据集"""
    output_dir.mkdir(parents=True, exist_ok=True)

    dumper = DataDumper()
    gen = ImageGenerator()

    # 标准测试尺寸（适合4组SIMD4 = 16 lanes）
    h, w = 64, 64

    examples = {
        'checkerboard': gen.checkerboard(h, w, 8),
        'gradient_h': gen.gradient_horizontal(h, w),
        'gradient_v': gen.gradient_vertical(h, w),
        'stripes_v': gen.stripes(h, w, 8, vertical=True),
        'stripes_h': gen.stripes(h, w, 8, vertical=False),
        'blocks': gen.blocks_pattern(h, w, 16),
        'noise': gen.random_noise(h, w),
    }

    for name, img in examples.items():
        # 保存hex格式（用于SV加载）
        dumper.save_hex_dump(img, output_dir / f'{name}.hex')
        # 保存PGM格式（用于人工查看）
        dumper.save_pgm(img, output_dir / f'{name}.pgm')
        # 保存二进制格式
        dumper.save_binary_dump(img, output_dir / f'{name}.bin')

    # 保存元数据
    metadata = {
        'image_dimensions': {'height': h, 'width': w},
        'format': 'uint8 grayscale',
        'examples': list(examples.keys()),
        'memory_layout': MemoryLayoutHelper.image_to_memory_layout(
            examples['checkerboard'], base_addr=0x1000)
    }

    with open(output_dir / 'metadata.json', 'w') as f:
        json.dump(metadata, f, indent=2)

    print(f"Created {len(examples)} example images in {output_dir}")
    print(f"Formats: .hex (SV), .pgm (visual), .bin (binary)")


if __name__ == '__main__':
    # 创建示例数据集
    output_dir = Path(__file__).parent.parent / 'test_data'
    create_example_dataset(output_dir)

    # 生成直方图测试数据
    hist_data = HistogramHelper.generate_histogram_test_data()
    dumper = DataDumper()
    dumper.save_hex_dump(hist_data['image'],
                        output_dir / 'histogram_test.hex')
    dumper.save_pgm(hist_data['image'],
                   output_dir / 'histogram_test.pgm')

    # 保存预期直方图
    np.save(output_dir / 'histogram_expected.npy', hist_data['histogram'])

    print(f"\nHistogram test data created")
    print(f"Expected peaks at: {hist_data['expected_peaks']}")
