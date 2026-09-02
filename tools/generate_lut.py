#!/usr/bin/env python3
"""
Generate lookup tables for VSP transcendental functions
Output format: binary files suitable for loading into LOCAL memory
"""

import math
import struct
import sys
from pathlib import Path


def generate_sin_table(size=256, format='q88'):
    """Generate sine lookup table

    Args:
        size: number of entries (default 256 for [0, 2*pi])
        format: 'q88' for Q8.8, 'u8' for unsigned byte

    Returns:
        list of values
    """
    table = []
    for i in range(size):
        angle = (i * 2.0 * math.pi) / size
        sin_val = math.sin(angle)

        if format == 'q88':
            # Q8.8: multiply by 256, clamp to [-32768, 32767]
            q88_val = int(sin_val * 256)
            q88_val = max(-32768, min(32767, q88_val))
            table.append(q88_val)
        elif format == 'u8':
            # Map [-1, 1] to [0, 255]
            u8_val = int((sin_val + 1.0) * 127.5)
            u8_val = max(0, min(255, u8_val))
            table.append(u8_val)

    return table


def generate_cos_table(size=256, format='q88'):
    """Generate cosine lookup table (same as sin shifted by pi/2)"""
    table = []
    for i in range(size):
        angle = (i * 2.0 * math.pi) / size + (math.pi / 2.0)
        cos_val = math.cos(angle)

        if format == 'q88':
            q88_val = int(cos_val * 256)
            q88_val = max(-32768, min(32767, q88_val))
            table.append(q88_val)
        elif format == 'u8':
            u8_val = int((cos_val + 1.0) * 127.5)
            u8_val = max(0, min(255, u8_val))
            table.append(u8_val)

    return table


def generate_exp_table(size=256, x_max=8.0):
    """Generate exponential lookup table

    exp(x) for x in [0, x_max]
    Q8.8 format, saturates at large values
    """
    table = []
    for i in range(size):
        x = (i * x_max) / size
        exp_val = math.exp(x)

        # Q8.8 format, saturate at 255.99
        q88_val = int(exp_val * 256)
        q88_val = max(0, min(65535, q88_val))
        table.append(q88_val)

    return table


def generate_log_table(size=256, x_max=256.0):
    """Generate natural logarithm lookup table

    log(x) for x in [1, x_max]
    Q8.8 format (can be negative)
    """
    table = []
    for i in range(size):
        # Avoid log(0), start from small positive value
        x = 1.0 + (i * (x_max - 1.0)) / size
        log_val = math.log(x)

        # Q8.8 format
        q88_val = int(log_val * 256)
        q88_val = max(-32768, min(32767, q88_val))
        table.append(q88_val)

    return table


def generate_sqrt_table(size=256):
    """Generate square root lookup table

    sqrt(x) for x in [0, 255]
    Q8.8 format output
    """
    table = []
    for i in range(size):
        sqrt_val = math.sqrt(i)

        # Q8.8 format
        q88_val = int(sqrt_val * 256)
        q88_val = max(0, min(65535, q88_val))
        table.append(q88_val)

    return table


def generate_reciprocal_table(size=256):
    """Generate reciprocal (1/x) lookup table

    1/x for x in [1, 255]
    Q8.8 format
    """
    table = []
    for i in range(size):
        if i == 0:
            # 1/0 = max value (saturate)
            recip_val = 255.99
        else:
            recip_val = 1.0 / i

        # Q8.8 format
        q88_val = int(recip_val * 256)
        q88_val = max(0, min(65535, q88_val))
        table.append(q88_val)

    return table


def generate_atan_table(size=16):
    """Generate CORDIC arctangent table

    atan(2^-i) for i in [0, size-1]
    Output in angle units [0, 255] representing [0, 2*pi]
    """
    table = []
    for i in range(size):
        atan_val = math.atan(2.0 ** (-i))
        # Convert to [0, 255] scale
        angle_units = int((atan_val / (2.0 * math.pi)) * 256)
        table.append(angle_units)

    return table


def write_table_binary(table, filename, format='u16le'):
    """Write table to binary file

    Args:
        table: list of integer values
        filename: output file path
        format: 'u8' (1 byte), 'u16le' (2 bytes little-endian),
                's16le' (2 bytes signed little-endian)
    """
    with open(filename, 'wb') as f:
        for val in table:
            if format == 'u8':
                f.write(struct.pack('<B', val & 0xFF))
            elif format == 'u16le':
                f.write(struct.pack('<H', val & 0xFFFF))
            elif format == 's16le':
                # Signed 16-bit
                f.write(struct.pack('<h', val))


def write_table_hex(table, filename, format='u16'):
    """Write table to hex text file (for $readmemh)

    Format: one value per line, hexadecimal
    """
    with open(filename, 'w') as f:
        for val in table:
            if format == 'u8':
                f.write(f"{val & 0xFF:02x}\n")
            elif format == 'u16':
                f.write(f"{val & 0xFFFF:04x}\n")


