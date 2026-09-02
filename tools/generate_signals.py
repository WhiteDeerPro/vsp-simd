#!/usr/bin/env python3
"""
Generate test signal data for VSP FFT and communication applications
Outputs: binary files and hex files for loading into VSP memory
"""

import numpy as np
import struct
from pathlib import Path


def q_format_convert(values, q_bits=8, int_bits=8):
    """Convert floating point to Q format fixed-point

    Args:
        values: numpy array of float values
        q_bits: fractional bits
        int_bits: integer bits (including sign)

    Returns:
        array of integers in Q format
    """
    scale = 2 ** q_bits
    max_val = (2 ** (int_bits + q_bits - 1)) - 1
    min_val = -(2 ** (int_bits + q_bits - 1))

    scaled = np.round(values * scale)
    clipped = np.clip(scaled, min_val, max_val)
    return clipped.astype(np.int16)


def generate_sine_wave(freq, sampling_rate, duration, amplitude=0.8):
    """Generate sine wave signal

    Args:
        freq: frequency in Hz
        sampling_rate: samples per second
        duration: signal duration in seconds
        amplitude: amplitude (0-1.0)
    """
    t = np.arange(0, duration, 1/sampling_rate)
    signal = amplitude * np.sin(2 * np.pi * freq * t)
    return signal


def generate_chirp(f0, f1, duration, sampling_rate, amplitude=0.8):
    """Generate linear frequency sweep (chirp) signal

    Args:
        f0: start frequency in Hz
        f1: end frequency in Hz
        duration: signal duration in seconds
        sampling_rate: samples per second
    """
    t = np.arange(0, duration, 1/sampling_rate)
    k = (f1 - f0) / duration  # chirp rate
    phase = 2 * np.pi * (f0 * t + 0.5 * k * t**2)
    signal = amplitude * np.sin(phase)
    return signal


def generate_qpsk(num_symbols, samples_per_symbol, amplitude=0.7):
    """Generate QPSK (Quadrature Phase Shift Keying) modulated signal

    QPSK constellation: (1+j, -1+j, -1-j, 1-j) / sqrt(2)
    """
    # Random symbol sequence (0, 1, 2, 3)
    symbols = np.random.randint(0, 4, num_symbols)

    # QPSK constellation mapping
    constellation = np.array([
        1+1j,   # 00
        -1+1j,  # 01
        -1-1j,  # 10
        1-1j    # 11
    ]) / np.sqrt(2) * amplitude

    # Map symbols to constellation
    modulated = constellation[symbols]

    # Upsample (repeat each symbol)
    upsampled = np.repeat(modulated, samples_per_symbol)

    # Apply pulse shaping (simple rectangular for now)
    # In practice, use raised cosine filter

    return upsampled.real, upsampled.imag


def generate_qam16(num_symbols, samples_per_symbol, amplitude=0.6):
    """Generate 16-QAM modulated signal"""
    symbols = np.random.randint(0, 16, num_symbols)

    # 16-QAM constellation (square)
    i_levels = np.array([-3, -1, 1, 3])
    q_levels = np.array([-3, -1, 1, 3])

    constellation = []
    for i in i_levels:
        for q in q_levels:
            constellation.append(i + 1j*q)
    constellation = np.array(constellation) * amplitude / 3

    modulated = constellation[symbols]
    upsampled = np.repeat(modulated, samples_per_symbol)

    return upsampled.real, upsampled.imag


def generate_ofdm_symbol(num_subcarriers=64, cp_length=16, amplitude=0.7):
    """Generate OFDM symbol (like used in WiFi, LTE)

    Args:
        num_subcarriers: number of subcarriers (must be power of 2)
        cp_length: cyclic prefix length
        amplitude: signal amplitude
    """
    # Random data on each subcarrier (QPSK for simplicity)
    data = np.random.choice([1+1j, -1+1j, -1-1j, 1-1j], num_subcarriers)
    data = data * amplitude / np.sqrt(2)

    # IFFT to generate time-domain signal
    time_signal = np.fft.ifft(data) * np.sqrt(num_subcarriers)

    # Add cyclic prefix
    symbol = np.concatenate([time_signal[-cp_length:], time_signal])

    return symbol.real, symbol.imag


def generate_fsk(num_bits, samples_per_bit, f0, f1, sampling_rate, amplitude=0.8):
    """Generate FSK (Frequency Shift Keying) signal

    Args:
        num_bits: number of bits to transmit
        samples_per_bit: samples per bit period
        f0: frequency for bit 0
        f1: frequency for bit 1
    """
    bits = np.random.randint(0, 2, num_bits)
    signal = []

    t_bit = np.arange(samples_per_bit) / sampling_rate

    for bit in bits:
        freq = f1 if bit else f0
        segment = amplitude * np.sin(2 * np.pi * freq * t_bit)
        signal.extend(segment)

    return np.array(signal)


def generate_bandlimited_noise(bandwidth, sampling_rate, duration, amplitude=0.5):
    """Generate band-limited white noise

    Args:
        bandwidth: signal bandwidth in Hz
        sampling_rate: sampling rate
        duration: duration in seconds
    """
    num_samples = int(duration * sampling_rate)

    # Generate white noise
    noise = np.random.randn(num_samples)

    # Apply band-limiting filter (ideal brick wall in frequency domain)
    fft_noise = np.fft.fft(noise)
    freqs = np.fft.fftfreq(num_samples, 1/sampling_rate)

    # Zero out frequencies outside bandwidth
    mask = np.abs(freqs) > bandwidth/2
    fft_noise[mask] = 0

    # Back to time domain
    filtered = np.fft.ifft(fft_noise).real

    # Normalize
    filtered = filtered / np.max(np.abs(filtered)) * amplitude

    return filtered


