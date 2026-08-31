#!/usr/bin/env python3
"""Checks for the static algorithm-to-uasm builder boundary."""

from __future__ import annotations

import pathlib
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import vsp_asm_generator as generator  # noqa: E402
import vsp_uword_asm as exact_asm  # noqa: E402


def expect_value_error(operation) -> None:
    try:
        operation()
    except ValueError:
        return
    raise AssertionError("operation unexpectedly accepted an invalid profile value")


def main() -> int:
    # A range allocation is genuinely contiguous even when earlier rows are
    # fragmented; this matters for algorithms which assign VRF row banks.
    allocation = generator.VRFAllocation(num_rows=8, allocated={0, 2})
    assert allocation.alloc_range(2, "bank") == [3, 4]
    assert allocation.allocated == {0, 2, 3, 4}

    # Catch resource/profile mistakes at the schedule layer, before the exact
    # assembler has to diagnose a much larger generated source file.
    expect_value_error(lambda: generator.VSPAsmBuilder().li(32, 0))
    expect_value_error(
        lambda: generator.VSPAsmBuilder().vload(16, 1, span_bytes=16)
    )
    expect_value_error(
        lambda: generator.VSPAsmBuilder().vload(0, 1, span_bytes=64)
    )
    expect_value_error(
        lambda: generator.generate_brightness_loop(byte_count=17)
    )

    expected_word_counts = {
        "brightness_loop": 15,
        "checkerboard": 13,
        "reduction": 8,
        "sliding_window": 17,
    }
    for name, factory in generator.PROGRAMS.items():
        assembly = exact_asm.assemble_text(factory().to_string(), 0x20)
        assert len(assembly.words) == expected_word_counts[name]

    brightness = exact_asm.assemble_text(
        generator.generate_brightness_loop().to_string(), 0x20
    )
    assert brightness.symbols == {"loop": 0x30}

    # The checked-in exact source is the reviewable program.  The builder is
    # an optional algorithm scheduling aid; comparing encoded words prevents
    # the two representations from silently drifting.
    exact_source = (
        REPO_ROOT / "examples/uword/program_brightness_loop.uasm"
    ).read_text(encoding="utf-8")
    checked_in = exact_asm.assemble_text(exact_source, 0x20)
    assert [word.value for word in brightness.words] == [
        word.value for word in checked_in.words
    ]

    # Other algorithm sources currently stop at the stated source-level
    # evidence boundary, but they must not silently become stale syntax.
    source_smokes = {
        "histogram_4bin_test.uasm": 34,
        "pingpong_buffer_test.uasm": 61,
    }
    for filename, expected_words in source_smokes.items():
        source = (REPO_ROOT / "examples/uword" / filename).read_text(
            encoding="utf-8"
        )
        assert len(exact_asm.assemble_text(source, 0).words) == expected_words

    # CLI output belongs under a caller-selected/generated directory.  It no
    # longer deposits transient sources in examples/uword by default.
    with tempfile.TemporaryDirectory() as directory:
        assert generator.main([
            "--program", "brightness_loop",
            "--output-dir", directory,
            "--base-pc", "0x20",
        ]) == 0
        generated = pathlib.Path(directory) / "brightness_loop.uasm"
        generated_program = exact_asm.assemble_text(
            generated.read_text(encoding="utf-8"), 0x20
        )
        assert [word.value for word in generated_program.words] == [
            word.value for word in checked_in.words
        ]

    print(
        "vsp_asm_generator_tb: static resource guards, generated programs "
        "and exact-source equivalence passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
