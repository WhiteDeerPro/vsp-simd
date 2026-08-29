#!/usr/bin/env python3
"""VSP仿真结果可视化工具

用于可视化SystemVerilog仿真输出的图像数据、直方图等。
这是可选宿主工具：``python3 -m pip install numpy matplotlib``。
"""

try:
    import numpy as np
    import matplotlib.pyplot as plt
except ModuleNotFoundError as exc:
    raise ModuleNotFoundError(
        "tools/vsp_visualizer.py is optional and requires NumPy and "
        "Matplotlib; install them with: python3 -m pip install numpy matplotlib"
    ) from exc
from pathlib import Path
from typing import Optional, List, Tuple
import json


class SimResultVisualizer:
    """仿真结果可视化器"""

    @staticmethod
    def plot_image_comparison(original: np.ndarray,
                             processed: np.ndarray,
                             title: str = "Image Comparison",
                             save_path: Optional[Path] = None):
        """对比显示原始图像和处理后图像"""
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))

        axes[0].imshow(original, cmap='gray', vmin=0, vmax=255)
        axes[0].set_title('Original')
        axes[0].axis('off')

        axes[1].imshow(processed, cmap='gray', vmin=0, vmax=255)
        axes[1].set_title('Processed')
        axes[1].axis('off')

        fig.suptitle(title)
        plt.tight_layout()

        if save_path:
            plt.savefig(save_path, dpi=150, bbox_inches='tight')
            print(f"Saved comparison to {save_path}")
        else:
            plt.show()

        plt.close()

    @staticmethod
    def plot_difference(img1: np.ndarray, img2: np.ndarray,
                       title: str = "Difference",
                       save_path: Optional[Path] = None):
        """显示两幅图像的差异"""
        diff = img1.astype(np.int16) - img2.astype(np.int16)
        abs_diff = np.abs(diff)

        fig, axes = plt.subplots(1, 3, figsize=(15, 4))

        axes[0].imshow(diff, cmap='RdBu_r', vmin=-255, vmax=255)
        axes[0].set_title('Signed Difference')
        axes[0].axis('off')
        plt.colorbar(axes[0].images[0], ax=axes[0])

        axes[1].imshow(abs_diff, cmap='hot', vmin=0, vmax=255)
        axes[1].set_title('Absolute Difference')
        axes[1].axis('off')
        plt.colorbar(axes[1].images[0], ax=axes[1])

        # 统计信息
        stats_text = f"Max abs diff: {abs_diff.max()}\n"
        stats_text += f"Mean abs diff: {abs_diff.mean():.2f}\n"
        stats_text += f"Num different: {(abs_diff > 0).sum()}\n"
        stats_text += f"Total pixels: {abs_diff.size}"

        axes[2].text(0.1, 0.5, stats_text, fontsize=12,
                    verticalalignment='center', family='monospace')
        axes[2].set_title('Statistics')
        axes[2].axis('off')

        fig.suptitle(title)
        plt.tight_layout()

        if save_path:
            plt.savefig(save_path, dpi=150, bbox_inches='tight')
        else:
            plt.show()

        plt.close()

    @staticmethod
    def plot_histogram(histogram: np.ndarray,
                      title: str = "Histogram",
                      save_path: Optional[Path] = None):
        """绘制直方图"""
        fig, ax = plt.subplots(figsize=(12, 6))

        bins = np.arange(len(histogram))
        ax.bar(bins, histogram, width=1.0, edgecolor='none')
        ax.set_xlabel('Pixel Value')
        ax.set_ylabel('Count')
        ax.set_title(title)
        ax.grid(True, alpha=0.3)

        if save_path:
            plt.savefig(save_path, dpi=150, bbox_inches='tight')
        else:
            plt.show()

        plt.close()

    @staticmethod
    def plot_histogram_comparison(hist1: np.ndarray, hist2: np.ndarray,
                                 labels: Tuple[str, str] = ("Expected", "Actual"),
                                 title: str = "Histogram Comparison",
                                 save_path: Optional[Path] = None):
        """对比两个直方图"""
        fig, axes = plt.subplots(2, 1, figsize=(12, 8))

        bins = np.arange(len(hist1))

        # 第一个直方图
        axes[0].bar(bins, hist1, width=1.0, alpha=0.7, label=labels[0])
        axes[0].set_ylabel('Count')
        axes[0].set_title(labels[0])
        axes[0].grid(True, alpha=0.3)
        axes[0].legend()

        # 第二个直方图（叠加差异）
        axes[1].bar(bins, hist2, width=1.0, alpha=0.7, label=labels[1], color='orange')
        axes[1].bar(bins, hist1, width=1.0, alpha=0.5, label=labels[0], color='blue')
        axes[1].set_xlabel('Pixel Value')
        axes[1].set_ylabel('Count')
        axes[1].set_title(f'{labels[1]} (with {labels[0]} overlay)')
        axes[1].grid(True, alpha=0.3)
        axes[1].legend()

        fig.suptitle(title)
        plt.tight_layout()

        if save_path:
            plt.savefig(save_path, dpi=150, bbox_inches='tight')
        else:
            plt.show()

        plt.close()

    @staticmethod
    def create_histogram_bar_image(histogram: np.ndarray,
                                   bar_width: int = 2,
                                   max_height: int = 100) -> np.ndarray:
        """将直方图转换为条形图图像（可用于进一步处理）

        Args:
            histogram: 直方图数据
            bar_width: 每个条的宽度（像素）
            max_height: 图像高度（像素）

        Returns:
            条形图图像 (max_height, bins*bar_width)
        """
        bins = len(histogram)
        width = bins * bar_width

        # 归一化到图像高度
        if histogram.max() > 0:
            normalized = (histogram * max_height / histogram.max()).astype(np.int32)
        else:
            normalized = np.zeros_like(histogram, dtype=np.int32)

        # 创建图像（上下翻转，底部为0）
        img = np.zeros((max_height, width), dtype=np.uint8)

        for i, height in enumerate(normalized):
            x_start = i * bar_width
            x_end = x_start + bar_width
            if height > 0:
                img[-height:, x_start:x_end] = 255

        return img

    @staticmethod
    def plot_multi_image_grid(images: List[np.ndarray],
                             titles: List[str],
                             rows: int = 2,
                             cols: int = 4,
                             figsize: Tuple[int, int] = (16, 8),
                             save_path: Optional[Path] = None):
        """在网格中显示多幅图像"""
        fig, axes = plt.subplots(rows, cols, figsize=figsize)
        axes = axes.flatten()

        for idx, (img, title) in enumerate(zip(images, titles)):
            if idx < len(axes):
                axes[idx].imshow(img, cmap='gray', vmin=0, vmax=255)
                axes[idx].set_title(title)
                axes[idx].axis('off')

        # 隐藏多余的子图
        for idx in range(len(images), len(axes)):
            axes[idx].axis('off')

        plt.tight_layout()

        if save_path:
            plt.savefig(save_path, dpi=150, bbox_inches='tight')
        else:
            plt.show()

        plt.close()


