VSP Test Dataset
==================================================

Image dimensions: 64 x 64 pixels
Format: 8-bit grayscale
Total size per image: 4096 bytes

Files:
  checkerboard.hex  - 32-bit words for $readmemh (4 address-ordered bytes per little-endian word)
  checkerboard.pgm  - PGM format for viewing
  checkerboard.bin  - Raw binary
  checkerboard.h    - C array format
  gradient_h.hex  - 32-bit words for $readmemh (4 address-ordered bytes per little-endian word)
  gradient_h.pgm  - PGM format for viewing
  gradient_h.bin  - Raw binary
  gradient_h.h    - C array format
  gradient_v.hex  - 32-bit words for $readmemh (4 address-ordered bytes per little-endian word)
  gradient_v.pgm  - PGM format for viewing
  gradient_v.bin  - Raw binary
  gradient_v.h    - C array format
  stripes_v.hex  - 32-bit words for $readmemh (4 address-ordered bytes per little-endian word)
  stripes_v.pgm  - PGM format for viewing
  stripes_v.bin  - Raw binary
  stripes_v.h    - C array format
  blocks_4x4.hex  - 32-bit words for $readmemh (4 address-ordered bytes per little-endian word)
  blocks_4x4.pgm  - PGM format for viewing
  blocks_4x4.bin  - Raw binary
  blocks_4x4.h    - C array format

Memory Layout (for VSP):
  Base address: 0x1000 (configurable)
  Stride: 64 bytes (row-major)
  Each row: 64 consecutive bytes
  VRF access: 16 bytes per load (1 row spans 4 VRF loads)
