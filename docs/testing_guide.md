# Testing data and uword examples

## What works today

The repository has host-side tools for deterministic byte fixtures, software
references, current-syntax uword generation, and assembly. They can validate
file formats and instruction-source acceptance without third-party packages.

They are not automatically consumed by the existing RTL tests. No command in
this guide claims to run a generated image algorithm through the cluster.

## Generate data

```bash
python3 tools/generate_test_data.py
```

This creates 64x64 byte images in four representations:

- `.hex`: 32-bit word lines for `$readmemh`;
- `.bin`: address-ordered raw bytes;
- `.pgm`: ASCII PGM for inspection;
- `.h`: C byte arrays.

It also creates a known-distribution four-bin histogram fixture and small
reduction vectors. The standard-library dumper can read its own hex format:

```python
from tools.generate_test_data import SimpleDataDumper

image = SimpleDataDumper.load_hex_dump(
    "test_data/checkerboard.hex", shape=(64, 64))
```

`//` and `#` comments are accepted. For an unshaped partial final word, pass
`byte_count=N` so padding is not returned as input data.

## Word-oriented hex and SystemVerilog

Four bytes at ascending addresses are written least-significant byte first in
a 32-bit value. Bytes `10 20 30 40` produce:

```text
40302010
```

Declare a 32-bit array for direct `$readmemh` loading:

```systemverilog
logic [31:0] fixture_words [0:1023];

initial begin
  $readmemh("test_data/checkerboard.hex", fixture_words);
end
```

Then use the harness's supported initialization interface to write each word,
or unpack `fixture_words[i][8*j +: 8]` to byte address `4*i+j`. Do not load
one 32-bit line directly into each element of a byte-wide array.

## Assemble current examples

The exact four-bin example is checked in:

```bash
python3 tools/vsp_uword_asm.py \
  examples/uword/histogram_4bin_test.uasm \
  -o /tmp/histogram_4bin.hex \
  --listing /tmp/histogram_4bin.lst \
  --symbols /tmp/histogram_4bin.json
```

The assembler validates while producing output; it does not implement a
`--check` flag.

Generate checkerboard, reduction, and sliding-window sources when needed:

```bash
python3 tools/vsp_asm_generator.py

for source in \
  examples/uword/checkerboard_test.uasm \
  examples/uword/reduction_test.uasm \
  examples/uword/sliding_window_test.uasm
do
  python3 tools/vsp_uword_asm.py "$source" -o "/tmp/$(basename "$source" .uasm).hex"
done
```

The checkerboard example computes byte-wise `255 - input` using a vector
constant and RR subtraction. The sliding example computes a group-local,
wrapped byte sum followed by `shr_u imm=2`; it is explicitly not an exact
divide-by-three mean filter.

## Four-bin histogram semantics

[`histogram_4bin_test.uasm`](../examples/uword/histogram_4bin_test.uasm)
computes for each byte lane:

```text
bin_id = pixel >> 6
diff   = absdiff(bin_id, k)
neq    = min(diff, 1)
eq     = 1 - neq
```

It reduces `eq` for `k=0..3`. Each `EXEC_REDUCE` completion is scoped to a
SIMD4 group; a sequencer or testbench must combine group and tile partials to
obtain the complete 64x64 histogram. The example does not store four global
counts and does not depend on scatter.

## Generate a software filter reference

```bash
python3 tools/create_end_to_end_test.py
```

Despite its historical filename, this script only creates input/reference
fixtures and an integration sketch. Its 3x3 mean reference is a software
oracle. The accompanying assembly text is a data-movement draft, not an
equivalent exact filter and not a passing RTL test.

## Optional NumPy and plotting helpers

Install optional host dependencies only if those tools are needed:

```bash
python3 -m pip install numpy matplotlib
```

```python
from tools.vsp_test_utils import DataDumper
from tools.vsp_visualizer import SimResultVisualizer

reference = DataDumper.load_hex_dump(
    "test_data/examples/filter_reference.hex", shape=(16, 16))
result = DataDumper.load_hex_dump("output.hex", shape=(16, 16))
SimResultVisualizer.plot_difference(reference, result)
```

`VCDTraceAnalyzer` in the visualizer is a placeholder and does not parse VCD
files yet.

## Checklist for a real RTL algorithm regression

- assemble the source into the instruction-memory format;
- initialize instruction and data models through supported harness interfaces;
- define start, completion, fault, and timeout conditions;
- collect all per-group reduction completions or memory output beats;
- compare the exact byte/word layout against a reference;
- keep generated simulator build products outside the repository.

See also:

- [Host-side asset summary](TEST_FRAMEWORK_SUMMARY.md)
- [Scatter sketches and limits](scatter_operations_guide.md)
- [Current routing architecture](architecture/routing.md)
- `python3 tools/vsp_uword_asm.py --help`
