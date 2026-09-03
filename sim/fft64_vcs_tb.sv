`timescale 1ns/1ps

// CLASS: workload reference/demo
// CLAIM: the checked-in Q8.8 bin-8 signal, twiddle and bit-reverse fixtures
//        produce the expected conjugate spectrum through a radix-2 DIT FFT.
// SOURCE / QUESTION: docs/DSP_FFT.md and the checked-in 64-point fixtures.
// ORACLE: an analytical real sinusoid has conjugate peaks at bins 8 and 56;
//         the checks also bound DC and every non-peak component.
// ASSUMPTIONS: signed Q8.8 inputs/twiddles, truncation after each complex
//              multiply, and 32-bit work values without per-stage saturation.
// NON-CLAIMS: this behavioral testbench does not execute VSP RTL/uwords and
//             does not establish a VSP cycle count or throughput.
// RETIRE WHEN: an end-to-end VSP FFT program regression subsumes the same
//              fixture, spectrum and quantization checks.
module fft64_vcs_tb;
  localparam integer N = 64;
  localparam integer Q_FRAC = 8;
  localparam integer POSITIVE_PEAK_BIN = 8;
  localparam integer NEGATIVE_PEAK_BIN = N - POSITIVE_PEAK_BIN;
  localparam integer EXPECTED_PEAK = 6561;
  localparam integer PEAK_TOLERANCE = 2;
  localparam integer SPURIOUS_LIMIT = 1;

  reg [15:0] input_samples [0:N-1];
  reg [15:0] twiddle_cos [0:(N/2)-1];
  reg [15:0] twiddle_sin [0:(N/2)-1];
  reg [15:0] bit_reverse [0:N-1];

  integer fft_real [0:N-1];
  integer fft_imag [0:N-1];
  integer stage_size;
  integer half_size;
  integer twiddle_step;
  integer base;
  integer lane;
  /* verilator lint_off UNUSED */
  integer twiddle_index;
  /* verilator lint_on UNUSED */
  integer index_a;
  /* verilator lint_off UNUSED */
  integer index_b;
  /* verilator lint_on UNUSED */
  integer a_real;
  integer a_imag;
  integer b_real;
  integer b_imag;
  integer product_real;
  integer product_imag;
  integer bin;
  /* verilator lint_off UNUSED */
  integer source_index;
  /* verilator lint_on UNUSED */
  integer checks;

  function integer signed16;
    input [15:0] value;
    begin
      signed16 = {{16{value[15]}}, value};
    end
  endfunction

  function integer abs_integer;
    input integer value;
    begin
      if (value < 0)
        abs_integer = -value;
      else
        abs_integer = value;
    end
  endfunction

  task expect_close;
    input [8*48-1:0] name;
    input integer expected;
    input integer actual;
    input integer tolerance;
    begin
      checks = checks + 1;
      if (abs_integer(actual - expected) > tolerance) begin
        $display("FAIL %0s expected=%0d actual=%0d tolerance=%0d",
                 name, expected, actual, tolerance);
        $fatal(1);
      end
    end
  endtask

  task check_loaded_fixtures;
    begin
      for (bin = 0; bin < N; bin = bin + 1) begin
        if (^input_samples[bin] === 1'bx) begin
          $display("FAIL input fixture has X at index %0d", bin);
          $fatal(1);
        end
        if (^bit_reverse[bin] === 1'bx) begin
          $display("FAIL bit-reverse fixture has X at index %0d", bin);
          $fatal(1);
        end
        if ({16'b0, bit_reverse[bin]} >= N) begin
          $display("FAIL bit-reverse index %0d is out of range", bin);
          $fatal(1);
        end
      end
      for (bin = 0; bin < N/2; bin = bin + 1) begin
        if (^twiddle_cos[bin] === 1'bx ||
            ^twiddle_sin[bin] === 1'bx) begin
          $display("FAIL twiddle fixture has X at index %0d", bin);
          $fatal(1);
        end
      end
    end
  endtask

  initial begin
    checks = 0;
    for (bin = 0; bin < N; bin = bin + 1) begin
      input_samples[bin] = 16'hxxxx;
      bit_reverse[bin] = 16'hxxxx;
    end
    for (bin = 0; bin < N/2; bin = bin + 1) begin
      twiddle_cos[bin] = 16'hxxxx;
      twiddle_sin[bin] = 16'hxxxx;
    end

    $readmemh("test_data/signals/fft_test_64_bin8.hex", input_samples);
    $readmemh("test_data/fft/fft64_twiddle_cos.hex", twiddle_cos);
    $readmemh("test_data/fft/fft64_twiddle_sin.hex", twiddle_sin);
    $readmemh("test_data/fft/fft64_bitreverse.hex", bit_reverse);
    check_loaded_fixtures();

    // The DIT kernel consumes bit-reversed input and produces natural-order
    // output.  The checked-in bit-reverse table is part of the demo contract.
    for (bin = 0; bin < N; bin = bin + 1) begin
      source_index = {16'b0, bit_reverse[bin]};
      fft_real[bin] = signed16(input_samples[source_index]);
      fft_imag[bin] = 0;
    end

    stage_size = 2;
    while (stage_size <= N) begin
      half_size = stage_size / 2;
      twiddle_step = N / stage_size;
      for (base = 0; base < N; base = base + stage_size) begin
        for (lane = 0; lane < half_size; lane = lane + 1) begin
          index_a = base + lane;
          index_b = index_a + half_size;
          twiddle_index = lane * twiddle_step;

          a_real = fft_real[index_a];
          a_imag = fft_imag[index_a];
          b_real = fft_real[index_b];
          b_imag = fft_imag[index_b];

          // W[k] is already exp(-j*2*pi*k/N).  Products return to Q8.8
          // after an arithmetic right shift, matching the intended fixed-
          // point VSP implementation.
          product_real =
              ((b_real * signed16(twiddle_cos[twiddle_index])) -
               (b_imag * signed16(twiddle_sin[twiddle_index]))) >>> Q_FRAC;
          product_imag =
              ((b_real * signed16(twiddle_sin[twiddle_index])) +
               (b_imag * signed16(twiddle_cos[twiddle_index]))) >>> Q_FRAC;

          fft_real[index_a] = a_real + product_real;
          fft_imag[index_a] = a_imag + product_imag;
          fft_real[index_b] = a_real - product_real;
          fft_imag[index_b] = a_imag - product_imag;
        end
      end
      // One marker interval per FFT stage makes stage progression observable
      // in a VCS waveform.  It is not a claim about VSP hardware latency.
      /* verilator lint_off STMTDLY */
      #1;
      /* verilator lint_on STMTDLY */
      stage_size = stage_size * 2;
    end

    expect_close("DC real", 0, fft_real[0], SPURIOUS_LIMIT);
    expect_close("DC imaginary", 0, fft_imag[0], SPURIOUS_LIMIT);
    expect_close("bin 8 real", 0, fft_real[POSITIVE_PEAK_BIN],
                 SPURIOUS_LIMIT);
    expect_close("bin 8 imaginary", -EXPECTED_PEAK,
                 fft_imag[POSITIVE_PEAK_BIN], PEAK_TOLERANCE);
    expect_close("bin 56 real", 0, fft_real[NEGATIVE_PEAK_BIN],
                 SPURIOUS_LIMIT);
    expect_close("bin 56 imaginary", EXPECTED_PEAK,
                 fft_imag[NEGATIVE_PEAK_BIN], PEAK_TOLERANCE);
    expect_close("peak conjugate real", fft_real[POSITIVE_PEAK_BIN],
                 fft_real[NEGATIVE_PEAK_BIN], SPURIOUS_LIMIT);
    expect_close("peak conjugate imaginary", -fft_imag[POSITIVE_PEAK_BIN],
                 fft_imag[NEGATIVE_PEAK_BIN], SPURIOUS_LIMIT);

    for (bin = 0; bin < N; bin = bin + 1) begin
      if (bin != POSITIVE_PEAK_BIN && bin != NEGATIVE_PEAK_BIN) begin
        expect_close("non-peak real", 0, fft_real[bin], SPURIOUS_LIMIT);
        expect_close("non-peak imaginary", 0, fft_imag[bin],
                     SPURIOUS_LIMIT);
      end
    end

    $display("FFT64 spectrum: bin 8=(%0d,%0d), bin 56=(%0d,%0d) Q8.8",
             fft_real[POSITIVE_PEAK_BIN], fft_imag[POSITIVE_PEAK_BIN],
             fft_real[NEGATIVE_PEAK_BIN], fft_imag[NEGATIVE_PEAK_BIN]);
    $display("PASS fft64_vcs_tb: %0d checks", checks);
    $finish;
  end
endmodule
