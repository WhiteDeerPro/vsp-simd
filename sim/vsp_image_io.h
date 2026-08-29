// 图像负载共享的测试图样生成、PGM 读写与性质统计。
//
// 存在理由：三个图像 workload testbench 需要同一套图样和同一份性质定义，复制会让
// 「同一图样」在不同 tb 里悄悄漂移。它不含任何 RTL 假设，也不参与协议验证。
//
// 图样一律程序化生成：回归必须离线可复现，仓库不携带二进制资源。可选的 PGM 读写
// 只服务手动查看，不进入 make test 的判定路径。

#ifndef VSP_IMAGE_IO_H_
#define VSP_IMAGE_IO_H_

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace vsp_image {

struct Image {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> pixels;

  // Zero padding is the shared border convention for every image workload.
  uint8_t at(int x, int y) const {
    if (x < 0 || x >= width || y < 0 || y >= height) return 0;
    return pixels[static_cast<size_t>(y * width + x)];
  }

  uint8_t& ref(int x, int y) {
    return pixels[static_cast<size_t>(y * width + x)];
  }

  size_t size() const { return pixels.size(); }
};

inline Image make_image(int width, int height) {
  Image image;
  image.width = width;
  image.height = height;
  image.pixels.assign(static_cast<size_t>(width * height), 0);
  return image;
}

// ---------------------------------------------------------------- patterns --
// Chosen by which numerical corner each one exposes, not by realism.

inline Image pattern_flat(int width, int height, uint8_t value) {
  Image image = make_image(width, height);
  std::fill(image.pixels.begin(), image.pixels.end(), value);
  return image;
}

inline Image pattern_ramp(int width, int height) {
  Image image = make_image(width, height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      image.ref(x, y) =
          static_cast<uint8_t>((x * 255) / std::max(1, width - 1));
    }
  }
  return image;
}

inline Image pattern_checkerboard(int width, int height, int period) {
  Image image = make_image(width, height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const bool high = (((x / period) + (y / period)) % 2) == 0;
      image.ref(x, y) = high ? 255 : 0;
    }
  }
  return image;
}

// direction 0: vertical edge, 1: horizontal edge, 2: diagonal edge.
inline Image pattern_step(int width, int height, int direction) {
  Image image = make_image(width, height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      bool high = false;
      if (direction == 0) high = x >= width / 2;
      if (direction == 1) high = y >= height / 2;
      if (direction == 2) high = (x + y) >= ((width + height) / 2);
      image.ref(x, y) = high ? 255 : 0;
    }
  }
  return image;
}

inline Image pattern_impulse(int width, int height) {
  Image image = make_image(width, height);
  image.ref(width / 2, height / 2) = 255;
  return image;
}

// Salt-and-pepper outliers on a mid-tone field. This is the content a median
// filter is meant to handle and a linear filter is not.
inline Image pattern_salt_pepper(int width, int height, unsigned percent,
                                 std::mt19937& rng) {
  Image image = pattern_flat(width, height, 128);
  for (auto& pixel : image.pixels) {
    const unsigned roll = rng() % 100;
    if (roll < percent) pixel = 0;
    else if (roll < (2 * percent)) pixel = 255;
  }
  return image;
}

// Concentric rings whose frequency rises with radius: sweeps smooth to Nyquist
// and is not axis aligned. The triangle wave of the squared radius keeps it
// integer-exact and reproducible.
inline Image pattern_zone_plate(int width, int height) {
  Image image = make_image(width, height);
  const int centre_x = width / 2;
  const int centre_y = height / 2;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const int dx = x - centre_x;
      const int dy = y - centre_y;
      const int phase = ((dx * dx) + (dy * dy)) % 16;
      const int folded = (phase < 8) ? phase : (16 - phase);
      image.ref(x, y) = static_cast<uint8_t>((folded * 255) / 8);
    }
  }
  return image;
}

inline Image pattern_noise(int width, int height, std::mt19937& rng) {
  Image image = make_image(width, height);
  for (auto& pixel : image.pixels) pixel = static_cast<uint8_t>(rng());
  return image;
}

// -------------------------------------------------------------- properties --
// The statistics a filter is judged by: level, spread and how much adjacent
// pixels differ. The two gradient means are a smoothness proxy, so a smoothing
// filter must lower them and a median filter must lower them on outlier noise
// without moving the level.

struct Properties {
  unsigned minimum = 255;
  unsigned maximum = 0;
  double mean = 0.0;
  double deviation = 0.0;
  double mean_abs_dx = 0.0;
  double mean_abs_dy = 0.0;
};

inline Properties measure(const Image& image) {
  Properties properties;
  if (image.size() == 0) return properties;

  uint64_t sum = 0;
  for (const uint8_t pixel : image.pixels) {
    properties.minimum = std::min(properties.minimum, unsigned(pixel));
    properties.maximum = std::max(properties.maximum, unsigned(pixel));
    sum += pixel;
  }
  properties.mean = static_cast<double>(sum) /
                    static_cast<double>(image.size());

  double variance = 0.0;
  for (const uint8_t pixel : image.pixels) {
    const double difference = static_cast<double>(pixel) - properties.mean;
    variance += difference * difference;
  }
  properties.deviation =
      std::sqrt(variance / static_cast<double>(image.size()));

  uint64_t horizontal = 0;
  uint64_t horizontal_count = 0;
  uint64_t vertical = 0;
  uint64_t vertical_count = 0;
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      if (x + 1 < image.width) {
        horizontal += static_cast<uint64_t>(
            std::abs(int(image.at(x + 1, y)) - int(image.at(x, y))));
        ++horizontal_count;
      }
      if (y + 1 < image.height) {
        vertical += static_cast<uint64_t>(
            std::abs(int(image.at(x, y + 1)) - int(image.at(x, y))));
        ++vertical_count;
      }
    }
  }
  if (horizontal_count != 0) {
    properties.mean_abs_dx = static_cast<double>(horizontal) /
                             static_cast<double>(horizontal_count);
  }
  if (vertical_count != 0) {
    properties.mean_abs_dy = static_cast<double>(vertical) /
                            static_cast<double>(vertical_count);
  }
  return properties;
}

