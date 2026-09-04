#!/usr/bin/env python3
"""Independently compare an FFT64 RTL spectrum with a direct complex DFT.

This verifier deliberately uses only Python's standard library and an O(N^2)
DFT.  It does not import the fixture generator or its staged FFT reference.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import json
import math
import pathlib
import sys
from typing import Iterable, Sequence


FFT_POINTS = 64
INPUT_COLUMNS = (
    "sample",
    "real_code",
    "imag_code",
    "real_value",
    "imag_value",
)
SPECTRUM_COLUMNS = (
    "bin",
    "real_mantissa",
    "imag_mantissa",
    "execution_exponent",
    "value_scale",
    "real_value",
    "imag_value",
    "magnitude",
    "power",
)


@dataclass(frozen=True)
class SpectrumBin:
    index: int
    real_mantissa: int
    imag_mantissa: int
    execution_exponent: int
    value_scale: float
    value: complex
    magnitude: float
    power: float


def _require_finite(value: float, label: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite")
    return value


def _read_rows(path: pathlib.Path, columns: tuple[str, ...]) -> list[dict[str, str]]:
    try:
        with path.open("r", encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source)
            if tuple(reader.fieldnames or ()) != columns:
                raise ValueError(
                    f"{path}: expected CSV columns {','.join(columns)}; got "
                    f"{','.join(reader.fieldnames or ())}"
                )
            return list(reader)
    except OSError as error:
        raise ValueError(f"cannot read {path}: {error}") from error


def read_input_csv(
    path: pathlib.Path, input_code_denominator: int | None = None
) -> list[complex]:
    rows = _read_rows(path, INPUT_COLUMNS)
    if len(rows) != FFT_POINTS:
        raise ValueError(f"{path}: expected {FFT_POINTS} input rows, got {len(rows)}")
    values: list[complex] = []
    for expected_index, row in enumerate(rows):
        try:
            sample = int(row["sample"], 10)
            real_code = int(row["real_code"], 10)
            imag_code = int(row["imag_code"], 10)
            real_value = _require_finite(float(row["real_value"]), "real_value")
            imag_value = _require_finite(float(row["imag_value"]), "imag_value")
        except (KeyError, ValueError) as error:
            raise ValueError(f"{path}: invalid input row {expected_index + 2}: {error}") from error
        if sample != expected_index:
            raise ValueError(f"{path}: expected sample {expected_index}, got {sample}")
        if not (-128 <= real_code <= 127 and -128 <= imag_code <= 127):
            raise ValueError(f"{path}: sample {sample} code is outside signed int8")
        if input_code_denominator is not None:
            if (
                abs(real_code) > input_code_denominator
                or abs(imag_code) > input_code_denominator
            ):
                raise ValueError(
                    f"{path}: sample {sample} code is outside symmetric "
                    f"[-{input_code_denominator},{input_code_denominator}] range"
                )
            expected_real = real_code / input_code_denominator
            expected_imag = imag_code / input_code_denominator
            if not math.isclose(
                real_value, expected_real, rel_tol=1e-12, abs_tol=1e-12
            ):
                raise ValueError(
                    f"{path}: sample {sample} real_value disagrees with "
                    f"real_code/{input_code_denominator}"
                )
            if not math.isclose(
                imag_value, expected_imag, rel_tol=1e-12, abs_tol=1e-12
            ):
                raise ValueError(
                    f"{path}: sample {sample} imag_value disagrees with "
                    f"imag_code/{input_code_denominator}"
                )
        values.append(complex(real_value, imag_value))
    return values


def read_spectrum_csv(path: pathlib.Path) -> list[SpectrumBin]:
    rows = _read_rows(path, SPECTRUM_COLUMNS)
    if len(rows) != FFT_POINTS:
        raise ValueError(f"{path}: expected {FFT_POINTS} spectrum rows, got {len(rows)}")
    result: list[SpectrumBin] = []
    for expected_index, row in enumerate(rows):
        try:
            index = int(row["bin"], 10)
            real_mantissa = int(row["real_mantissa"], 10)
            imag_mantissa = int(row["imag_mantissa"], 10)
            execution_exponent = int(row["execution_exponent"], 10)
            value_scale = _require_finite(float(row["value_scale"]), "value_scale")
            real_value = _require_finite(float(row["real_value"]), "real_value")
            imag_value = _require_finite(float(row["imag_value"]), "imag_value")
            magnitude = _require_finite(float(row["magnitude"]), "magnitude")
            power = _require_finite(float(row["power"]), "power")
        except (KeyError, ValueError) as error:
            raise ValueError(
                f"{path}: invalid spectrum row {expected_index + 2}: {error}"
            ) from error
        if index != expected_index:
            raise ValueError(f"{path}: expected bin {expected_index}, got {index}")
        if not (-128 <= real_mantissa <= 127 and -128 <= imag_mantissa <= 127):
            raise ValueError(f"{path}: bin {index} mantissa is outside signed int8")
        if not -128 <= execution_exponent <= 127:
            raise ValueError(f"{path}: bin {index} exponent is outside signed int8")
        if value_scale <= 0.0:
            raise ValueError(f"{path}: bin {index} value_scale must be positive")
        expected_real = real_mantissa * value_scale
        expected_imag = imag_mantissa * value_scale
        expected_power = real_value * real_value + imag_value * imag_value
        if not math.isclose(real_value, expected_real, rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f"{path}: bin {index} real_value disagrees with mantissa scale")
        if not math.isclose(imag_value, expected_imag, rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f"{path}: bin {index} imag_value disagrees with mantissa scale")
        if not math.isclose(magnitude, math.hypot(real_value, imag_value),
                            rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f"{path}: bin {index} magnitude is inconsistent")
        if not math.isclose(power, expected_power, rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f"{path}: bin {index} power is inconsistent")
        result.append(
            SpectrumBin(
                index=index,
                real_mantissa=real_mantissa,
                imag_mantissa=imag_mantissa,
                execution_exponent=execution_exponent,
                value_scale=value_scale,
                value=complex(real_value, imag_value),
                magnitude=magnitude,
                power=power,
            )
        )
    return result


def direct_dft(samples: Sequence[complex]) -> list[complex]:
    """Return the unnormalized forward DFT using the negative-angle convention."""

    count = len(samples)
    result: list[complex] = []
    for frequency in range(count):
        accumulator = 0j
        for sample_index, sample in enumerate(samples):
            angle = -2.0 * math.pi * frequency * sample_index / count
            accumulator += sample * complex(math.cos(angle), math.sin(angle))
        result.append(accumulator)
    return result


def parse_expected_bins(values: Iterable[str], point_count: int) -> list[int]:
    bins: set[int] = set()
    for value in values:
        for token in value.split(","):
            token = token.strip()
            if not token:
                raise ValueError("expected-bin list contains an empty item")
            try:
                index = int(token, 10)
            except ValueError as error:
                raise ValueError(f"invalid expected bin: {token}") from error
            if not 0 <= index < point_count:
                raise ValueError(f"expected bin {index} is outside 0..{point_count - 1}")
            bins.add(index)
    return sorted(bins)


def expected_bins_from_manifest(path: pathlib.Path, point_count: int) -> list[int]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read manifest {path}: {error}") from error
    components = manifest.get("components") if isinstance(manifest, dict) else None
    if not isinstance(components, list) or not components:
        raise ValueError(f"{path}: manifest has no non-empty components list")
    bins: set[int] = set()
    for component in components:
        if not isinstance(component, dict) or "bin" not in component:
            raise ValueError(f"{path}: each component must contain a bin")
        try:
            index = int(component["bin"])
        except (TypeError, ValueError) as error:
            raise ValueError(f"{path}: invalid component bin") from error
        if not 0 <= index < point_count:
            raise ValueError(f"{path}: component bin {index} is outside FFT range")
        bins.add(index)
        bins.add((-index) % point_count)
    return sorted(bins)


def _top_bins(values: Sequence[complex], count: int) -> list[int]:
    return sorted(range(len(values)), key=lambda index: (-abs(values[index]), index))[:count]


def _phase_difference(left: float, right: float) -> float:
    return math.atan2(math.sin(left - right), math.cos(left - right))


def _symmetry_error(values: Sequence[complex]) -> float:
    return max(
        abs(values[index] - values[(-index) % len(values)].conjugate())
        for index in range(len(values))
    )


def analyze(
    samples: Sequence[complex],
    rtl_bins: Sequence[SpectrumBin],
    expected_bins: Sequence[int],
    *,
    max_complex_error: float,
    max_rms_complex_error: float,
    max_conjugate_symmetry_error: float,
    max_parseval_relative_error: float,
) -> tuple[list[complex], list[dict[str, float | int]], dict[str, object]]:
    if len(samples) != len(rtl_bins):
        raise ValueError("input and spectrum point counts differ")
    reference = direct_dft(samples)
    rtl = [item.value for item in rtl_bins]
    errors = [rtl_value - reference_value for rtl_value, reference_value in zip(rtl, reference)]
    complex_errors = [abs(value) for value in errors]
    max_error = max(complex_errors)
    max_error_bin = complex_errors.index(max_error)
    rms_error = math.sqrt(sum(value * value for value in complex_errors) / len(errors))
    top_count = len(expected_bins) if expected_bins else min(8, len(reference))
    reference_top = _top_bins(reference, top_count)
    rtl_top = _top_bins(rtl, top_count)

    input_energy = sum(abs(value) ** 2 for value in samples)
    reference_parseval_energy = sum(abs(value) ** 2 for value in reference) / len(reference)
    rtl_parseval_energy = sum(abs(value) ** 2 for value in rtl) / len(rtl)
    parseval_absolute_error = abs(rtl_parseval_energy - input_energy)
    parseval_relative_error = parseval_absolute_error / max(input_energy, 1e-300)
    real_input = all(abs(value.imag) <= 1e-12 for value in samples)
    reference_symmetry_error = _symmetry_error(reference)
    rtl_symmetry_error = _symmetry_error(rtl)

    comparisons: list[dict[str, float | int]] = []
    for index, (reference_value, rtl_value, error) in enumerate(zip(reference, rtl, errors)):
        comparisons.append(
            {
                "bin": index,
                "reference_real": reference_value.real,
                "reference_imag": reference_value.imag,
                "reference_magnitude": abs(reference_value),
                "reference_power": abs(reference_value) ** 2,
                "rtl_real": rtl_value.real,
                "rtl_imag": rtl_value.imag,
                "rtl_magnitude": abs(rtl_value),
                "rtl_power": abs(rtl_value) ** 2,
                "error_real": error.real,
                "error_imag": error.imag,
                "complex_error": abs(error),
            }
        )

    peak_metrics: dict[str, object] = {}
    peak_indices = list(expected_bins) if expected_bins else reference_top
    for index in peak_indices:
        reference_phase = math.atan2(reference[index].imag, reference[index].real)
        rtl_phase = math.atan2(rtl[index].imag, rtl[index].real)
        peak_metrics[str(index)] = {
            "reference_magnitude": abs(reference[index]),
            "reference_phase_radians": reference_phase,
            "rtl_magnitude": abs(rtl[index]),
            "rtl_phase_radians": rtl_phase,
            "magnitude_error": abs(rtl[index]) - abs(reference[index]),
            "phase_error_radians": _phase_difference(rtl_phase, reference_phase),
        }

    failures: list[str] = []
    expected_set = set(expected_bins)
    if expected_bins and set(reference_top) != expected_set:
        failures.append(
            f"reference top bins {sorted(reference_top)} != expected {sorted(expected_set)}"
        )
    if expected_bins and set(rtl_top) != expected_set:
        failures.append(f"RTL top bins {sorted(rtl_top)} != expected {sorted(expected_set)}")
    if max_error > max_complex_error:
        failures.append(
            f"max complex error {max_error:.9g} exceeds {max_complex_error:.9g}"
        )
    if rms_error > max_rms_complex_error:
        failures.append(
            f"RMS complex error {rms_error:.9g} exceeds {max_rms_complex_error:.9g}"
        )
    if real_input and rtl_symmetry_error > max_conjugate_symmetry_error:
        failures.append(
            "conjugate symmetry error "
            f"{rtl_symmetry_error:.9g} exceeds {max_conjugate_symmetry_error:.9g}"
        )
    if parseval_relative_error > max_parseval_relative_error:
        failures.append(
            "Parseval relative error "
            f"{parseval_relative_error:.9g} exceeds {max_parseval_relative_error:.9g}"
        )

    metrics: dict[str, object] = {
        "passed": not failures,
        "points": len(samples),
        "expected_bins": list(expected_bins),
        "reference_top_bins": reference_top,
        "rtl_top_bins": rtl_top,
        "max_complex_error": max_error,
        "max_complex_error_bin": max_error_bin,
        "rms_complex_error": rms_error,
        "input_energy": input_energy,
        "reference_parseval_energy": reference_parseval_energy,
        "rtl_parseval_energy": rtl_parseval_energy,
        "parseval_absolute_error": parseval_absolute_error,
        "parseval_relative_error": parseval_relative_error,
        "real_input": real_input,
        "reference_conjugate_symmetry_error": reference_symmetry_error,
        "conjugate_symmetry_error": rtl_symmetry_error,
        "peaks": peak_metrics,
        "thresholds": {
            "max_complex_error": max_complex_error,
            "max_rms_complex_error": max_rms_complex_error,
            "max_conjugate_symmetry_error": max_conjugate_symmetry_error,
            "max_parseval_relative_error": max_parseval_relative_error,
        },
        "failures": failures,
    }
    return reference, comparisons, metrics


def _write_csv(path: pathlib.Path, columns: Sequence[str], rows: Iterable[Sequence[object]]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as output:
            writer = csv.writer(output, lineterminator="\n")
            writer.writerow(columns)
            writer.writerows(rows)
    except OSError as error:
        raise ValueError(f"cannot write {path}: {error}") from error


def write_reference_csv(path: pathlib.Path, reference: Sequence[complex]) -> None:
    _write_csv(
        path,
        ("bin", "reference_real", "reference_imag", "reference_magnitude", "reference_power"),
        (
            (
                index,
                format(value.real, ".17g"),
                format(value.imag, ".17g"),
                format(abs(value), ".17g"),
                format(abs(value) ** 2, ".17g"),
            )
            for index, value in enumerate(reference)
        ),
    )


def write_comparison_csv(path: pathlib.Path, comparisons: Sequence[dict[str, float | int]]) -> None:
    columns = (
        "bin",
        "reference_real",
        "reference_imag",
        "reference_magnitude",
        "reference_power",
        "rtl_real",
        "rtl_imag",
        "rtl_magnitude",
        "rtl_power",
        "error_real",
        "error_imag",
        "complex_error",
    )
    _write_csv(
        path,
        columns,
        (
            tuple(row[column] if column == "bin" else format(float(row[column]), ".17g")
                  for column in columns)
            for row in comparisons
        ),
    )


def write_metrics_json(path: pathlib.Path, metrics: dict[str, object]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot write {path}: {error}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_csv", type=pathlib.Path)
    parser.add_argument("spectrum_csv", type=pathlib.Path)
    parser.add_argument("--reference-csv", type=pathlib.Path, required=True)
    parser.add_argument("--comparison-csv", type=pathlib.Path, required=True)
    parser.add_argument("--metrics-json", type=pathlib.Path, required=True)
    parser.add_argument(
        "--input-code-denominator", type=int,
        help=(
            "validate input real/imag values as code divided by this positive "
            "symmetric full-scale denominator (127 rejects code -128)"
        ),
    )
    parser.add_argument(
        "--expected-bins", "--expected-bin", dest="expected_bins", action="append",
        default=[], metavar="BIN[,BIN...]",
    )
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument("--max-complex-error", type=float, default=0.75)
    parser.add_argument("--max-rms-complex-error", type=float, default=0.25)
    parser.add_argument("--max-conjugate-symmetry-error", type=float, default=0.75)
    parser.add_argument("--max-parseval-relative-error", type=float, default=0.05)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        thresholds = (
            args.max_complex_error,
            args.max_rms_complex_error,
            args.max_conjugate_symmetry_error,
            args.max_parseval_relative_error,
        )
        if any(not math.isfinite(value) or value < 0.0 for value in thresholds):
            raise ValueError("all error thresholds must be finite and non-negative")
        if (
            args.input_code_denominator is not None
            and args.input_code_denominator <= 0
        ):
            raise ValueError("input code denominator must be positive")
        samples = read_input_csv(args.input_csv, args.input_code_denominator)
        rtl_bins = read_spectrum_csv(args.spectrum_csv)
        if args.expected_bins:
            expected_bins = parse_expected_bins(args.expected_bins, len(samples))
        elif args.manifest is not None:
            expected_bins = expected_bins_from_manifest(args.manifest, len(samples))
        else:
            expected_bins = []
        reference, comparisons, metrics = analyze(
            samples,
            rtl_bins,
            expected_bins,
            max_complex_error=args.max_complex_error,
            max_rms_complex_error=args.max_rms_complex_error,
            max_conjugate_symmetry_error=args.max_conjugate_symmetry_error,
            max_parseval_relative_error=args.max_parseval_relative_error,
        )
        metrics["input_code_denominator"] = args.input_code_denominator
        write_reference_csv(args.reference_csv, reference)
        write_comparison_csv(args.comparison_csv, comparisons)
        write_metrics_json(args.metrics_json, metrics)
    except ValueError as error:
        print(f"FAIL verify_fft64_spectrum: {error}", file=sys.stderr)
        return 2

    status = "PASS" if metrics["passed"] else "FAIL"
    print(
        f"{status} verify_fft64_spectrum: max_error={metrics['max_complex_error']:.9g}, "
        f"rms_error={metrics['rms_complex_error']:.9g}, "
        f"top_bins={metrics['rtl_top_bins']}, "
        f"parseval_relative_error={metrics['parseval_relative_error']:.9g}"
    )
    if not metrics["passed"]:
        for failure in metrics["failures"]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
