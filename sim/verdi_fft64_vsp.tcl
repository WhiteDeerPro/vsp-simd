# SPDX-License-Identifier: MIT
# Populate the nWave window for the FFT64 static-BFP8 VCS regression.
# Launch after loading either the bin-8 or mixed-wave FFT64 FSDB.

if {![info exists _nWave2]} {
  set _nWave2 [wvCreateWindow]
}
wvResizeWindow -win $_nWave2 1200 780

wvAddSignal -win $_nWave2 -clear
wvAddSignal -win $_nWave2 -group {"FFT control" \
  {/fft64_vsp_vcs_tb/clk_i} \
  {/fft64_vsp_vcs_tb/rst_ni} \
  {/fft64_vsp_vcs_tb/program_active_o} \
  {/fft64_vsp_vcs_tb/program_done_o} \
  {/fft64_vsp_vcs_tb/fetch_pc_o[31:0]} \
  {/fft64_vsp_vcs_tb/completed_actions} \
  {/fft64_vsp_vcs_tb/fft_stage} \
  {/fft64_vsp_vcs_tb/fft_batch} \
  {/fft64_vsp_vcs_tb/bfp_exponent} \
}
wvAddSignal -win $_nWave2 -group {"Completion and memory" \
  {/fft64_vsp_vcs_tb/action_cpl_valid_o} \
  {/fft64_vsp_vcs_tb/action_cpl_class_o[1:0]} \
  {/fft64_vsp_vcs_tb/perf_icache_read_hit_o} \
  {/fft64_vsp_vcs_tb/perf_icache_read_miss_o} \
  {/fft64_vsp_vcs_tb/perf_dcache_read_hit_o} \
  {/fft64_vsp_vcs_tb/perf_dcache_read_miss_o} \
  {/fft64_vsp_vcs_tb/perf_dcache_write_hit_o} \
  {/fft64_vsp_vcs_tb/perf_dcache_write_miss_o} \
  {/fft64_vsp_vcs_tb/icache_misses} \
  {/fft64_vsp_vcs_tb/dcache_read_misses} \
  {/fft64_vsp_vcs_tb/lower_req_count_o[31:0]} \
}
wvAddSignal -win $_nWave2 -group {"FFT spectrum scan" \
  {/fft64_vsp_vcs_tb/plot_valid} \
  {/fft64_vsp_vcs_tb/plot_bin[5:0]} \
  {/fft64_vsp_vcs_tb/plot_real_mantissa[7:0]} \
  {/fft64_vsp_vcs_tb/plot_imag_mantissa[7:0]} \
  {/fft64_vsp_vcs_tb/plot_exponent[7:0]} \
  {/fft64_vsp_vcs_tb/plot_real_value} \
  {/fft64_vsp_vcs_tb/plot_imag_value} \
  {/fft64_vsp_vcs_tb/plot_magnitude} \
  {/fft64_vsp_vcs_tb/plot_power} \
  {/fft64_vsp_vcs_tb/plot_real_q16_16[31:0]} \
  {/fft64_vsp_vcs_tb/plot_imag_q16_16[31:0]} \
  {/fft64_vsp_vcs_tb/plot_magnitude_q16_16[31:0]} \
  {/fft64_vsp_vcs_tb/plot_power_q16_16[31:0]} \
}

# Open directly on the final 67 clock cycles, which contain the post-quiescence
# 64-bin visualization phase.  Deriving the range from the loaded FSDB keeps
# the view valid if the workload latency changes.
wvCollapseGroup -win $_nWave2 "FFT control"
wvCollapseGroup -win $_nWave2 "Completion and memory"
wvExpandGroup -win $_nWave2 "FFT spectrum scan"
wvSetRadix -win $_nWave2 -format Dec \
  {("FFT spectrum scan" 2)}
wvSetRadix -win $_nWave2 -2Com -format Dec \
  {("FFT spectrum scan" 3 4 5 10 11 12 13)}
wvSelectSignal -win $_nWave2 \
  {("FFT spectrum scan" 6 7 8 9)}
wvBusWaveform -win $_nWave2 -analog
set _fft_file_time_range [wvGetFileTimeRange -win $_nWave2]
if {[llength $_fft_file_time_range] >= 2 &&
    [string is double -strict [lindex $_fft_file_time_range 1]]} {
  set _fft_file_end [lindex $_fft_file_time_range 1]
  set _fft_scan_start [expr {max(0.0, $_fft_file_end - 670000.0)}]
  wvZoom -win $_nWave2 $_fft_scan_start $_fft_file_end
} else {
  wvZoomAll -win $_nWave2
}
wvScrollUp -win $_nWave2 1000
