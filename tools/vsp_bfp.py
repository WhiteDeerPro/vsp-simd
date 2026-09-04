#!/usr/bin/env python3
"""Bit-exact helpers for VSP's static signed BFP8 convention.

A block stores signed 8-bit mantissas and one signed 8-bit exponent ``E``.
Each decoded element is::

    x = mantissa * 2 ** (E - 7)

The exponent is normally replicated into 16 byte lanes when it is consumed by
VSP microcode.  This module models the numerical contract; it does not model
the replicated in-memory representation.
"""

from __future__ import annotations

import math


MANTISSA_FRACTION_BITS = 7
ACCUMULATOR_BITS = 32

_SIGNED_BYTE_MIN = -(1 << 7)
_SIGNED_BYTE_MAX = (1 << 7) - 1
_SIGNED_ACC_MIN = -(1 << (ACCUMULATOR_BITS - 1))
_SIGNED_ACC_MAX = (1 << (ACCUMULATOR_BITS - 1)) - 1

__all__ = [
    "MANTISSA_FRACTION_BITS",
    "decode",
    "round_shift_clip",
    "stage_exponents",
    "validate_exponent",
    "validate_mantissa",
]


def _require_int(name: str, value: object) -> int:
    """Return a plain integer and reject booleans and non-integer values."""

    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an integer, got {type(value).__name__}")
    return value


def _validate_signed_byte(name: str, value: object) -> int:
    integer = _require_int(name, value)
    if not _SIGNED_BYTE_MIN <= integer <= _SIGNED_BYTE_MAX:
        raise ValueError(
            f"{name} must fit signed int8 "
            f"({_SIGNED_BYTE_MIN}..{_SIGNED_BYTE_MAX}), got {integer}"
        )
    return integer


def validate_mantissa(mantissa: int) -> int:
    """Validate and return one signed BFP8 mantissa."""

    return _validate_signed_byte("mantissa", mantissa)


def validate_exponent(exponent: int) -> int:
    """Validate and return the shared signed int8 block exponent."""

    return _validate_signed_byte("exponent", exponent)


def round_shift_clip(value: int, shift: int, bits: int = 8) -> int:
    """Match ``SIMD_OP_NCLIP_S`` for a signed 32-bit accumulator.

    RTL first performs an arithmetic right shift, adds the most-significant
    discarded bit, and then saturates to the requested signed result width.
    This is round-to-nearest-up: exact half-way cases, including negative
    ones, round toward positive infinity.

    ``value`` is the signed interpretation of the 32-bit ARF lane.  ``shift``
    consequently accepts the hardware range 0..31.  ``bits`` is kept explicit
    for narrow-width reference tests; VSP BFP8 uses the default value of 8.
    """

    integer = _require_int("value", value)
    amount = _require_int("shift", shift)
    width = _require_int("bits", bits)

    if not _SIGNED_ACC_MIN <= integer <= _SIGNED_ACC_MAX:
        raise ValueError(
            f"value must fit signed int{ACCUMULATOR_BITS} "
            f"({_SIGNED_ACC_MIN}..{_SIGNED_ACC_MAX}), got {integer}"
        )
    if not 0 <= amount < ACCUMULATOR_BITS:
        raise ValueError(
            f"shift must be in the RTL range 0..{ACCUMULATOR_BITS - 1}, "
            f"got {amount}"
        )
    if not 2 <= width <= ACCUMULATOR_BITS:
        raise ValueError(
            f"bits must be in the range 2..{ACCUMULATOR_BITS}, got {width}"
        )

    round_bit = 0 if amount == 0 else (integer >> (amount - 1)) & 1
    rounded = (integer >> amount) + round_bit

    minimum = -(1 << (width - 1))
    maximum = (1 << (width - 1)) - 1
    return max(minimum, min(maximum, rounded))


def stage_exponents(input_exponent: int, stages: int) -> list[int]:
    """Return input and per-stage exponents for mandatory divide-by-two stages.

    A static BFP stage narrows each mantissa by one bit and increments the
    shared exponent.  The returned list therefore has ``stages + 1`` entries.
    Any sequence that would overflow signed int8 is rejected before execution.
    """

    initial = validate_exponent(input_exponent)
    count = _require_int("stages", stages)
    if count < 0:
        raise ValueError(f"stages must be non-negative, got {count}")

    return [validate_exponent(initial + stage) for stage in range(count + 1)]


def decode(mantissa: int, exponent: int) -> float:
    """Decode one BFP8 mantissa using its block exponent."""

    coefficient = validate_mantissa(mantissa)
    block_exponent = validate_exponent(exponent)
    return math.ldexp(
        float(coefficient), block_exponent - MANTISSA_FRACTION_BITS
    )
