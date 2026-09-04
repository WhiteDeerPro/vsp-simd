#!/usr/bin/env python3
"""Pure numerical regression for the VSP static BFP8 contract."""

from __future__ import annotations

import math
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import vsp_bfp  # noqa: E402


def reference_round_shift_clip(value: int, shift: int, bits: int = 8) -> int:
    """Exact integer oracle for floor(value / 2**shift + 1/2)."""

    divisor = 1 << shift
    quotient, remainder = divmod(value, divisor)
    rounded = quotient + (2 * remainder >= divisor)
    minimum = -(1 << (bits - 1))
    maximum = (1 << (bits - 1)) - 1
    return max(minimum, min(maximum, rounded))


class StaticBfp8Test(unittest.TestCase):
    def test_format_and_decode(self) -> None:
        self.assertEqual(vsp_bfp.MANTISSA_FRACTION_BITS, 7)
        self.assertEqual(vsp_bfp.decode(64, 0), 0.5)
        self.assertEqual(vsp_bfp.decode(-128, 0), -1.0)
        self.assertEqual(vsp_bfp.decode(127, 1), 127.0 / 64.0)
        self.assertEqual(vsp_bfp.decode(1, -128), math.ldexp(1.0, -135))

    def test_round_to_nearest_up_positive_and_negative(self) -> None:
        cases = {
            (0, 1): 0,
            (1, 1): 1,
            (2, 1): 1,
            (3, 1): 2,
            (4, 1): 2,
            (5, 1): 3,
            (-1, 1): 0,
            (-2, 1): -1,
            (-3, 1): -1,
            (-4, 1): -2,
            (-5, 1): -2,
            (6, 2): 2,
            (-6, 2): -1,
        }
        for (value, shift), expected in cases.items():
            with self.subTest(value=value, shift=shift):
                self.assertEqual(
                    vsp_bfp.round_shift_clip(value, shift), expected
                )

    def test_signed_saturation(self) -> None:
        self.assertEqual(vsp_bfp.round_shift_clip(127, 0), 127)
        self.assertEqual(vsp_bfp.round_shift_clip(128, 0), 127)
        self.assertEqual(vsp_bfp.round_shift_clip(255, 1), 127)
        self.assertEqual(vsp_bfp.round_shift_clip(-128, 0), -128)
        self.assertEqual(vsp_bfp.round_shift_clip(-129, 0), -128)
        self.assertEqual(vsp_bfp.round_shift_clip(-259, 1), -128)
        self.assertEqual(vsp_bfp.round_shift_clip(32767, 0, bits=16), 32767)
        self.assertEqual(vsp_bfp.round_shift_clip(65535, 1, bits=16), 32767)

    def test_rtl_rounding_oracle_sweep(self) -> None:
        for shift in range(13):
            for value in range(-4096, 4096):
                self.assertEqual(
                    vsp_bfp.round_shift_clip(value, shift),
                    reference_round_shift_clip(value, shift),
                    (value, shift),
                )

    def test_rtl_rounding_int32_and_full_shift_boundaries(self) -> None:
        int32_min = -(1 << 31)
        int32_max = (1 << 31) - 1
        accumulator_boundaries = {
            int32_min,
            int32_min + 1,
            int32_min + 2,
            -(1 << 30) - 1,
            -(1 << 30),
            -(1 << 30) + 1,
            -1,
            0,
            1,
            (1 << 30) - 1,
            1 << 30,
            (1 << 30) + 1,
            int32_max - 2,
            int32_max - 1,
            int32_max,
        }

        for shift in range(32):
            divisor = 1 << shift
            values = set(accumulator_boundaries)

            # Exercise both sides of ties and the signed-int8 clipping limits
            # at every legal RTL shift, where those products fit int32.
            for quotient in (-129, -128, -127, -1, 0, 1, 126, 127, 128):
                offsets = {0}
                if shift:
                    half = divisor >> 1
                    offsets.update((half - 1, half, half + 1))
                for offset in offsets:
                    value = quotient * divisor + offset
                    if int32_min <= value <= int32_max:
                        values.add(value)

            for value in sorted(values):
                with self.subTest(value=value, shift=shift):
                    self.assertEqual(
                        vsp_bfp.round_shift_clip(value, shift),
                        reference_round_shift_clip(value, shift),
                    )

    def test_stage_exponents_include_input_and_each_stage(self) -> None:
        self.assertEqual(
            vsp_bfp.stage_exponents(-3, 6), [-3, -2, -1, 0, 1, 2, 3]
        )
        self.assertEqual(vsp_bfp.stage_exponents(127, 0), [127])
        self.assertEqual(vsp_bfp.stage_exponents(121, 6)[-1], 127)

    def test_fft64_static_scale_reconstruction(self) -> None:
        sample_count = 64
        input_exponent = -2
        output_exponent = vsp_bfp.stage_exponents(input_exponent, 6)[-1]

        # With Ein=-2, mantissa 96 decodes to 0.1875.  Its transform is exact
        # and saturation-free: the stored DC mantissa remains 96 after six /2
        # stages, while Eout=4 restores the unscaled FFT sum of 12.0.
        input_mantissas = [96] * sample_count
        stored_dc_mantissa = 96
        expected_dc = sum(
            vsp_bfp.decode(value, input_exponent)
            for value in input_mantissas
        )
        self.assertEqual(
            vsp_bfp.decode(stored_dc_mantissa, output_exponent), expected_dc
        )

        # More generally, incrementing E by log2(N) reverses FFT/N storage.
        for mantissa in (-128, -64, -1, 0, 1, 64, 127):
            with self.subTest(mantissa=mantissa):
                self.assertEqual(
                    vsp_bfp.decode(mantissa, output_exponent),
                    sample_count * vsp_bfp.decode(mantissa, input_exponent),
                )

    def test_input_validation(self) -> None:
        for exponent in (-128, -1, 0, 126, 127):
            self.assertEqual(vsp_bfp.validate_exponent(exponent), exponent)

        for invalid in (-129, 128):
            with self.assertRaises(ValueError):
                vsp_bfp.validate_exponent(invalid)
        for invalid in (False, 1.0, "1", None):
            with self.assertRaises(TypeError):
                vsp_bfp.validate_exponent(invalid)  # type: ignore[arg-type]

        for invalid in (-129, 128):
            with self.assertRaises(ValueError):
                vsp_bfp.decode(invalid, 0)
        with self.assertRaises(ValueError):
            vsp_bfp.decode(0, 128)

        with self.assertRaises(ValueError):
            vsp_bfp.stage_exponents(122, 6)
        with self.assertRaises(ValueError):
            vsp_bfp.stage_exponents(0, -1)
        with self.assertRaises(TypeError):
            vsp_bfp.stage_exponents(0, True)

        for invalid_shift in (-1, 32):
            with self.assertRaises(ValueError):
                vsp_bfp.round_shift_clip(0, invalid_shift)
        for invalid_bits in (1, 33):
            with self.assertRaises(ValueError):
                vsp_bfp.round_shift_clip(0, 0, invalid_bits)
        for invalid_value in (-(1 << 31) - 1, 1 << 31):
            with self.assertRaises(ValueError):
                vsp_bfp.round_shift_clip(invalid_value, 0)
        with self.assertRaises(TypeError):
            vsp_bfp.round_shift_clip(True, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
