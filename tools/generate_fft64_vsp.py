#!/usr/bin/env python3
"""Generate the executable 64-point static-BFP FFT and SRAM fixtures.

The mapping deliberately uses the native signed 8-bit VSP lanes. Samples are
BFP8 mantissas (Q1.7 at block exponent zero), twiddles are Q2.6, and every
radix-2 DIT stage divides the mantissas by two while incrementing the shared
block exponent. The stored mantissas are FFT(x) / 64; together with Eout=Ein+6
they represent the unscaled transform.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
from dataclasses import dataclass

import vsp_bfp as bfp
import vsp_uword_asm as uasm


N = 64
LOG2_N = 6
LANES = 16
PROGRAM_BASE = 0x0020
DATA_BASE = 0x1000

REAL_BASE = 0x1000
IMAG_BASE = 0x1040
TWIDDLE_REAL_BASE = 0x1080
TWIDDLE_IMAG_BASE = 0x10A0
TWIDDLE_NEG_REAL_BASE = 0x10C0
TWIDDLE_NEG_IMAG_BASE = 0x10E0
ZERO_VECTOR_BASE = 0x1100
A_INDEX_BASE = 0x1120
B_INDEX_BASE = 0x11E0
W_INDEX_BASE = 0x12A0
BFP_EXPONENT_IN_BASE = 0x1360
BFP_EXPONENT_OUT_BASE = 0x1370
DATA_END = 0x1380

SETUP_ACTIONS = 13
ACTIONS_PER_BATCH = 36
BATCHES_PER_STAGE = 2
TOTAL_BATCHES = LOG2_N * BATCHES_PER_STAGE
POST_FFT_ACTIONS = 3


@dataclass(frozen=True)
class Batch:
    stage: int
    number: int
    a_indices: list[int]
    b_indices: list[int]
    twiddle_indices: list[int]


@dataclass(frozen=True)
class WaveformProfile:
    name: str
    input_block_exponent: int
    natural_real: tuple[int, ...]
    natural_imag: tuple[int, ...]
    ideal_real: tuple[float, ...]
    ideal_imag: tuple[float, ...]
    components: tuple[dict[str, object], ...]
    quantization: str
    input_decode: str
    input_value_denominator: int | None


def round_away(value: float) -> int:
    """Round halves away from zero, independent of Python's banker rounding."""
    if value >= 0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def round_nearest_up(value: float) -> int:
    """Round to nearest integer with exact ties toward positive infinity."""

    return int(math.floor(value + 0.5))


def make_waveform_profile(name: str) -> WaveformProfile:
    """Build one named natural-order FFT input profile."""

    if name == "bin8":
        ideal_real = tuple(
            96.0 * math.sin(2.0 * math.pi * 8 * sample / N)
            for sample in range(N)
        )
        natural_real = tuple(
            max(-128, min(127, round_away(value))) for value in ideal_real
        )
        return WaveformProfile(
            name=name,
            input_block_exponent=-2,
            natural_real=natural_real,
            natural_imag=(0,) * N,
            ideal_real=ideal_real,
            ideal_imag=(0.0,) * N,
            components=(
                {
                    "kind": "sine",
                    "bin": 8,
                    "amplitude_code": 96,
                    "phase_radians": 0.0,
                },
            ),
            quantization=(
                "legacy bin8: round halves away from zero after scaling by "
                "96, then clip to signed int8 [-128,127]"
            ),
            input_decode="mantissa * 2^(input_block_exponent - 7)",
            input_value_denominator=None,
        )

    if name == "mixed":
        components: tuple[dict[str, object], ...] = (
            {
                "kind": "cosine",
                "bin": 5,
                "amplitude": 0.40,
                "phase_radians": 0.0,
                "phase": "0",
            },
            {
                "kind": "cosine",
                "bin": 13,
                "amplitude": 0.28,
                "phase_radians": math.pi / 4.0,
                "phase": "+pi/4",
            },
            {
                "kind": "cosine",
                "bin": 23,
                "amplitude": 0.16,
                "phase_radians": -math.pi / 3.0,
                "phase": "-pi/3",
            },
        )
        ideal_real = tuple(
            sum(
                float(component["amplitude"])
                * math.cos(
                    2.0 * math.pi * int(component["bin"]) * sample / N
                    + float(component["phase_radians"])
                )
                for component in components
            )
            for sample in range(N)
        )
        natural_real = tuple(
            max(-127, min(127, round_nearest_up(127.0 * value)))
            for value in ideal_real
        )
        if -128 in natural_real:
            raise AssertionError("mixed symmetric quantizer must never emit -128")
        return WaveformProfile(
            name=name,
            input_block_exponent=0,
            natural_real=natural_real,
            natural_imag=(0,) * N,
            ideal_real=ideal_real,
            ideal_imag=(0.0,) * N,
            components=components,
            quantization=(
                "real_code = clip(floor(127*real_value + 0.5), "
                "-127, 127); -128 is prohibited; imag_code uses the same rule"
            ),
            input_decode="real_value = real_code / 127; imag_value = imag_code / 127",
            input_value_denominator=127,
        )

    raise ValueError(f"unknown waveform profile: {name}")


