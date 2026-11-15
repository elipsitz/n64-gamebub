`default_nettype none

// Top-level SystemVerilog wrapper bound to `N64Core` (`SELF_TEST_MODE = 0`)
// and `N64SelfTestCore` (`SELF_TEST_MODE = 1`) via Chisel `bindExtModule`.
//
// Integrates:
//   1. `n64_mmcm`: single-MMCM 7-clock tree (`VCO = 750.000 MHz`) + runtime
//      fine-phase shift (`ps_target`) for `sdram_clk`
//   2. `gb_host_bridge`: `HostV0` (eager + Phase-5 `on_demand` `0x0400..0x0404`),
//      `InputExtendedV0(4)`, `VibrateV0` (Rumble Pak), and 48 kHz `AudioV0`
//   3. `n64_soc_gb`: VR4300 (`93.75 MHz`) + COP1 FPU + RSP (`LANES=8`) + RDP +
//      dual-rank 64 MiB `W9825G6KH-6` SDRAM + 512 KiB 10 ns SRAM + L1/L2 PI
//      ROM cache + `320x240` `RGB666` video scanout/downsampler
module n64_gamebub_top #(
    parameter int DISPLAY_DIVIDER = 25,
    parameter int NUM_SDRAM_CHIPS = 2,
    parameter int SELF_TEST_MODE  = 0,
    parameter     BOOTROM         = "boot.hex",
    parameter     SELFTEST_HEX    = "n64_selftest.hex",
    parameter int SDR_T_INIT      = 12600
) (
    input  wire logic        clock,
    input  wire logic        reset,

    // ClocksV0
    input  wire logic        clocks_clockIn50M,
    output wire logic        clocks_clockOutSystem,
    output wire logic        clocks_clockOutDisplay,
    output wire logic        clocks_clockOutSpi,
    output wire logic        clocks_locked,

    // VideoV0 (320x240 RGB666 @ 60 Hz, synchronous to `clock` / `clk_sys`)
    output wire logic [5:0]  video_data_r,
    output wire logic [5:0]  video_data_g,
    output wire logic [5:0]  video_data_b,
    output wire logic        video_dataEnable,
    output wire logic        video_vblank,
    output wire logic        video_hblank,

    // AudioV0 (signed 16-bit stereo @ 48 kHz)
    output wire logic signed [15:0] audio_left,
    output wire logic signed [15:0] audio_right,

    // HostV0
    input  wire logic        host_mem_enable,
    input  wire logic        host_mem_write,
    output wire logic        host_mem_done,
    input  wire logic [31:0] host_mem_address,
    output wire logic [31:0] host_mem_dataRead,
    input  wire logic [31:0] host_mem_dataWrite,

    input  wire logic        host_commandHost_request,
    output wire logic        host_commandHost_busy,
    output wire logic        host_commandHost_done,
    output wire logic        host_commandHost_error,

    output wire logic        host_commandCore_request,
    input  wire logic        host_commandCore_busy,
    input  wire logic        host_commandCore_done,
    input  wire logic        host_commandCore_error,

    // InputExtendedV0 (4 controller slots)
    input  wire logic        input_slots_0_active,
    input  wire logic [3:0]  input_slots_0_deviceType,
    input  wire logic        input_slots_0_buttons_a,
    input  wire logic        input_slots_0_buttons_b,
    input  wire logic        input_slots_0_buttons_x,
    input  wire logic        input_slots_0_buttons_y,
    input  wire logic        input_slots_0_buttons_up,
    input  wire logic        input_slots_0_buttons_down,
    input  wire logic        input_slots_0_buttons_left,
    input  wire logic        input_slots_0_buttons_right,
    input  wire logic        input_slots_0_buttons_l1,
    input  wire logic        input_slots_0_buttons_r1,
    input  wire logic        input_slots_0_buttons_l2,
    input  wire logic        input_slots_0_buttons_r2,
    input  wire logic        input_slots_0_buttons_l3,
    input  wire logic        input_slots_0_buttons_r3,
    input  wire logic        input_slots_0_buttons_start,
    input  wire logic        input_slots_0_buttons_select,
    input  wire logic [7:0]  input_slots_0_analog_leftX,
    input  wire logic [7:0]  input_slots_0_analog_leftY,
    input  wire logic [7:0]  input_slots_0_analog_rightX,
    input  wire logic [7:0]  input_slots_0_analog_rightY,
    input  wire logic [7:0]  input_slots_0_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_0_analog_rightTrigger,

    input  wire logic        input_slots_1_active,
    input  wire logic [3:0]  input_slots_1_deviceType,
    input  wire logic        input_slots_1_buttons_a,
    input  wire logic        input_slots_1_buttons_b,
    input  wire logic        input_slots_1_buttons_x,
    input  wire logic        input_slots_1_buttons_y,
    input  wire logic        input_slots_1_buttons_up,
    input  wire logic        input_slots_1_buttons_down,
    input  wire logic        input_slots_1_buttons_left,
    input  wire logic        input_slots_1_buttons_right,
    input  wire logic        input_slots_1_buttons_l1,
    input  wire logic        input_slots_1_buttons_r1,
    input  wire logic        input_slots_1_buttons_l2,
    input  wire logic        input_slots_1_buttons_r2,
    input  wire logic        input_slots_1_buttons_l3,
    input  wire logic        input_slots_1_buttons_r3,
    input  wire logic        input_slots_1_buttons_start,
    input  wire logic        input_slots_1_buttons_select,
    input  wire logic [7:0]  input_slots_1_analog_leftX,
    input  wire logic [7:0]  input_slots_1_analog_leftY,
    input  wire logic [7:0]  input_slots_1_analog_rightX,
    input  wire logic [7:0]  input_slots_1_analog_rightY,
    input  wire logic [7:0]  input_slots_1_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_1_analog_rightTrigger,

    input  wire logic        input_slots_2_active,
    input  wire logic [3:0]  input_slots_2_deviceType,
    input  wire logic        input_slots_2_buttons_a,
    input  wire logic        input_slots_2_buttons_b,
    input  wire logic        input_slots_2_buttons_x,
    input  wire logic        input_slots_2_buttons_y,
    input  wire logic        input_slots_2_buttons_up,
    input  wire logic        input_slots_2_buttons_down,
    input  wire logic        input_slots_2_buttons_left,
    input  wire logic        input_slots_2_buttons_right,
    input  wire logic        input_slots_2_buttons_l1,
    input  wire logic        input_slots_2_buttons_r1,
    input  wire logic        input_slots_2_buttons_l2,
    input  wire logic        input_slots_2_buttons_r2,
    input  wire logic        input_slots_2_buttons_l3,
    input  wire logic        input_slots_2_buttons_r3,
    input  wire logic        input_slots_2_buttons_start,
    input  wire logic        input_slots_2_buttons_select,
    input  wire logic [7:0]  input_slots_2_analog_leftX,
    input  wire logic [7:0]  input_slots_2_analog_leftY,
    input  wire logic [7:0]  input_slots_2_analog_rightX,
    input  wire logic [7:0]  input_slots_2_analog_rightY,
    input  wire logic [7:0]  input_slots_2_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_2_analog_rightTrigger,

    input  wire logic        input_slots_3_active,
    input  wire logic [3:0]  input_slots_3_deviceType,
    input  wire logic        input_slots_3_buttons_a,
    input  wire logic        input_slots_3_buttons_b,
    input  wire logic        input_slots_3_buttons_x,
    input  wire logic        input_slots_3_buttons_y,
    input  wire logic        input_slots_3_buttons_up,
    input  wire logic        input_slots_3_buttons_down,
    input  wire logic        input_slots_3_buttons_left,
    input  wire logic        input_slots_3_buttons_right,
    input  wire logic        input_slots_3_buttons_l1,
    input  wire logic        input_slots_3_buttons_r1,
    input  wire logic        input_slots_3_buttons_l2,
    input  wire logic        input_slots_3_buttons_r2,
    input  wire logic        input_slots_3_buttons_l3,
    input  wire logic        input_slots_3_buttons_r3,
    input  wire logic        input_slots_3_buttons_start,
    input  wire logic        input_slots_3_buttons_select,
    input  wire logic [7:0]  input_slots_3_analog_leftX,
    input  wire logic [7:0]  input_slots_3_analog_leftY,
    input  wire logic [7:0]  input_slots_3_analog_rightX,
    input  wire logic [7:0]  input_slots_3_analog_rightY,
    input  wire logic [7:0]  input_slots_3_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_3_analog_rightTrigger,

    // VibrateV0
    output wire logic [1:0]  vibrate_mode,

    // SdramV0 (2x W9825G6KH-6 = 64 MiB total on Rev4)
    output wire logic        sdram_clock,
    output wire logic [NUM_SDRAM_CHIPS-1:0] sdram_cke,
    output wire logic [NUM_SDRAM_CHIPS-1:0] sdram_cs,
    output wire logic        sdram_ras,
    output wire logic        sdram_cas,
    output wire logic        sdram_we,
    output wire logic [1:0]  sdram_dqm,
    output wire logic [1:0]  sdram_bank,
    output wire logic [12:0] sdram_address,
    input  wire logic [15:0] sdram_dataIn,
    output wire logic [15:0] sdram_dataOut,
    output wire logic        sdram_dataDir,

    // SramV0 (IS61WV25616EDBLL-10TLI = 512 KiB, 10 ns)
    output wire logic        sram_ceN,
    output wire logic        sram_weN,
    output wire logic        sram_oeN,
    output wire logic [1:0]  sram_writeMaskN,
    output wire logic [17:0] sram_address,
    input  wire logic [15:0] sram_dataIn,
    output wire logic [15:0] sram_dataOut,
    output wire logic        sram_dataDir
);
    // -------------------------------------------------------------------------
    // 1. Unified MMCM Clock Generation (VCO = 750.000 MHz)
    // -------------------------------------------------------------------------
    wire clk_sys;
    wire clk_cpu;
    wire clk_sys2x;
    wire clk_sdram_pad;
    wire clk_spi;
    wire clk_display;
    wire clk_vid;
    wire mmcm_locked;
    wire signed [7:0] sdram_ps_target;

    n64_mmcm #(
        .CLK_DISPLAY_DIVIDE (DISPLAY_DIVIDER),
        .SDRAM_CLK_PHASE    (-135.0)
    ) u_mmcm (
        .clk_in_50mhz  (clocks_clockIn50M),
        .clk_sys       (clk_sys),
        .clk_cpu       (clk_cpu),
        .clk_sys2x     (clk_sys2x),
        .clk_sdram_pad (clk_sdram_pad),
        .clk_spi       (clk_spi),
        .clk_display   (clk_display),
        .clk_vid       (clk_vid),
        .locked        (mmcm_locked),
        .ps_target     (sdram_ps_target),
        .ps_current    ()
    );

    assign clocks_clockOutSystem  = clk_sys;
    assign clocks_clockOutDisplay = clk_display;
    assign clocks_clockOutSpi     = clk_spi;
    assign clocks_locked          = mmcm_locked;

    // -------------------------------------------------------------------------
    // 2. Host Bridge <-> SoC Interconnect Wires
    // -------------------------------------------------------------------------
    wire        sdr_ready_raw, sram_ready;
    wire        sdr_ready_for_host;

    wire [11:0] apf_audio_buffer_fill;
    wire [31:0] apf_audio_bus_out;
    wire        apf_audio_bus_wr;
    wire        apf_audio_flush;
    wire        apf_audio_playback_en;

    wire [2:0]  apf_bridge_command_result_code;
    wire        apf_bridge_complete_trigger;
    wire [31:0] apf_bridge_current_address;
    wire [31:0] apf_bridge_data_offset;
    wire [31:0] apf_bridge_file_size;
    wire        apf_bridge_file_size_wr;
    wire        apf_bridge_host_loaded_br;
    wire        apf_bridge_host_loaded_soc;
    wire        apf_bridge_host_reset_n;
    wire [31:0] apf_bridge_length;
    wire [31:0] apf_bridge_new_file_size_data;
    wire [31:0] apf_bridge_ram_data_address;
    wire        apf_bridge_request_getfile;
    wire        apf_bridge_request_openfile;
    wire        apf_bridge_request_read;
    wire        apf_bridge_request_write;
    wire        apf_bridge_request_setsize;
    wire        apf_bridge_request_flush;
    wire [15:0] apf_bridge_slot_id;

    wire        apf_pad_clk;
    wire        apf_pad_we;
    wire [3:0]  apf_pad_wa;
    wire [31:0] apf_pad_wd;

    wire [4:0]  apf_interact_address;
    wire [31:0] apf_interact_data;
    wire        apf_interact_wr;
    wire [31:0] apf_interact_q;
    wire        rumble_motor_on;

    wire        hb_sdr_valid, hb_sdr_we, hb_sdr_ready, hb_sdr_rvalid, hb_sdr_pending;
    wire [23:0] hb_sdr_addr;
    wire [31:0] hb_sdr_wdata, hb_sdr_rdata;
    wire [3:0]  hb_sdr_be;

    wire        soc_sdr_valid, soc_sdr_we, soc_sdr_ready, soc_sdr_rvalid, soc_sdr_pending;
    wire [23:0] soc_sdr_addr;
    wire [31:0] soc_sdr_wdata, soc_sdr_rdata;
    wire [3:0]  soc_sdr_be;

    wire        h_sram_valid, h_sram_we, h_sram_ack;
    wire [16:0] h_sram_addr;
    wire [31:0] h_sram_wdata, h_sram_rdata;
    wire [3:0]  h_sram_be;

    wire        setup_done, core_running, core_focused;
    wire        rom_cache_inv;
    wire        vid_horiz_blend_en, vid_dither_en, vid_no_weave;

    // Simulation observable UART & CPU debug taps
    wire        uart_tx_we   /* verilator public_flat_rd */;
    wire [7:0]  uart_tx_byte /* verilator public_flat_rd */;
    wire [31:0] dbg_cpu_pc   /* verilator public_flat_rd */;
    wire [31:0] dbg_cpu_cause/* verilator public_flat_rd */;
    wire [31:0] dbg_cpu_epc  /* verilator public_flat_rd */;

    gb_host_bridge #(
        .DIAG_L3_RUMBLE (SELF_TEST_MODE != 0)
    ) u_host_bridge (
        .clk                            (clock),
        .rst                            (reset),
        .sdr_ready                      (sdr_ready_for_host),
        .sram_ready                     (sram_ready),

        .host_mem_enable                (host_mem_enable),
        .host_mem_write                 (host_mem_write),
        .host_mem_done                  (host_mem_done),
        .host_mem_address               (host_mem_address),
        .host_mem_dataRead              (host_mem_dataRead),
        .host_mem_dataWrite             (host_mem_dataWrite),

        .host_commandHost_request       (host_commandHost_request),
        .host_commandHost_busy          (host_commandHost_busy),
        .host_commandHost_done          (host_commandHost_done),
        .host_commandHost_error         (host_commandHost_error),

        .host_commandCore_request       (host_commandCore_request),
        .host_commandCore_busy          (host_commandCore_busy),
        .host_commandCore_done          (host_commandCore_done),
        .host_commandCore_error         (host_commandCore_error),

        .input_slots_0_active           (input_slots_0_active),
        .input_slots_0_deviceType       (input_slots_0_deviceType),
        .input_slots_0_buttons_a        (input_slots_0_buttons_a),
        .input_slots_0_buttons_b        (input_slots_0_buttons_b),
        .input_slots_0_buttons_x        (input_slots_0_buttons_x),
        .input_slots_0_buttons_y        (input_slots_0_buttons_y),
        .input_slots_0_buttons_up       (input_slots_0_buttons_up),
        .input_slots_0_buttons_down     (input_slots_0_buttons_down),
        .input_slots_0_buttons_left     (input_slots_0_buttons_left),
        .input_slots_0_buttons_right    (input_slots_0_buttons_right),
        .input_slots_0_buttons_l1       (input_slots_0_buttons_l1),
        .input_slots_0_buttons_r1       (input_slots_0_buttons_r1),
        .input_slots_0_buttons_l2       (input_slots_0_buttons_l2),
        .input_slots_0_buttons_r2       (input_slots_0_buttons_r2),
        .input_slots_0_buttons_l3       (input_slots_0_buttons_l3),
        .input_slots_0_buttons_r3       (input_slots_0_buttons_r3),
        .input_slots_0_buttons_start    (input_slots_0_buttons_start),
        .input_slots_0_buttons_select   (input_slots_0_buttons_select),
        .input_slots_0_analog_leftX     (input_slots_0_analog_leftX),
        .input_slots_0_analog_leftY     (input_slots_0_analog_leftY),
        .input_slots_0_analog_rightX    (input_slots_0_analog_rightX),
        .input_slots_0_analog_rightY    (input_slots_0_analog_rightY),
        .input_slots_0_analog_leftTrigger (input_slots_0_analog_leftTrigger),
        .input_slots_0_analog_rightTrigger(input_slots_0_analog_rightTrigger),

        .input_slots_1_active           (input_slots_1_active),
        .input_slots_1_deviceType       (input_slots_1_deviceType),
        .input_slots_1_buttons_a        (input_slots_1_buttons_a),
        .input_slots_1_buttons_b        (input_slots_1_buttons_b),
        .input_slots_1_buttons_x        (input_slots_1_buttons_x),
        .input_slots_1_buttons_y        (input_slots_1_buttons_y),
        .input_slots_1_buttons_up       (input_slots_1_buttons_up),
        .input_slots_1_buttons_down     (input_slots_1_buttons_down),
        .input_slots_1_buttons_left     (input_slots_1_buttons_left),
        .input_slots_1_buttons_right    (input_slots_1_buttons_right),
        .input_slots_1_buttons_l1       (input_slots_1_buttons_l1),
        .input_slots_1_buttons_r1       (input_slots_1_buttons_r1),
        .input_slots_1_buttons_l2       (input_slots_1_buttons_l2),
        .input_slots_1_buttons_r2       (input_slots_1_buttons_r2),
        .input_slots_1_buttons_l3       (input_slots_1_buttons_l3),
        .input_slots_1_buttons_r3       (input_slots_1_buttons_r3),
        .input_slots_1_buttons_start    (input_slots_1_buttons_start),
        .input_slots_1_buttons_select   (input_slots_1_buttons_select),
        .input_slots_1_analog_leftX     (input_slots_1_analog_leftX),
        .input_slots_1_analog_leftY     (input_slots_1_analog_leftY),
        .input_slots_1_analog_rightX    (input_slots_1_analog_rightX),
        .input_slots_1_analog_rightY    (input_slots_1_analog_rightY),
        .input_slots_1_analog_leftTrigger (input_slots_1_analog_leftTrigger),
        .input_slots_1_analog_rightTrigger(input_slots_1_analog_rightTrigger),

        .input_slots_2_active           (input_slots_2_active),
        .input_slots_2_deviceType       (input_slots_2_deviceType),
        .input_slots_2_buttons_a        (input_slots_2_buttons_a),
        .input_slots_2_buttons_b        (input_slots_2_buttons_b),
        .input_slots_2_buttons_x        (input_slots_2_buttons_x),
        .input_slots_2_buttons_y        (input_slots_2_buttons_y),
        .input_slots_2_buttons_up       (input_slots_2_buttons_up),
        .input_slots_2_buttons_down     (input_slots_2_buttons_down),
        .input_slots_2_buttons_left     (input_slots_2_buttons_left),
        .input_slots_2_buttons_right    (input_slots_2_buttons_right),
        .input_slots_2_buttons_l1       (input_slots_2_buttons_l1),
        .input_slots_2_buttons_r1       (input_slots_2_buttons_r1),
        .input_slots_2_buttons_l2       (input_slots_2_buttons_l2),
        .input_slots_2_buttons_r2       (input_slots_2_buttons_r2),
        .input_slots_2_buttons_l3       (input_slots_2_buttons_l3),
        .input_slots_2_buttons_r3       (input_slots_2_buttons_r3),
        .input_slots_2_buttons_start    (input_slots_2_buttons_start),
        .input_slots_2_buttons_select   (input_slots_2_buttons_select),
        .input_slots_2_analog_leftX     (input_slots_2_analog_leftX),
        .input_slots_2_analog_leftY     (input_slots_2_analog_leftY),
        .input_slots_2_analog_rightX    (input_slots_2_analog_rightX),
        .input_slots_2_analog_rightY    (input_slots_2_analog_rightY),
        .input_slots_2_analog_leftTrigger (input_slots_2_analog_leftTrigger),
        .input_slots_2_analog_rightTrigger(input_slots_2_analog_rightTrigger),

        .input_slots_3_active           (input_slots_3_active),
        .input_slots_3_deviceType       (input_slots_3_deviceType),
        .input_slots_3_buttons_a        (input_slots_3_buttons_a),
        .input_slots_3_buttons_b        (input_slots_3_buttons_b),
        .input_slots_3_buttons_x        (input_slots_3_buttons_x),
        .input_slots_3_buttons_y        (input_slots_3_buttons_y),
        .input_slots_3_buttons_up       (input_slots_3_buttons_up),
        .input_slots_3_buttons_down     (input_slots_3_buttons_down),
        .input_slots_3_buttons_left     (input_slots_3_buttons_left),
        .input_slots_3_buttons_right    (input_slots_3_buttons_right),
        .input_slots_3_buttons_l1       (input_slots_3_buttons_l1),
        .input_slots_3_buttons_r1       (input_slots_3_buttons_r1),
        .input_slots_3_buttons_l2       (input_slots_3_buttons_l2),
        .input_slots_3_buttons_r2       (input_slots_3_buttons_r2),
        .input_slots_3_buttons_l3       (input_slots_3_buttons_l3),
        .input_slots_3_buttons_r3       (input_slots_3_buttons_r3),
        .input_slots_3_buttons_start    (input_slots_3_buttons_start),
        .input_slots_3_buttons_select   (input_slots_3_buttons_select),
        .input_slots_3_analog_leftX     (input_slots_3_analog_leftX),
        .input_slots_3_analog_leftY     (input_slots_3_analog_leftY),
        .input_slots_3_analog_rightX    (input_slots_3_analog_rightX),
        .input_slots_3_analog_rightY    (input_slots_3_analog_rightY),
        .input_slots_3_analog_leftTrigger (input_slots_3_analog_leftTrigger),
        .input_slots_3_analog_rightTrigger(input_slots_3_analog_rightTrigger),

        .rumble_motor_on                (rumble_motor_on),
        .vibrate_mode                   (vibrate_mode),

        .audio_left                     (audio_left),
        .audio_right                    (audio_right),

        .apf_audio_buffer_fill          (apf_audio_buffer_fill),
        .apf_audio_bus_out              (apf_audio_bus_out),
        .apf_audio_bus_wr               (apf_audio_bus_wr),
        .apf_audio_flush                (apf_audio_flush),
        .apf_audio_playback_en          (apf_audio_playback_en),

        .apf_bridge_command_result_code (apf_bridge_command_result_code),
        .apf_bridge_complete_trigger    (apf_bridge_complete_trigger),
        .apf_bridge_current_address     (apf_bridge_current_address),
        .apf_bridge_data_offset         (apf_bridge_data_offset),
        .apf_bridge_file_size           (apf_bridge_file_size),
        .apf_bridge_file_size_wr        (apf_bridge_file_size_wr),
        .apf_bridge_host_loaded         (apf_bridge_host_loaded_br),
        .apf_bridge_host_reset_n        (apf_bridge_host_reset_n),
        .apf_bridge_length              (apf_bridge_length),
        .apf_bridge_new_file_size_data  (apf_bridge_new_file_size_data),
        .apf_bridge_ram_data_address    (apf_bridge_ram_data_address),
        .apf_bridge_request_getfile     (apf_bridge_request_getfile),
        .apf_bridge_request_openfile    (apf_bridge_request_openfile),
        .apf_bridge_request_read        (apf_bridge_request_read),
        .apf_bridge_request_write       (apf_bridge_request_write),
        .apf_bridge_request_setsize     (apf_bridge_request_setsize),
        .apf_bridge_request_flush       (apf_bridge_request_flush),
        .apf_bridge_slot_id             (apf_bridge_slot_id),

        .apf_pad_clk                    (apf_pad_clk),
        .apf_pad_we                     (apf_pad_we),
        .apf_pad_wa                     (apf_pad_wa),
        .apf_pad_wd                     (apf_pad_wd),

        .apf_interact_address           (apf_interact_address),
        .apf_interact_data              (apf_interact_data),
        .apf_interact_wr                (apf_interact_wr),

        .br_sdr_valid                   (hb_sdr_valid),
        .br_sdr_we                      (hb_sdr_we),
        .br_sdr_addr                    (hb_sdr_addr),
        .br_sdr_wdata                   (hb_sdr_wdata),
        .br_sdr_be                      (hb_sdr_be),
        .br_sdr_ready                   (hb_sdr_ready),
        .br_sdr_rvalid                  (hb_sdr_rvalid),
        .br_sdr_rdata                   (hb_sdr_rdata),
        .br_sdr_pending                 (hb_sdr_pending),

        .h_sram_valid                   (h_sram_valid),
        .h_sram_we                      (h_sram_we),
        .h_sram_addr                    (h_sram_addr),
        .h_sram_wdata                   (h_sram_wdata),
        .h_sram_be                      (h_sram_be),
        .h_sram_ack                     (h_sram_ack),
        .h_sram_rdata                   (h_sram_rdata),

        .setup_done                     (setup_done),
        .core_running                   (core_running),
        .core_focused                   (core_focused),
        .rom_cache_inv                  (rom_cache_inv),
        .vid_horiz_blend_en             (vid_horiz_blend_en),
        .vid_dither_en                  (vid_dither_en),
        .vid_no_weave                   (vid_no_weave),
        .sdram_ps_target                (sdram_ps_target)
    );

    // -------------------------------------------------------------------------
    // 3. Optional Embedded `N64SelfTestCore` BRAM -> SDRAM Loader
    //    (Zero LUT/BRAM cost when `SELF_TEST_MODE == 0`)
    // -------------------------------------------------------------------------
    generate if (SELF_TEST_MODE != 0) begin : g_selftest_loader
        localparam int ST_WORDS = 2048; // 8 KiB = 2.0 RAMB36E1s

        (* rom_style = "block" *) logic [31:0] st_rom [0:ST_WORDS-1];
        initial $readmemh(SELFTEST_HEX, st_rom);

        logic        st_done, st_have_word;
        logic [10:0] st_idx;
        logic [31:0] st_word;

        always_ff @(posedge clock) begin
            st_word <= st_rom[st_idx];
            if (reset) begin
                st_done      <= 1'b0;
                st_have_word <= 1'b0;
                st_idx       <= 11'd0;
            end else if (sdr_ready_raw && !st_done) begin
                if (!st_have_word) begin
                    st_have_word <= 1'b1;
                end else if (soc_sdr_ready) begin
                    st_have_word <= 1'b0;
                    if (st_idx == 11'(ST_WORDS - 1))
                        st_done <= 1'b1;
                    else
                        st_idx  <= st_idx + 11'd1;
                end
            end
        end

        assign sdr_ready_for_host         = sdr_ready_raw && st_done;
        assign apf_bridge_host_loaded_soc = 1'b1;

        assign soc_sdr_valid   = st_done ? hb_sdr_valid   : (sdr_ready_raw && st_have_word);
        assign soc_sdr_we      = st_done ? hb_sdr_we      : 1'b1;
        assign soc_sdr_addr    = st_done ? hb_sdr_addr    : {13'd0, st_idx};
        assign soc_sdr_wdata   = st_done ? hb_sdr_wdata   : st_word;
        assign soc_sdr_be      = st_done ? hb_sdr_be      : 4'hF;
        assign soc_sdr_pending = st_done ? hb_sdr_pending : 1'b1;

        assign hb_sdr_ready    = st_done && soc_sdr_ready;
        assign hb_sdr_rvalid   = st_done && soc_sdr_rvalid;
        assign hb_sdr_rdata    = soc_sdr_rdata;
    end else begin : g_normal_mode
        assign sdr_ready_for_host         = sdr_ready_raw;
        assign apf_bridge_host_loaded_soc = apf_bridge_host_loaded_br;

        assign soc_sdr_valid   = hb_sdr_valid;
        assign soc_sdr_we      = hb_sdr_we;
        assign soc_sdr_addr    = hb_sdr_addr;
        assign soc_sdr_wdata   = hb_sdr_wdata;
        assign soc_sdr_be      = hb_sdr_be;
        assign soc_sdr_pending = hb_sdr_pending;

        assign hb_sdr_ready    = soc_sdr_ready;
        assign hb_sdr_rvalid   = soc_sdr_rvalid;
        assign hb_sdr_rdata    = soc_sdr_rdata;
    end endgenerate

    // -------------------------------------------------------------------------
    // 4. Nintendo 64 SoC (`n64_soc_gb`)
    // -------------------------------------------------------------------------
    wire [1:0] soc_sdram_cke, soc_sdram_cs_n;
    assign sdram_cke = soc_sdram_cke[NUM_SDRAM_CHIPS-1:0];
    assign sdram_cs  = soc_sdram_cs_n[NUM_SDRAM_CHIPS-1:0];

    n64_soc_gb #(
        .BOOTROM    (BOOTROM),
        .SDR_T_INIT (SDR_T_INIT)
    ) u_soc (
        .clk_sys                        (clock),
        .clk_cpu                        (clk_cpu),
        .clk_sys2x                      (clk_sys2x),
        .clk_sdram_pad                  (clk_sdram_pad),
        .clk_vid                        (clk_vid),
        .reset                          (reset),

        .sdr_ready                      (sdr_ready_raw),
        .sram_ready                     (sram_ready),

        .br_sdr_valid                   (soc_sdr_valid),
        .br_sdr_we                      (soc_sdr_we),
        .br_sdr_addr                    (soc_sdr_addr),
        .br_sdr_wdata                   (soc_sdr_wdata),
        .br_sdr_be                      (soc_sdr_be),
        .br_sdr_ready                   (soc_sdr_ready),
        .br_sdr_rvalid                  (soc_sdr_rvalid),
        .br_sdr_rdata                   (soc_sdr_rdata),
        .br_sdr_pending                 (soc_sdr_pending),

        .h_sram_valid                   (h_sram_valid),
        .h_sram_we                      (h_sram_we),
        .h_sram_addr                    (h_sram_addr),
        .h_sram_wdata                   (h_sram_wdata),
        .h_sram_be                      (h_sram_be),
        .h_sram_ack                     (h_sram_ack),
        .h_sram_rdata                   (h_sram_rdata),

        .rom_cache_inv                  (rom_cache_inv),

        .apf_audio_buffer_fill          (apf_audio_buffer_fill),
        .apf_audio_bus_out              (apf_audio_bus_out),
        .apf_audio_bus_wr               (apf_audio_bus_wr),
        .apf_audio_flush                (apf_audio_flush),
        .apf_audio_playback_en          (apf_audio_playback_en),

        .apf_bridge_command_result_code (apf_bridge_command_result_code),
        .apf_bridge_complete_trigger    (apf_bridge_complete_trigger),
        .apf_bridge_current_address     (apf_bridge_current_address),
        .apf_bridge_data_offset         (apf_bridge_data_offset),
        .apf_bridge_file_size           (apf_bridge_file_size),
        .apf_bridge_file_size_wr        (apf_bridge_file_size_wr),
        .apf_bridge_host_loaded         (apf_bridge_host_loaded_soc),
        .apf_bridge_host_reset_n        (apf_bridge_host_reset_n),
        .apf_bridge_length              (apf_bridge_length),
        .apf_bridge_new_file_size_data  (apf_bridge_new_file_size_data),
        .apf_bridge_ram_data_address    (apf_bridge_ram_data_address),
        .apf_bridge_request_getfile     (apf_bridge_request_getfile),
        .apf_bridge_request_openfile    (apf_bridge_request_openfile),
        .apf_bridge_request_read        (apf_bridge_request_read),
        .apf_bridge_request_write       (apf_bridge_request_write),
        .apf_bridge_request_setsize     (apf_bridge_request_setsize),
        .apf_bridge_request_flush       (apf_bridge_request_flush),
        .apf_bridge_slot_id             (apf_bridge_slot_id),

        .apf_pad_clk                    (apf_pad_clk),
        .apf_pad_we                     (apf_pad_we),
        .apf_pad_wa                     (apf_pad_wa),
        .apf_pad_wd                     (apf_pad_wd),
        .apf_interact_address           (apf_interact_address),
        .apf_interact_data              (apf_interact_data),
        .apf_interact_wr                (apf_interact_wr),
        .apf_interact_q                 (apf_interact_q),
        .rumble_motor_on                (rumble_motor_on),

        .vid_horiz_blend_en             (vid_horiz_blend_en),
        .vid_dither_en                  (vid_dither_en),
        .vid_no_weave                   (vid_no_weave),

        .video_data_r                   (video_data_r),
        .video_data_g                   (video_data_g),
        .video_data_b                   (video_data_b),
        .video_dataEnable               (video_dataEnable),
        .video_vblank                   (video_vblank),
        .video_hblank                   (video_hblank),

        .sdram_clock                    (sdram_clock),
        .sdram_cke                      (soc_sdram_cke),
        .sdram_cs_n                     (soc_sdram_cs_n),
        .sdram_ras_n                    (sdram_ras),
        .sdram_cas_n                    (sdram_cas),
        .sdram_we_n                     (sdram_we),
        .sdram_dqm                      (sdram_dqm),
        .sdram_ba                       (sdram_bank),
        .sdram_a                        (sdram_address),
        .sdram_dq_in                    (sdram_dataIn),
        .sdram_dq_out                   (sdram_dataOut),
        .sdram_dq_oe                    (sdram_dataDir),

        .sram_ceN                       (sram_ceN),
        .sram_weN                       (sram_weN),
        .sram_oeN                       (sram_oeN),
        .sram_writeMaskN                (sram_writeMaskN),
        .sram_address                   (sram_address),
        .sram_dataIn                    (sram_dataIn),
        .sram_dataOut                   (sram_dataOut),
        .sram_dataDir                   (sram_dataDir),

        .uart_tx_we                     (uart_tx_we),
        .uart_tx_byte                   (uart_tx_byte),
        .dbg_cpu_pc                     (dbg_cpu_pc),
        .dbg_cpu_cause                  (dbg_cpu_cause),
        .dbg_cpu_epc                    (dbg_cpu_epc)
    );

    wire _unused_ok = &{1'b0, core_focused, apf_interact_q, uart_tx_we, uart_tx_byte,
                        dbg_cpu_pc, dbg_cpu_cause, dbg_cpu_epc, soc_sdram_cke, soc_sdram_cs_n};
endmodule

`default_nettype wire
