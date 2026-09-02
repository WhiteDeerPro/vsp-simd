#!/usr/bin/env python3
"""
Generate FFT twiddle factors for VSP
Twiddle factors: W_N^k = exp(-j*2*pi*k/N) = cos(2*pi*k/N) - j*sin(2*pi*k/N)
"""

import math
import struct
from pathlib import Path


def generate_twiddle_factors(N):
    """Generate twiddle factors for N-point FFT

    Returns:
        (cos_table, sin_table) with N/2 entries each
    """
    cos_table = []
    sin_table = []

    for k in range(N // 2):
        angle = -2 * math.pi * k / N
        cos_val = math.cos(angle)
        sin_val = math.sin(angle)
        cos_table.append(cos_val)
        sin_table.append(sin_val)

    return cos_table, sin_table


def bit_reverse_order(N):
    """Generate bit-reversed permutation for N-point FFT"""
    log2N = int(math.log2(N))
    indices = []

    for i in range(N):
        # Reverse bits of i
        reversed_i = 0
        for bit in range(log2N):
            if i & (1 << bit):
                reversed_i |= (1 << (log2N - 1 - bit))
        indices.append(reversed_i)

    return indices


def q88_convert(value):
    """Convert float to Q8.8 fixed-point"""
    scaled = round(value * 256)
    return max(-32768, min(32767, scaled))


def write_twiddle_table(N, output_dir):
    """Write twiddle factor tables for FFT"""
    cos_table, sin_table = generate_twiddle_factors(N)

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Write cosine table
    with open(output_dir / f"fft{N}_twiddle_cos.hex", 'w') as f:
        for val in cos_table:
            q88 = q88_convert(val)
            f.write(f"{q88 & 0xFFFF:04x}\n")

    # Write sine table
    with open(output_dir / f"fft{N}_twiddle_sin.hex", 'w') as f:
        for val in sin_table:
            q88 = q88_convert(val)
            f.write(f"{q88 & 0xFFFF:04x}\n")

    # Write bit-reverse table
    bit_rev = bit_reverse_order(N)
    with open(output_dir / f"fft{N}_bitreverse.hex", 'w') as f:
        for idx in bit_rev:
            f.write(f"{idx:04x}\n")

    # Write C reference
    with open(output_dir / f"fft{N}_twiddle.c", 'w') as f:
        f.write(f"// FFT-{N} twiddle factors (Q8.8 format)\n\n")
        f.write(f"const int16_t fft{N}_twiddle_cos[{len(cos_table)}] = {{\n")
        for i, val in enumerate(cos_table):
            if i % 8 == 0:
                f.write("    ")
            f.write(f"{q88_convert(val):6d}")
            if i < len(cos_table) - 1:
                f.write(",")
            if (i + 1) % 8 == 0 or i == len(cos_table) - 1:
                f.write("\n")
        f.write("};\n\n")

        f.write(f"const int16_t fft{N}_twiddle_sin[{len(sin_table)}] = {{\n")
        for i, val in enumerate(sin_table):
            if i % 8 == 0:
                f.write("    ")
            f.write(f"{q88_convert(val):6d}")
            if i < len(sin_table) - 1:
                f.write(",")
            if (i + 1) % 8 == 0 or i == len(sin_table) - 1:
                f.write("\n")
        f.write("};\n")

    return len(cos_table)


def main():
    output_dir = Path("test_data/fft")

    print("Generating FFT twiddle factor tables...")
    print()

    for N in [64, 128, 256, 512, 1024]:
        n_twiddles = write_twiddle_table(N, output_dir)
        print(f"FFT-{N:4d}: {n_twiddles} twiddle factors, {N} bit-reverse indices")

    print(f"\n✓ Twiddle tables generated in {output_dir}/")
    print("\nUsage in VSP:")
    print("  - Load twiddle_cos and twiddle_sin to memory")
    print("  - Use bit-reverse table to reorder input")
    print("  - Access twiddles during butterfly computation")


if __name__ == "__main__":
    main()