def signed_byte(value: int) -> int:
    if value < -128 or value > 127:
        raise ValueError(f"signed byte overflow: {value}")
    return value & 0xFF


def bit_reverse(value: int, width: int = LOG2_N) -> int:
    result = 0
    for bit in range(width):
        result |= ((value >> bit) & 1) << (width - 1 - bit)
    return result


def make_batches() -> list[Batch]:
    batches: list[Batch] = []
    batch_number = 0
    stage_size = 2
    for stage in range(LOG2_N):
        butterflies: list[tuple[int, int, int]] = []
        half_size = stage_size // 2
        twiddle_step = N // stage_size
        for base in range(0, N, stage_size):
            for lane in range(half_size):
                a_index = base + lane
                butterflies.append(
                    (a_index, a_index + half_size, lane * twiddle_step)
                )
        if len(butterflies) != N // 2:
            raise AssertionError("each FFT stage must contain 32 butterflies")
        for offset in range(0, len(butterflies), LANES):
            group = butterflies[offset:offset + LANES]
            batches.append(
                Batch(
                    stage=stage,
                    number=batch_number,
                    a_indices=[item[0] for item in group],
                    b_indices=[item[1] for item in group],
                    twiddle_indices=[item[2] for item in group],
                )
            )
            batch_number += 1
        stage_size *= 2
    if len(batches) != TOTAL_BATCHES:
        raise AssertionError("64-point FFT must map to twelve 16-lane batches")
    return batches


def reference_fft(
    natural_real: list[int], natural_imag: list[int],
    twiddle_real: list[int], twiddle_imag: list[int],
) -> tuple[list[int], list[int], list[tuple[list[int], list[int]]]]:
    real = [natural_real[bit_reverse(index)] for index in range(N)]
    imag = [natural_imag[bit_reverse(index)] for index in range(N)]
    stage_states: list[tuple[list[int], list[int]]] = []

    stage_size = 2
    for _stage in range(LOG2_N):
        half_size = stage_size // 2
        twiddle_step = N // stage_size
        for base in range(0, N, stage_size):
            for lane in range(half_size):
                a = base + lane
                b = a + half_size
                twiddle = lane * twiddle_step
                ar, ai = real[a], imag[a]
                br, bi = real[b], imag[b]
                wr, wi = twiddle_real[twiddle], twiddle_imag[twiddle]

                tr = br * wr - bi * wi
                ti = br * wi + bi * wr
                real[a] = bfp.round_shift_clip(tr + (ar << 6), 7)
                imag[a] = bfp.round_shift_clip(ti + (ai << 6), 7)
                real[b] = bfp.round_shift_clip(-tr + (ar << 6), 7)
                imag[b] = bfp.round_shift_clip(-ti + (ai << 6), 7)
        stage_states.append((real.copy(), imag.copy()))
        stage_size *= 2
    return real, imag, stage_states


def store_bytes(image: bytearray, address: int, values: list[int]) -> None:
    start = address - DATA_BASE
    end = start + len(values)
    if start < 0 or end > len(image):
        raise ValueError(f"image write 0x{address:x}..0x{address + len(values):x} out of range")
    image[start:end] = bytes(values)


def pack_words(values: bytes | bytearray | list[int]) -> list[int]:
    if len(values) % 4:
        raise ValueError("word image length must be a multiple of four bytes")
    return [
        values[index]
        | (values[index + 1] << 8)
        | (values[index + 2] << 16)
        | (values[index + 3] << 24)
        for index in range(0, len(values), 4)
    ]


