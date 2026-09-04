#!/usr/bin/env python3
"""Unit regression for the independent FFT64 direct-DFT verifier."""

from __future__ import annotations

import csv
import json
import math
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import verify_fft64_spectrum as verifier  # noqa: E402


def write_input(path: pathlib.Path, values: list[complex]) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(verifier.INPUT_COLUMNS)
        for index, value in enumerate(values):
            writer.writerow(
                (
                    index,
                    max(-128, min(127, round(value.real * 127))),
                    max(-128, min(127, round(value.imag * 127))),
                    format(value.real, ".17g"),
                    format(value.imag, ".17g"),
                )
            )


def quantized_spectrum(values: list[complex], scale: float) -> list[complex]:
    result: list[complex] = []
    for value in values:
        real_mantissa = round(value.real / scale)
        imag_mantissa = round(value.imag / scale)
        if not (-128 <= real_mantissa <= 127 and -128 <= imag_mantissa <= 127):
            raise AssertionError("test spectrum does not fit signed int8")
        result.append(complex(real_mantissa * scale, imag_mantissa * scale))
    return result


def write_spectrum(path: pathlib.Path, values: list[complex], scale: float) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(verifier.SPECTRUM_COLUMNS)
        for index, value in enumerate(values):
            real_mantissa = round(value.real / scale)
            imag_mantissa = round(value.imag / scale)
            power = value.real * value.real + value.imag * value.imag
            writer.writerow(
                (
                    index,
                    real_mantissa,
                    imag_mantissa,
                    0,
                    format(scale, ".17g"),
                    format(value.real, ".17g"),
                    format(value.imag, ".17g"),
                    format(math.sqrt(power), ".17g"),
                    format(power, ".17g"),
                )
            )


