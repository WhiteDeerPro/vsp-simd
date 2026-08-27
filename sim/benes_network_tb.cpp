#include "Vbenes_network.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <unordered_set>

namespace {

constexpr unsigned kPorts = 8;
constexpr unsigned kLogPorts = 3;
constexpr unsigned kStages = 2 * kLogPorts - 1;
constexpr unsigned kSwitchesPerStage = kPorts / 2;
constexpr unsigned kControlBits = kStages * kSwitchesPerStage;

uint32_t pack(const std::array<uint8_t, kPorts>& ports) {
  uint32_t value = 0;
  for (unsigned port = 0; port < kPorts; ++port) {
    value |= static_cast<uint32_t>(ports[port] & 0x0fu) << (port * 4);
  }
  return value;
}

std::array<uint8_t, kPorts> reference(uint32_t control) {
  std::array<uint8_t, kPorts> wires{};
  for (unsigned port = 0; port < kPorts; ++port) wires[port] = port;

  for (unsigned stage = 0; stage < kStages; ++stage) {
    std::array<uint8_t, kPorts> switched{};
    for (unsigned sw = 0; sw < kSwitchesPerStage; ++sw) {
      const unsigned even = 2 * sw;
      const unsigned odd = even + 1;
      const bool cross = (control >> (stage * kSwitchesPerStage + sw)) & 1u;
      switched[even] = cross ? wires[odd] : wires[even];
      switched[odd] = cross ? wires[even] : wires[odd];
    }

    if (stage == kStages - 1) return switched;

    std::array<uint8_t, kPorts> next{};
    for (unsigned link = 0; link < kPorts; ++link) {
      unsigned next_link;
      if (stage < kLogPorts - 1) {
        next_link = ((link << 1) & (kPorts - 1)) |
                    (link >> (kLogPorts - 1));
      } else {
        next_link = (link >> 1) | ((link & 1u) << (kLogPorts - 1));
      }
      next[next_link] = switched[link];
    }
    wires = next;
  }

  std::abort();
}

[[noreturn]] void fail(uint32_t control, uint32_t expected, uint32_t actual) {
  std::cerr << "FAIL control=0x" << std::hex << control
            << " expected=0x" << expected << " actual=0x" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vbenes_network dut;

  std::array<uint8_t, kPorts> identity{};
  for (unsigned port = 0; port < kPorts; ++port) identity[port] = port;
  dut.data_i = pack(identity);

  std::unordered_set<uint32_t> permutations;
  permutations.reserve(40320);

  const uint32_t configurations = 1u << kControlBits;
  for (uint32_t control = 0; control < configurations; ++control) {
    dut.ctrl_i = control;
    dut.eval();

    const uint32_t expected = pack(reference(control));
    const uint32_t actual = dut.data_o;
    if (actual != expected) fail(control, expected, actual);
    permutations.insert(actual);
  }

  if (permutations.size() != 40320u) {
    std::cerr << "FAIL: expected all 40320 8-port permutations, observed "
              << permutations.size() << '\n';
    return 1;
  }

  dut.final();
  std::cout << "PASS: exhaustive 8-port Benes controls reach all 40320 permutations\n";
  return 0;
}

