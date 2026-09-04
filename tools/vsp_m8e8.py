#!/usr/bin/env python3
"""Bit-exact numerical oracle for VSP's per-element M8E8 format.

M8E8 stores a signed int8 mantissa and a signed int8 exponent, without a
separate sign bit.  Its exact value is::

    value = mantissa * 2 ** (exponent - 7)

This module defines the proposed numerical and memory-ABI contract.  It is a
software oracle, not an RTL implementation or a claim that VSP executes M8E8.
All arithmetic uses :class:`fractions.Fraction`; Python binary floating point
is deliberately not part of the reference path.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from typing import Iterable, Sequence


MANTISSA_BITS = 8
EXPONENT_BITS = 8
MANTISSA_FRACTION_BITS = 7
MIN_EXPONENT = -128
MAX_EXPONENT = 127
MIN_NORMAL_MANTISSA = 64
MAX_NORMAL_MANTISSA = 127


def _pow2(exponent: int) -> Fraction:
    if exponent >= 0:
        return Fraction(1 << exponent, 1)
    return Fraction(1, 1 << -exponent)


MIN_NORMAL = Fraction(MIN_NORMAL_MANTISSA) * _pow2(
    MIN_EXPONENT - MANTISSA_FRACTION_BITS
)
MAX_FINITE = Fraction(MAX_NORMAL_MANTISSA) * _pow2(
    MAX_EXPONENT - MANTISSA_FRACTION_BITS
)


def _require_plain_int(name: str, value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an integer, got {type(value).__name__}")
    return value


def _require_fraction(value: object) -> Fraction:
    """Accept exact rational inputs while rejecting floats and booleans."""

    if isinstance(value, bool) or not isinstance(value, (int, Fraction)):
        raise TypeError(
            "value must be an int or fractions.Fraction; "
            f"got {type(value).__name__}"
        )
    return Fraction(value)


def _signed_byte(value: object, name: str) -> int:
    integer = _require_plain_int(name, value)
    if not -128 <= integer <= 127:
        raise ValueError(f"{name} must fit signed int8 (-128..127), got {integer}")
    return integer


def encode_signed_byte(value: int) -> int:
    """Encode a signed int8 as its unsigned two's-complement byte."""

    return _signed_byte(value, "value") & 0xFF


def decode_signed_byte(value: int) -> int:
    """Decode one unsigned byte as signed two's-complement int8."""

    byte = _require_plain_int("value", value)
    if not 0 <= byte <= 0xFF:
        raise ValueError(f"value must fit an unsigned byte (0..255), got {byte}")
    return byte - 0x100 if byte & 0x80 else byte


@dataclass(frozen=True, slots=True)
class M8E8:
    """One canonical M8E8 datum."""

    mantissa: int
    exponent: int

    def __post_init__(self) -> None:
        mantissa = _signed_byte(self.mantissa, "mantissa")
        exponent = _signed_byte(self.exponent, "exponent")
        if mantissa == 0:
            if exponent != 0:
                raise ValueError("canonical zero must be encoded as M=0, E=0")
            return
        if not MIN_NORMAL_MANTISSA <= abs(mantissa) <= MAX_NORMAL_MANTISSA:
            raise ValueError(
                "nonzero mantissa must be normalized with 64 <= abs(M) <= 127; "
                "M=-128 must be renormalized as M=-64, E=E+1"
            )

    @property
    def mantissa_byte(self) -> int:
        return encode_signed_byte(self.mantissa)

    @property
    def exponent_byte(self) -> int:
        return encode_signed_byte(self.exponent)


ZERO = M8E8(0, 0)


@dataclass(frozen=True, slots=True)
class M8E8Result:
    """A rounded result plus explicit exceptional and precision status."""

    number: M8E8
    overflow: bool = False
    underflow: bool = False
    inexact: bool = False

    def __post_init__(self) -> None:
        if self.overflow and self.underflow:
            raise ValueError("overflow and underflow cannot both be asserted")


def decode(number: M8E8) -> Fraction:
    """Decode one M8E8 datum to an exact rational value."""

    if not isinstance(number, M8E8):
        raise TypeError(f"number must be M8E8, got {type(number).__name__}")
    return Fraction(number.mantissa) * _pow2(
        number.exponent - MANTISSA_FRACTION_BITS
    )


def _floor_log2_positive(value: Fraction) -> int:
    """Return floor(log2(value)) for an exact positive rational."""

    if value <= 0:
        raise ValueError("value must be positive")
    estimate = value.numerator.bit_length() - value.denominator.bit_length()
    if value < _pow2(estimate):
        estimate -= 1
    return estimate


def _round_nearest_up(value: Fraction) -> int:
    """Round to nearest integer, resolving exact ties toward +infinity."""

    shifted = value + Fraction(1, 2)
    return shifted.numerator // shifted.denominator


