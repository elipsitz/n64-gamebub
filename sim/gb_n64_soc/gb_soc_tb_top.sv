`default_nettype none

// Top-level Verilator testbench wrapper for `N64Core` (`n64_gamebub_top`).
module gb_soc_tb_top #(
    parameter int SDR_T_INIT     = 200,
    parameter     BOOTROM        = "rtl/soc/boot.hex"
) (
    input  wire logic        tb_clk_sys,
    input  wire logic        tb_clk_cpu,
    input  wire logic        tb_clk_sys2x,
    input  wire logic        tb_clk_vid,
    input  wire logic        reset,

    // Simulation telemetry outputs
    output wire logic        tb_uart_we,
    output wire logic [7:0]  tb_uart_byte,
    output wire logic [31:0] tb_cpu_pc,
    output wire logic signed [7:0] tb_mmcm_ps_cur,

    // VideoV0 (320x240 RGB666 @ 60 Hz)
    output wire logic [5:0]  video_data_r,
    output wire logic [5:0]  video_data_g,
    output wire logic [5:0]  video_data_b,
    output wire logic        video_dataEnable,
    output wire logic        video_vblank,
    output wire logic        video_hblank,

    // AudioV0
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

    // Packed Slot 0..3 gamepad controls for clean C++ driving
    input  wire logic [3:0]  pad_active,
    input  wire logic [3:0]  pad_dev_type_0,
    input  wire logic [15:0] pad_btns_0, // {sel,start,r3,l3,r2,l2,r1,l1,right,left,down,up,y,x,b,a}
    input  wire logic [31:0] pad_axes_0, // {ry,rx,ly,lx}
    input  wire logic [15:0] pad_trig_0, // {rt,lt}
    input  wire logic [15:0] pad_btns_1,

    // VibrateV0
    output wire logic [1:0]  vibrate_mode,

    // CartridgePortV0 simulation controls & telemetry
    input  wire logic        tb_cart_switch,
    output wire logic [15:0] tb_cart_bus_err,
    output wire logic [15:0] tb_cart_reads,
    output wire logic [15:0] tb_cart_writes,

    // SdramV0 (2x W9825G6KH-6)
    output wire logic        sdram_clock,
    output wire logic [1:0]  sdram_cke,
    output wire logic [1:0]  sdram_cs_n,
    output wire logic        sdram_ras_n,
    output wire logic        sdram_cas_n,
    output wire logic        sdram_we_n,
    output wire logic [1:0]  sdram_dm,
    output wire logic [1:0]  sdram_ba,
    output wire logic [12:0] sdram_a,
    input  wire logic [15:0] sdram_dq_in,
    output wire logic [15:0] sdram_dq_out,
    output wire logic        sdram_dq_oe,

    // SramV0 (IS61WV25616EDBLL-10TLI)
    output wire logic        sram_ceN,
    output wire logic        sram_weN,
    output wire logic        sram_oeN,
    output wire logic [1:0]  sram_writeMaskN,
    output wire logic [17:0] sram_address,
    input  wire logic [15:0] sram_dataIn,
    output wire logic [15:0] sram_dataOut,
    output wire logic        sram_dataDir
);
    wire clk_sys, clk_display, clk_spi, clk_locked;

    wire       cart_enabled;
    wire [7:0] cart_bank0_in, cart_bank0_out, cart_bank1_out, cart_bank2_out;
    wire [3:0] cart_bank3_out;
    wire       cart_pin30_out, cart_pin31_out;
    wire       cart_bank0_dir, cart_bank1_dir, cart_bank2_dir, cart_bank3_dir;
    wire       cart_pin30_dir, cart_pin31_dir;

    n64_gamebub_top #(
        .DISPLAY_DIVIDER (25),
        .NUM_SDRAM_CHIPS (2),
        .BOOTROM         (BOOTROM),
        .SDR_T_INIT      (SDR_T_INIT)
    ) u_top (
            .clock                              (clk_sys),
            .reset                              (reset),
            .clocks_clockIn50M                  (1'b0),
            .clocks_clockOutSystem              (clk_sys),
            .clocks_clockOutDisplay             (clk_display),
            .clocks_clockOutSpi                 (clk_spi),
            .clocks_locked                      (clk_locked),
            .video_data_r                       (video_data_r),
            .video_data_g                       (video_data_g),
            .video_data_b                       (video_data_b),
            .video_dataEnable                   (video_dataEnable),
            .video_vblank                       (video_vblank),
            .video_hblank                       (video_hblank),
            .audio_left                         (audio_left),
            .audio_right                        (audio_right),
            .host_mem_enable                    (host_mem_enable),
            .host_mem_write                     (host_mem_write),
            .host_mem_done                      (host_mem_done),
            .host_mem_address                   (host_mem_address),
            .host_mem_dataRead                  (host_mem_dataRead),
            .host_mem_dataWrite                 (host_mem_dataWrite),
            .host_commandHost_request           (host_commandHost_request),
            .host_commandHost_busy              (host_commandHost_busy),
            .host_commandHost_done              (host_commandHost_done),
            .host_commandHost_error             (host_commandHost_error),
            .host_commandCore_request           (host_commandCore_request),
            .host_commandCore_busy              (host_commandCore_busy),
            .host_commandCore_done              (host_commandCore_done),
            .host_commandCore_error             (host_commandCore_error),

            .input_slots_0_active               (pad_active[0]),
            .input_slots_0_deviceType           (pad_dev_type_0),
            .input_slots_0_buttons_a            (pad_btns_0[0]),
            .input_slots_0_buttons_b            (pad_btns_0[1]),
            .input_slots_0_buttons_x            (pad_btns_0[2]),
            .input_slots_0_buttons_y            (pad_btns_0[3]),
            .input_slots_0_buttons_up           (pad_btns_0[4]),
            .input_slots_0_buttons_down         (pad_btns_0[5]),
            .input_slots_0_buttons_left         (pad_btns_0[6]),
            .input_slots_0_buttons_right        (pad_btns_0[7]),
            .input_slots_0_buttons_l1           (pad_btns_0[8]),
            .input_slots_0_buttons_r1           (pad_btns_0[9]),
            .input_slots_0_buttons_l2           (pad_btns_0[10]),
            .input_slots_0_buttons_r2           (pad_btns_0[11]),
            .input_slots_0_buttons_l3           (pad_btns_0[12]),
            .input_slots_0_buttons_r3           (pad_btns_0[13]),
            .input_slots_0_buttons_start        (pad_btns_0[14]),
            .input_slots_0_buttons_select       (pad_btns_0[15]),
            .input_slots_0_analog_leftX         (pad_axes_0[7:0]),
            .input_slots_0_analog_leftY         (pad_axes_0[15:8]),
            .input_slots_0_analog_rightX        (pad_axes_0[23:16]),
            .input_slots_0_analog_rightY        (pad_axes_0[31:24]),
            .input_slots_0_analog_leftTrigger   (pad_trig_0[7:0]),
            .input_slots_0_analog_rightTrigger  (pad_trig_0[15:8]),

            .input_slots_1_active               (pad_active[1]),
            .input_slots_1_deviceType           (pad_active[1] ? 4'd3 : 4'd0),
            .input_slots_1_buttons_a            (pad_btns_1[0]),
            .input_slots_1_buttons_b            (pad_btns_1[1]),
            .input_slots_1_buttons_x            (pad_btns_1[2]),
            .input_slots_1_buttons_y            (pad_btns_1[3]),
            .input_slots_1_buttons_up           (pad_btns_1[4]),
            .input_slots_1_buttons_down         (pad_btns_1[5]),
            .input_slots_1_buttons_left         (pad_btns_1[6]),
            .input_slots_1_buttons_right        (pad_btns_1[7]),
            .input_slots_1_buttons_l1           (pad_btns_1[8]),
            .input_slots_1_buttons_r1           (pad_btns_1[9]),
            .input_slots_1_buttons_l2           (pad_btns_1[10]),
            .input_slots_1_buttons_r2           (pad_btns_1[11]),
            .input_slots_1_buttons_l3           (pad_btns_1[12]),
            .input_slots_1_buttons_r3           (pad_btns_1[13]),
            .input_slots_1_buttons_start        (pad_btns_1[14]),
            .input_slots_1_buttons_select       (pad_btns_1[15]),
            .input_slots_1_analog_leftX         (8'd0),
            .input_slots_1_analog_leftY         (8'd0),
            .input_slots_1_analog_rightX        (8'd0),
            .input_slots_1_analog_rightY        (8'd0),
            .input_slots_1_analog_leftTrigger   (8'd0),
            .input_slots_1_analog_rightTrigger  (8'd0),

            .input_slots_2_active               (pad_active[2]),
            .input_slots_2_deviceType           (pad_active[2] ? 4'd3 : 4'd0),
            .input_slots_2_buttons_a            (1'b0),
            .input_slots_2_buttons_b            (1'b0),
            .input_slots_2_buttons_x            (1'b0),
            .input_slots_2_buttons_y            (1'b0),
            .input_slots_2_buttons_up           (1'b0),
            .input_slots_2_buttons_down         (1'b0),
            .input_slots_2_buttons_left         (1'b0),
            .input_slots_2_buttons_right        (1'b0),
            .input_slots_2_buttons_l1           (1'b0),
            .input_slots_2_buttons_r1           (1'b0),
            .input_slots_2_buttons_l2           (1'b0),
            .input_slots_2_buttons_r2           (1'b0),
            .input_slots_2_buttons_l3           (1'b0),
            .input_slots_2_buttons_r3           (1'b0),
            .input_slots_2_buttons_start        (1'b0),
            .input_slots_2_buttons_select       (1'b0),
            .input_slots_2_analog_leftX         (8'd0),
            .input_slots_2_analog_leftY         (8'd0),
            .input_slots_2_analog_rightX        (8'd0),
            .input_slots_2_analog_rightY        (8'd0),
            .input_slots_2_analog_leftTrigger   (8'd0),
            .input_slots_2_analog_rightTrigger  (8'd0),

            .input_slots_3_active               (pad_active[3]),
            .input_slots_3_deviceType           (pad_active[3] ? 4'd3 : 4'd0),
            .input_slots_3_buttons_a            (1'b0),
            .input_slots_3_buttons_b            (1'b0),
            .input_slots_3_buttons_x            (1'b0),
            .input_slots_3_buttons_y            (1'b0),
            .input_slots_3_buttons_up           (1'b0),
            .input_slots_3_buttons_down         (1'b0),
            .input_slots_3_buttons_left         (1'b0),
            .input_slots_3_buttons_right        (1'b0),
            .input_slots_3_buttons_l1           (1'b0),
            .input_slots_3_buttons_r1           (1'b0),
            .input_slots_3_buttons_l2           (1'b0),
            .input_slots_3_buttons_r2           (1'b0),
            .input_slots_3_buttons_l3           (1'b0),
            .input_slots_3_buttons_r3           (1'b0),
            .input_slots_3_buttons_start        (1'b0),
            .input_slots_3_buttons_select       (1'b0),
            .input_slots_3_analog_leftX         (8'd0),
            .input_slots_3_analog_leftY         (8'd0),
            .input_slots_3_analog_rightX        (8'd0),
            .input_slots_3_analog_rightY        (8'd0),
            .input_slots_3_analog_leftTrigger   (8'd0),
            .input_slots_3_analog_rightTrigger  (8'd0),

            .vibrate_mode                       (vibrate_mode),

            .cartridge_enabled                  (cart_enabled),
            .cartridge_switch                   (tb_cart_switch),
            .cartridge_bank0In                  (cart_bank0_in),
            .cartridge_bank1In                  (8'hFF),
            .cartridge_bank2In                  (8'hFF),
            .cartridge_bank3In                  (4'hF),
            .cartridge_pin30In                  (1'b1),
            .cartridge_pin31In                  (1'b1),
            .cartridge_bank0Out                 (cart_bank0_out),
            .cartridge_bank1Out                 (cart_bank1_out),
            .cartridge_bank2Out                 (cart_bank2_out),
            .cartridge_bank3Out                 (cart_bank3_out),
            .cartridge_pin30Out                 (cart_pin30_out),
            .cartridge_pin31Out                 (cart_pin31_out),
            .cartridge_bank0Dir                 (cart_bank0_dir),
            .cartridge_bank1Dir                 (cart_bank1_dir),
            .cartridge_bank2Dir                 (cart_bank2_dir),
            .cartridge_bank3Dir                 (cart_bank3_dir),
            .cartridge_pin30Dir                 (cart_pin30_dir),
            .cartridge_pin31Dir                 (cart_pin31_dir),

            .sdram_clock                        (sdram_clock),
            .sdram_cke                          (sdram_cke),
            .sdram_cs                           (sdram_cs_n),
            .sdram_ras                          (sdram_ras_n),
            .sdram_cas                          (sdram_cas_n),
            .sdram_we                           (sdram_we_n),
            .sdram_dqm                          (sdram_dm),
            .sdram_bank                         (sdram_ba),
            .sdram_address                      (sdram_a),
            .sdram_dataIn                       (sdram_dq_in),
            .sdram_dataOut                      (sdram_dq_out),
            .sdram_dataDir                      (sdram_dq_oe),

            .sram_ceN                           (sram_ceN),
            .sram_weN                           (sram_weN),
            .sram_oeN                           (sram_oeN),
            .sram_writeMaskN                    (sram_writeMaskN),
            .sram_address                       (sram_address),
            .sram_dataIn                        (sram_dataIn),
            .sram_dataOut                       (sram_dataOut),
            .sram_dataDir                       (sram_dataDir)
        );
        gb_cart_model_gb u_gb_cart_model (
            .clk          (clk_sys),
            .rst          (reset),
            .cart_switch  (tb_cart_switch),
            .cart_enabled (cart_enabled),
            .bank0_in     (cart_bank0_in),
            .bank0_out    (cart_bank0_out),
            .bank0_dir    (cart_bank0_dir),
            .bank1_out    (cart_bank1_out),
            .bank1_dir    (cart_bank1_dir),
            .bank2_out    (cart_bank2_out),
            .bank2_dir    (cart_bank2_dir),
            .bank3_out    (cart_bank3_out),
            .bank3_dir    (cart_bank3_dir),
            .pin30_out    (cart_pin30_out),
            .pin30_dir    (cart_pin30_dir),
            .pin31_out    (cart_pin31_out),
            .pin31_dir    (cart_pin31_dir),
            .bus_errors   (tb_cart_bus_err),
            .bus_reads    (tb_cart_reads),
            .bus_writes   (tb_cart_writes)
        );

    assign u_top.u_mmcm.sim_clk_sys   = tb_clk_sys;
    assign u_top.u_mmcm.sim_clk_cpu   = tb_clk_cpu;
    assign u_top.u_mmcm.sim_clk_sys2x = tb_clk_sys2x;
    assign u_top.u_mmcm.sim_clk_vid   = tb_clk_vid;
    assign tb_uart_we       = u_top.uart_tx_we;
    assign tb_uart_byte     = u_top.uart_tx_byte;
    assign tb_cpu_pc        = u_top.dbg_cpu_pc;
    assign tb_mmcm_ps_cur   = u_top.u_mmcm.ps_current;

    wire _unused_ok = &{1'b0, clk_display, clk_spi, clk_locked};
endmodule

`default_nettype wire
