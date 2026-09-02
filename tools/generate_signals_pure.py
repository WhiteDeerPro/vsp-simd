#!/usr/bin/env python3
"""
Pure Python signal generator (no numpy required)
Generate test signals for VSP FFT and communication applications
"""

import math
import struct
import random
from pathlib import Path


def q88_convert(value):
    """Convert float to Q8.8 fixed-point (16-bit signed)"""
    scaled = round(value * 256)
    # Clamp to 16-bit signed range
    if scaled > 32767:
        scaled = 32767
    elif scaled < -32768:
        scaled = -32768
    return scaled


def generate_sine(freq, sampling_rate, num_samples, amplitude=0.8):
    """Generate sine wave"""
    signal = []
    for n in range(num_samples):
        t = n / sampling_rate
        sample = amplitude * math.sin(2 * math.pi * freq * t)
        signal.append(sample)
    return signal


def generate_cosine(freq, sampling_rate, num_samples, amplitude=0.8):
    """Generate cosine wave"""
    signal = []
    for n in range(num_samples):
        t = n / sampling_rate
        sample = amplitude * math.cos(2 * math.pi * freq * t)
        signal.append(sample)
    return signal


def generate_chirp(f0, f1, num_samples, sampling_rate, amplitude=0.8):
    """Generate linear chirp (frequency sweep)"""
    signal = []
    duration = num_samples / sampling_rate
    k = (f1 - f0) / duration  # chirp rate

    for n in range(num_samples):
        t = n / sampling_rate
        phase = 2 * math.pi * (f0 * t + 0.5 * k * t * t)
        sample = amplitude * math.sin(phase)
        signal.append(sample)
    return signal


def generate_square_wave(freq, sampling_rate, num_samples, amplitude=0.8):
    """Generate square wave"""
    signal = []
    period = sampling_rate / freq

    for n in range(num_samples):
        phase = (n % period) / period
        sample = amplitude if phase < 0.5 else -amplitude
        signal.append(sample)
    return signal


def generate_qpsk_baseband(num_symbols, samples_per_symbol):
    """Generate QPSK baseband signal (I and Q)

    QPSK symbols: (1,1), (-1,1), (-1,-1), (1,-1)
    """
    i_signal = []
    q_signal = []

    # Symbol mapping
    symbols = [
        (1, 1),   # 00
        (-1, 1),  # 01
        (-1, -1), # 10
        (1, -1)   # 11
    ]

    amplitude = 0.7 / math.sqrt(2)

    for _ in range(num_symbols):
        # Random symbol
        idx = random.randint(0, 3)
        i_val, q_val = symbols[idx]
        i_val *= amplitude
        q_val *= amplitude

        # Repeat for pulse shaping (rectangular)
        for _ in range(samples_per_symbol):
            i_signal.append(i_val)
            q_signal.append(q_val)

    return i_signal, q_signal


def write_signal_hex(signal, filename):
    """Write signal to hex file (Q8.8 format)"""
    with open(filename, 'w') as f:
        for sample in signal:
            q88_val = q88_convert(sample)
            # Write as unsigned 16-bit hex
            f.write(f"{q88_val & 0xFFFF:04x}\n")


def write_signal_binary(signal, filename):
    """Write signal to binary file (Q8.8 format, little-endian)"""
    with open(filename, 'wb') as f:
        for sample in signal:
            q88_val = q88_convert(sample)
            f.write(struct.pack('<h', q88_val))


def write_complex_signal(i_signal, q_signal, base_filename, output_dir):
    """Write complex signal (I/Q interleaved and separate)"""
    # Interleaved I/Q
    interleaved = []
    for i, q in zip(i_signal, q_signal):
        interleaved.append(i)
        interleaved.append(q)

    write_signal_hex(interleaved, output_dir / f"{base_filename}_iq.hex")
    write_signal_binary(interleaved, output_dir / f"{base_filename}_iq.bin")

    # Separate I and Q
    write_signal_hex(i_signal, output_dir / f"{base_filename}_i.hex")
    write_signal_hex(q_signal, output_dir / f"{base_filename}_q.hex")


