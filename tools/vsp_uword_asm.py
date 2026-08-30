#!/usr/bin/env python3
"""Assemble the current internal VSP uword-stream experiment.

This is deliberately a small engineering tool, not an architectural assembler.
It emits one 32-bit word per line for a behavioral control store and can also
write a byte-PC listing and a JSON symbol map.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import sys
from dataclasses import dataclass


ALU_OPS = {
    "add": 0,
    "sub": 1,
    "add_sat_u": 2,
    "sub_sat_u": 3,
    "add_sat_s": 4,
    "sub_sat_s": 5,
    "min_u": 6,
    "max_u": 7,
    "min_s": 8,
    "max_s": 9,
    "absdiff_u": 10,
    "avg_u": 11,
    "avg_s": 12,
    "and": 13,
    "or": 14,
    "xor": 15,
    "shl": 16,
    "shr_u": 17,
    "shr_s": 18,
    "abs_sat_s": 19,
    "pass_a": 20,
}

# These are the ALU functions for which profile v0 exposes HALF/WORD element
# modes. All other ALU builders are byte-only; RAW remains available when a
# test intentionally needs an illegal packet.
DYNAMIC_MODE_ALU_OPS = {
    "add", "sub", "min_u", "max_u", "min_s", "max_s",
    "and", "or", "xor", "shl", "shr_u", "shr_s", "pass_a",
}
UNARY_ALU_OPS = {"abs_sat_s", "pass_a"}

ELEMENT_MODES = {"byte": 0, "half": 1, "word": 2}
ELEMENT_WIDTHS = {"byte": 8, "half": 16, "word": 32}
MASK_SELECTORS = {"none": 0, "m0": 1, "m1": 2, "m2": 3, "m3": 4}
REDUCE_SELECTORS = {
    "none": 0,
    "sum_u": 1,
    "sum_s": 2,
    "min_u": 3,
    "min_s": 4,
    "max_u": 5,
    "max_s": 6,
}
STATE_OPS = {
    "smovi": 0,
    "sadd": 1,
    "saddi": 2,
}
STATE_ALIASES = {
    "li": "smovi",
    "add": "sadd",
    "addi": "saddi",
}
BRANCH_CONDITIONS = {
    "j": 0,
    "beq": 1,
    "bne": 2,
    "blt": 3,
    "bge": 4,
    "bltu": 5,
    "bgeu": 6,
    "beqz": 1,
    "bnez": 2,
    "bltz": 3,
    "bgez": 4,
    "bgtz": 3,
    "blez": 4,
}
SINGLE_REGISTER_BRANCHES = {
    "beqz", "bnez", "bltz", "bgez", "bgtz", "blez",
}
ZERO_FIRST_BRANCHES = {"bgtz", "blez"}
MEMORY_OPS = {
    "vload": 0,
    "vstore": 1,
    "vgather": 0,
    "vscatter": 1,
}
INDEXED_MEMORY_OPS = {"vgather", "vscatter"}
MEMORY_ADDR_SPACES = {
    "local": 0,
    "physical": 1,
    "translated": 2,
}
# Profile-v0 semantic records use the current default widths of the state and
# memory engines. Opaque MEMORY/CONTROL remain available below for framing
# and rejection tests which intentionally need records outside this profile.
STATE_REGS = 32
MEMORY_VRF_ROWS = 16
MEMORY_MAX_EXPLICIT_SPAN_BYTES = 31
MEMORY_OFFSET_W = 16


class AssemblyError(Exception):
    pass


@dataclass(frozen=True)
class SourceWord:
    value: int
    line_number: int
    source: str
    part: int
    part_count: int


@dataclass(frozen=True)
class Assembly:
    words: list[SourceWord]
    symbols: dict[str, int]
    base_pc: int


def parse_integer(text: str, line_number: int) -> int:
    try:
        return int(text, 0)
    except ValueError as error:
        raise AssemblyError(
            f"line {line_number}: invalid integer {text!r}"
        ) from error


def require_range(name: str, value: int, low: int, high: int,
                  line_number: int) -> int:
    if value < low or value > high:
        raise AssemblyError(
            f"line {line_number}: {name}={value} is outside {low}..{high}"
        )
    return value


def parse_boolean(text: str, name: str, line_number: int) -> int:
    lowered = text.lower()
    if lowered in {"1", "true", "yes", "on"}:
        return 1
    if lowered in {"0", "false", "no", "off"}:
        return 0
    raise AssemblyError(f"line {line_number}: {name} expects a boolean")


def split_arguments(tokens: list[str], line_number: int) -> tuple[dict[str, str], list[str]]:
    named: dict[str, str] = {}
    positional: list[str] = []
    for token in tokens:
        if "=" not in token:
            positional.append(token)
            continue
        key, value = token.split("=", 1)
        key = key.lower()
        if not key or not value:
            raise AssemblyError(f"line {line_number}: malformed argument {token!r}")
        if key in named:
            raise AssemblyError(f"line {line_number}: duplicate argument {key!r}")
        named[key] = value
    return named, positional


def take_named(named: dict[str, str], key: str, default: str | None,
               line_number: int) -> str:
    if key in named:
        return named.pop(key)
    if default is not None:
        return default
    raise AssemblyError(f"line {line_number}: missing required argument {key!r}")


def encode_element_immediate(text: str, mode: str, line_number: int) -> int:
    value = parse_integer(text, line_number)
    width = ELEMENT_WIDTHS[mode]
    unsigned_max = (1 << width) - 1
    signed_min = -(1 << (width - 1))
    if value < signed_min or value > unsigned_max:
        raise AssemblyError(
            f"line {line_number}: immediate {value} does not fit {width} bits"
        )
    return value & unsigned_max


def encode_word_immediate(text: str, name: str, line_number: int) -> int:
    """Encode a full 32-bit word, accepting signed or unsigned spelling."""
    value = parse_integer(text, line_number)
    if value < -(1 << 31) or value > 0xFFFFFFFF:
        raise AssemblyError(
            f"line {line_number}: {name} {value} does not fit 32 bits"
        )
    return value & 0xFFFFFFFF


def encode_signed_immediate(text: str, name: str, width: int,
                            line_number: int) -> int:
    value = parse_integer(text, line_number)
    signed_min = -(1 << (width - 1))
    signed_max = (1 << (width - 1)) - 1
    if value < signed_min or value > signed_max:
        raise AssemblyError(
            f"line {line_number}: {name} {value} does not fit signed {width} bits"
        )
    return value & 0xFFFFFFFF


def encode_state(tokens: list[str], operation: str,
                 line_number: int) -> list[int]:
    """Encode a sequencer-state CONTROL record."""
    named, positional = split_arguments(tokens, line_number)
    if positional:
        raise AssemblyError(
            f"line {line_number}: {operation.upper()} fields must use key=value syntax"
        )

    rd = require_range(
        "rd", parse_integer(take_named(named, "rd", None, line_number),
                            line_number),
        0, STATE_REGS - 1, line_number,
    )
    rs1 = 0
    rs2 = 0
    immediate: int | None = None

    if operation == "sadd":
        rs1 = require_range(
            "rs1", parse_integer(take_named(named, "rs1", None, line_number),
                                 line_number),
            0, STATE_REGS - 1, line_number,
        )
        rs2 = require_range(
            "rs2", parse_integer(take_named(named, "rs2", None, line_number),
                                 line_number),
            0, STATE_REGS - 1, line_number,
        )
    elif operation == "saddi":
        rs1 = require_range(
            "rs1", parse_integer(take_named(named, "rs1", None, line_number),
                                 line_number),
            0, STATE_REGS - 1, line_number,
        )
        immediate = encode_word_immediate(
            take_named(named, "imm", None, line_number), "immediate",
            line_number,
        )
    else:
        immediate = encode_word_immediate(
            take_named(named, "imm", None, line_number), "immediate",
            line_number,
        )

    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(
            f"line {line_number}: unknown {operation.upper()} fields: {unknown}"
        )

    body_words = int(immediate is not None)
    header = 0
    header |= 0xC << 28
    header |= body_words << 26
    header |= STATE_OPS[operation] << 24
    header |= rd << 19
    header |= rs1 << 14
    header |= rs2 << 9
    return [header] if immediate is None else [header, immediate]


def resolve_branch_target(text: str, symbols: dict[str, int],
                          line_number: int) -> int:
    """Resolve a branch target as a label or an absolute byte PC."""
    if text in symbols:
        return symbols[text]
    try:
        target = int(text, 0)
    except ValueError as error:
        raise AssemblyError(
            f"line {line_number}: undefined branch target {text!r}"
        ) from error
    if target < 0:
        raise AssemblyError(
            f"line {line_number}: branch target PC must be non-negative"
        )
    return target


def encode_branch(tokens: list[str], operation: str, line_number: int,
                  current_pc: int, symbols: dict[str, int]) -> list[int]:
    """Encode a fixed two-word sequencer CONTROL-flow record."""
    named, positional = split_arguments(tokens, line_number)
    if positional:
        raise AssemblyError(
            f"line {line_number}: {operation.upper()} fields must use key=value syntax"
        )

    target_text = take_named(named, "target", None, line_number)
    rs1 = 0
    rs2 = 0
    if operation != "j":
        rs1 = require_range(
            "rs1", parse_integer(take_named(named, "rs1", None, line_number),
                                  line_number),
            0, STATE_REGS - 1, line_number,
        )
        if operation in ZERO_FIRST_BRANCHES:
            rs2 = rs1
            rs1 = 0
        elif operation not in SINGLE_REGISTER_BRANCHES:
            rs2 = require_range(
                "rs2", parse_integer(
                    take_named(named, "rs2", None, line_number), line_number
                ),
                0, STATE_REGS - 1, line_number,
            )

    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(
            f"line {line_number}: unknown {operation.upper()} fields: {unknown}"
        )

    target_pc = resolve_branch_target(target_text, symbols, line_number)
    if target_pc & 0x3:
        raise AssemblyError(
            f"line {line_number}: branch target PC 0x{target_pc:x} is not word aligned"
        )
    displacement = target_pc - current_pc
    if displacement < -(1 << 31) or displacement > (1 << 31) - 1:
        raise AssemblyError(
            f"line {line_number}: branch displacement {displacement} "
            "does not fit signed 32 bits"
        )

    # CONTROL branch profile:
    #   [31:28] major C, [27:26] one body word, [25:24] branch family 3,
    #   [23:21] condition, [20:16] rs1, [15:11] rs2, [10:0] zero.
    # The body is a signed byte displacement relative to this header's PC.
    header = 0
    header |= 0xC << 28
    header |= 1 << 26
    header |= 3 << 24
    header |= BRANCH_CONDITIONS[operation] << 21
    header |= rs1 << 16
    header |= rs2 << 11
    return [header, displacement & 0xFFFFFFFF]


def encode_memory(tokens: list[str], operation: str,
                  line_number: int) -> list[int]:
    """Encode the fixed two-word MEMORY profile-v0 record."""
    named, positional = split_arguments(tokens, line_number)
    if positional:
        raise AssemblyError(
            f"line {line_number}: {operation.upper()} fields must use key=value syntax"
        )

    space_name = take_named(named, "space", "local", line_number).lower()
    if space_name not in MEMORY_ADDR_SPACES:
        raise AssemblyError(
            f"line {line_number}: unknown address space {space_name!r}"
        )
    addr_context = require_range(
        "addr_context",
        parse_integer(take_named(named, "addr_context", "0", line_number),
                      line_number),
        0, 0xFF, line_number,
    )
    sbase = require_range(
        "sbase",
        parse_integer(take_named(named, "sbase", None, line_number),
                      line_number),
        0, STATE_REGS - 1, line_number,
    )
    if operation == "vgather":
        data_row_field = "vd"
    elif operation == "vscatter":
        data_row_field = "vs"
    else:
        data_row_field = "vrf"
    vrf = require_range(
        data_row_field,
        parse_integer(take_named(named, data_row_field, None, line_number),
                      line_number),
        0, MEMORY_VRF_ROWS - 1, line_number,
    )
    op = MEMORY_OPS[operation]
    indexed = operation in INDEXED_MEMORY_OPS
    span = 0
    index = 0
    if not indexed:
        span = require_range(
            "span", parse_integer(take_named(named, "span", None, line_number),
                                  line_number),
            0, MEMORY_MAX_EXPLICIT_SPAN_BYTES, line_number,
        )
    else:
        index = require_range(
            "vi", parse_integer(take_named(named, "vi", None, line_number),
                                line_number),
            0, MEMORY_VRF_ROWS - 1, line_number,
        )
    offset = encode_signed_immediate(
        take_named(named, "offset", "0", line_number), "offset",
        MEMORY_OFFSET_W, line_number,
    )

    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(
            f"line {line_number}: unknown {operation.upper()} fields: {unknown}"
        )

    header = 0
    header |= 0xB << 28
    header |= 1 << 26
    header |= op << 25
    header |= MEMORY_ADDR_SPACES[space_name] << 23
    header |= addr_context << 15
    header |= sbase << 10
    header |= vrf << 6
    if not indexed:
        header |= span << 1
    else:
        header |= index << 2
        header |= 1
    return [header, offset]


def encode_alu(tokens: list[str], immediate_form: bool,
               line_number: int) -> list[int]:
    named, positional = split_arguments(tokens, line_number)
    if positional:
        raise AssemblyError(
            f"line {line_number}: ALU fields must use key=value syntax"
        )

    op_name = take_named(named, "op", None, line_number).lower()
    mode_name = take_named(named, "mode", "byte", line_number).lower()
    if op_name not in ALU_OPS:
        raise AssemblyError(f"line {line_number}: unknown ALU op {op_name!r}")
    if mode_name not in ELEMENT_MODES:
        raise AssemblyError(f"line {line_number}: unknown element mode {mode_name!r}")

    va = require_range(
        "va", parse_integer(take_named(named, "va", None, line_number), line_number),
        0, 15, line_number
    )
    vd = require_range(
        "vd", parse_integer(take_named(named, "vd", None, line_number), line_number),
        0, 15, line_number
    )
    vb = 0
    if not immediate_form:
        vb = require_range(
            "vb", parse_integer(take_named(named, "vb", None, line_number), line_number),
            0, 15, line_number
        )

    mask_name = take_named(named, "mask", "none", line_number).lower()
    reduce_name = take_named(named, "reduce", "none", line_number).lower()
    if mask_name not in MASK_SELECTORS:
        raise AssemblyError(f"line {line_number}: unknown mask selector {mask_name!r}")
    if reduce_name not in REDUCE_SELECTORS:
        raise AssemblyError(f"line {line_number}: unknown reduction {reduce_name!r}")
    write_vrf = parse_boolean(
        take_named(named, "write", "1", line_number), "write", line_number
    )
    export_narrow = parse_boolean(
        take_named(named, "export", "0", line_number), "export", line_number
    )

    extension: int | None = None
    if immediate_form:
        if op_name in UNARY_ALU_OPS:
            raise AssemblyError(
                f"line {line_number}: {op_name} has no immediate form in EXEC profile v0"
            )
        extension = encode_element_immediate(
            take_named(named, "imm", None, line_number), mode_name, line_number
        )

    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(f"line {line_number}: unknown ALU fields: {unknown}")

    if mode_name != "byte" and op_name not in DYNAMIC_MODE_ALU_OPS:
        raise AssemblyError(
            f"line {line_number}: {op_name} is byte-only in EXEC profile v0"
        )
    if reduce_name != "none" and mode_name != "byte":
        raise AssemblyError(
            f"line {line_number}: profile-v0 reduction requires byte mode"
        )
    if not immediate_form and op_name in UNARY_ALU_OPS and vb != 0:
        raise AssemblyError(
            f"line {line_number}: {op_name} requires vb=0"
        )
    if not write_vrf and vd != 0:
        raise AssemblyError(
            f"line {line_number}: vd must be zero when write=0"
        )

    base = 0
    base |= 0x1 << 28
    base |= ALU_OPS[op_name] << 23
    base |= ELEMENT_MODES[mode_name] << 21
    base |= va << 17
    base |= vb << 13
    base |= vd << 9
    base |= MASK_SELECTORS[mask_name] << 6
    base |= int(immediate_form) << 5
    base |= write_vrf << 4
    base |= export_narrow << 3
    base |= REDUCE_SELECTORS[reduce_name]
    return [base] if extension is None else [base, extension]


def encode_reduce(tokens: list[str], line_number: int) -> list[int]:
    """Pseudo-op for the existing PASS_A plus SIMD4 reduction encoding."""
    named, positional = split_arguments(tokens, line_number)
    if positional:
        raise AssemblyError(
            f"line {line_number}: reduction fields must use key=value syntax"
        )

    reduce_name = take_named(named, "op", None, line_number).lower()
    if reduce_name == "none" or reduce_name not in REDUCE_SELECTORS:
        raise AssemblyError(
            f"line {line_number}: unknown reduction {reduce_name!r}"
        )
    va_text = take_named(named, "va", None, line_number)
    mask_name = take_named(named, "mask", "none", line_number).lower()
    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(
            f"line {line_number}: unknown reduction fields: {unknown}"
        )

    return encode_alu(
        ["op=pass_a", "mode=byte", f"va={va_text}", "vb=0", "vd=0",
         f"mask={mask_name}", "write=0", "export=0",
         f"reduce={reduce_name}"],
        False,
        line_number,
    )


def encode_opaque_record(major: int, tokens: list[str],
                         line_number: int) -> list[int]:
    named, positional = split_arguments(tokens, line_number)
    meta = require_range(
        "meta", parse_integer(take_named(named, "meta", "0", line_number), line_number),
        0, (1 << 26) - 1, line_number
    )
    if named:
        unknown = ", ".join(sorted(named))
        raise AssemblyError(f"line {line_number}: unknown record fields: {unknown}")
    if len(positional) > 3:
        raise AssemblyError(
            f"line {line_number}: a framed record supports at most three body words"
        )
    body = [parse_integer(token, line_number) for token in positional]
    for value in body:
        require_range("body word", value, 0, 0xFFFFFFFF, line_number)
    header = (major << 28) | (len(body) << 26) | meta
    return [header, *body]


def encode_statement(statement: str, line_number: int, current_pc: int = 0,
                     symbols: dict[str, int] | None = None) -> list[int]:
    normalized = statement.replace(",", " ")
    try:
        tokens = shlex.split(normalized, comments=False, posix=True)
    except ValueError as error:
        raise AssemblyError(f"line {line_number}: {error}") from error
    if not tokens:
        return []

    operation = tokens[0].lower()
    arguments = tokens[1:]
    operation = STATE_ALIASES.get(operation, operation)
    if operation in {"raw", ".word"}:
        if len(arguments) != 1:
            raise AssemblyError(f"line {line_number}: {operation} expects one word")
        value = parse_integer(arguments[0], line_number)
        return [require_range("raw word", value, 0, 0xFFFFFFFF, line_number)]
    if operation == "exec_alu_rr":
        return encode_alu(arguments, False, line_number)
    if operation == "exec_alu_ri":
        return encode_alu(arguments, True, line_number)
    if operation == "exec_reduce":
        return encode_reduce(arguments, line_number)
    if operation in STATE_OPS:
        return encode_state(arguments, operation, line_number)
    if operation in BRANCH_CONDITIONS:
        return encode_branch(
            arguments, operation, line_number, current_pc,
            {} if symbols is None else symbols,
        )
    if operation in MEMORY_OPS:
        return encode_memory(arguments, operation, line_number)
    if operation == "memory":
        return encode_opaque_record(0xB, arguments, line_number)
    if operation == "control":
        return encode_opaque_record(0xC, arguments, line_number)
    if operation in {"control_end", "end"}:
        if arguments:
            raise AssemblyError(f"line {line_number}: {operation.upper()} takes no arguments")
        return [0xC0000000]
    raise AssemblyError(f"line {line_number}: unknown operation {tokens[0]!r}")


def assemble_text(text: str, base_pc: int) -> Assembly:
    if base_pc < 0 or (base_pc & 0x3):
        raise AssemblyError("base PC must be a non-negative multiple of four")

    statements: list[tuple[int, str]] = []
    symbols: dict[str, int] = {}
    word_count = 0
    for line_number, original in enumerate(text.splitlines(), 1):
        statement = original.split("#", 1)[0].strip()
        if not statement:
            continue

        while ":" in statement:
            candidate, remainder = statement.split(":", 1)
            label = candidate.strip()
            if not label or any(not (char.isalnum() or char in "_.$") for char in label):
                break
            if label[0].isdigit():
                raise AssemblyError(f"line {line_number}: label may not start with a digit")
            if label in symbols:
                raise AssemblyError(f"line {line_number}: duplicate label {label!r}")
            symbols[label] = base_pc + 4 * word_count
            statement = remainder.strip()
            if not statement:
                break
        if not statement:
            continue

        statements.append((line_number, statement))
        operation = statement.replace(",", " ").split(None, 1)[0].lower()
        if operation in BRANCH_CONDITIONS:
            word_count += 2
        else:
            word_count += len(encode_statement(statement, line_number))

    words: list[SourceWord] = []
    for line_number, statement in statements:
        current_pc = base_pc + 4 * len(words)
        encoded = encode_statement(
            statement, line_number, current_pc=current_pc, symbols=symbols
        )
        for part, value in enumerate(encoded, 1):
            words.append(
                SourceWord(
                    value=value,
                    line_number=line_number,
                    source=statement,
                    part=part,
                    part_count=len(encoded),
                )
            )
    return Assembly(words=words, symbols=symbols, base_pc=base_pc)


def write_hex(path: str, assembly: Assembly) -> None:
    content = "".join(f"{item.value:08x}\n" for item in assembly.words)
    if path == "-":
        sys.stdout.write(content)
    else:
        pathlib.Path(path).write_text(content, encoding="utf-8")


def write_listing(path: str, assembly: Assembly) -> None:
    lines = []
    for index, item in enumerate(assembly.words):
        pc = assembly.base_pc + 4 * index
        suffix = "" if item.part_count == 1 else f" [{item.part}/{item.part_count}]"
        lines.append(
            f"{pc:08x}: {item.value:08x}  line {item.line_number}{suffix}  {item.source}\n"
        )
    pathlib.Path(path).write_text("".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="assemble the current internal VSP uword-stream experiment"
    )
    parser.add_argument("input", help="uword source file")
    parser.add_argument("-o", "--output", required=True,
                        help="one-word-per-line hex output, or - for stdout")
    parser.add_argument("--base-pc", default="0", help="byte PC of the first word")
    parser.add_argument("--listing", help="optional byte-PC listing")
    parser.add_argument("--symbols", help="optional JSON symbol map")
    arguments = parser.parse_args()

    try:
        base_pc = int(arguments.base_pc, 0)
        source = pathlib.Path(arguments.input).read_text(encoding="utf-8")
        assembly = assemble_text(source, base_pc)
        write_hex(arguments.output, assembly)
        if arguments.listing:
            write_listing(arguments.listing, assembly)
        if arguments.symbols:
            pathlib.Path(arguments.symbols).write_text(
                json.dumps(assembly.symbols, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    except (AssemblyError, OSError, ValueError) as error:
        print(f"vsp_uword_asm: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