def write_words(path: pathlib.Path, words: list[int]) -> None:
    path.write_text(
        "".join(f"{word & 0xFFFFFFFF:08x}\n" for word in words),
        encoding="utf-8",
    )


def write_bytes(path: pathlib.Path, values: list[int]) -> None:
    path.write_text("".join(f"{value & 0xFF:02x}\n" for value in values),
                    encoding="utf-8")


def write_input_csv(path: pathlib.Path, profile: WaveformProfile) -> None:
    """Write natural-order quantized input values without external packages."""

    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(
            ("sample", "real_code", "imag_code", "real_value", "imag_value")
        )
        for sample, (real_code, imag_code) in enumerate(
            zip(profile.natural_real, profile.natural_imag)
        ):
            if profile.input_value_denominator is not None:
                real_value = real_code / profile.input_value_denominator
                imag_value = imag_code / profile.input_value_denominator
            else:
                real_value = math.ldexp(
                    float(real_code),
                    profile.input_block_exponent - bfp.MANTISSA_FRACTION_BITS,
                )
                imag_value = math.ldexp(
                    float(imag_code),
                    profile.input_block_exponent - bfp.MANTISSA_FRACTION_BITS,
                )
            writer.writerow(
                (
                    sample,
                    real_code,
                    imag_code,
                    format(real_value, ".17g"),
                    format(imag_value, ".17g"),
                )
            )


def make_program(batches: list[Batch]) -> str:
    if len(batches) != TOTAL_BATCHES:
        raise ValueError("unexpected FFT schedule size")
    lines = [
        "# GENERATED by tools/generate_fft64_vsp.py; do not hand edit.",
        "# 64-point radix-2 DIT, static BFP8 data, signed Q2.6 twiddles.",
        "# Input is bit reversed; each stage halves mantissas and raises E by 1.",
        "",
        "entry:",
        f"    LI rd=1 imm=0x{REAL_BASE:x}",
        f"    LI rd=2 imm=0x{IMAG_BASE:x}",
        f"    LI rd=3 imm=0x{TWIDDLE_REAL_BASE:x}",
        f"    LI rd=4 imm=0x{TWIDDLE_IMAG_BASE:x}",
        f"    LI rd=5 imm=0x{TWIDDLE_NEG_REAL_BASE:x}",
        f"    LI rd=6 imm=0x{TWIDDLE_NEG_IMAG_BASE:x}",
        f"    LI rd=7 imm=0x{ZERO_VECTOR_BASE:x}",
        f"    LI rd=8 imm=0x{A_INDEX_BASE:x}",
        f"    LI rd=9 imm=0x{B_INDEX_BASE:x}",
        f"    LI rd=10 imm=0x{W_INDEX_BASE:x}",
        "    LI rd=11 imm=0",
        f"    LI rd=12 imm={TOTAL_BATCHES}",
        "    # Keep the butterfly zero vector independent of BFP metadata.",
        "    VLOAD space=physical addr_context=0 sbase=7 vrf=11 span=16 offset=0",
        "",
        "fft_loop:",
        "    VLOAD space=physical addr_context=0 sbase=8 vrf=0 span=16 offset=0",
        "    VLOAD space=physical addr_context=0 sbase=9 vrf=1 span=16 offset=0",
        "    VLOAD space=physical addr_context=0 sbase=10 vrf=2 span=16 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=1 vd=3 vi=0 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=2 vd=4 vi=0 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=1 vd=5 vi=1 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=2 vd=6 vi=1 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=3 vd=7 vi=2 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=4 vd=8 vi=2 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=5 vd=9 vi=2 offset=0",
        "    VGATHER space=physical addr_context=0 sbase=6 vd=10 vi=2 offset=0",
        "    EXEC_MUL_RR op=mul_s va=5 vb=7 dst_arf=0",
        "    EXEC_MAC_RR op=mac_s va=6 vb=10 src_arf=0 dst_arf=0",
        "    EXEC_MUL_RR op=mul_s va=5 vb=9 dst_arf=1",
        "    EXEC_MAC_RR op=mac_s va=6 vb=8 src_arf=1 dst_arf=1",
        "    EXEC_MUL_RR op=mul_s va=5 vb=8 dst_arf=2",
        "    EXEC_MAC_RR op=mac_s va=6 vb=7 src_arf=2 dst_arf=2",
        "    EXEC_MUL_RR op=mul_s va=5 vb=10 dst_arf=3",
        "    EXEC_MAC_RR op=mac_s va=6 vb=9 src_arf=3 dst_arf=3",
        "    EXEC_WADD op=wadd_s va=3 vb=11 src_arf=0 dst_arf=0 align=6",
        "    EXEC_WADD op=wadd_s va=3 vb=11 src_arf=1 dst_arf=1 align=6",
        "    EXEC_WADD op=wadd_s va=4 vb=11 src_arf=2 dst_arf=2 align=6",
        "    EXEC_WADD op=wadd_s va=4 vb=11 src_arf=3 dst_arf=3 align=6",
        "    EXEC_WIDE_RI op=nclip_s arf=0 shift=7 vd=12",
        "    EXEC_WIDE_RI op=nclip_s arf=2 shift=7 vd=13",
        "    EXEC_WIDE_RI op=nclip_s arf=1 shift=7 vd=14",
        "    EXEC_WIDE_RI op=nclip_s arf=3 shift=7 vd=15",
        "    VSCATTER space=physical addr_context=0 sbase=1 vs=12 vi=0 offset=0",
        "    VSCATTER space=physical addr_context=0 sbase=2 vs=13 vi=0 offset=0",
        "    VSCATTER space=physical addr_context=0 sbase=1 vs=14 vi=1 offset=0",
        "    VSCATTER space=physical addr_context=0 sbase=2 vs=15 vi=1 offset=0",
        "    ADDI rd=8 rs1=8 imm=16",
        "    ADDI rd=9 rs1=9 imm=16",
        "    ADDI rd=10 rs1=10 imm=16",
        "    ADDI rd=11 rs1=11 imm=1",
        "    BLTU rs1=11 rs2=12 target=fft_loop",
        "",
        "    # Static BFP metadata; after twelve batches r10 == exponent_in.",
        "    VLOAD space=physical addr_context=0 sbase=10 vrf=11 span=16 offset=0",
        f"    EXEC_ALU_RI op=add mode=byte va=11 vd=1 imm={LOG2_N}",
        "    VSTORE space=physical addr_context=0 sbase=10 vrf=1 span=16 offset=16",
        "",
        "    END",
        "",
    ]
    return "\n".join(lines)


