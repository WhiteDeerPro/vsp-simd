#include "Vsimd_uop_legal.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

bool defined(unsigned op) { return op <= 0x2d; }

bool dynamic_mode(unsigned op) {
  return op <= 0x01 || (op >= 0x06 && op <= 0x09) ||
         (op >= 0x0c && op <= 0x14) ||
         (op >= 0x1a && op <= 0x1b) ||
         (op >= 0x28 && op <= 0x29);
}

bool mode_legal(unsigned op, unsigned mode) {
  return defined(op) && (dynamic_mode(op) ? mode <= 2 : mode == 0);
}

bool can_write_vrf(unsigned op) {
  return defined(op) && (op <= 0x1b || op >= 0x24);
}

bool can_write_arf(unsigned op) {
  return (op >= 0x16 && op <= 0x19) ||
         (op >= 0x1c && op <= 0x23);
}

bool can_write_mrf(unsigned op) {
  return (op >= 0x12 && op <= 0x14) ||
         (op >= 0x28 && op <= 0x2d);
}

bool can_reduce(unsigned op, unsigned mode) {
  const bool excluded = (op >= 0x12 && op <= 0x14) ||
                        (op >= 0x1c && op <= 0x23) ||
                        (op >= 0x2a && op <= 0x2d);
  return mode == 0 && defined(op) && !excluded;
}

bool can_route(unsigned op) {
  const bool excluded = (op >= 0x22 && op <= 0x26) ||
                        (op >= 0x2a && op <= 0x2d);
  return defined(op) && !excluded;
}

[[noreturn]] void fail(unsigned test_case, const char* field,
                       unsigned expected, unsigned actual) {
  std::cerr << "FAIL case=" << test_case << ' ' << field
            << " expected=" << expected << " actual=" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_uop_legal dut;
  unsigned test_case = 0;

  for (unsigned op = 0; op < 64; ++op) {
    for (unsigned mode = 0; mode < 4; ++mode) {
      for (unsigned controls = 0; controls < 32;
           ++controls, ++test_case) {
        const bool write_vrf = controls & 0x01;
        const bool write_arf = controls & 0x02;
        const bool write_mrf = controls & 0x04;
        const bool reduce = controls & 0x08;
        const bool route = controls & 0x10;

        const bool expected_mode = mode_legal(op, mode);
        const bool expected_writeback =
            (!write_vrf || can_write_vrf(op)) &&
            (!write_arf || can_write_arf(op)) &&
            (!write_mrf || can_write_mrf(op));
        const bool expected_reduce = !reduce || can_reduce(op, mode);
        const bool expected_route = !route || can_route(op);
        const bool expected_legal = expected_mode && expected_writeback &&
                                    expected_reduce && expected_route;

        dut.op_i = op;
        dut.elem_mode_i = mode;
        dut.write_vrf_i = write_vrf;
        dut.write_arf_i = write_arf;
        dut.write_mrf_i = write_mrf;
        dut.reduce_enable_i = reduce;
        dut.route_enable_i = route;
        dut.eval();

        if (bool(dut.mode_legal_o) != expected_mode) {
          fail(test_case, "mode", expected_mode, dut.mode_legal_o);
        }
        if (bool(dut.writeback_legal_o) != expected_writeback) {
          fail(test_case, "writeback", expected_writeback,
               dut.writeback_legal_o);
        }
        if (bool(dut.reduce_legal_o) != expected_reduce) {
          fail(test_case, "reduce", expected_reduce, dut.reduce_legal_o);
        }
        if (bool(dut.route_legal_o) != expected_route) {
          fail(test_case, "route", expected_route, dut.route_legal_o);
        }
        if (bool(dut.legal_o) != expected_legal) {
          fail(test_case, "legal", expected_legal, dut.legal_o);
        }
      }
    }
  }

  dut.final();
  std::cout << "PASS: " << test_case
            << " exhaustive opcode/mode/writeback/reduce/route legality "
               "cases\n";
  return 0;
}
