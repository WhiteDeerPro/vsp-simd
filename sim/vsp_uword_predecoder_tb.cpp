#include "Vvsp_uword_predecoder.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int kBundleWords = 4;
constexpr int kMaxRecordWords = 4;

enum : uint8_t {
  kExec = 0,
  kMemory = 1,
  kControl = 2,
  kUndefined = 3,
};

struct Record {
  bool major_defined = false;
  uint8_t dispatch_class = kUndefined;
  int start = 0;
  std::vector<uint32_t> words;
};

struct ModelResult {
  std::vector<Record> records;
  int consumed = 0;
  bool tail_valid = false;
  uint8_t tail_class = kUndefined;
  int tail_start = 0;
  int tail_required = 0;
  std::vector<uint32_t> tail_words;
};

[[noreturn]] void fail(const std::string& message) {
  throw std::runtime_error(message);
}

void expect(bool condition, const std::string& message) {
  if (!condition) fail(message);
}

bool exec_major(uint8_t major) { return major >= 0x1 && major <= 0xa; }

bool major_defined(uint32_t word) {
  const uint8_t major = static_cast<uint8_t>(word >> 28);
  return exec_major(major) || major == 0xb || major == 0xc;
}

uint8_t dispatch_class(uint32_t word) {
  const uint8_t major = static_cast<uint8_t>(word >> 28);
  if (exec_major(major)) return kExec;
  if (major == 0xb) return kMemory;
  if (major == 0xc) return kControl;
  return kUndefined;
}

bool exec_extension_required(uint32_t word) {
  switch (word >> 28) {
    case 0x1:
      return ((word >> 5) & 1U) != 0;
    case 0x2:
      return ((word >> 6) & 1U) != 0;
    case 0x3:
    case 0x4:
      return ((word >> 8) & 1U) != 0;
    case 0x6:
      return true;
    case 0x7:
      return ((word >> 9) & 1U) != 0;
    default:
      return false;
  }
}

int record_word_count(uint32_t word) {
  const uint8_t major = static_cast<uint8_t>(word >> 28);
  if (exec_major(major)) return exec_extension_required(word) ? 2 : 1;
  if (major == 0xb || major == 0xc)
    return 1 + static_cast<int>((word >> 26) & 0x3U);
  return 1;
}

ModelResult model(const std::array<uint32_t, kBundleWords>& words,
                  int valid_count) {
  ModelResult result;
  int cursor = 0;
  while (cursor < valid_count) {
    const uint32_t header = words[cursor];
    const int required = record_word_count(header);
    const int remaining = valid_count - cursor;
    if (remaining < required) {
      result.tail_valid = true;
      result.tail_class = dispatch_class(header);
      result.tail_start = cursor;
      result.tail_required = required;
      for (int i = 0; i < remaining; ++i)
        result.tail_words.push_back(words[cursor + i]);
      break;
    }

    Record record;
    record.major_defined = major_defined(header);
    record.dispatch_class = dispatch_class(header);
    record.start = cursor;
    for (int i = 0; i < required; ++i)
      record.words.push_back(words[cursor + i]);
    result.records.push_back(record);
    cursor += required;
  }
  result.consumed = cursor;
  return result;
}

void drive(Vvsp_uword_predecoder& dut,
           const std::array<uint32_t, kBundleWords>& words, int valid_count) {
  for (int i = 0; i < kBundleWords; ++i) dut.bundle_words_i[i] = words[i];
  dut.bundle_word_count_i = valid_count;
  dut.eval();
}

uint32_t output_record_word(const Vvsp_uword_predecoder& dut, int record,
                            int word) {
  return dut.record_words_o[record * kMaxRecordWords + word];
}

