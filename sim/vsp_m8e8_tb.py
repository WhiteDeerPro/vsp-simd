#!/usr/bin/env python3
"""Bit-exact unit regression for the proposed VSP M8E8 oracle and ABI."""

from __future__ import annotations

from fractions import Fraction
import pathlib
import random
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import vsp_m8e8 as m8  # noqa: E402


def canonical_mantissas() -> tuple[int, ...]:
    return tuple(range(-127, -63)) + tuple(range(64, 128))


class M8E8Test(unittest.TestCase):
    def test_known_exact_values_and_canonical_zero(self) -> None:
        cases = {
            Fraction(0): m8.ZERO,
            Fraction(1, 4): m8.M8E8(64, -1),
            Fraction(1, 2): m8.M8E8(64, 0),
            Fraction(127, 128): m8.M8E8(127, 0),
            Fraction(1): m8.M8E8(64, 1),
            Fraction(-1): m8.M8E8(-64, 1),
        }
        for exact, expected in cases.items():
            with self.subTest(exact=exact):
                result = m8.quantize(exact)
                self.assertEqual(result.number, expected)
                self.assertEqual(m8.decode(result.number), exact)
                self.assertFalse(result.overflow)
                self.assertFalse(result.underflow)
                self.assertFalse(result.inexact)

        with self.assertRaisesRegex(ValueError, "canonical zero"):
            m8.M8E8(0, 1)

    def test_normalization_and_negative_128_renormalization(self) -> None:
        # Raw (-128, E=0) denotes -1 and must become canonical (-64, E=1).
        result = m8.quantize(Fraction(-128, 128))
        self.assertEqual(result.number, m8.M8E8(-64, 1))
        self.assertFalse(result.inexact)

        with self.assertRaisesRegex(ValueError, "M=-128"):
            m8.M8E8(-128, 0)
        for mantissa in (-63, -1, 1, 63):
            with self.subTest(mantissa=mantissa):
                with self.assertRaisesRegex(ValueError, "normalized"):
                    m8.M8E8(mantissa, 0)

    def test_round_nearest_up_ties(self) -> None:
        # At E=0 one mantissa ulp is 1/128.  Halfway cases therefore have an
        # odd numerator over 256.  Both signs resolve toward +infinity.
        positive = m8.quantize(Fraction(129, 256))
        negative = m8.quantize(Fraction(-129, 256))
        self.assertEqual(positive.number, m8.M8E8(65, 0))
        self.assertEqual(negative.number, m8.M8E8(-64, 0))
        self.assertTrue(positive.inexact)
        self.assertTrue(negative.inexact)

        # Crossing +127.5 renormalizes; -127.5 rounds upward to -127.
        self.assertEqual(
            m8.quantize(Fraction(255, 256)).number, m8.M8E8(64, 1)
        )
        self.assertEqual(
            m8.quantize(Fraction(-255, 256)).number, m8.M8E8(-127, 0)
        )

    def test_underflow_flush_zero_and_symmetric_overflow(self) -> None:
        self.assertEqual(m8.MIN_NORMAL, Fraction(1, 1 << 129))
        for sign in (-1, 1):
            minimum = m8.quantize(sign * m8.MIN_NORMAL)
            self.assertEqual(minimum.number, m8.M8E8(sign * 64, -128))
            self.assertFalse(minimum.underflow)

            underflow = m8.quantize(sign * m8.MIN_NORMAL / 2)
            self.assertEqual(underflow.number, m8.ZERO)
            self.assertTrue(underflow.underflow)
            self.assertTrue(underflow.inexact)
            self.assertFalse(underflow.overflow)

        for sign in (-1, 1):
            endpoint = m8.quantize(sign * m8.MAX_FINITE)
            self.assertEqual(endpoint.number, m8.M8E8(sign * 127, 127))
            self.assertFalse(endpoint.overflow)

            overflow = m8.quantize(sign * (m8.MAX_FINITE + 1))
            self.assertEqual(overflow.number, m8.M8E8(sign * 127, 127))
            self.assertTrue(overflow.overflow)
            self.assertTrue(overflow.inexact)
            self.assertFalse(overflow.underflow)

    def test_add_sub_mul_and_status(self) -> None:
        half = m8.M8E8(64, 0)
        quarter = m8.M8E8(64, -1)
        minus_half = m8.M8E8(-64, 0)

        self.assertEqual(m8.add(half, quarter).number, m8.M8E8(96, 0))
        self.assertEqual(m8.sub(half, quarter).number, quarter)
        self.assertEqual(m8.mul(half, half).number, quarter)
        self.assertEqual(m8.add(half, minus_half), m8.M8E8Result(m8.ZERO))

        largest = m8.M8E8(127, 127)
        overflow = m8.add(largest, largest)
        self.assertEqual(overflow.number, largest)
        self.assertTrue(overflow.overflow)

        smallest = m8.M8E8(64, -128)
        underflow = m8.mul(smallest, half)
        self.assertEqual(underflow.number, m8.ZERO)
        self.assertTrue(underflow.underflow)

    def test_twos_complement_and_soa_abi(self) -> None:
        signed = (-128, -127, -64, -1, 0, 1, 64, 127)
        expected = (0x80, 0x81, 0xC0, 0xFF, 0x00, 0x01, 0x40, 0x7F)
        self.assertEqual(tuple(map(m8.encode_signed_byte, signed)), expected)
        self.assertEqual(tuple(map(m8.decode_signed_byte, expected)), signed)

        numbers = [m8.ZERO, m8.M8E8(-64, 1), m8.M8E8(127, -2)]
        mantissas, exponents = m8.pack_soa(numbers)
        self.assertEqual(mantissas, bytes((0x00, 0xC0, 0x7F)))
        self.assertEqual(exponents, bytes((0x00, 0x01, 0xFE)))
        self.assertEqual(m8.unpack_soa(mantissas, exponents), numbers)

    def test_exhaustive_canonical_round_trip_and_unique_encoding(self) -> None:
        decoded: set[Fraction] = {Fraction(0)}
        count = 1
        for exponent in range(-128, 128):
            for mantissa in canonical_mantissas():
                number = m8.M8E8(mantissa, exponent)
                exact = m8.decode(number)
                result = m8.quantize(exact)
                self.assertEqual(result.number, number)
                self.assertFalse(result.inexact)
                self.assertNotIn(exact, decoded)
                decoded.add(exact)
                count += 1
        self.assertEqual(count, 32769)
        self.assertEqual(len(decoded), count)

    def test_seeded_random_arithmetic_properties(self) -> None:
        rng = random.Random(0x8E8)
        mantissas = canonical_mantissas()
        for _ in range(3000):
            left = m8.M8E8(rng.choice(mantissas), rng.randrange(-128, 128))
            right = m8.M8E8(rng.choice(mantissas), rng.randrange(-128, 128))

            add_lr = m8.add(left, right)
            add_rl = m8.add(right, left)
            mul_lr = m8.mul(left, right)
            mul_rl = m8.mul(right, left)
            self.assertEqual(add_lr, add_rl)
            self.assertEqual(mul_lr, mul_rl)

            for result, exact in (
                (add_lr, m8.decode(left) + m8.decode(right)),
                (m8.sub(left, right), m8.decode(left) - m8.decode(right)),
                (mul_lr, m8.decode(left) * m8.decode(right)),
            ):
                self.assertEqual(result, m8.quantize(exact))
                if not result.overflow and not result.underflow:
                    self.assertEqual(result.inexact, m8.decode(result.number) != exact)

    def test_input_validation(self) -> None:
        for invalid in (False, 0.5, "1", None):
            with self.assertRaises(TypeError):
                m8.quantize(invalid)  # type: ignore[arg-type]
        for invalid in (-129, 128):
            with self.assertRaises(ValueError):
                m8.M8E8(64, invalid)
            with self.assertRaises(ValueError):
                m8.encode_signed_byte(invalid)
        for invalid in (-1, 256):
            with self.assertRaises(ValueError):
                m8.decode_signed_byte(invalid)
        with self.assertRaises(ValueError):
            m8.unpack_soa(bytes((0x40,)), bytes())
        with self.assertRaises(TypeError):
            m8.pack_soa([m8.ZERO, 1])  # type: ignore[list-item]


if __name__ == "__main__":
    unittest.main(verbosity=2)
