#!/usr/bin/env python3
"""Render a 64-sample complex time-domain CSV with Graphviz neato.

This tool intentionally depends only on the Python standard library and
Graphviz.  Pinned node coordinates plus ``neato -n2`` keep the generated plot
geometry deterministic.
"""

from __future__ import annotations

import argparse
import csv
import math
import pathlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, Sequence


INPUT_COLUMNS = (
    "sample",
    "real_code",
    "imag_code",
    "real_value",
    "imag_value",
)

SAMPLE_COUNT = 64
PLOT_LEFT = 95.0
PLOT_RIGHT = 815.0
PLOT_BOTTOM = 100.0
PLOT_TOP = 510.0
VALUE_REL_TOL = 1e-9
VALUE_ABS_TOL = 1e-12


@dataclass(frozen=True)
class InputSample:
    sample: int
    real_code: int
    imag_code: int
    real_value: float
    imag_value: float


def _parse_int(value: str, *, row_number: int, column: str) -> int:
    try:
        return int(value, 10)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"row {row_number}: {column} must be a base-10 integer, got {value!r}"
        ) from exc


def _parse_float(value: str, *, row_number: int, column: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"row {row_number}: {column} must be numeric, got {value!r}"
        ) from exc
    if not math.isfinite(result):
        raise ValueError(f"row {row_number}: {column} must be finite, got {value!r}")
    return result


def _expect_decoded_value(
    actual: float,
    code: int,
    denominator: int,
    *,
    row_number: int,
    column: str,
) -> None:
    expected = code / denominator
    if not math.isclose(
        actual, expected, rel_tol=VALUE_REL_TOL, abs_tol=VALUE_ABS_TOL
    ):
        raise ValueError(
            f"row {row_number}: {column}={actual!r} is inconsistent with "
            f"code/denominator={code}/{denominator}={expected!r}"
        )


def read_input_csv(path: pathlib.Path, denominator: int) -> list[InputSample]:
    if denominator <= 0:
        raise ValueError("--input-code-denominator must be positive")
    try:
        input_file = path.open("r", encoding="utf-8", newline="")
    except OSError as exc:
        raise ValueError(f"cannot open CSV {path}: {exc}") from exc

    with input_file:
        reader = csv.DictReader(input_file)
        if reader.fieldnames is None:
            raise ValueError(f"CSV {path} has no header")
        fieldnames = tuple(name.strip() for name in reader.fieldnames)
        if fieldnames != INPUT_COLUMNS:
            raise ValueError(
                f"CSV {path} columns must be {', '.join(INPUT_COLUMNS)}; "
                f"got {', '.join(fieldnames)}"
            )

        samples: list[InputSample] = []
        for row_number, raw in enumerate(reader, start=2):
            if None in raw:
                raise ValueError(f"row {row_number}: too many CSV fields")
            normalized = {
                (key or "").strip(): (value or "").strip()
                for key, value in raw.items()
            }
            sample = InputSample(
                sample=_parse_int(
                    normalized["sample"], row_number=row_number, column="sample"
                ),
                real_code=_parse_int(
                    normalized["real_code"],
                    row_number=row_number,
                    column="real_code",
                ),
                imag_code=_parse_int(
                    normalized["imag_code"],
                    row_number=row_number,
                    column="imag_code",
                ),
                real_value=_parse_float(
                    normalized["real_value"],
                    row_number=row_number,
                    column="real_value",
                ),
                imag_value=_parse_float(
                    normalized["imag_value"],
                    row_number=row_number,
                    column="imag_value",
                ),
            )
            samples.append(sample)

    if len(samples) != SAMPLE_COUNT:
        raise ValueError(
            f"CSV {path} must contain exactly {SAMPLE_COUNT} data rows; "
            f"got {len(samples)}"
        )
    actual_indices = [sample.sample for sample in samples]
    expected_indices = list(range(SAMPLE_COUNT))
    if actual_indices != expected_indices:
        raise ValueError("sample values must be ordered and contiguous from 0 through 63")

    for row_number, sample in enumerate(samples, start=2):
        for column, code in (
            ("real_code", sample.real_code),
            ("imag_code", sample.imag_code),
        ):
            if not -128 <= code <= 127:
                raise ValueError(f"row {row_number}: {column} is outside signed int8")
            if denominator == 127 and code == -128:
                raise ValueError(
                    f"row {row_number}: {column}=-128 is invalid for symmetric q/127"
                )
        _expect_decoded_value(
            sample.real_value,
            sample.real_code,
            denominator,
            row_number=row_number,
            column="real_value",
        )
        _expect_decoded_value(
            sample.imag_value,
            sample.imag_code,
            denominator,
            row_number=row_number,
            column="imag_value",
        )

    return samples


def _dot_quote(text: str) -> str:
    return (
        '"'
        + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        + '"'
    )