void check(const Vvsp_uword_predecoder& dut, const ModelResult& expected,
           const std::string& name) {
  std::ostringstream prefix;
  prefix << name << ": ";

  expect(dut.count_error_o == 0, prefix.str() + "unexpected count error");
  expect(static_cast<int>(dut.record_count_o) ==
             static_cast<int>(expected.records.size()),
         prefix.str() + "record count mismatch");
  expect(static_cast<int>(dut.consumed_word_count_o) == expected.consumed,
         prefix.str() + "consumed count mismatch");

  for (int record = 0; record < kBundleWords; ++record) {
    const bool valid = ((dut.record_valid_o >> record) & 1U) != 0;
    const bool expect_valid = record < static_cast<int>(expected.records.size());
    expect(valid == expect_valid, prefix.str() + "record valid mismatch");

    const uint8_t actual_class =
        static_cast<uint8_t>((dut.record_class_o >> (record * 2)) & 0x3U);
    const int actual_start =
        static_cast<int>((dut.record_start_index_o >> (record * 2)) & 0x3U);
    const int actual_count =
        static_cast<int>((dut.record_word_count_o >> (record * 3)) & 0x7U);
    const bool actual_defined =
        ((dut.record_major_defined_o >> record) & 1U) != 0;

    if (expect_valid) {
      const Record& item = expected.records[record];
      expect(actual_class == item.dispatch_class,
             prefix.str() + "record class mismatch");
      expect(actual_start == item.start,
             prefix.str() + "record start mismatch");
      expect(actual_count == static_cast<int>(item.words.size()),
             prefix.str() + "record length mismatch");
      expect(actual_defined == item.major_defined,
             prefix.str() + "header-defined mismatch");
      for (int word = 0; word < kMaxRecordWords; ++word) {
        const uint32_t expected_word =
            word < static_cast<int>(item.words.size()) ? item.words[word] : 0;
        expect(output_record_word(dut, record, word) == expected_word,
               prefix.str() + "normalized record word mismatch");
      }
    } else {
      expect(actual_class == 0 && actual_start == 0 && actual_count == 0 &&
                 !actual_defined,
             prefix.str() + "unused record metadata is not zero");
      for (int word = 0; word < kMaxRecordWords; ++word)
        expect(output_record_word(dut, record, word) == 0,
               prefix.str() + "unused record payload is not zero");
    }
  }

  expect((dut.tail_valid_o != 0) == expected.tail_valid,
         prefix.str() + "tail valid mismatch");
  if (expected.tail_valid) {
    expect(static_cast<uint8_t>(dut.tail_class_o) == expected.tail_class,
           prefix.str() + "tail class mismatch");
    expect(static_cast<int>(dut.tail_start_index_o) == expected.tail_start,
           prefix.str() + "tail start mismatch");
    expect(static_cast<int>(dut.tail_required_word_count_o) ==
               expected.tail_required,
           prefix.str() + "tail required count mismatch");
    expect(static_cast<int>(dut.tail_present_word_count_o) ==
               static_cast<int>(expected.tail_words.size()),
           prefix.str() + "tail present count mismatch");
    for (int word = 0; word < kMaxRecordWords; ++word) {
      const uint32_t expected_word =
          word < static_cast<int>(expected.tail_words.size())
              ? expected.tail_words[word]
              : 0;
      expect(dut.tail_words_o[word] == expected_word,
             prefix.str() + "normalized tail word mismatch");
    }
  } else {
    expect(static_cast<uint8_t>(dut.tail_class_o) == kUndefined &&
               dut.tail_start_index_o == 0 &&
               dut.tail_required_word_count_o == 0 &&
               dut.tail_present_word_count_o == 0,
           prefix.str() + "idle tail metadata mismatch");
    for (int word = 0; word < kMaxRecordWords; ++word)
      expect(dut.tail_words_o[word] == 0,
             prefix.str() + "idle tail payload is not zero");
  }
}

void run_case(Vvsp_uword_predecoder& dut,
              const std::array<uint32_t, kBundleWords>& words, int valid_count,
              const std::string& name) {
  drive(dut, words, valid_count);
  check(dut, model(words, valid_count), name);
}

void test_directed(Vvsp_uword_predecoder& dut) {
  run_case(dut, {0x80000000U, 0xb0000000U, 0xc0000000U, 0xf1234567U},
           4, "four mixed one-word records");

  // The second word looks like a MEMORY header.  It belongs to the ALU base
  // because bit 5 declared an EXEC immediate extension.
  run_case(dut, {0x10000020U, 0xbfffffffU, 0xc0000000U, 0x80000000U},
           4, "EXEC extension is not reclassified");

  // MEMORY continuation words are equally opaque to the header scan.
  run_case(dut, {0xb4000000U, 0x60000000U, 0xc0000000U, 0xd0000000U},
           4, "MEMORY body is not reclassified");

  run_case(dut, {0x10000020U, 0xc0000000U, 0x60000000U, 0xb0000000U},
           4, "two extended EXEC records");

  run_case(dut, {0x80000000U, 0x60000000U, 0xfeedfaceU, 0x12345678U},
           2, "complete prefix and incomplete EXEC tail");
  run_case(dut, {0xbc000000U, 0x11111111U, 0x22222222U, 0x33333333U},
           3, "incomplete four-word MEMORY tail");
  run_case(dut, {0xc8000000U, 0x11111111U, 0x22222222U, 0x00000000U},
           3, "complete three-word CONTROL record");
  run_case(dut, {0, 0, 0, 0}, 0, "empty bundle");
}

