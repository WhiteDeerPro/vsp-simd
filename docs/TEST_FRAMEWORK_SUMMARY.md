# Host-side test assets: current status

## Scope

This directory contains input/reference-data generators, uword source
generators, and optional visualization helpers. The current closed checks are:

- pure-Python fixture generation and little-endian hex round-trip;
- assembly of the generated brightness, checkerboard, reduction, and sliding
  examples;
- assembly of the exact four-bin histogram predicate example;
- a fetched 48-byte saturating-brightness program which loops across four
  SIMD4 groups and checks final D-memory bytes against a scalar oracle;
- software reference generation for a 3x3 mean filter.

The brightness program is wired into the RTL program-wrapper regression. Other
generated fixtures are not automatically end-to-end tests. In particular,
generating a filter reference does not mean that an equivalent VSP program has
executed or matched it. The file named `create_end_to_end_test.py` creates the
two ends of such a future test (input and expected output); it does not
currently connect them through RTL.

## Assets

| Path | Purpose | Dependency / status |
|---|---|---|
| `tools/generate_test_data.py` | deterministic byte fixtures and word hex I/O | Python standard library |
| `tools/vsp_asm_generator.py` | static algorithm schedules to validated current-syntax uword source | Python standard library |
| `tools/create_end_to_end_test.py` | input/reference fixture generation | Python standard library; no RTL execution |
| `tools/vsp_test_utils.py` | NumPy-based data helpers | optional NumPy |
| `tools/vsp_visualizer.py` | image/result plots | optional NumPy + Matplotlib |
| `examples/uword/histogram_4bin_test.uasm` | exact lane predicate + reduction example | accepted by current assembler |
| `examples/uword/program_brightness_loop.uasm` | 48-byte saturating-brightness loop | RTL output checked by program-wrapper test |
| `test_data/` | deterministic inputs and software references | host-side fixtures only |

The generated brightness/checkerboard/reduction/sliding uword files are
intentionally not required as checked-in artifacts:
`tools/vsp_asm_generator.py` materializes them under
`build/generated/uword/` by default, and validation can use a temporary
directory. The exact brightness source remains checked in because it is the
reviewable input to the RTL regression.

## Hex contract

The `.hex` files are word-oriented. Each non-comment line holds four
address-ordered bytes packed into one 32-bit little-endian word. For bytes
`01 02 03 04`, the line is:

```text
04030201
```

A partial final word pads missing high-address bytes with zero. Thus bytes
`05 06 07` produce `00070605`. `SimpleDataDumper.load_hex_dump` accepts both
`//` and `#` comments; pass `shape=` or `byte_count=` to remove final padding.

SystemVerilog must load this format into a word array, then unpack bytes or
drive the memory model's initialization interface:

```systemverilog
logic [31:0] fixture_words [0:1023];
initial $readmemh("test_data/checkerboard.hex", fixture_words);

// For word i:
// byte address 4*i+0 = fixture_words[i][7:0]
// byte address 4*i+1 = fixture_words[i][15:8]
// byte address 4*i+2 = fixture_words[i][23:16]
// byte address 4*i+3 = fixture_words[i][31:24]
```

Loading these word lines directly into `logic [7:0] memory[]` is incorrect:
`$readmemh` assigns one input line to one array element.

## Reproducible host checks

Generate fixtures:

```bash
python3 tools/generate_test_data.py
python3 tools/create_end_to_end_test.py
```

Assemble one source (the assembler has no `--check` option):

```bash
python3 tools/vsp_uword_asm.py \
  examples/uword/histogram_4bin_test.uasm \
  -o /tmp/histogram_4bin.hex \
  --listing /tmp/histogram_4bin.lst
```

Materialize generated examples only when desired and run their source-level
checks:

```bash
python3 tools/vsp_asm_generator.py
make test-vsp-asm-generator
```

Run the closed program-level algorithm regression:

```bash
make test-vsp-uword-cluster-program
```

NumPy and Matplotlib are optional and are not needed by the pure generator or
assembler checks:

```bash
python3 -m pip install numpy matplotlib
```

## Remaining generalization work

The first brightness program now performs these steps. A reusable workload
harness still needs a data-driven interface that:

1. initializes the D-side model from the 32-bit fixture words;
2. initializes/fetches an assembled uword program;
3. starts the cluster and observes completion/fault behavior;
4. extracts output memory or reduction completions;
5. compares them with the software reference using a stated exact/tolerance
   policy.

Until that general harness exists, other generated verification snippets
remain integration recipes unless they name a specific RTL result check.