def _nice_number(value: float) -> float:
    if value <= 0.0:
        return 1.0
    exponent = math.floor(math.log10(value))
    fraction = value / (10.0**exponent)
    if fraction < 1.5:
        nice_fraction = 1.0
    elif fraction < 3.0:
        nice_fraction = 2.0
    elif fraction < 7.0:
        nice_fraction = 5.0
    else:
        nice_fraction = 10.0
    return nice_fraction * (10.0**exponent)


def _format_number(value: float) -> str:
    if math.isclose(value, 0.0, abs_tol=1e-12):
        return "0"
    if abs(value) >= 10000.0 or abs(value) < 0.001:
        return f"{value:.3e}"
    return f"{value:.6g}"


def _axis_limit(samples: Sequence[InputSample]) -> tuple[float, float]:
    maximum = max(
        abs(value)
        for sample in samples
        for value in (sample.real_value, sample.imag_value)
    )
    if maximum == 0.0:
        return 1.0, 0.25
    tick = _nice_number(maximum / 4.0)
    limit = math.ceil(maximum / tick) * tick
    if math.isclose(limit, maximum, rel_tol=VALUE_REL_TOL):
        limit += tick
    return limit, tick


def _tick_samples(maximum_ticks: int = 9) -> list[int]:
    return sorted(
        {
            round(index * (SAMPLE_COUNT - 1) / (maximum_ticks - 1))
            for index in range(maximum_ticks)
        }
    )


def _extrema(
    samples: Sequence[InputSample], attribute: str
) -> tuple[InputSample, InputSample]:
    minimum = min(samples, key=lambda sample: (getattr(sample, attribute), sample.sample))
    maximum = max(samples, key=lambda sample: (getattr(sample, attribute), -sample.sample))
    return minimum, maximum


def build_dot(samples: Sequence[InputSample], title: str) -> str:
    axis_limit, y_tick = _axis_limit(samples)
    value_span = 2.0 * axis_limit

    def x_position(sample_index: int) -> float:
        return PLOT_LEFT + (PLOT_RIGHT - PLOT_LEFT) * sample_index / (
            SAMPLE_COUNT - 1
        )

    def y_position(value: float) -> float:
        return PLOT_BOTTOM + (PLOT_TOP - PLOT_BOTTOM) * (
            value + axis_limit
        ) / value_span

    lines = [
        "graph fft_input_time_domain {",
        "  graph [layout=neato, overlap=true, splines=false, outputorder=edgesfirst, bgcolor=white, margin=0.08];",
        "  node [fontname=Helvetica, fontsize=10, margin=0, pin=true];",
        "  edge [fontname=Helvetica, fontsize=9];",
        f"  title [shape=plaintext, fontsize=18, label={_dot_quote(title)}, pos=\"455,565!\"];",
        "  x_axis_l [shape=point, width=0.01, label=\"\", pos=\"95,100!\"];",
        "  x_axis_r [shape=point, width=0.01, label=\"\", pos=\"830,100!\"];",
        "  y_axis_b [shape=point, width=0.01, label=\"\", pos=\"95,100!\"];",
        "  y_axis_t [shape=point, width=0.01, label=\"\", pos=\"95,525!\"];",
        "  x_axis_l -- x_axis_r [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  y_axis_b -- y_axis_t [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  x_label [shape=plaintext, label=\"sample n\", pos=\"455,47!\"];",
        "  y_label [shape=plaintext, label=\"decoded\\ninput value\", pos=\"25,305!\"];",
    ]

    y_value = -axis_limit
    y_index = 0
    while y_value <= axis_limit + y_tick * 0.25:
        y = y_position(min(y_value, axis_limit))
        is_zero = math.isclose(y_value, 0.0, abs_tol=y_tick * 1e-9)
        grid_color = "#666666" if is_zero else "#dedede"
        grid_width = 1.4 if is_zero else 0.6
        lines.extend(
            (
                f"  yg_l_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_LEFT:.3f},{y:.3f}!\"];",
                f"  yg_r_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_RIGHT:.3f},{y:.3f}!\"];",
                f"  yg_l_{y_index} -- yg_r_{y_index} [color={_dot_quote(grid_color)}, penwidth={grid_width:.1f}];",
                f"  yl_{y_index} [shape=plaintext, label={_dot_quote(_format_number(y_value))}, pos=\"65,{y:.3f}!\"];",
            )
        )
        y_value += y_tick
        y_index += 1

    for index, sample_index in enumerate(_tick_samples()):
        x = x_position(sample_index)
        lines.extend(
            (
                f"  xg_b_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_BOTTOM:.3f}!\"];",
                f"  xg_t_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_TOP:.3f}!\"];",
                f"  xg_b_{index} -- xg_t_{index} [color=\"#eeeeee\", penwidth=0.5];",
                f"  xl_{index} [shape=plaintext, label=\"{sample_index}\", pos=\"{x:.3f},76!\"];",
            )
        )

    series = (
        ("real", "#d62728", "circle", "real_value", "real_code"),
        ("imag", "#1f77b4", "box", "imag_value", "imag_code"),
    )
    for name, color, shape, value_attribute, code_attribute in series:
        for index, sample in enumerate(samples):
            value = getattr(sample, value_attribute)
            code = getattr(sample, code_attribute)
            x = x_position(sample.sample)
            y = y_position(value)
            tooltip = (
                f"sample={sample.sample}, {name}={_format_number(value)}, code={code}"
            )
            lines.append(
                f"  {name}_{index} [shape={shape}, fixedsize=true, width=0.052, "
                f"height=0.052, label=\"\", color={_dot_quote(color)}, "
                f"fillcolor={_dot_quote(color)}, style=filled, "
                f"tooltip={_dot_quote(tooltip)}, pos=\"{x:.3f},{y:.3f}!\"];"
            )
        for index in range(SAMPLE_COUNT - 1):
            lines.append(
                f"  {name}_{index} -- {name}_{index + 1} "
                f"[color={_dot_quote(color)}, penwidth=1.7];"
            )

    real_min, real_max = _extrema(samples, "real_value")
    imag_min, imag_max = _extrema(samples, "imag_value")
    summary = (
        f"real: min {_format_number(real_min.real_value)} @ {real_min.sample}, "
        f"max {_format_number(real_max.real_value)} @ {real_max.sample}\n"
        f"imag: min {_format_number(imag_min.imag_value)} @ {imag_min.sample}, "
        f"max {_format_number(imag_max.imag_value)} @ {imag_max.sample}"
    )
    lines.append(
        f"  range_summary [shape=box, style=\"rounded,filled\", color=\"#888888\", "
        f"fillcolor=\"#ffffffdd\", fontsize=9, label={_dot_quote(summary)}, "
        "pos=\"650,535!\"] ;"
    )

    legend_y = 22.0
    for index, (x, color, label) in enumerate(
        ((365.0, "#d62728", "real"), (525.0, "#1f77b4", "imag"))
    ):
        lines.extend(
            (
                f"  legend_l_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{legend_y:.3f}!\"];",
                f"  legend_r_{index} [shape=point, width=0.01, label=\"\", pos=\"{x + 35.0:.3f},{legend_y:.3f}!\"];",
                f"  legend_l_{index} -- legend_r_{index} [color={_dot_quote(color)}, penwidth=2.5];",
                f"  legend_text_{index} [shape=plaintext, label={_dot_quote(label)}, pos=\"{x + 72.0:.3f},{legend_y:.3f}!\"];",
            )
        )

    lines.append("}")
    return "\n".join(lines) + "\n"


