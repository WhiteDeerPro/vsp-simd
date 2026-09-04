#!/usr/bin/env python3
"""Independent numerical and compatibility checks for FFT64 fixtures."""

from __future__ import annotations

import cmath
import csv
import hashlib
import json
import math
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import generate_fft64_vsp as fft_fixture  # noqa: E402


N = 64
MIXED_BINS = {5, 13, 23, 41, 51, 59}


def direct_dft(values: list[complex] | tuple[float, ...]) -> list[complex]:
    """Straight O(N^2) DFT, intentionally independent of the FFT model."""

    return [
        sum(
            values[sample]
            * cmath.exp(-2j * math.pi * frequency * sample / len(values))
            for sample in range(len(values))
        )
        for frequency in range(len(values))
    ]


class Fft64FixtureTest(unittest.TestCase):
    def test_mixed_quantization_range_symmetry_and_no_clipping(self) -> None:
        profile = fft_fixture.make_waveform_profile("mixed")
        self.assertEqual(profile.input_block_exponent, 0)
        self.assertEqual(len(profile.natural_real), N)
        self.assertEqual(min(profile.natural_real), -94)
        self.assertEqual(max(profile.natural_real), 94)
        self.assertNotIn(-128, profile.natural_real)
        self.assertTrue(all(-127 <= code <= 127 for code in profile.natural_real))
        self.assertTrue(all(code == 0 for code in profile.natural_imag))

        for sample in range(N // 2):
            self.assertEqual(
                profile.natural_real[sample + N // 2],
                -profile.natural_real[sample],
            )

        independently_quantized = tuple(
            max(-127, min(127, math.floor(127.0 * value + 0.5)))
            for value in profile.ideal_real
        )
        self.assertEqual(profile.natural_real, independently_quantized)
        self.assertLess(max(map(abs, profile.ideal_real)), 1.0)
        self.assertAlmostEqual(max(map(abs, profile.ideal_real)), 0.7439158597967501)

    def test_mixed_analytic_and_quantized_direct_dft(self) -> None:
        profile = fft_fixture.make_waveform_profile("mixed")
        analytic = direct_dft(profile.ideal_real)
        expected_analytic = {
            5: complex(12.8, 0.0),
            59: complex(12.8, 0.0),
            13: cmath.rect(8.96, math.pi / 4.0),
            51: cmath.rect(8.96, -math.pi / 4.0),
            23: cmath.rect(5.12, -math.pi / 3.0),
            41: cmath.rect(5.12, math.pi / 3.0),
        }
        for frequency, expected in expected_analytic.items():
            with self.subTest(kind="analytic", frequency=frequency):
                self.assertLess(abs(analytic[frequency] - expected), 1e-12)
        self.assertLess(
            max(abs(value) for index, value in enumerate(analytic)
                if index not in MIXED_BINS),
            1e-12,
        )

        decoded = [code / 127.0 for code in profile.natural_real]
        quantized = direct_dft(decoded)
        expected_quantized = {
            5: complex(12.783387826806376, -0.006941841300890983),
            59: complex(12.78338782680638, 0.0069418413010178814),
            13: complex(6.315980897434353, 6.382686407872111),
            51: complex(6.315980897434404, -6.382686407872071),
            23: complex(2.5656321251960867, -4.468569362698614),
            41: complex(2.565632125195975, 4.46856936269864),
        }
        for frequency, expected in expected_quantized.items():
            with self.subTest(kind="quantized", frequency=frequency):
                self.assertLess(abs(quantized[frequency] - expected), 1e-12)

        strongest = {
            index for index, _value in sorted(
                enumerate(quantized), key=lambda item: abs(item[1]), reverse=True
            )[:6]
        }
        self.assertEqual(strongest, MIXED_BINS)
        max_leakage = max(
            abs(value) for index, value in enumerate(quantized)
            if index not in MIXED_BINS
        )
        self.assertAlmostEqual(max_leakage, 0.03782645014532582, places=12)

    def test_mixed_artifacts_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fft64-mixed-test-") as directory:
            output_dir = pathlib.Path(directory)
            manifest = fft_fixture.generate(output_dir, waveform="mixed")
            self.assertEqual(manifest["waveform"], "mixed")
            self.assertEqual(manifest["input_block_exponent"], 0)
            self.assertEqual(manifest["output_block_exponent"], 6)
            self.assertEqual(manifest["stage_block_exponents"], list(range(7)))
            self.assertEqual(manifest["dominant_bins"], [5, 13, 23, 41, 51, 59])
            self.assertEqual(manifest["quantized_code_range"]["real"], [-94, 94])
            self.assertEqual(
                manifest["spectrum_output_scale"],
                {
                    "numerator": 64,
                    "denominator": 127,
                    "formula": (
                        "symmetric DFT component = stored output code * 64/127"
                    ),
                },
            )
            self.assertIn("DFT of code/128", manifest["normalization"])
            self.assertIn("stored output code * 64/127", manifest["normalization"])

            disk_manifest = json.loads(
                (output_dir / "fft64_q7_manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(disk_manifest, manifest)
            profile = fft_fixture.make_waveform_profile("mixed")
            with (output_dir / "fft64_input.csv").open(
                encoding="utf-8", newline=""
            ) as input_file:
                rows = list(csv.DictReader(input_file))
            self.assertEqual(len(rows), N)
            self.assertEqual(list(rows[0]), [
                "sample", "real_code", "imag_code", "real_value", "imag_value"
            ])
            for sample, row in enumerate(rows):
                self.assertEqual(int(row["sample"]), sample)
                self.assertEqual(int(row["real_code"]),
                                 profile.natural_real[sample])
                self.assertEqual(int(row["imag_code"]), 0)
                self.assertAlmostEqual(
                    float(row["real_value"]), int(row["real_code"]) / 127.0
                )

            imag_hex = (
                output_dir / "fft64_q7_input_natural_imag.hex"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(imag_hex, ["00"] * N)
            exponent_hex = (
                output_dir / "fft64_bfp_exponents.hex"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(exponent_hex, ["00", "01", "02", "03", "04", "05", "06"])
            config = (output_dir / "fft64_q7_config.svh").read_text(
                encoding="utf-8"
            )
            self.assertIn("`define FFT64_VSP_BFP_INPUT_EXPONENT 0", config)
            self.assertIn("`define FFT64_VSP_BFP_OUTPUT_EXPONENT 6", config)

    def test_default_bin8_legacy_artifacts_are_byte_compatible(self) -> None:
        expected_sha256 = {
            "dsp_fft64_q7.hex": "fc61c4ff3fa7ec95240e229fc94da2ffa4fbdbd21cfac8099c6c6f76435b5602",
            "dsp_fft64_q7.json": "1a620d1df79b5eb43479ab3c25446550c553e3819dbf206e0e52d26a971dc8dc",
            "dsp_fft64_q7.lst": "0025987b1ef52f3abcbf830732a522bba76673b4e0cfab9a47ceda4560c31743",
            "dsp_fft64_q7.uasm": "59c5c8187aa0b55ac3c0453b4f19d9a683abfe7342ba6dab5485bc40920bbb22",
            "fft64_bfp_exponents.hex": "532d4ebc61d9974c1bd97ff191255504a1fba1e723b3a734bd1dfc8101d98a25",
            "fft64_q7_config.svh": "a9166b46d712879ff22c6f9f2641e72226ae4e7e9f52165948b93e9672ad34e8",
            "fft64_q7_data.hex": "2171b51034a98e6fb9ea64c4a2d6bf5708943104e40a94af25c474822b24c8bc",
            "fft64_q7_golden.hex": "db4164e5ba2cb80a7f551c268a01e422fc07bcfc594509f62092a02384264a11",
            "fft64_q7_input_bitreversed.hex": "fc6f726a86835b6d65601d2ed974d848d0a352d63127c515d38fb1b1b4aec04f",
            "fft64_q7_input_natural.hex": "8735a50b1bb6bde9a3d766bdb29be367bed5b5365fb640b6c07be2fb6ec559bd",
            "fft64_q7_manifest.json": "b90bf3c9e54df8f4f5cfc4d5a16a4700f793eda655ace590673c2cba6e0d8f4d",
            "fft64_q7_stage_golden.hex": "7431df14ee3b67277c0a4c78038aebcc8c9814a1e001022d3794735798e5f342",
        }
        profile = fft_fixture.make_waveform_profile("bin8")
        self.assertEqual(profile.input_block_exponent, -2)
        with tempfile.TemporaryDirectory(prefix="fft64-bin8-test-") as directory:
            output_dir = pathlib.Path(directory)
            manifest = fft_fixture.generate(output_dir)
            self.assertEqual(manifest["input_block_exponent"], -2)
            self.assertEqual(manifest["output_block_exponent"], 4)
            self.assertEqual(manifest["expected_peak_bins"], [8, 56])
            for filename, expected in expected_sha256.items():
                with self.subTest(filename=filename):
                    actual = hashlib.sha256((output_dir / filename).read_bytes()).hexdigest()
                    self.assertEqual(actual, expected)

    def test_unknown_profile_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown waveform profile"):
            fft_fixture.make_waveform_profile("unknown")


if __name__ == "__main__":
    unittest.main(verbosity=2)