class Fft64SpectrumVerifierTest(unittest.TestCase):
    def test_symmetric_input_scale_is_checked_from_codes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            input_csv = pathlib.Path(temporary) / "input.csv"

            def write_first_sample(code: int, value: float) -> None:
                with input_csv.open("w", encoding="utf-8", newline="") as output:
                    writer = csv.writer(output, lineterminator="\n")
                    writer.writerow(verifier.INPUT_COLUMNS)
                    for index in range(verifier.FFT_POINTS):
                        writer.writerow(
                            (
                                index,
                                code if index == 0 else 0,
                                0,
                                format(value if index == 0 else 0.0, ".17g"),
                                "0",
                            )
                        )

            write_first_sample(1, 1.0 / 127.0)
            parsed = verifier.read_input_csv(input_csv, 127)
            self.assertAlmostEqual(parsed[0].real, 1.0 / 127.0)

            write_first_sample(1, 1.0 / 128.0)
            with self.assertRaisesRegex(ValueError, "real_code/127"):
                verifier.read_input_csv(input_csv, 127)

            write_first_sample(-128, -1.0)
            with self.assertRaisesRegex(ValueError, "symmetric.*127"):
                verifier.read_input_csv(input_csv, 127)

    def test_exact_impulse_direct_dft(self) -> None:
        samples = [0j] * verifier.FFT_POINTS
        samples[0] = 1.0 + 0j
        reference = verifier.direct_dft(samples)
        self.assertEqual(reference, [1.0 + 0j] * verifier.FFT_POINTS)

        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            input_csv = directory / "input.csv"
            spectrum_csv = directory / "spectrum.csv"
            write_input(input_csv, samples)
            write_spectrum(spectrum_csv, reference, 1.0)
            parsed_input = verifier.read_input_csv(input_csv)
            parsed_spectrum = verifier.read_spectrum_csv(spectrum_csv)
            _, _, metrics = verifier.analyze(
                parsed_input,
                parsed_spectrum,
                [],
                max_complex_error=1e-12,
                max_rms_complex_error=1e-12,
                max_conjugate_symmetry_error=1e-12,
                max_parseval_relative_error=1e-12,
            )
            self.assertTrue(metrics["passed"])
            self.assertEqual(metrics["max_complex_error"], 0.0)
            self.assertEqual(metrics["parseval_relative_error"], 0.0)

    def test_cosine_top_bins_and_exports(self) -> None:
        tone_bin = 5
        samples = [
            complex(0.5 * math.cos(2.0 * math.pi * tone_bin * index /
                                   verifier.FFT_POINTS), 0.0)
            for index in range(verifier.FFT_POINTS)
        ]
        reference = verifier.direct_dft(samples)
        rtl = quantized_spectrum(reference, 0.25)

        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            input_csv = directory / "input.csv"
            spectrum_csv = directory / "spectrum.csv"
            reference_csv = directory / "reference.csv"
            comparison_csv = directory / "comparison.csv"
            metrics_json = directory / "metrics.json"
            write_input(input_csv, samples)
            write_spectrum(spectrum_csv, rtl, 0.25)
            result = verifier.main(
                [
                    str(input_csv),
                    str(spectrum_csv),
                    "--reference-csv", str(reference_csv),
                    "--comparison-csv", str(comparison_csv),
                    "--metrics-json", str(metrics_json),
                    "--expected-bins", "5,59",
                    "--max-complex-error", "1e-10",
                    "--max-rms-complex-error", "1e-10",
                    "--max-conjugate-symmetry-error", "1e-10",
                    "--max-parseval-relative-error", "1e-10",
                ]
            )
            self.assertEqual(result, 0)
            self.assertEqual(len(reference_csv.read_text(encoding="utf-8").splitlines()), 65)
            comparison_lines = comparison_csv.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(comparison_lines), 65)
            self.assertIn("complex_error", comparison_lines[0])
            metrics = json.loads(metrics_json.read_text(encoding="utf-8"))
            self.assertTrue(metrics["passed"])
            self.assertEqual(set(metrics["rtl_top_bins"]), {5, 59})
            self.assertIn("5", metrics["peaks"])
            self.assertIn("rtl_phase_radians", metrics["peaks"]["5"])

    def test_manifest_bin_derivation_and_repeated_lists(self) -> None:
        self.assertEqual(
            verifier.parse_expected_bins(("5,13", "23"), 64),
            [5, 13, 23],
        )
        with tempfile.TemporaryDirectory() as temporary:
            manifest = pathlib.Path(temporary) / "manifest.json"
            manifest.write_text(
                json.dumps({"components": [{"bin": 5}, {"bin": 13}, {"bin": 0}]}),
                encoding="utf-8",
            )
            self.assertEqual(
                verifier.expected_bins_from_manifest(manifest, 64),
                [0, 5, 13, 51, 59],
            )

    def test_intentional_wrong_spectrum_returns_failure(self) -> None:
        tone_bin = 5
        samples = [
            complex(0.5 * math.cos(2.0 * math.pi * tone_bin * index / 64), 0.0)
            for index in range(64)
        ]
        reference = quantized_spectrum(verifier.direct_dft(samples), 0.25)
        reference[6] = reference[5]
        reference[5] = 0j

        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            input_csv = directory / "input.csv"
            spectrum_csv = directory / "spectrum.csv"
            write_input(input_csv, samples)
            write_spectrum(spectrum_csv, reference, 0.25)
            result = verifier.main(
                [
                    str(input_csv),
                    str(spectrum_csv),
                    "--reference-csv", str(directory / "reference.csv"),
                    "--comparison-csv", str(directory / "comparison.csv"),
                    "--metrics-json", str(directory / "metrics.json"),
                    "--expected-bin", "5", "--expected-bin", "59",
                ]
            )
            self.assertEqual(result, 1)
            metrics = json.loads((directory / "metrics.json").read_text(encoding="utf-8"))
            self.assertFalse(metrics["passed"])
            self.assertTrue(any("RTL top bins" in item for item in metrics["failures"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