def generate(output_dir: pathlib.Path, waveform: str = "bin8") -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    batches = make_batches()
    profile = make_waveform_profile(waveform)
    input_block_exponent = profile.input_block_exponent
    output_block_exponent = input_block_exponent + LOG2_N
    exponent_schedule = bfp.stage_exponents(input_block_exponent, LOG2_N)
    if exponent_schedule[-1] != output_block_exponent:
        raise AssertionError("unexpected static-BFP exponent schedule")

    natural_real = list(profile.natural_real)
    natural_imag = list(profile.natural_imag)
    twiddle_real = [round_away(64.0 * math.cos(2.0 * math.pi * k / N))
                    for k in range(N // 2)]
    twiddle_imag = [round_away(-64.0 * math.sin(2.0 * math.pi * k / N))
                    for k in range(N // 2)]
    twiddle_neg_real = [-value for value in twiddle_real]
    twiddle_neg_imag = [-value for value in twiddle_imag]

    golden_real, golden_imag, stage_states = reference_fft(
        natural_real, natural_imag, twiddle_real, twiddle_imag
    )
    bit_reversed_real = [natural_real[bit_reverse(index)] for index in range(N)]
    bit_reversed_imag = [natural_imag[bit_reverse(index)] for index in range(N)]

    data_image = bytearray(DATA_END - DATA_BASE)
    store_bytes(data_image, REAL_BASE, [signed_byte(v) for v in bit_reversed_real])
    store_bytes(data_image, IMAG_BASE, [signed_byte(v) for v in bit_reversed_imag])
    store_bytes(data_image, TWIDDLE_REAL_BASE,
                [signed_byte(v) for v in twiddle_real])
    store_bytes(data_image, TWIDDLE_IMAG_BASE,
                [signed_byte(v) for v in twiddle_imag])
    store_bytes(data_image, TWIDDLE_NEG_REAL_BASE,
                [signed_byte(v) for v in twiddle_neg_real])
    store_bytes(data_image, TWIDDLE_NEG_IMAG_BASE,
                [signed_byte(v) for v in twiddle_neg_imag])
    store_bytes(data_image, ZERO_VECTOR_BASE, [0] * (2 * LANES))
    store_bytes(data_image, A_INDEX_BASE,
                [value for batch in batches for value in batch.a_indices])
    store_bytes(data_image, B_INDEX_BASE,
                [value for batch in batches for value in batch.b_indices])
    store_bytes(data_image, W_INDEX_BASE,
                [value for batch in batches for value in batch.twiddle_indices])
    store_bytes(data_image, BFP_EXPONENT_IN_BASE,
                [signed_byte(input_block_exponent)] * LANES)
    store_bytes(data_image, BFP_EXPONENT_OUT_BASE, [0xA5] * LANES)

    source = make_program(batches)
    source_path = output_dir / "dsp_fft64_q7.uasm"
    source_path.write_text(source, encoding="utf-8")
    assembly = uasm.assemble_text(source, PROGRAM_BASE)
    uasm.write_hex(str(output_dir / "dsp_fft64_q7.hex"), assembly)
    uasm.write_listing(str(output_dir / "dsp_fft64_q7.lst"), assembly)
    (output_dir / "dsp_fft64_q7.json").write_text(
        json.dumps(assembly.symbols, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    write_words(output_dir / "fft64_q7_data.hex", pack_words(data_image))
    golden_bytes = [signed_byte(v) for v in golden_real + golden_imag]
    write_words(output_dir / "fft64_q7_golden.hex", pack_words(golden_bytes))
    stage_bytes = [
        signed_byte(value)
        for real, imag in stage_states
        for value in real + imag
    ]
    write_words(output_dir / "fft64_q7_stage_golden.hex",
                pack_words(stage_bytes))
    write_bytes(output_dir / "fft64_q7_input_natural.hex",
                [signed_byte(v) for v in natural_real])
    write_bytes(output_dir / "fft64_q7_input_natural_imag.hex",
                [signed_byte(v) for v in natural_imag])
    write_bytes(output_dir / "fft64_q7_input_bitreversed.hex",
                [signed_byte(v) for v in bit_reversed_real])
    write_bytes(output_dir / "fft64_bfp_exponents.hex",
                [signed_byte(value) for value in exponent_schedule])
    write_input_csv(output_dir / "fft64_input.csv", profile)

    if waveform == "bin8":
        expected_peak_bins = [8, 56]
        golden_peak_values = {
            "bin_8": [golden_real[8], golden_imag[8]],
            "bin_56": [golden_real[56], golden_imag[56]],
        }
    else:
        expected_peak_bins = [5, 13, 23, 41, 51, 59]
        golden_peak_values = {
            f"bin_{index}": [golden_real[index], golden_imag[index]]
            for index in expected_peak_bins
        }

    manifest: dict[str, object] = {
        "algorithm": "radix-2 DIT",
        "points": N,
        "program_base": PROGRAM_BASE,
        "program_words": len(assembly.words),
        "program_end_exclusive": PROGRAM_BASE + 4 * len(assembly.words),
        "data_base": DATA_BASE,
        "data_end_exclusive": DATA_END,
        "data_words": len(data_image) // 4,
        "data_format": "static BFP8: signed int8 mantissa with shared exponent",
        "twiddle_format": "signed Q2.6 byte",
        "number_value": "mantissa * 2^(block_exponent - 7)",
        "input_block_exponent": input_block_exponent,
        "stage_block_exponents": exponent_schedule,
        "output_block_exponent": output_block_exponent,
        "normalization": (
            "one mantissa right shift and one exponent increment per stage; "
            "mantissas are FFT(input)/64 and (mantissa,Eout) is the unscaled FFT"
        ),
        "rounding": "SIMD_OP_NCLIP_S: arithmetic shift plus discarded MSB",
        "memory_map": {
            "work_real": [REAL_BASE, REAL_BASE + N],
            "work_imag": [IMAG_BASE, IMAG_BASE + N],
            "twiddle_real": [TWIDDLE_REAL_BASE, TWIDDLE_REAL_BASE + N // 2],
            "twiddle_imag": [TWIDDLE_IMAG_BASE, TWIDDLE_IMAG_BASE + N // 2],
            "twiddle_neg_real": [TWIDDLE_NEG_REAL_BASE,
                                  TWIDDLE_NEG_REAL_BASE + N // 2],
            "twiddle_neg_imag": [TWIDDLE_NEG_IMAG_BASE,
                                  TWIDDLE_NEG_IMAG_BASE + N // 2],
            "zero_vector": [ZERO_VECTOR_BASE, ZERO_VECTOR_BASE + 2 * LANES],
            "a_indices": [A_INDEX_BASE, A_INDEX_BASE + TOTAL_BATCHES * LANES],
            "b_indices": [B_INDEX_BASE, B_INDEX_BASE + TOTAL_BATCHES * LANES],
            "twiddle_indices": [W_INDEX_BASE,
                                W_INDEX_BASE + TOTAL_BATCHES * LANES],
            "bfp_exponent_in": [BFP_EXPONENT_IN_BASE,
                                BFP_EXPONENT_IN_BASE + LANES],
            "bfp_exponent_out": [BFP_EXPONENT_OUT_BASE,
                                 BFP_EXPONENT_OUT_BASE + LANES],
        },
        "setup_actions": SETUP_ACTIONS,
        "actions_per_batch": ACTIONS_PER_BATCH,
        "batches_per_stage": BATCHES_PER_STAGE,
        "post_fft_actions": POST_FFT_ACTIONS,
        "total_actions": (SETUP_ACTIONS + TOTAL_BATCHES * ACTIONS_PER_BATCH +
                          POST_FFT_ACTIONS + 1),
        "expected_peak_bins": expected_peak_bins,
        "golden_peak_values": golden_peak_values,
    }
    if waveform == "mixed":
        manifest.update(
            {
                "waveform": profile.name,
                "input_decode": profile.input_decode,
                "execution_input_block_exponent": input_block_exponent,
                "execution_number_value": (
                    "code * 2^(execution_input_block_exponent - 7); "
                    "for mixed execution this is code/128"
                ),
                "normalization": (
                    "execution (mantissa,Eout=6) approximates the unscaled "
                    "DFT of code/128; in the requested symmetric code/127 "
                    "coordinates use stored output code * 64/127"
                ),
                "spectrum_output_scale": {
                    "numerator": N,
                    "denominator": 127,
                    "formula": (
                        "symmetric DFT component = stored output code * 64/127"
                    ),
                },
                "components": list(profile.components),
                "dominant_bins": expected_peak_bins,
                "quantization": profile.quantization,
                "quantized_code_range": {
                    "real": [min(natural_real), max(natural_real)],
                    "imag": [min(natural_imag), max(natural_imag)],
                },
            }
        )
    (output_dir / "fft64_q7_manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "fft64_q7_config.svh").write_text(
        "// GENERATED by tools/generate_fft64_vsp.py\n"
        f"`define FFT64_VSP_PROGRAM_WORDS {len(assembly.words)}\n"
        f"`define FFT64_VSP_DATA_WORDS {len(data_image) // 4}\n"
        f"`define FFT64_VSP_TOTAL_ACTIONS {manifest['total_actions']}\n"
        f"`define FFT64_VSP_BFP_INPUT_EXPONENT {input_block_exponent}\n"
        f"`define FFT64_VSP_BFP_OUTPUT_EXPONENT {output_block_exponent}\n",
        encoding="utf-8",
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir", type=pathlib.Path,
        default=pathlib.Path("build/fft64_vsp"),
        help="generated artifact directory (default: build/fft64_vsp)",
    )
    parser.add_argument(
        "--waveform", choices=("bin8", "mixed"), default="bin8",
        help="natural-order input waveform profile (default: bin8)",
    )
    args = parser.parse_args()
    manifest = generate(args.output_dir, waveform=args.waveform)
    peak = manifest["golden_peak_values"]
    print(
        f"generated {manifest['program_words']} program words and "
        f"{manifest['data_words']} SRAM words in {args.output_dir}; "
        f"peaks={peak}, Eout={manifest['output_block_exponent']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