def write_signal_files(signal, name, output_dir, is_complex=False):
    """Write signal to various formats

    Args:
        signal: numpy array (real) or tuple (real, imag) for complex
        name: base filename
        output_dir: output directory
        is_complex: whether signal is complex
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if is_complex:
        real_part, imag_part = signal
        # Convert to Q8.8
        real_q88 = q_format_convert(real_part)
        imag_q88 = q_format_convert(imag_part)

        # Interleave I and Q
        interleaved = np.empty(len(real_q88) * 2, dtype=np.int16)
        interleaved[0::2] = real_q88
        interleaved[1::2] = imag_q88

        # Write binary (I/Q interleaved)
        with open(output_dir / f"{name}_iq.bin", 'wb') as f:
            interleaved.tofile(f)

        # Write hex (for $readmemh)
        with open(output_dir / f"{name}_iq.hex", 'w') as f:
            for val in interleaved:
                f.write(f"{val & 0xFFFF:04x}\n")

        # Write separate I/Q files
        with open(output_dir / f"{name}_i.hex", 'w') as f:
            for val in real_q88:
                f.write(f"{val & 0xFFFF:04x}\n")

        with open(output_dir / f"{name}_q.hex", 'w') as f:
            for val in imag_q88:
                f.write(f"{val & 0xFFFF:04x}\n")

        return len(real_q88)
    else:
        # Real signal
        signal_q88 = q_format_convert(signal)

        # Write binary
        with open(output_dir / f"{name}.bin", 'wb') as f:
            signal_q88.tofile(f)

        # Write hex
        with open(output_dir / f"{name}.hex", 'w') as f:
            for val in signal_q88:
                f.write(f"{val & 0xFFFF:04x}\n")

        return len(signal_q88)


def main():
    output_dir = Path("test_data/signals")
    print("Generating test signals for VSP...")
    print(f"Output directory: {output_dir}")
    print()

    # Parameters
    sampling_rate = 8000  # 8 kHz

    # 1. Simple sine waves (different frequencies)
    print("1. Sine waves...")
    for freq in [100, 440, 1000, 2000]:
        signal = generate_sine_wave(freq, sampling_rate, duration=0.25, amplitude=0.8)
        n = write_signal_files(signal, f"sine_{freq}hz", output_dir)
        print(f"   sine_{freq}hz: {n} samples")

    # 2. Chirp signal (frequency sweep)
    print("\n2. Chirp signal...")
    chirp = generate_chirp(f0=100, f1=2000, duration=0.5, sampling_rate=sampling_rate)
    n = write_signal_files(chirp, "chirp_100_2000hz", output_dir)
    print(f"   chirp: {n} samples")

    # 3. QPSK modulated signal
    print("\n3. QPSK signal...")
    qpsk_i, qpsk_q = generate_qpsk(num_symbols=32, samples_per_symbol=8, amplitude=0.7)
    n = write_signal_files((qpsk_i, qpsk_q), "qpsk_32sym", output_dir, is_complex=True)
    print(f"   qpsk: {n} samples (I/Q)")

    # 4. 16-QAM signal
    print("\n4. 16-QAM signal...")
    qam_i, qam_q = generate_qam16(num_symbols=32, samples_per_symbol=8, amplitude=0.6)
    n = write_signal_files((qam_i, qam_q), "qam16_32sym", output_dir, is_complex=True)
    print(f"   qam16: {n} samples (I/Q)")

    # 5. OFDM symbol
    print("\n5. OFDM symbol...")
    ofdm_i, ofdm_q = generate_ofdm_symbol(num_subcarriers=64, cp_length=16)
    n = write_signal_files((ofdm_i, ofdm_q), "ofdm_64sc", output_dir, is_complex=True)
    print(f"   ofdm: {n} samples (I/Q)")

    # 6. FSK signal
    print("\n6. FSK signal...")
    fsk = generate_fsk(num_bits=32, samples_per_bit=16, f0=800, f1=1200,
                       sampling_rate=sampling_rate)
    n = write_signal_files(fsk, "fsk_32bits", output_dir)
    print(f"   fsk: {n} samples")

    # 7. Band-limited noise
    print("\n7. Band-limited noise...")
    noise = generate_bandlimited_noise(bandwidth=2000, sampling_rate=sampling_rate,
                                       duration=0.25)
    n = write_signal_files(noise, "bandlimited_noise_2khz", output_dir)
    print(f"   noise: {n} samples")

    # 8. Multi-tone signal (sum of sines)
    print("\n8. Multi-tone signal...")
    multitone = (generate_sine_wave(300, sampling_rate, 0.25, 0.3) +
                 generate_sine_wave(700, sampling_rate, 0.25, 0.3) +
                 generate_sine_wave(1400, sampling_rate, 0.25, 0.3))
    n = write_signal_files(multitone, "multitone_3freq", output_dir)
    print(f"   multitone: {n} samples")

    print(f"\nAll signals generated in {output_dir}/")
    print("\nSignal formats:")
    print("  .bin - Binary (int16, little-endian)")
    print("  .hex - Hex text (for $readmemh)")
    print("  _iq.bin/hex - I/Q interleaved")
    print("  _i.hex/_q.hex - Separate I and Q channels")
    print("\nAll signals in Q8.8 fixed-point format")


if __name__ == "__main__":
    main()