def main():
    output_dir = Path("test_data/signals")
    output_dir.mkdir(parents=True, exist_ok=True)

    print("Generating test signals (pure Python)...")
    print(f"Output: {output_dir}/")
    print()

    sampling_rate = 8000  # 8 kHz

    # 1. Sine waves at different frequencies
    print("1. Sine waves...")
    for freq in [100, 440, 1000, 2000]:
        num_samples = int(0.25 * sampling_rate)  # 250ms
        signal = generate_sine(freq, sampling_rate, num_samples, 0.8)
        write_signal_hex(signal, output_dir / f"sine_{freq}hz.hex")
        write_signal_binary(signal, output_dir / f"sine_{freq}hz.bin")
        print(f"   sine_{freq}hz: {num_samples} samples")

    # 2. Chirp
    print("\n2. Chirp signal (100-2000 Hz)...")
    num_samples = int(0.5 * sampling_rate)
    chirp = generate_chirp(100, 2000, num_samples, sampling_rate, 0.8)
    write_signal_hex(chirp, output_dir / "chirp_100_2000hz.hex")
    write_signal_binary(chirp, output_dir / "chirp_100_2000hz.bin")
    print(f"   chirp: {num_samples} samples")

    # 3. Square wave
    print("\n3. Square wave (440 Hz)...")
    num_samples = int(0.25 * sampling_rate)
    square = generate_square_wave(440, sampling_rate, num_samples, 0.8)
    write_signal_hex(square, output_dir / "square_440hz.hex")
    write_signal_binary(square, output_dir / "square_440hz.bin")
    print(f"   square: {num_samples} samples")

    # 4. QPSK signal
    print("\n4. QPSK modulated signal...")
    num_symbols = 32
    samples_per_symbol = 8
    i_signal, q_signal = generate_qpsk_baseband(num_symbols, samples_per_symbol)
    write_complex_signal(i_signal, q_signal, "qpsk_32sym", output_dir)
    print(f"   qpsk: {len(i_signal)} samples (I/Q)")

    # 5. Multi-tone (sum of 3 sines)
    print("\n5. Multi-tone signal (300+700+1400 Hz)...")
    num_samples = int(0.25 * sampling_rate)
    tone1 = generate_sine(300, sampling_rate, num_samples, 0.3)
    tone2 = generate_sine(700, sampling_rate, num_samples, 0.3)
    tone3 = generate_sine(1400, sampling_rate, num_samples, 0.3)
    multitone = [t1 + t2 + t3 for t1, t2, t3 in zip(tone1, tone2, tone3)]
    write_signal_hex(multitone, output_dir / "multitone_3freq.hex")
    write_signal_binary(multitone, output_dir / "multitone_3freq.bin")
    print(f"   multitone: {num_samples} samples")

    # 6. FFT test sizes (powers of 2)
    print("\n6. FFT test signals (powers of 2)...")
    for size in [64, 128, 256]:
        # Impulse at DC
        impulse = [1.0] + [0.0] * (size - 1)
        write_signal_hex(impulse, output_dir / f"impulse_{size}.hex")

        # Single frequency bin
        k = size // 8  # Frequency bin
        signal = generate_sine(k * sampling_rate / size, sampling_rate, size, 0.8)
        write_signal_hex(signal, output_dir / f"fft_test_{size}_bin{k}.hex")
        print(f"   FFT size {size}: impulse and tone")

    print(f"\n✓ All signals generated in {output_dir}/")
    print("\nFile formats:")
    print("  .hex - Hex text (one value per line, for $readmemh)")
    print("  .bin - Binary (int16 little-endian)")
    print("  _iq.hex - I/Q interleaved")
    print("  _i.hex, _q.hex - Separate I and Q")
    print("\nAll values in Q8.8 fixed-point format")


if __name__ == "__main__":
    main()