def quantize(value: int | Fraction) -> M8E8Result:
    """Quantize an exact rational to canonical M8E8.

    Values smaller in magnitude than the minimum normalized value flush to
    canonical zero and assert ``underflow``.  Values beyond either symmetric
    finite endpoint saturate to ``(+/-127, 127)`` and assert ``overflow``.
    Otherwise the mantissa is rounded to nearest with exact ties toward
    positive infinity, matching the existing ``NCLIP_S`` convention.
    """

    exact = _require_fraction(value)
    if exact == 0:
        return M8E8Result(ZERO)

    if abs(exact) < MIN_NORMAL:
        return M8E8Result(ZERO, underflow=True, inexact=True)

    if exact > MAX_FINITE:
        return M8E8Result(
            M8E8(MAX_NORMAL_MANTISSA, MAX_EXPONENT),
            overflow=True,
            inexact=True,
        )
    if exact < -MAX_FINITE:
        return M8E8Result(
            M8E8(-MAX_NORMAL_MANTISSA, MAX_EXPONENT),
            overflow=True,
            inexact=True,
        )

    exponent = _floor_log2_positive(abs(exact)) + 1
    # The range checks above make these unreachable for a correct oracle, but
    # retain explicit guards so format changes cannot silently wrap int8 E.
    if exponent < MIN_EXPONENT:
        return M8E8Result(ZERO, underflow=True, inexact=True)
    if exponent > MAX_EXPONENT:
        saturated = MAX_NORMAL_MANTISSA if exact > 0 else -MAX_NORMAL_MANTISSA
        return M8E8Result(
            M8E8(saturated, MAX_EXPONENT), overflow=True, inexact=True
        )

    scale = _pow2(exponent - MANTISSA_FRACTION_BITS)
    mantissa = _round_nearest_up(exact / scale)

    # +128 and -128 are not canonical.  Renormalization is exact for -128;
    # +128 can arise after rounding at the top of a binade.
    if mantissa == 128:
        mantissa = 64
        exponent += 1
    elif mantissa == -128:
        mantissa = -64
        exponent += 1

    if exponent > MAX_EXPONENT:
        saturated = MAX_NORMAL_MANTISSA if exact > 0 else -MAX_NORMAL_MANTISSA
        return M8E8Result(
            M8E8(saturated, MAX_EXPONENT), overflow=True, inexact=True
        )

    number = M8E8(mantissa, exponent)
    return M8E8Result(number, inexact=(decode(number) != exact))


def _require_number(name: str, number: object) -> M8E8:
    if not isinstance(number, M8E8):
        raise TypeError(f"{name} must be M8E8, got {type(number).__name__}")
    return number


def add(left: M8E8, right: M8E8) -> M8E8Result:
    """Add two M8E8 values with one final format rounding."""

    return quantize(
        decode(_require_number("left", left))
        + decode(_require_number("right", right))
    )


def sub(left: M8E8, right: M8E8) -> M8E8Result:
    """Subtract two M8E8 values with one final format rounding."""

    return quantize(
        decode(_require_number("left", left))
        - decode(_require_number("right", right))
    )


def mul(left: M8E8, right: M8E8) -> M8E8Result:
    """Multiply two M8E8 values with one final format rounding."""

    return quantize(
        decode(_require_number("left", left))
        * decode(_require_number("right", right))
    )


def pack_soa(numbers: Iterable[M8E8]) -> tuple[bytes, bytes]:
    """Pack values as separate mantissa and exponent byte arrays (SoA)."""

    materialized = list(numbers)
    for index, number in enumerate(materialized):
        _require_number(f"numbers[{index}]", number)
    return (
        bytes(number.mantissa_byte for number in materialized),
        bytes(number.exponent_byte for number in materialized),
    )


def unpack_soa(mantissas: Sequence[int], exponents: Sequence[int]) -> list[M8E8]:
    """Decode equal-length SoA byte arrays into canonical M8E8 values."""

    if len(mantissas) != len(exponents):
        raise ValueError(
            "mantissa and exponent arrays must have equal length, got "
            f"{len(mantissas)} and {len(exponents)}"
        )
    return [
        M8E8(decode_signed_byte(mantissa), decode_signed_byte(exponent))
        for mantissa, exponent in zip(mantissas, exponents)
    ]


__all__ = [
    "EXPONENT_BITS",
    "MAX_EXPONENT",
    "MAX_FINITE",
    "MAX_NORMAL_MANTISSA",
    "MANTISSA_BITS",
    "MANTISSA_FRACTION_BITS",
    "MIN_EXPONENT",
    "MIN_NORMAL",
    "MIN_NORMAL_MANTISSA",
    "M8E8",
    "M8E8Result",
    "ZERO",
    "add",
    "decode",
    "decode_signed_byte",
    "encode_signed_byte",
    "mul",
    "pack_soa",
    "quantize",
    "sub",
    "unpack_soa",
]