void test_structural_table(Vvsp_uword_predecoder& dut) {
  struct ExecCase {
    uint32_t base;
    int length;
    const char* name;
  };
  const std::array<ExecCase, 16> cases = {{
      {0x10000000U, 1, "ALU register"},
      {0x10000020U, 2, "ALU immediate"},
      {0x20000000U, 1, "CMP register"},
      {0x20000040U, 2, "CMP immediate"},
      {0x30000000U, 1, "SELECT register"},
      {0x30000100U, 2, "SELECT immediate"},
      {0x40000000U, 1, "MUL register"},
      {0x40000100U, 2, "MUL immediate"},
      {0x50000000U, 1, "MAC_RR"},
      {0x60000000U, 2, "MAC_RI"},
      {0x70000000U, 1, "WIDE register"},
      {0x70000200U, 2, "WIDE immediate"},
      {0x80000000U, 1, "WADD_WSUB"},
      {0x90000000U, 1, "COMPACT"},
      {0xa0000000U, 1, "MRF_LOGIC"},
      {0xf0000000U, 1, "undefined major"},
  }};

  for (const ExecCase& item : cases) {
    const std::array<uint32_t, kBundleWords> words = {
        item.base, 0xcafebabeU, 0, 0};
    drive(dut, words, item.length);
    expect(dut.record_count_o == 1,
           std::string(item.name) + ": did not emit exactly one record");
    expect((dut.record_word_count_o & 0x7U) == item.length,
           std::string(item.name) + ": structural length mismatch");
    expect(dut.consumed_word_count_o == item.length && !dut.tail_valid_o,
           std::string(item.name) + ": structural consumption mismatch");
  }

  // Every possible high nibble is legal data in an EXEC extension.
  for (uint32_t major = 0; major < 16; ++major) {
    const uint32_t extension = (major << 28) | 0x01234567U;
    run_case(dut, {0x10000020U, extension, 0x80000000U, 0}, 3,
             "opaque EXEC extension major " + std::to_string(major));
  }

  // The framing experiment permits zero through three opaque body words for
  // both non-EXEC classes.
  for (uint32_t major : {0xbU, 0xcU}) {
    for (uint32_t body_count = 0; body_count < 4; ++body_count) {
      const uint32_t header = (major << 28) | (body_count << 26);
      run_case(dut, {header, 0x60000000U, 0xbfffffffU, 0xd0000000U},
               static_cast<int>(body_count + 1),
               "non-EXEC body count " + std::to_string(body_count));
    }
  }

  for (uint32_t major : {0U, 0xdU, 0xeU, 0xfU}) {
    run_case(dut, {(major << 28) | 0x0fffffffU, 0x80000000U, 0, 0},
             2, "undefined major forward progress " + std::to_string(major));
  }
}

void test_bad_count(Vvsp_uword_predecoder& dut) {
  const std::array<uint32_t, kBundleWords> words = {
      0x80000000U, 0x80000000U, 0x80000000U, 0x80000000U};
  for (int count : {5, 6, 7}) {
    drive(dut, words, count);
    expect(dut.count_error_o != 0, "out-of-range count was not rejected");
    expect(dut.record_valid_o == 0 && dut.record_count_o == 0 &&
               dut.consumed_word_count_o == 0 && dut.tail_valid_o == 0,
           "count error leaked a record or tail");
  }
}

void test_random(Vvsp_uword_predecoder& dut) {
  std::mt19937_64 rng(0x5653505f50524544ULL);
  for (int trial = 0; trial < 50000; ++trial) {
    std::array<uint32_t, kBundleWords> words{};
    for (uint32_t& word : words) word = static_cast<uint32_t>(rng());
    const int valid_count = static_cast<int>(rng() % (kBundleWords + 1));
    run_case(dut, words, valid_count, "random trial " +
                                          std::to_string(trial));
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  try {
    Vvsp_uword_predecoder dut;
    test_directed(dut);
    test_structural_table(dut);
    test_bad_count(dut);
    test_random(dut);
    dut.final();
    std::cout << "vsp_uword_predecoder_tb: 50000 randomized bundles passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "vsp_uword_predecoder_tb failed: " << error.what() << '\n';
    return 1;
  }
}
