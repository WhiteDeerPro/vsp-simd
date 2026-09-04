#!/usr/bin/env python3
"""Render an FFT spectrum CSV with Graphviz, without NumPy or Matplotlib.

The legacy input schema contains these columns:

    bin,real_mantissa,imag_mantissa,exponent,
    real_value,imag_value,magnitude,power

The current schema replaces ``exponent`` with the more explicit
``execution_exponent,value_scale`` pair.  Both schemas are accepted.

The generated DOT uses pinned coordinates.  It is rendered with ``neato -n2``
so repeated runs with the same input produce the same geometry.
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


LEGACY_COLUMNS = (
    "bin",
    "real_mantissa",
    "imag_mantissa",
    "exponent",
    "real_value",
    "imag_value",
    "magnitude",
    "power",
)

CURRENT_COLUMNS = (
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

# Keep the original public name for callers that import the tool.
REQUIRED_COLUMNS = LEGACY_COLUMNS
CONSISTENCY_REL_TOL = 1e-6
CONSISTENCY_ABS_TOL = 1e-9
RELATIVE_DB_FLOOR = -80.0
TOP_PEAK_COUNT = 4

PLOT_LEFT = 90.0
PLOT_RIGHT = 810.0
PLOT_BOTTOM = 90.0
PLOT_TOP = 510.0


@dataclass(frozen=True)
class SpectrumRow:
    bin: int
    real_mantissa: int
    imag_mantissa: int
    exponent: int
    real_value: float
    imag_value: float
    magnitude: float
    power: float
    value_scale: float | None = None


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


def read_spectrum(path: pathlib.Path) -> list[SpectrumRow]:
    try:
        input_file = path.open("r", encoding="utf-8", newline="")
    except OSError as exc:
        raise ValueError(f"cannot open CSV {path}: {exc}") from exc

    with input_file:
        reader = csv.DictReader(input_file)
        if reader.fieldnames is None:
            raise ValueError(f"CSV {path} has no header")
        fieldnames = tuple(name.strip() for name in reader.fieldnames)
        if fieldnames not in (LEGACY_COLUMNS, CURRENT_COLUMNS):
            raise ValueError(
                f"CSV {path} columns must be either {', '.join(LEGACY_COLUMNS)} "
                f"or {', '.join(CURRENT_COLUMNS)}; "
                f"got {', '.join(fieldnames)}"
            )
        current_schema = fieldnames == CURRENT_COLUMNS

        rows: list[SpectrumRow] = []
        for row_number, raw in enumerate(reader, start=2):
            if None in raw:
                raise ValueError(f"row {row_number}: too many CSV fields")
            normalized = {(key or "").strip(): (value or "").strip() for key, value in raw.items()}
            rows.append(
                SpectrumRow(
                    bin=_parse_int(normalized["bin"], row_number=row_number, column="bin"),
                    real_mantissa=_parse_int(
                        normalized["real_mantissa"],
                        row_number=row_number,
                        column="real_mantissa",
                    ),
                    imag_mantissa=_parse_int(
                        normalized["imag_mantissa"],
                        row_number=row_number,
                        column="imag_mantissa",
                    ),
                    exponent=_parse_int(
                        normalized["execution_exponent" if current_schema else "exponent"],
                        row_number=row_number,
                        column="execution_exponent" if current_schema else "exponent",
                    ),
                    real_value=_parse_float(
                        normalized["real_value"], row_number=row_number, column="real_value"
                    ),
                    imag_value=_parse_float(
                        normalized["imag_value"], row_number=row_number, column="imag_value"
                    ),
                    magnitude=_parse_float(
                        normalized["magnitude"], row_number=row_number, column="magnitude"
                    ),
                    power=_parse_float(
                        normalized["power"], row_number=row_number, column="power"
                    ),
                    value_scale=(
                        _parse_float(
                            normalized["value_scale"],
                            row_number=row_number,
                            column="value_scale",
                        )
                        if current_schema
                        else None
                    ),
                )
            )

    if not rows:
        raise ValueError(f"CSV {path} contains no data rows")
    if len(rows) < 2:
        raise ValueError("at least two FFT bins are required to draw a spectrum")

    expected_bins = list(range(len(rows)))
    actual_bins = [row.bin for row in rows]
    if actual_bins != expected_bins:
        raise ValueError(
            "bin values must be unique, ordered and contiguous from 0 through N-1; "
            f"got {actual_bins!r}"
        )

    for row_number, row in enumerate(rows, start=2):
        if not -128 <= row.real_mantissa <= 127:
            raise ValueError(f"row {row_number}: real_mantissa is outside signed int8")
        if not -128 <= row.imag_mantissa <= 127:
            raise ValueError(f"row {row_number}: imag_mantissa is outside signed int8")
        if not -128 <= row.exponent <= 127:
            raise ValueError(f"row {row_number}: exponent is outside signed int8")
        if row.value_scale is not None and row.value_scale <= 0.0:
            raise ValueError(f"row {row_number}: value_scale must be positive")
        if row.magnitude < 0.0:
            raise ValueError(f"row {row_number}: magnitude cannot be negative")
        if row.power < 0.0:
            raise ValueError(f"row {row_number}: power cannot be negative")

        expected_magnitude = math.hypot(row.real_value, row.imag_value)
        _expect_close(
            row.magnitude, expected_magnitude, row_number=row_number, relationship="magnitude=hypot(real_value,imag_value)"
        )
        _expect_close(
            row.power, row.magnitude * row.magnitude, row_number=row_number, relationship="power=magnitude^2"
        )
        if row.value_scale is not None:
            _expect_close(
                row.real_value,
                row.real_mantissa * row.value_scale,
                row_number=row_number,
                relationship="real_value=real_mantissa*value_scale",
            )
            _expect_close(
                row.imag_value,
                row.imag_mantissa * row.value_scale,
                row_number=row_number,
                relationship="imag_value=imag_mantissa*value_scale",
            )

    return rows


def _expect_close(
    actual: float, expected: float, *, row_number: int, relationship: str
) -> None:
    if not math.isclose(
        actual,
        expected,
        rel_tol=CONSISTENCY_REL_TOL,
        abs_tol=CONSISTENCY_ABS_TOL,
    ):
        raise ValueError(
            f"row {row_number}: inconsistent {relationship}: "
            f"got {actual!r}, expected {expected!r}"
        )


def _dot_quote(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _nice_number(value: float, *, round_result: bool) -> float:
    if value <= 0.0:
        return 1.0
    exponent = math.floor(math.log10(value))
    fraction = value / (10.0**exponent)
    if round_result:
        if fraction < 1.5:
            nice_fraction = 1.0
        elif fraction < 3.0:
            nice_fraction = 2.0
        elif fraction < 7.0:
            nice_fraction = 5.0
        else:
            nice_fraction = 10.0
    elif fraction <= 1.0:
        nice_fraction = 1.0
    elif fraction <= 2.0:
        nice_fraction = 2.0
    elif fraction <= 5.0:
        nice_fraction = 5.0
    else:
        nice_fraction = 10.0
    return nice_fraction * (10.0**exponent)


def _axis_range(rows: Sequence[SpectrumRow]) -> tuple[float, float, float]:
    values = [0.0]
    for row in rows:
        values.extend((row.real_value, row.imag_value, row.magnitude))
    data_min = min(values)
    data_max = max(values)
    if math.isclose(data_min, data_max, rel_tol=0.0, abs_tol=1e-15):
        data_min -= 1.0
        data_max += 1.0
    raw_range = data_max - data_min
    tick = _nice_number(raw_range / 6.0, round_result=True)
    axis_min = math.floor(data_min / tick) * tick
    axis_max = math.ceil(data_max / tick) * tick
    if axis_min == axis_max:
        axis_max = axis_min + tick
    return axis_min, axis_max, tick


def _format_number(value: float) -> str:
    if math.isclose(value, 0.0, abs_tol=1e-12):
        return "0"
    magnitude = abs(value)
    if magnitude >= 10000.0 or magnitude < 0.001:
        return f"{value:.3e}"
    return f"{value:.6g}"


def _tick_bins(count: int, maximum_ticks: int = 9) -> list[int]:
    tick_count = min(count, maximum_ticks)
    return sorted({round(index * (count - 1) / (tick_count - 1)) for index in range(tick_count)})


def build_dot(rows: Sequence[SpectrumRow], title: str) -> str:
    axis_min, axis_max, y_tick = _axis_range(rows)
    value_span = axis_max - axis_min
    bin_span = len(rows) - 1

    def x_position(bin_number: int) -> float:
        return PLOT_LEFT + (PLOT_RIGHT - PLOT_LEFT) * bin_number / bin_span

    def y_position(value: float) -> float:
        return PLOT_BOTTOM + (PLOT_TOP - PLOT_BOTTOM) * (value - axis_min) / value_span

    lines = [
        "graph fft_spectrum {",
        "  graph [layout=neato, overlap=true, splines=false, outputorder=edgesfirst, bgcolor=white, margin=0.08];",
        "  node [fontname=Helvetica, fontsize=10, margin=0, pin=true];",
        "  edge [fontname=Helvetica, fontsize=9];",
        f"  title [shape=plaintext, fontsize=18, label={_dot_quote(title)}, pos=\"450,550!\"];",
        "  x_axis_l [shape=point, width=0.01, label=\"\", pos=\"90,90!\"];",
        "  x_axis_r [shape=point, width=0.01, label=\"\", pos=\"825,90!\"];",
        "  y_axis_b [shape=point, width=0.01, label=\"\", pos=\"90,90!\"];",
        "  y_axis_t [shape=point, width=0.01, label=\"\", pos=\"90,525!\"];",
        "  x_axis_l -- x_axis_r [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  y_axis_b -- y_axis_t [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  x_label [shape=plaintext, label=\"FFT bin\", pos=\"450,38!\"];",
        "  y_label [shape=plaintext, label=\"decoded\\nvalue\", pos=\"24,300!\"];",
    ]

    y_value = axis_min
    y_index = 0
    while y_value <= axis_max + y_tick * 0.25:
        y = y_position(min(y_value, axis_max))
        lines.extend(
            (
                f"  yg_l_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_LEFT:.3f},{y:.3f}!\"];",
                f"  yg_r_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_RIGHT:.3f},{y:.3f}!\"];",
                f"  yg_l_{y_index} -- yg_r_{y_index} [color=\"#d9d9d9\", penwidth=0.6];",
                f"  yl_{y_index} [shape=plaintext, label={_dot_quote(_format_number(y_value))}, pos=\"62,{y:.3f}!\"];",
            )
        )
        y_value += y_tick
        y_index += 1

    for index, bin_number in enumerate(_tick_bins(len(rows))):
        x = x_position(bin_number)
        lines.extend(
            (
                f"  xg_b_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_BOTTOM:.3f}!\"];",
                f"  xg_t_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_TOP:.3f}!\"];",
                f"  xg_b_{index} -- xg_t_{index} [color=\"#eeeeee\", penwidth=0.5];",
                f"  xl_{index} [shape=plaintext, label=\"{bin_number}\", pos=\"{x:.3f},67!\"];",
            )
        )

    series = (
        ("real", "#d62728", "real", lambda row: row.real_value),
        ("imag", "#1f77b4", "imag", lambda row: row.imag_value),
        ("magnitude", "#2ca02c", "magnitude", lambda row: row.magnitude),
    )
    for series_name, color, _label, getter in series:
        for index, row in enumerate(rows):
            x = x_position(row.bin)
            y = y_position(getter(row))
            tooltip = (
                f"bin={row.bin}, {series_name}={_format_number(getter(row))}, "
                f"M=({row.real_mantissa},{row.imag_mantissa}), E={row.exponent}"
            )
            lines.append(
                f"  {series_name}_{index} [shape=circle, fixedsize=true, width=0.045, "
                f"label=\"\", color={_dot_quote(color)}, fillcolor={_dot_quote(color)}, "
                f"style=filled, tooltip={_dot_quote(tooltip)}, pos=\"{x:.3f},{y:.3f}!\"] ;"
            )
        for index in range(len(rows) - 1):
            lines.append(
                f"  {series_name}_{index} -- {series_name}_{index + 1} "
                f"[color={_dot_quote(color)}, penwidth=2.0];"
            )

    legend_y = 18.0
    legend_entries = ((280.0, "#d62728", "real"), (430.0, "#1f77b4", "imag"), (580.0, "#2ca02c", "magnitude"))
    for index, (x, color, label) in enumerate(legend_entries):
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


def _one_sided_amplitudes(rows: Sequence[SpectrumRow]) -> list[tuple[SpectrumRow, float]]:
    point_count = len(rows)
    highest_bin = point_count // 2
    result: list[tuple[SpectrumRow, float]] = []
    for row in rows[: highest_bin + 1]:
        is_dc = row.bin == 0
        is_nyquist = point_count % 2 == 0 and row.bin == highest_bin
        multiplier = 1.0 if is_dc or is_nyquist else 2.0
        result.append((row, multiplier * row.magnitude / point_count))
    return result


def _relative_db(rows: Sequence[SpectrumRow]) -> list[tuple[SpectrumRow, float]]:
    peak = max(row.magnitude for row in rows)
    if peak == 0.0:
        return [(row, RELATIVE_DB_FLOOR) for row in rows]
    return [
        (
            row,
            max(
                RELATIVE_DB_FLOOR,
                20.0 * math.log10(row.magnitude / peak)
                if row.magnitude > 0.0
                else RELATIVE_DB_FLOOR,
            ),
        )
        for row in rows
    ]


def _positive_axis_range(values: Sequence[float]) -> tuple[float, float, float]:
    maximum = max(values, default=0.0)
    if maximum <= 0.0:
        return 0.0, 1.0, 0.2
    tick = _nice_number(maximum / 5.0, round_result=True)
    axis_max = math.ceil(maximum / tick) * tick
    if math.isclose(axis_max, maximum, rel_tol=CONSISTENCY_REL_TOL):
        axis_max += tick
    return 0.0, axis_max, tick


def _top_peaks(values: Sequence[float], baseline: float) -> list[int]:
    candidates: list[int] = []
    for index, value in enumerate(values):
        if value <= baseline:
            continue
        left = values[index - 1] if index > 0 else baseline
        right = values[index + 1] if index + 1 < len(values) else baseline
        if value >= left and value >= right and (value > left or value > right):
            candidates.append(index)
    candidates.sort(key=lambda index: (-values[index], index))
    return candidates[:TOP_PEAK_COUNT]


def build_stem_dot(rows: Sequence[SpectrumRow], title: str, view: str) -> str:
    if view == "one-sided-amplitude":
        samples = _one_sided_amplitudes(rows)
        axis_min, axis_max, y_tick = _positive_axis_range(
            [value for _row, value in samples]
        )
        baseline = 0.0
        y_axis_label = "one-sided\namplitude"
        color = "#2ca02c"
        legend_label = "one-sided amplitude"
    elif view == "relative-db":
        samples = _relative_db(rows)
        axis_min = RELATIVE_DB_FLOOR
        axis_max = 0.0
        y_tick = 20.0
        baseline = RELATIVE_DB_FLOOR
        y_axis_label = "relative\nmagnitude (dB)"
        color = "#9467bd"
        legend_label = "relative magnitude"
    else:
        raise ValueError(f"unsupported stem view: {view}")

    values = [value for _row, value in samples]
    value_span = axis_max - axis_min
    bin_span = max(1, samples[-1][0].bin - samples[0][0].bin)

    def x_position(bin_number: int) -> float:
        return PLOT_LEFT + (PLOT_RIGHT - PLOT_LEFT) * (
            bin_number - samples[0][0].bin
        ) / bin_span

    def y_position(value: float) -> float:
        return PLOT_BOTTOM + (PLOT_TOP - PLOT_BOTTOM) * (
            value - axis_min
        ) / value_span

    lines = [
        "graph fft_spectrum {",
        "  graph [layout=neato, overlap=true, splines=false, outputorder=edgesfirst, bgcolor=white, margin=0.08];",
        "  node [fontname=Helvetica, fontsize=10, margin=0, pin=true];",
        "  edge [fontname=Helvetica, fontsize=9];",
        f"  title [shape=plaintext, fontsize=18, label={_dot_quote(title)}, pos=\"450,550!\"];",
        "  x_axis_l [shape=point, width=0.01, label=\"\", pos=\"90,90!\"];",
        "  x_axis_r [shape=point, width=0.01, label=\"\", pos=\"825,90!\"];",
        "  y_axis_b [shape=point, width=0.01, label=\"\", pos=\"90,90!\"];",
        "  y_axis_t [shape=point, width=0.01, label=\"\", pos=\"90,525!\"];",
        "  x_axis_l -- x_axis_r [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  y_axis_b -- y_axis_t [color=black, penwidth=1.2, dir=forward, arrowhead=normal];",
        "  x_label [shape=plaintext, label=\"FFT bin\", pos=\"450,38!\"];",
        f"  y_label [shape=plaintext, label={_dot_quote(y_axis_label)}, pos=\"24,300!\"];",
    ]

    y_value = axis_min
    y_index = 0
    while y_value <= axis_max + y_tick * 0.25:
        y = y_position(min(y_value, axis_max))
        lines.extend(
            (
                f"  yg_l_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_LEFT:.3f},{y:.3f}!\"];",
                f"  yg_r_{y_index} [shape=point, width=0.01, label=\"\", pos=\"{PLOT_RIGHT:.3f},{y:.3f}!\"];",
                f"  yg_l_{y_index} -- yg_r_{y_index} [color=\"#d9d9d9\", penwidth=0.6];",
                f"  yl_{y_index} [shape=plaintext, label={_dot_quote(_format_number(y_value))}, pos=\"62,{y:.3f}!\"];",
            )
        )
        y_value += y_tick
        y_index += 1

    tick_bins = _tick_bins(len(samples))
    for index, sample_index in enumerate(tick_bins):
        bin_number = samples[sample_index][0].bin
        x = x_position(bin_number)
        lines.extend(
            (
                f"  xg_b_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_BOTTOM:.3f}!\"];",
                f"  xg_t_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{PLOT_TOP:.3f}!\"];",
                f"  xg_b_{index} -- xg_t_{index} [color=\"#eeeeee\", penwidth=0.5];",
                f"  xl_{index} [shape=plaintext, label=\"{bin_number}\", pos=\"{x:.3f},67!\"];",
            )
        )

    baseline_y = y_position(baseline)
    for index, (row, value) in enumerate(samples):
        x = x_position(row.bin)
        y = y_position(value)
        tooltip = (
            f"bin={row.bin}, {legend_label}={_format_number(value)}, "
            f"|X|={_format_number(row.magnitude)}, "
            f"M=({row.real_mantissa},{row.imag_mantissa}), E={row.exponent}"
        )
        lines.extend(
            (
                f"  stem_base_{index} [shape=point, width=0.01, label=\"\", pos=\"{x:.3f},{baseline_y:.3f}!\"];",
                f"  stem_point_{index} [shape=circle, fixedsize=true, width=0.065, label=\"\", "
                f"color={_dot_quote(color)}, fillcolor={_dot_quote(color)}, style=filled, "
                f"tooltip={_dot_quote(tooltip)}, pos=\"{x:.3f},{y:.3f}!\"];",
                f"  stem_base_{index} -- stem_point_{index} [color={_dot_quote(color)}, penwidth=1.4];",
            )
        )

    for label_index, sample_index in enumerate(_top_peaks(values, baseline)):
        row, value = samples[sample_index]
        x = x_position(row.bin)
        y = y_position(value)
        label_y = min(PLOT_TOP + 24.0, y + 24.0 + 12.0 * (label_index % 2))
        peak_label = f"bin {row.bin}\n{_format_number(value)}"
        lines.append(
            f"  peak_label_{label_index} [shape=plaintext, fontsize=9, "
            f"fontcolor={_dot_quote(color)}, label={_dot_quote(peak_label)}, "
            f"pos=\"{x:.3f},{label_y:.3f}!\"];"
        )

    lines.extend(
        (
            "  legend_l [shape=point, width=0.01, label=\"\", pos=\"365,18!\"];",
            "  legend_r [shape=point, width=0.01, label=\"\", pos=\"405,18!\"];",
            f"  legend_l -- legend_r [color={_dot_quote(color)}, penwidth=2.5];",
            f"  legend_text [shape=plaintext, label={_dot_quote(legend_label)}, pos=\"485,18!\"];",
            "}",
        )
    )
    return "\n".join(lines) + "\n"


def render(neato: str, dot_path: pathlib.Path, output_path: pathlib.Path, fmt: str) -> None:
    command = [neato, "-n2", f"-T{fmt}", str(dot_path), "-o", str(output_path)]
    try:
        subprocess.run(command, check=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"Graphviz renderer not found: {neato}") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"Graphviz {fmt} rendering failed with exit code {exc.returncode}") from exc


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render real, imaginary and magnitude FFT curves using Graphviz neato."
    )
    parser.add_argument("csv", type=pathlib.Path, help="spectrum CSV input")
    parser.add_argument(
        "--output-prefix",
        type=pathlib.Path,
        help="output path without extension (default: INPUT-stem_graphviz beside INPUT)",
    )
    parser.add_argument("--title", help="plot title (default: '<N>-point FFT spectrum')")
    parser.add_argument(
        "--view",
        choices=("components", "one-sided-amplitude", "relative-db"),
        default="components",
        help=(
            "plot view: legacy connected components, discrete one-sided amplitude, "
            "or discrete relative magnitude in dB (default: components)"
        ),
    )
    parser.add_argument(
        "--neato",
        default="neato",
        help="Graphviz neato executable (default: neato from PATH)",
    )
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        rows = read_spectrum(args.csv)
        output_prefix = args.output_prefix
        if output_prefix is None:
            default_suffix = (
                "graphviz" if args.view == "components" else args.view.replace("-", "_")
            )
            output_prefix = args.csv.with_name(f"{args.csv.stem}_{default_suffix}")
        if output_prefix.name in ("", ".", ".."):
            raise ValueError("--output-prefix must include a file name")
        output_prefix.parent.mkdir(parents=True, exist_ok=True)

        neato = shutil.which(args.neato) if pathlib.Path(args.neato).name == args.neato else args.neato
        if not neato:
            raise RuntimeError(
                f"Graphviz renderer {args.neato!r} was not found; install Graphviz or pass --neato"
            )

        default_titles = {
            "components": f"{len(rows)}-point FFT spectrum",
            "one-sided-amplitude": f"{len(rows)}-point FFT one-sided amplitude",
            "relative-db": f"{len(rows)}-point FFT relative magnitude (dB)",
        }
        title = args.title if args.title is not None else default_titles[args.view]
        dot_path = pathlib.Path(f"{output_prefix}.dot")
        svg_path = pathlib.Path(f"{output_prefix}.svg")
        png_path = pathlib.Path(f"{output_prefix}.png")
        dot = (
            build_dot(rows, title)
            if args.view == "components"
            else build_stem_dot(rows, title, args.view)
        )
        dot_path.write_text(dot, encoding="utf-8")
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
