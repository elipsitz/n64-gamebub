`default_nettype none

// Top-level SystemVerilog wrapper bound to N64Core (Chisel ExtModule).
// Phase 0 scaffold: instantiates the 6-output single-MMCM clock generator,
// ODDR SDRAM clock output, safe external memory idle states, HostV0 status
// responder, and a 60 Hz 320x240 RGB666 color-bar test generator for initial
// Vivado synthesis, BRAM decomposition, and STA verification.
module n64_gamebub_top #(
    parameter int DISPLAY_DIVIDER = 25,
    parameter int NUM_SDRAM_CHIPS = 2
) (
    input  wire logic        clock,
    input  wire logic        reset,

    // ClocksV0
    input  wire logic        clocks_clockIn50M,
    output wire logic        clocks_clockOutSystem,
    output wire logic        clocks_clockOutDisplay,
    output wire logic        clocks_clockOutSpi,
    output wire logic        clocks_locked,

    // VideoV0 (320x240 RGB666 @ 60 Hz, synchronous to clk_sys)
    output logic      [5:0]  video_data_r,
    output logic      [5:0]  video_data_g,
    output logic      [5:0]  video_data_b,
    output logic             video_dataEnable,
    output logic             video_vblank,
    output logic             video_hblank,

    // AudioV0 (signed 16-bit stereo)
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,

    // HostV0
    input  wire logic        host_mem_enable,
    input  wire logic        host_mem_write,
    output logic             host_mem_done,
    input  wire logic [31:0] host_mem_address,
    output logic      [31:0] host_mem_dataRead,
    input  wire logic [31:0] host_mem_dataWrite,

    input  wire logic        host_commandHost_request,
    output logic             host_commandHost_busy,
    output logic             host_commandHost_done,
    output logic             host_commandHost_error,

    output logic             host_commandCore_request,
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
    output logic      [1:0]  vibrate_mode,

    // SdramV0 (2x W9825G6KH-6 = 64 MiB total on Rev4)
    output wire logic        sdram_clock,
    output logic      [NUM_SDRAM_CHIPS-1:0] sdram_cke,
    output logic      [NUM_SDRAM_CHIPS-1:0] sdram_cs,
    output logic             sdram_ras,
    output logic             sdram_cas,
    output logic             sdram_we,
    output logic      [1:0]  sdram_dqm,
    output logic      [1:0]  sdram_bank,
    output logic      [12:0] sdram_address,
    input  wire logic [15:0] sdram_dataIn,
    output logic      [15:0] sdram_dataOut,
    output logic             sdram_dataDir,

    // SramV0 (IS61WV25616EDBLL-10TLI = 512 KiB, 10 ns)
    output logic             sram_ceN,
    output logic             sram_weN,
    output logic             sram_oeN,
    output logic      [1:0]  sram_writeMaskN,
    output logic      [17:0] sram_address,
    input  wire logic [15:0] sram_dataIn,
    output logic      [15:0] sram_dataOut,
    output logic             sram_dataDir
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
    wire mmcm_locked;

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
        .locked        (mmcm_locked),
        .ps_clk        (clk_sys),
        .ps_en         (1'b0),
        .ps_incdec     (1'b0),
        .ps_done       ()
    );

    assign clocks_clockOutSystem  = clk_sys;
    assign clocks_clockOutDisplay = clk_display;
    assign clocks_clockOutSpi     = clk_spi;
    assign clocks_locked          = mmcm_locked;

    // Forward 125 MHz phase-shifted SDRAM clock via dedicated IOB ODDR
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_sdram_clk_oddr (
        .Q  (sdram_clock),
        .C  (clk_sdram_pad),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    // Keep clk_cpu and clk_sys2x alive in Phase 0 stub to verify clock tree STA
    (* keep = "true" *) logic cpu_heartbeat_q = 1'b0;
    (* keep = "true" *) logic sys2x_heartbeat_q = 1'b0;
    always_ff @(posedge clk_cpu)   cpu_heartbeat_q   <= ~cpu_heartbeat_q;
    always_ff @(posedge clk_sys2x) sys2x_heartbeat_q <= ~sys2x_heartbeat_q;

    // -------------------------------------------------------------------------
    // 2. Safe External Memory Idle Ties (Phase 0 Stub)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_sys2x) begin
        sdram_cke     <= '0;
        sdram_cs      <= '1;
        sdram_ras     <= 1'b1;
        sdram_cas     <= 1'b1;
        sdram_we      <= 1'b1;
        sdram_dqm     <= 2'b11;
        sdram_bank    <= 2'b00;
        sdram_address <= 13'h0000;
        sdram_dataOut <= 16'h0000;
        sdram_dataDir <= 1'b0;
    end

    always_ff @(posedge clock) begin
        sram_ceN        <= 1'b1;
        sram_weN        <= 1'b1;
        sram_oeN        <= 1'b1;
        sram_writeMaskN <= 2'b11;
        sram_address    <= 18'h00000;
        sram_dataOut    <= 16'h0000;
        sram_dataDir    <= 1'b0;
    end

    // -------------------------------------------------------------------------
    // 3. Minimal HostV0 Status & Lifecycle Responder
    // -------------------------------------------------------------------------
    localparam logic [31:0] ADDR_HOST_CMD0 = 32'hF000_0000;
    localparam logic [31:0] ADDR_HOST_CMD1 = 32'hF000_0004;

    localparam logic [15:0] CMD_GET_STATUS     = 16'h0000;
    localparam logic [15:0] CMD_CORE_RUN       = 16'h0100;
    localparam logic [15:0] CMD_CORE_HALT      = 16'h0101;
    localparam logic [15:0] CMD_SETUP_COMPLETE = 16'h0102;
    localparam logic [15:0] CMD_NOTIFY_FOCUS   = 16'h0200;

    localparam logic [31:0] STATUS_SETUP     = 32'd2;
    localparam logic [31:0] STATUS_CORE_HALT = 32'd3;
    localparam logic [31:0] STATUS_CORE_RUN  = 32'd4;

    logic [31:0] cmd_reg0, cmd_reg1;
    logic        core_setup, core_running, core_focused;
    logic [1:0]  cmd_state;

    assign host_commandHost_busy    = (cmd_state == 2'd1);
    assign host_commandHost_done    = (cmd_state == 2'd2);
    assign host_commandHost_error   = (cmd_state == 2'd3);
    assign host_commandCore_request = 1'b0;

    always_ff @(posedge clock) begin
        if (reset) begin
            host_mem_done     <= 1'b0;
            host_mem_dataRead <= 32'h0;
            cmd_reg0          <= 32'h0;
            cmd_reg1          <= 32'h0;
            core_setup        <= 1'b0;
            core_running      <= 1'b0;
            core_focused      <= 1'b0;
            cmd_state         <= 2'd0;
        end else begin
            host_mem_done <= host_mem_enable && !host_mem_done;
            if (host_mem_enable && !host_mem_done) begin
                if (host_mem_write) begin
                    case (host_mem_address)
                        ADDR_HOST_CMD0: cmd_reg0 <= host_mem_dataWrite;
                        ADDR_HOST_CMD1: cmd_reg1 <= host_mem_dataWrite;
                        default: ;
                    endcase
                end else begin
                    case (host_mem_address)
                        ADDR_HOST_CMD0: host_mem_dataRead <= cmd_reg0;
                        ADDR_HOST_CMD1: host_mem_dataRead <= cmd_reg1;
                        default:        host_mem_dataRead <= 32'h0;
                    endcase
                end
            end

            if (host_commandHost_request) begin
                if (cmd_state == 2'd0) begin
                    cmd_state <= 2'd2;
                    case (cmd_reg0[15:0])
                        CMD_GET_STATUS:
                            cmd_reg0 <= core_setup
                                ? (core_running ? STATUS_CORE_RUN : STATUS_CORE_HALT)
                                : STATUS_SETUP;
                        CMD_SETUP_COMPLETE: begin
                            core_setup <= 1'b1;
                            cmd_reg0   <= 32'h0;
                        end
                        CMD_CORE_RUN: begin
                            core_running <= 1'b1;
                            cmd_reg0     <= 32'h0;
                        end
                        CMD_CORE_HALT: begin
                            core_running <= 1'b0;
                            cmd_reg0     <= 32'h0;
                        end
                        CMD_NOTIFY_FOCUS: begin
                            core_focused <= cmd_reg1[0];
                            cmd_reg0     <= 32'h0;
                        end
                        default: cmd_state <= 2'd2;
                    endcase
                end
            end else begin
                cmd_state <= 2'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. 320x240 @ 59.94 Hz RGB666 Test Pattern Generator (62.5 MHz clk_sys)
    //    3976 cycles/line * 262 lines = 1,041,712 cycles/frame = 59.997 Hz
    // -------------------------------------------------------------------------
    localparam int LINE_CYCLES = 3976;
    localparam int TOTAL_LINES = 262;
    localparam int H_ACTIVE    = 320;
    localparam int V_ACTIVE    = 240;

    logic [11:0] cyc_cnt;
    logic [8:0]  line_cnt;
    wire  [8:0]  px_x = cyc_cnt[11:3]; // 1 pixel every 8 clk_sys cycles (2560 active cycles)
    wire         px_stb = (cyc_cnt[2:0] == 3'd0) && (cyc_cnt < (H_ACTIVE * 8));

    always_ff @(posedge clock) begin
        if (reset) begin
            cyc_cnt          <= 12'd0;
            line_cnt         <= 9'd0;
            video_dataEnable <= 1'b0;
            video_hblank     <= 1'b1;
            video_vblank     <= 1'b1;
            video_data_r     <= 6'd0;
            video_data_g     <= 6'd0;
            video_data_b     <= 6'd0;
        end else begin
            if (cyc_cnt == LINE_CYCLES - 1) begin
                cyc_cnt <= 12'd0;
                if (line_cnt == TOTAL_LINES - 1)
                    line_cnt <= 9'd0;
                else
                    line_cnt <= line_cnt + 9'd1;
            end else begin
                cyc_cnt <= cyc_cnt + 12'd1;
            end

            video_vblank     <= (line_cnt >= V_ACTIVE);
            video_hblank     <= (line_cnt >= V_ACTIVE) || (cyc_cnt >= (H_ACTIVE * 8));
            video_dataEnable <= (line_cnt < V_ACTIVE) && px_stb;

            case (px_x[8:5])
                4'd0:    {video_data_r, video_data_g, video_data_b} <= {6'd63, 6'd63, 6'd63};
                4'd1:    {video_data_r, video_data_g, video_data_b} <= {6'd63, 6'd63, 6'd0 };
                4'd2:    {video_data_r, video_data_g, video_data_b} <= {6'd0,  6'd63, 6'd63};
                4'd3:    {video_data_r, video_data_g, video_data_b} <= {6'd0,  6'd63, 6'd0 };
                4'd4:    {video_data_r, video_data_g, video_data_b} <= {6'd63, 6'd0,  6'd63};
                4'd5:    {video_data_r, video_data_g, video_data_b} <= {6'd63, 6'd0,  6'd0 };
                4'd6:    {video_data_r, video_data_g, video_data_b} <= {6'd0,  6'd0,  6'd63};
                default: {video_data_r, video_data_g, video_data_b} <= {line_cnt[7:2], px_x[5:0], {5'd0, cpu_heartbeat_q ^ sys2x_heartbeat_q}};
            endcase
        end
    end

    assign audio_left   = 16'sd0;
    assign audio_right  = 16'sd0;
    assign vibrate_mode = (input_slots_0_active && input_slots_0_buttons_l3) ? 2'd1 : 2'd0;
endmodule

`default_nettype wire