class VCDTraceAnalyzer:
    """VCD波形分析工具（概念性，需要外部VCD解析库）"""

    @staticmethod
    def analyze_memory_transactions(vcd_file: Path) -> dict:
        """分析内存事务（需要实现）"""
        # 这里需要VCD解析库如pyvcd
        return {
            'note': 'VCD parsing requires external library like pyvcd',
            'metrics': {
                'total_loads': 0,
                'total_stores': 0,
                'memory_bandwidth': 0,
            }
        }


class PerformanceMetrics:
    """性能指标计算"""

    @staticmethod
    def compute_image_quality_metrics(original: np.ndarray,
                                     processed: np.ndarray) -> dict:
        """计算图像质量指标"""
        # MSE (Mean Squared Error)
        mse = np.mean((original.astype(np.float32) -
                      processed.astype(np.float32)) ** 2)

        # PSNR (Peak Signal-to-Noise Ratio)
        if mse > 0:
            psnr = 10 * np.log10(255.0 ** 2 / mse)
        else:
            psnr = float('inf')

        # MAE (Mean Absolute Error)
        mae = np.mean(np.abs(original.astype(np.float32) -
                            processed.astype(np.float32)))

        return {
            'mse': float(mse),
            'psnr': float(psnr),
            'mae': float(mae),
            'max_error': float(np.max(np.abs(original.astype(np.int16) -
                                             processed.astype(np.int16)))),
        }

    @staticmethod
    def report_metrics(metrics: dict, filepath: Optional[Path] = None):
        """输出性能指标报告"""
        report = "=== Image Quality Metrics ===\n"
        report += f"MSE:        {metrics['mse']:.4f}\n"
        report += f"PSNR:       {metrics['psnr']:.2f} dB\n"
        report += f"MAE:        {metrics['mae']:.4f}\n"
        report += f"Max Error:  {metrics['max_error']:.0f}\n"

        if filepath:
            with open(filepath, 'w') as f:
                f.write(report)
        else:
            print(report)

        return report


def demo_visualization():
    """演示可视化功能"""
    from vsp_test_utils import ImageGenerator, DataDumper

    # 创建测试数据
    gen = ImageGenerator()
    original = gen.checkerboard(64, 64, 8)

    # 模拟处理结果（添加噪声）
    np.random.seed(42)
    noise = np.random.randint(-10, 10, original.shape, dtype=np.int16)
    processed = np.clip(original.astype(np.int16) + noise, 0, 255).astype(np.uint8)

    # 可视化
    vis = SimResultVisualizer()

    output_dir = Path(__file__).parent.parent / 'test_data' / 'visualizations'
    output_dir.mkdir(parents=True, exist_ok=True)

    # 对比图
    vis.plot_image_comparison(
        original, processed,
        title="Checkerboard Processing Test",
        save_path=output_dir / 'comparison.png'
    )

    # 差异图
    vis.plot_difference(
        original, processed,
        title="Processing Difference Analysis",
        save_path=output_dir / 'difference.png'
    )

    # 计算指标
    metrics = PerformanceMetrics.compute_image_quality_metrics(original, processed)
    PerformanceMetrics.report_metrics(metrics, output_dir / 'metrics.txt')

    # 多图网格
    test_images = [
        gen.checkerboard(64, 64, 8),
        gen.gradient_horizontal(64, 64),
        gen.gradient_vertical(64, 64),
        gen.stripes(64, 64, 8),
        gen.blocks_pattern(64, 64, 16),
        gen.random_noise(64, 64),
    ]
    test_titles = ['Checkerboard', 'Gradient H', 'Gradient V',
                   'Stripes', 'Blocks', 'Noise']

    vis.plot_multi_image_grid(
        test_images, test_titles,
        rows=2, cols=3, figsize=(15, 10),
        save_path=output_dir / 'test_suite.png'
    )

    print(f"Visualizations saved to {output_dir}")


if __name__ == '__main__':
    demo_visualization()