def write_table_c_array(table, name, filename, format='uint16_t'):
    """Write table as C array for reference"""
    with open(filename, 'w') as f:
        f.write(f"// Auto-generated lookup table: {name}\n")
        f.write(f"const {format} {name}[{len(table)}] = {{\n")
        for i, val in enumerate(table):
            if i % 8 == 0:
                f.write("    ")
            f.write(f"{val:5d}")
            if i < len(table) - 1:
                f.write(",")
            if (i + 1) % 8 == 0 or i == len(table) - 1:
                f.write("\n")
        f.write("};\n")


def main():
    output_dir = Path("test_data/lut")
    output_dir.mkdir(parents=True, exist_ok=True)

    print("Generating lookup tables...")

    # Sine table (256 entries, Q8.8)
    sin_table = generate_sin_table(256, 'q88')
    write_table_binary(sin_table, output_dir / "sin_q88.bin", 's16le')
    write_table_hex(sin_table, output_dir / "sin_q88.hex", 'u16')
    write_table_c_array(sin_table, "sin_table_q88", output_dir / "sin_q88.c", 'int16_t')
    print(f"  sin_table: {len(sin_table)} entries")

    # Cosine table
    cos_table = generate_cos_table(256, 'q88')
    write_table_binary(cos_table, output_dir / "cos_q88.bin", 's16le')
    write_table_hex(cos_table, output_dir / "cos_q88.hex", 'u16')
    print(f"  cos_table: {len(cos_table)} entries")

    # Exponential table
    exp_table = generate_exp_table(256, 8.0)
    write_table_binary(exp_table, output_dir / "exp_q88.bin", 'u16le')
    write_table_hex(exp_table, output_dir / "exp_q88.hex", 'u16')
    write_table_c_array(exp_table, "exp_table_q88", output_dir / "exp_q88.c", 'uint16_t')
    print(f"  exp_table: {len(exp_table)} entries")

    # Natural log table
    log_table = generate_log_table(256, 256.0)
    write_table_binary(log_table, output_dir / "log_q88.bin", 's16le')
    write_table_hex(log_table, output_dir / "log_q88.hex", 'u16')
    write_table_c_array(log_table, "log_table_q88", output_dir / "log_q88.c", 'int16_t')
    print(f"  log_table: {len(log_table)} entries")

    # Square root table
    sqrt_table = generate_sqrt_table(256)
    write_table_binary(sqrt_table, output_dir / "sqrt_q88.bin", 'u16le')
    write_table_hex(sqrt_table, output_dir / "sqrt_q88.hex", 'u16')
    print(f"  sqrt_table: {len(sqrt_table)} entries")

    # Reciprocal table
    recip_table = generate_reciprocal_table(256)
    write_table_binary(recip_table, output_dir / "recip_q88.bin", 'u16le')
    write_table_hex(recip_table, output_dir / "recip_q88.hex", 'u16')
    print(f"  recip_table: {len(recip_table)} entries")

    # CORDIC atan table (16 entries for 16 iterations)
    atan_table = generate_atan_table(16)
    write_table_binary(atan_table, output_dir / "cordic_atan.bin", 'u8')
    write_table_hex(atan_table, output_dir / "cordic_atan.hex", 'u8')
    write_table_c_array(atan_table, "cordic_atan_table", output_dir / "cordic_atan.c", 'uint8_t')
    print(f"  cordic_atan: {len(atan_table)} entries")

    print(f"\nLookup tables generated in {output_dir}/")
    print("\nTable sizes:")
    print(f"  Total memory: {(256*2*6 + 16*1)} bytes = {(256*2*6 + 16*1)/1024:.2f} KB")
    print(f"    sin:   512 bytes")
    print(f"    cos:   512 bytes")
    print(f"    exp:   512 bytes")
    print(f"    log:   512 bytes")
    print(f"    sqrt:  512 bytes")
    print(f"    recip: 512 bytes")
    print(f"    atan:   16 bytes")

    # Generate memory initialization file
    mem_init_file = output_dir / "lut_memory_init.hex"
    print(f"\nGenerating unified memory init file: {mem_init_file}")

    with open(mem_init_file, 'w') as f:
        f.write("// VSP Lookup Table Memory Initialization\n")
        f.write("// Format: address : data (32-bit words)\n")
        f.write("// Base addresses:\n")
        f.write("//   0x4000: sin_table\n")
        f.write("//   0x4200: cos_table\n")
        f.write("//   0x5000: exp_table\n")
        f.write("//   0x5200: log_table\n")
        f.write("//   0x5400: sqrt_table\n")
        f.write("//   0x5600: recip_table\n")
        f.write("//   0x6000: cordic_atan\n")
        f.write("\n")


if __name__ == "__main__":
    main()