// --------------------------------------------------------------- deviation --

struct Deviation {
  unsigned max_absolute = 0;
  uint64_t sum_absolute = 0;
  uint64_t differing = 0;
  uint64_t total = 0;

  void accumulate(int measured, int reference) {
    const unsigned difference =
        static_cast<unsigned>(std::abs(measured - reference));
    max_absolute = std::max(max_absolute, difference);
    sum_absolute += difference;
    if (difference != 0) ++differing;
    ++total;
  }

  void merge(const Deviation& other) {
    max_absolute = std::max(max_absolute, other.max_absolute);
    sum_absolute += other.sum_absolute;
    differing += other.differing;
    total += other.total;
  }

  double mean() const {
    return (total == 0) ? 0.0
                        : static_cast<double>(sum_absolute) /
                              static_cast<double>(total);
  }

  double differing_share() const {
    return (total == 0) ? 0.0
                        : (100.0 * static_cast<double>(differing) /
                           static_cast<double>(total));
  }
};

// ----------------------------------------------------------------- PGM I/O --

inline bool read_pgm(const char* path, Image& image) {
  std::FILE* file = std::fopen(path, "rb");
  if (file == nullptr) return false;
  char magic[3] = {0, 0, 0};
  if (std::fscanf(file, "%2s", magic) != 1 || std::strcmp(magic, "P5") != 0) {
    std::fclose(file);
    return false;
  }
  int values[3] = {0, 0, 0};
  for (int index = 0; index < 3;) {
    int character = std::fgetc(file);
    if (character == EOF) {
      std::fclose(file);
      return false;
    }
    if (character == '#') {
      while (character != '\n' && character != EOF) {
        character = std::fgetc(file);
      }
      continue;
    }
    if (std::isspace(character) != 0) continue;
    std::ungetc(character, file);
    if (std::fscanf(file, "%d", &values[index]) != 1) {
      std::fclose(file);
      return false;
    }
    ++index;
  }
  std::fgetc(file);
  if (values[0] <= 0 || values[1] <= 0 || values[2] != 255) {
    std::fclose(file);
    return false;
  }
  image = make_image(values[0], values[1]);
  const size_t read =
      std::fread(image.pixels.data(), 1, image.size(), file);
  std::fclose(file);
  return read == image.size();
}

inline bool write_pgm(const std::string& path, const Image& image) {
  std::FILE* file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  std::fprintf(file, "P5\n%d %d\n255\n", image.width, image.height);
  const size_t written =
      std::fwrite(image.pixels.data(), 1, image.size(), file);
  std::fclose(file);
  return written == image.size();
}

inline void ensure_directory(const std::string& path) {
  for (size_t index = 1; index <= path.size(); ++index) {
    if (index != path.size() && path[index] != '/') continue;
    const std::string prefix = path.substr(0, index);
    if (prefix.empty()) continue;
    ::mkdir(prefix.c_str(), 0755);
  }
}

// ------------------------------------------------------------------- writer --
// Collects one CSV row per emitted image plus the PGM files themselves, so a
// dump directory is self describing without a separate index.

class Writer {
 public:
  Writer(const std::string& directory, const char* workload)
      : directory_(directory), workload_(workload) {
    ensure_directory(directory_);
    const std::string csv = directory_ + "/properties.csv";
    const bool fresh = !exists(csv);
    csv_ = std::fopen(csv.c_str(), "a");
    if ((csv_ != nullptr) && fresh) {
      std::fprintf(csv_,
                   "workload,image,role,width,height,min,max,mean,stddev,"
                   "mean_abs_dx,mean_abs_dy,dev_max,dev_mean,dev_share\n");
    }
  }

  ~Writer() {
    if (csv_ != nullptr) std::fclose(csv_);
  }

  Writer(const Writer&) = delete;
  Writer& operator=(const Writer&) = delete;

  void emit(const char* image_name, const char* role, const Image& image,
            const Deviation* deviation = nullptr) {
    const std::string stem = std::string(workload_) + "_" + image_name + "_" +
                             role;
    write_pgm(directory_ + "/" + stem + ".pgm", image);
    if (csv_ == nullptr) return;
    const Properties properties = measure(image);
    std::fprintf(csv_, "%s,%s,%s,%d,%d,%u,%u,%.3f,%.3f,%.3f,%.3f", workload_,
                 image_name, role, image.width, image.height,
                 properties.minimum, properties.maximum, properties.mean,
                 properties.deviation, properties.mean_abs_dx,
                 properties.mean_abs_dy);
    if (deviation == nullptr) {
      std::fprintf(csv_, ",,,\n");
    } else {
      std::fprintf(csv_, ",%u,%.4f,%.2f\n", deviation->max_absolute,
                   deviation->mean(), deviation->differing_share());
    }
  }

 private:
  static bool exists(const std::string& path) {
    struct stat info;
    return ::stat(path.c_str(), &info) == 0;
  }

  std::string directory_;
  const char* workload_;
  std::FILE* csv_ = nullptr;
};

}  // namespace vsp_image

#endif  // VSP_IMAGE_IO_H_
