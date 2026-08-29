# Host-side test assets: current status

## Scope

This directory contains input/reference-data generators, uword source
generators, and optional visualization helpers. The current closed checks are:

- pure-Python fixture generation and little-endian hex round-trip;
- assembly of the generated checkerboard, reduction, and sliding examples;
- assembly of the exact four-bin histogram predicate example;
- software reference generation for a 3x3 mean filter.

These assets are **not yet wired into an RTL regression harness or a Makefile
target**. In particular, generating a filter reference does not mean that an
equivalent VSP program has executed or matched it. The file named
`create_end_to_end_test.py` creates the two ends of such a future test (input
and expected output); it does not currently connect them through RTL.

## Assets

| Path | Purpose | Dependency / status |
|---|---|---|
| `tools/generate_test_data.py` | deterministic byte fixtures and word hex I/O | Python standard library |
| `tools/vsp_asm_generator.py` | current-syntax uword examples | Python standard library |
| `tools/create_end_to_end_test.py` | input/reference fixture generation | Python standard library; no RTL execution |
| `tools/vsp_test_utils.py` | NumPy-based data helpers | optional NumPy |
| `tools/vsp_visualizer.py` | image/result plots | optional NumPy + Matplotlib |
| `examples/uword/histogram_4bin_test.uasm` | exact lane predicate + reduction example | accepted by current assembler |
| `test_data/` | deterministic inputs and software references | host-side fixtures only |

The generated checkerboard/reduction/sliding uword files are intentionally not
required as checked-in artifacts: `tools/vsp_asm_generator.py` can materialize
them, and validation can generate them into a temporary directory.

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

Materialize the three generated examples only when desired:

```bash
python3 tools/vsp_asm_generator.py
```

NumPy and Matplotlib are optional and are not needed by the pure generator or
assembler checks:

```bash
python3 -m pip install numpy matplotlib
```

## Remaining integration work

An RTL end-to-end regression still needs an explicit harness that:

1. initializes the D-side model from the 32-bit fixture words;
2. initializes/fetches an assembled uword program;
3. starts the cluster and observes completion/fault behavior;
4. extracts output memory or reduction completions;
5. compares them with the software reference using a stated exact/tolerance
   policy.

Until that exists, documents and generated verification snippets should be
read as integration recipes, not passing hardware tests.