def render(
    neato: str, dot_path: pathlib.Path, output_path: pathlib.Path, fmt: str
) -> None:
    command = [neato, "-n2", f"-T{fmt}", str(dot_path), "-o", str(output_path)]
    try:
        subprocess.run(command, check=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"Graphviz renderer not found: {neato}") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Graphviz {fmt} rendering failed with exit code {exc.returncode}"
        ) from exc


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render an FFT64 complex input waveform using Graphviz neato."
    )
    parser.add_argument("input_csv", type=pathlib.Path, help="64-row input CSV")
    parser.add_argument(
        "--output-prefix",
        required=True,
        type=pathlib.Path,
        help="output path without extension",
    )
    parser.add_argument("--title", default="FFT64 input waveform", help="plot title")
    parser.add_argument(
        "--neato",
        default="neato",
        help="Graphviz neato executable (default: neato from PATH)",
    )
    parser.add_argument(
        "--input-code-denominator",
        type=int,
        default=127,
        help="decode scale for real/imag code values (default: 127)",
    )
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        samples = read_input_csv(args.input_csv, args.input_code_denominator)
        if args.output_prefix.name in ("", ".", ".."):
            raise ValueError("--output-prefix must include a file name")
        args.output_prefix.parent.mkdir(parents=True, exist_ok=True)

        neato = (
            shutil.which(args.neato)
            if pathlib.Path(args.neato).name == args.neato
            else args.neato
        )
        if not neato:
            raise RuntimeError(
                f"Graphviz renderer {args.neato!r} was not found; "
                "install Graphviz or pass --neato"
            )

        dot_path = pathlib.Path(f"{args.output_prefix}.dot")
        svg_path = pathlib.Path(f"{args.output_prefix}.svg")
        png_path = pathlib.Path(f"{args.output_prefix}.png")
        dot_path.write_text(build_dot(samples, args.title), encoding="utf-8")
        render(neato, dot_path, svg_path, "svg")
        render(neato, dot_path, png_path, "png")
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(f"wrote {dot_path}")
    print(f"wrote {svg_path}")
    print(f"wrote {png_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
