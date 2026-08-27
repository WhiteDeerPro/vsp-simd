#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

uint8_t byte(uint32_t value, unsigned index) {
  return static_cast<uint8_t>(value >> (index * 8));
}

// Reference-model notation: one PMAC8 step selects one byte from each
// source, multiplies them with an 8x8 multiplier, aligns the 16-bit partial
// product, and adds it to a wrapping 32-bit accumulator. No cross-lane partial
// product compressor is assumed. PMAC8 is not a deployed RTL opcode.
uint32_t serial_pmac8(uint32_t a, uint32_t b, unsigned& micro_ops) {
  uint32_t acc = 0;
  micro_ops = 0;
  for (unsigned diagonal = 0; diagonal < 4; ++diagonal) {
    for (unsigned a_byte = 0; a_byte <= diagonal; ++a_byte) {
      const unsigned b_byte = diagonal - a_byte;
      const uint32_t partial =
          static_cast<uint32_t>(byte(a, a_byte)) * byte(b, b_byte);
      acc += partial << (diagonal * 8);
      ++micro_ops;
    }
  }
  return acc;
}

// Optional accelerated contract: up to four 8x8 products from one convolution
// diagonal are summed before one aligned accumulator update. This requires a
// small partial-product reduction path and is intentionally not current RTL.
uint32_t diagonal_conv4(uint32_t a, uint32_t b, unsigned& micro_ops) {
  uint32_t acc = 0;
  micro_ops = 0;
  for (unsigned diagonal = 0; diagonal < 4; ++diagonal) {
    uint32_t diagonal_sum = 0;
    for (unsigned a_byte = 0; a_byte <= diagonal; ++a_byte) {
      const unsigned b_byte = diagonal - a_byte;
      diagonal_sum +=
          static_cast<uint32_t>(byte(a, a_byte)) * byte(b, b_byte);
    }
    acc += diagonal_sum << (diagonal * 8);
    ++micro_ops;
  }
  return acc;
}

[[noreturn]] void fail(unsigned test, uint32_t a, uint32_t b,
                       uint32_t expected, uint32_t serial,
                       uint32_t diagonal) {
  std::cerr << "FAIL test=" << std::dec << test
            << " a=0x" << std::hex << a << " b=0x" << b
            << " expected=0x" << expected << " serial=0x" << serial
            << " diagonal=0x" << diagonal << '\n';
  std::exit(1);
}

}  // namespace

int main() {
  constexpr std::array<std::pair<uint32_t, uint32_t>, 8> directed{{
      {0u, 0u},
      {1u, 1u},
      {0xffffffffu, 2u},
      {0x80000000u, 0xffffffffu},
      {0x12345678u, 0x9abcdef0u},
      {0x0000ffffu, 0x0000ffffu},
      {0xff00ff00u, 0x00ff00ffu},
      {0xffffffffu, 0xffffffffu},
  }};
  std::mt19937 rng(0x434f4e56u);
  constexpr unsigned kRandomTests = 1000000;
  unsigned test = 0;

  auto check = [&](uint32_t a, uint32_t b) {
    unsigned serial_ops = 0;
    unsigned diagonal_ops = 0;
    const uint32_t serial = serial_pmac8(a, b, serial_ops);
    const uint32_t diagonal = diagonal_conv4(a, b, diagonal_ops);
    const uint32_t expected =
        static_cast<uint32_t>(static_cast<uint64_t>(a) * b);
    if (serial_ops != 10 || diagonal_ops != 4 || serial != expected ||
        diagonal != expected) {
      fail(test, a, b, expected, serial, diagonal);
    }
    ++test;
  };

  for (const auto& [a, b] : directed) check(a, b);
  for (unsigned iteration = 0; iteration < kRandomTests; ++iteration) {
    check(rng(), rng());
  }

  std::cout << "PASS: " << test
            << " low-32-bit byte-convolution products; baseline=10 PMAC8"
            << " micro-ops, optional diagonal path=4 micro-ops\n";
  return 0;
}
