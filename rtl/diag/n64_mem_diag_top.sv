`default_nettype none

// Phase 2 Deliverable #1: Standalone Hardware Memory & Phase-Sweep Diagnostic
// Top-Level (`N64MemDiagCore`, /cores/GameBub.N64MemDiag/).
//
// Exercises the exact production N64 memory hierarchy on Game Bub Rev4:
//   - Dual-rank Winbond W9825G6KH-6 (64 MiB @ 125 MHz, 9-bit col, 8 open banks)
//   - ISSI IS61WV25616EDBLL-10TLI (512 KiB @ 10 ns glitch-free halfword PHY)
//   - Two-level PI Cartridge ROM Cache (16 KiB L1 BRAM + 64 KiB L2 Async SRAM)
//   - Runtime MMCME2_ADV fine phase shift on sdram_clk (settings.json or D-Pad)
//   - Live 320x240 RGB666 diagnostic HUD + 440 Hz AudioV0 tone + VibrateV0 test
module n64_mem_diag_top #(
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

    // VideoV0 (320x240 RGB666 @ 60 Hz)
    output logic      [5:0]  video_data_r,
    output logic      [5:0]  video_data_g,
    output logic      [5:0]  video_data_b,
    output logic             video_dataEnable,
    output logic             video_vblank,
    output logic             video_hblank,

    // AudioV0
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

    // SdramV0
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
    output logic      [15:0] sdram_dataTri,

    // SramV0
    output logic             sram_ceN,
    output logic             sram_weN,
    output logic             sram_oeN,
    output logic      [1:0]  sram_writeMaskN,
    output logic      [17:0] sram_address,
    input  wire logic [15:0] sram_dataIn,
    output logic      [15:0] sram_dataOut,
    output logic             sram_dataDir,
    output logic      [15:0] sram_dataTri
);
    // -------------------------------------------------------------------------
    // 1. Unified MMCM Clock Generation + Runtime Fine Phase Shift
    // -------------------------------------------------------------------------
    wire clk_sys, clk_cpu, clk_sys2x, clk_sdram_pad, clk_spi, clk_display, clk_vid;
    wire mmcm_locked;
    logic signed [7:0] ps_target;
    wire  signed [7:0] ps_current;

    n64_mmcm #(
        .CLK_DISPLAY_DIVIDE (DISPLAY_DIVIDER),
        .SDRAM_CLK_PHASE    (-150.0)
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
        .ps_target     (ps_target),
        .ps_current    (ps_current)
    );

    assign clocks_clockOutSystem  = clk_sys;
    assign clocks_clockOutDisplay = clk_display;
    assign clocks_clockOutSpi     = clk_spi;
    assign clocks_locked          = mmcm_locked;

    (* keep = "true" *) logic cpu_hb = 1'b0, vid_hb = 1'b0;
    always_ff @(posedge clk_cpu) cpu_hb <= ~cpu_hb;
    always_ff @(posedge clk_vid) vid_hb <= ~vid_hb;

    logic rst2x;
    always_ff @(posedge clk_sys2x) rst2x <= reset;

    // -------------------------------------------------------------------------
    // 2. HostV0 Lifecycle & Settings (0x7000_0028 restart, 0x7000_002C phase)
    // -------------------------------------------------------------------------
    logic [31:0] cmd_reg0, cmd_reg1;
    logic        core_setup, core_running, core_focused;
    logic [1:0]  cmd_state;
    logic signed [7:0] cfg_ps_base, dpad_ps_off;
    logic        restart_req;

    wire sdr_ready, sram_ready;
    assign host_commandHost_busy    = (cmd_state == 2'd1);
    assign host_commandHost_done    = (cmd_state == 2'd2);
    assign host_commandHost_error   = (cmd_state == 2'd3);
    assign host_commandCore_request = 1'b0;

    always_ff @(posedge clock) begin
        restart_req <= 1'b0;
        if (reset) begin
            host_mem_done     <= 1'b0;
            host_mem_dataRead <= 32'h0;
            cmd_reg0          <= 32'h0;
            cmd_reg1          <= 32'h0;
            core_setup        <= 1'b0;
            core_running      <= 1'b0;
            core_focused      <= 1'b0;
            cmd_state         <= 2'd0;
            cfg_ps_base       <= 8'sd0;
        end else begin
            host_mem_done <= host_mem_enable && !host_mem_done;
            if (host_mem_enable && !host_mem_done) begin
                if (host_mem_write) begin
                    case (host_mem_address)
                        32'hF000_0000: cmd_reg0    <= host_mem_dataWrite;
                        32'hF000_0004: cmd_reg1    <= host_mem_dataWrite;
                        32'h7000_0028: restart_req <= (host_mem_dataWrite != 32'd0);
                        32'h7000_002C: begin
                            cfg_ps_base <= signed'(host_mem_dataWrite[7:0]);
                            restart_req <= 1'b1;
                        end
                        default: ;
                    endcase
                end else begin
                    case (host_mem_address)
                        32'hF000_0000: host_mem_dataRead <= cmd_reg0;
                        32'hF000_0004: host_mem_dataRead <= cmd_reg1;
                        32'h7000_002C: host_mem_dataRead <= {24'd0, cfg_ps_base};
                        default:       host_mem_dataRead <= 32'h0;
                    endcase
                end
            end

            if (host_commandHost_request) begin
                if (cmd_state == 2'd0) begin
                    cmd_state <= 2'd2;
                    case (cmd_reg0[15:0])
                        16'h0000: cmd_reg0 <= !(sdr_ready && sram_ready) ? 32'd1
                                            : !core_setup                ? 32'd2
                                            : core_running               ? 32'd4 : 32'd3;
                        16'h0102: begin core_setup <= 1'b1; cmd_reg0 <= 32'h0; end
                        16'h0100: begin core_running <= 1'b1; cmd_reg0 <= 32'h0; end
                        16'h0101: begin core_running <= 1'b0; cmd_reg0 <= 32'h0; end
                        16'h0200: begin core_focused <= cmd_reg1[0]; cmd_reg0 <= 32'h0; end
                        default:  cmd_reg0 <= 32'h0;
                    endcase
                end
            end else begin
                cmd_state <= 2'd0;
            end
        end
    end

    // D-Pad Left / Right live phase-offset stepping (+/-4 steps = +/-95 ps)
    logic prev_left, prev_right, prev_a;
    always_ff @(posedge clock) begin
        if (reset) begin
            prev_left   <= 1'b0;
            prev_right  <= 1'b0;
            prev_a      <= 1'b0;
            dpad_ps_off <= 8'sd0;
        end else begin
            prev_left  <= input_slots_0_active && input_slots_0_buttons_left;
            prev_right <= input_slots_0_active && input_slots_0_buttons_right;
            prev_a     <= input_slots_0_active && input_slots_0_buttons_a;
            if (input_slots_0_active && input_slots_0_buttons_left && !prev_left && dpad_ps_off > -8'sd80)
                dpad_ps_off <= dpad_ps_off - 8'sd4;
            if (input_slots_0_active && input_slots_0_buttons_right && !prev_right && dpad_ps_off < 8'sd80)
                dpad_ps_off <= dpad_ps_off + 8'sd4;
        end
    end
    wire btn_clear = input_slots_0_active && input_slots_0_buttons_a && !prev_a;
    assign ps_target = cfg_ps_base + dpad_ps_off;

    // -------------------------------------------------------------------------
    // 3. Production External Memory Hierarchy (SDRAM + SRAM + L1/L2 PI Cache)
    // -------------------------------------------------------------------------
    localparam int NP = 6;
    logic [NP-1:0]       p_valid, p_we, p_urgent, p_ready, p_rvalid;
    logic [NP-1:0][23:0] p_addr;
    logic [NP-1:0][31:0] p_wdata;
    logic [NP-1:0][3:0]  p_be;
    logic [31:0]         p_rdata;

    logic        rq_valid, rq_we, rq_ready, rd_valid, rd_next, la_valid;
    logic [23:0] rq_addr, la_addr;
    logic [31:0] rq_wdata, rd_data;
    logic [3:0]  rq_be;
    logic [2:0]  rq_tag, rd_tag, rd_next_tag;

    logic [3:0]  dfi_cs_n, dfi_ba, dfi_wm;
    logic [1:0]  dfi_cke, dfi_ras_n, dfi_cas_n, dfi_we_n;
    logic [25:0] dfi_addr;
    logic        dfi_wren, dfi_rden, dfi_rv;
    logic [31:0] dfi_wd, dfi_rd;

    sdr_arb_gb #(.N(NP), .APF_PREEMPT(1)) u_arb (
        .clk       (clock),
        .rst       (reset),
        .p_valid   (p_valid),
        .p_we      (p_we),
        .p_addr    (p_addr),
        .p_wdata   (p_wdata),
        .p_be      (p_be),
        .p_urgent  (p_urgent),
        .apf_force (1'b0),
        .p_ready   (p_ready),
        .p_rvalid  (p_rvalid),
        .p_rdata   (p_rdata),
        .req_valid (rq_valid),
        .req_we    (rq_we),
        .req_addr  (rq_addr),
        .req_wdata (rq_wdata),
        .req_be    (rq_be),
        .req_tag   (rq_tag),
        .req_ready (rq_ready),
        .la_valid  (la_valid),
        .la_addr   (la_addr),
        .rd_valid  (rd_valid),
        .rd_data   (rd_data),
        .rd_tag    (rd_tag)
    );

    sdr_ctrl_w9825 u_sdr_ctrl (
        .clk              (clock),
        .rst              (reset),
        .ready            (sdr_ready),
        .req_valid        (rq_valid),
        .req_we           (rq_we),
        .req_addr         (rq_addr),
        .req_wdata        (rq_wdata),
        .req_be           (rq_be),
        .req_tag          (rq_tag),
        .req_ready        (rq_ready),
        .la_valid         (la_valid),
        .la_addr          (la_addr),
        .rd_valid         (rd_valid),
        .rd_data          (rd_data),
        .rd_tag           (rd_tag),
        .rd_next          (rd_next),
        .rd_next_tag      (rd_next_tag),
        .dfi_cs_n         (dfi_cs_n),
        .dfi_cke          (dfi_cke),
        .dfi_ras_n        (dfi_ras_n),
        .dfi_cas_n        (dfi_cas_n),
        .dfi_we_n         (dfi_we_n),
        .dfi_addr         (dfi_addr),
        .dfi_ba           (dfi_ba),
        .dfi_wrdata_en    (dfi_wren),
        .dfi_wrdata       (dfi_wd),
        .dfi_wrdata_mask  (dfi_wm),
        .dfi_rddata_en    (dfi_rden),
        .dfi_rddata       (dfi_rd),
        .dfi_rddata_valid (dfi_rv)
    );

    sdr_phy_x7 u_sdr_phy (
        .clk          (clock),
        .rst          (reset),
        .clk2x        (clk_sys2x),
        .rst2x        (rst2x),
        .clk2x_90     (clk_sdram_pad),
        .cs_n         (dfi_cs_n),
        .cke          (dfi_cke),
        .ras_n        (dfi_ras_n),
        .cas_n        (dfi_cas_n),
        .we_n         (dfi_we_n),
        .addr         (dfi_addr),
        .ba           (dfi_ba),
        .wrdata_en    (dfi_wren),
        .wrdata       (dfi_wd),
        .wrdata_mask  (dfi_wm),
        .rddata_en    (dfi_rden),
        .rddata       (dfi_rd),
        .rddata_valid (dfi_rv),
        .sdram_a      (sdram_address),
        .sdram_ba     (sdram_bank),
        .sdram_cs_n   (sdram_cs),
        .sdram_cke    (sdram_cke),
        .sdram_ras_n  (sdram_ras),
        .sdram_cas_n  (sdram_cas),
        .sdram_we_n   (sdram_we),
        .sdram_dm     (sdram_dqm),
        .sdram_dq_in  (sdram_dataIn),
        .sdram_dq_out (sdram_dataOut),
        .sdram_dq_oe  (sdram_dataDir),
        .sdram_dq_tri (sdram_dataTri),
        .sdram_clock  (sdram_clock)
    );

    logic        x_sram_valid, x_sram_we, x_sram_ack;
    logic [16:0] x_sram_addr;
    logic [31:0] x_sram_wdata, x_sram_rdata;
    logic [3:0]  x_sram_be;

    logic        l2_valid, l2_we, l2_ack;
    logic [16:0] l2_addr;
    logic [31:0] l2_wdata, l2_rdata;

    gb_sram_ctrl u_sram_ctrl (
        .clk             (clock),
        .rst             (reset),
        .clk2x           (clk_sys2x),
        .rst2x           (rst2x),
        .ready           (sram_ready),
        .h_valid         (1'b0),
        .h_we            (1'b0),
        .h_addr          (17'd0),
        .h_wdata         (32'd0),
        .h_be            (4'd0),
        .h_ack           (),
        .h_rdata         (),
        .x_valid         (x_sram_valid),
        .x_we            (x_sram_we),
        .x_addr          (x_sram_addr),
        .x_wdata         (x_sram_wdata),
        .x_be            (x_sram_be),
        .x_ack           (x_sram_ack),
        .x_rdata         (x_sram_rdata),
        .l2_valid        (l2_valid),
        .l2_we           (l2_we),
        .l2_addr         (l2_addr),
        .l2_wdata        (l2_wdata),
        .l2_ack          (l2_ack),
        .l2_rdata        (l2_rdata),
        .sram_ceN        (sram_ceN),
        .sram_weN        (sram_weN),
        .sram_oeN        (sram_oeN),
        .sram_writeMaskN (sram_writeMaskN),
        .sram_address    (sram_address),
        .sram_dataIn     (sram_dataIn),
        .sram_dataOut    (sram_dataOut),
        .sram_dataDir    (sram_dataDir),
        .sram_dataTri    (sram_dataTri)
    );

    logic        rom_req, rom_ack, rom_inv;
    logic [23:0] rom_addr;
    logic [31:0] rom_rdata;

    pi_rom_cache u_pi_cache (
        .clk       (clock),
        .rst       (reset),
        .inv_all   (rom_inv),
        .rom_req   (rom_req),
        .rom_addr  (rom_addr),
        .rom_ack   (rom_ack),
        .rom_rdata (rom_rdata),
        .m_valid   (p_valid[4]),
        .m_addr    (p_addr[4]),
        .m_ready   (p_ready[4]),
        .m_rvalid  (p_rvalid[4]),
        .m_rdata   (p_rdata),
        .l2_valid  (l2_valid),
        .l2_we     (l2_we),
        .l2_addr   (l2_addr),
        .l2_wdata  (l2_wdata),
        .l2_ack    (l2_ack),
        .l2_rdata  (l2_rdata)
    );
    assign p_we[4]     = 1'b0;
    assign p_wdata[4]  = 32'd0;
    assign p_be[4]     = 4'hF;
    assign p_urgent[4] = 1'b0;

    // Tie unused arbiter ports 0, 2, 3, 5 idle; port 1 is driven by stress FSM
    for (genvar gi = 0; gi < NP; gi++) begin : g_unused_ports
        if (gi != 1 && gi != 4) begin : g_tie
            assign p_valid[gi]  = 1'b0;
            assign p_we[gi]     = 1'b0;
            assign p_addr[gi]   = 24'd0;
            assign p_wdata[gi]  = 32'd0;
            assign p_be[gi]     = 4'hF;
            assign p_urgent[gi] = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // 4. Automated 4-Stage Hardware Stress FSM
    // -------------------------------------------------------------------------
    function automatic logic [31:0] pattern_of(input logic [23:0] a, input logic [15:0] epoch);
        logic [31:0] x;
        x = {epoch[7:0], a} ^ 32'hA5C3_5A3C;
        x = x ^ {x[18:0], x[31:19]} ^ {x[6:0], x[31:7]};
        x = x ^ (x << 11) ^ (x >> 5);
        return x ^ {epoch, ~epoch};
    endfunction

    typedef enum logic [3:0] {
        T_WAIT_INIT,
        T_R0_WR,
        T_R0_RD_REQ,
        T_R0_RD_WAIT,
        T_R1_WR,
        T_R1_RD_REQ,
        T_R1_RD_WAIT,
        T_R0_ISO_REQ,
        T_R0_ISO_WAIT,
        T_SRAM_WR,
        T_SRAM_RD,
        T_CACHE_INV,
        T_CACHE_RD
    } tst_t;

    localparam logic [16:0] SDR_TEST_WORDS  = 17'd65536;  // 256 KiB across rows & all 4 banks/rank
    localparam logic [16:0] SRAM_TEST_WORDS = 17'd98304;  // 384 KiB (0x00000..0x17FFF, below L2 0x1A000)

    tst_t        tst;
    logic [16:0] idx;
    logic [15:0] pass_cnt;
    logic [15:0] err_r0, err_r1, err_sram, err_cache;
    logic [31:0] last_bad_got, last_bad_exp;

    wire [23:0] r0_addr = 24'h04_0000 + {7'd0, idx[15:0]}; // Rank 0 (0x4010_0000..)
    wire [23:0] r1_addr = 24'h80_0000 + {7'd0, idx[15:0]}; // Rank 1 (0x4200_0000..)

    assign p_urgent[1] = 1'b1;
    assign p_valid[1]  = (tst == T_R0_WR) || (tst == T_R0_RD_REQ) ||
                         (tst == T_R1_WR) || (tst == T_R1_RD_REQ) || (tst == T_R0_ISO_REQ);
    assign p_we[1]     = (tst == T_R0_WR) || (tst == T_R1_WR);
    assign p_addr[1]   = (tst == T_R1_WR || tst == T_R1_RD_REQ) ? r1_addr : r0_addr;
    assign p_wdata[1]  = (tst == T_R1_WR) ? pattern_of(r1_addr, pass_cnt) : pattern_of(r0_addr, pass_cnt);
    assign p_be[1]     = 4'hF;

    assign x_sram_valid = (tst == T_SRAM_WR) || (tst == T_SRAM_RD);
    assign x_sram_we    = (tst == T_SRAM_WR);
    assign x_sram_addr  = idx;
    assign x_sram_wdata = pattern_of({7'h55, idx}, pass_cnt);
    assign x_sram_be    = 4'hF;

    assign rom_inv  = (tst == T_CACHE_INV);
    assign rom_req  = (tst == T_CACHE_RD);
    assign rom_addr = r0_addr;

    always_ff @(posedge clock) begin
        if (reset || restart_req || btn_clear) begin
            tst          <= T_WAIT_INIT;
            idx          <= 17'd0;
            pass_cnt     <= 16'd0;
            err_r0       <= 16'd0;
            err_r1       <= 16'd0;
            err_sram     <= 16'd0;
            err_cache    <= 16'd0;
            last_bad_got <= 32'd0;
            last_bad_exp <= 32'd0;
        end else begin
            case (tst)
                T_WAIT_INIT: if (sdr_ready && sram_ready) begin
                    idx <= 17'd0;
                    tst <= T_R0_WR;
                end

                // Stage 0: Rank 0 write + readback
                T_R0_WR: if (p_ready[1]) begin
                    if (idx == SDR_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_R0_RD_REQ; end
                    else idx <= idx + 17'd1;
                end
                T_R0_RD_REQ: if (p_ready[1]) tst <= T_R0_RD_WAIT;
                T_R0_RD_WAIT: if (p_rvalid[1]) begin
                    if (p_rdata != pattern_of(r0_addr, pass_cnt)) begin
                        if (err_r0 != 16'hFFFF) err_r0 <= err_r0 + 16'd1;
                        last_bad_got <= p_rdata;
                        last_bad_exp <= pattern_of(r0_addr, pass_cnt);
                    end
                    if (idx == SDR_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_R1_WR; end
                    else begin idx <= idx + 17'd1; tst <= T_R0_RD_REQ; end
                end

                // Stage 1: Rank 1 write + readback + Rank 0 CS isolation check
                T_R1_WR: if (p_ready[1]) begin
                    if (idx == SDR_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_R1_RD_REQ; end
                    else idx <= idx + 17'd1;
                end
                T_R1_RD_REQ: if (p_ready[1]) tst <= T_R1_RD_WAIT;
                T_R1_RD_WAIT: if (p_rvalid[1]) begin
                    if (p_rdata != pattern_of(r1_addr, pass_cnt)) begin
                        if (err_r1 != 16'hFFFF) err_r1 <= err_r1 + 16'd1;
                        last_bad_got <= p_rdata;
                        last_bad_exp <= pattern_of(r1_addr, pass_cnt);
                    end
                    if (idx == SDR_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_R0_ISO_REQ; end
                    else begin idx <= idx + 17'd1; tst <= T_R1_RD_REQ; end
                end
                T_R0_ISO_REQ: if (p_ready[1]) tst <= T_R0_ISO_WAIT;
                T_R0_ISO_WAIT: if (p_rvalid[1]) begin
                    if (p_rdata != pattern_of(r0_addr, pass_cnt)) begin
                        if (err_r0 != 16'hFFFF) err_r0 <= err_r0 + 16'd1;
                    end
                    if (idx == 17'd4095) begin idx <= 17'd0; tst <= T_SRAM_WR; end
                    else begin idx <= idx + 17'd1; tst <= T_R0_ISO_REQ; end
                end

                // Stage 2: 10 ns Async SRAM write + readback
                T_SRAM_WR: if (x_sram_ack) begin
                    if (idx == SRAM_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_SRAM_RD; end
                    else idx <= idx + 17'd1;
                end
                T_SRAM_RD: if (x_sram_ack) begin
                    if (x_sram_rdata != pattern_of({7'h55, idx}, pass_cnt)) begin
                        if (err_sram != 16'hFFFF) err_sram <= err_sram + 16'd1;
                        last_bad_got <= x_sram_rdata;
                        last_bad_exp <= pattern_of({7'h55, idx}, pass_cnt);
                    end
                    if (idx == SRAM_TEST_WORDS - 17'd1) begin idx <= 17'd0; tst <= T_CACHE_INV; end
                    else idx <= idx + 17'd1;
                end

                // Stage 3: L1 BRAM + L2 Async SRAM PI ROM Cache read & eviction check
                T_CACHE_INV: begin
                    idx <= 17'd0;
                    tst <= T_CACHE_RD;
                end
                T_CACHE_RD: if (rom_ack) begin
                    if (rom_rdata != pattern_of(r0_addr, pass_cnt)) begin
                        if (err_cache != 16'hFFFF) err_cache <= err_cache + 16'd1;
                    end
                    if (idx == SDR_TEST_WORDS - 17'd1) begin
                        idx      <= 17'd0;
                        pass_cnt <= (pass_cnt == 16'hFFFF) ? 16'hFFFF : (pass_cnt + 16'd1);
                        tst      <= T_R0_WR;
                    end else begin
                        idx <= idx + 17'd1;
                    end
                end

                default: tst <= T_WAIT_INIT;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 5. 320x240 @ 60 Hz RGB666 Live Diagnostic HUD Renderer
    // -------------------------------------------------------------------------
    localparam int LINE_CYCLES = 3976;
    localparam int TOTAL_LINES = 262;
    localparam int H_ACTIVE    = 320;
    localparam int V_ACTIVE    = 240;

    logic [11:0] cyc_cnt;
    logic [8:0]  line_cnt;
    wire  [8:0]  px_x   = cyc_cnt[11:3];
    wire  [8:0]  px_y   = line_cnt;
    wire         px_stb = (cyc_cnt[2:0] == 3'd0) && (cyc_cnt < (H_ACTIVE * 8));

    wire any_err = (err_r0 != 0) || (err_r1 != 0) || (err_sram != 0) || (err_cache != 0);

    // Helper: render a 16-bit binary LED strip across X = 96..223 (8 px per bit, power-of-2 decode)
    function automatic logic bit_led(input logic [8:0] x, input logic [8:0] y_rel, input logic [15:0] val, output logic on_bit);
        logic [8:0] bx;
        logic [3:0] bidx;
        if (x >= 9'd96 && x < 9'd224 && y_rel >= 9'd2 && y_rel < 9'd14) begin
            bx     = x - 9'd96;
            bidx   = 4'd15 - bx[6:3];
            on_bit = val[bidx];
            return (bx[2:0] < 3'd6);
        end else begin
            on_bit = 1'b0;
            return 1'b0;
        end
    endfunction

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
                line_cnt <= (line_cnt == TOTAL_LINES - 1) ? 9'd0 : (line_cnt + 9'd1);
            end else begin
                cyc_cnt <= cyc_cnt + 12'd1;
            end

            video_vblank     <= (line_cnt >= V_ACTIVE);
            video_hblank     <= (line_cnt >= V_ACTIVE) || (cyc_cnt >= (H_ACTIVE * 8));
            video_dataEnable <= (line_cnt < V_ACTIVE) && px_stb;

            // Default dark slate background
            {video_data_r, video_data_g, video_data_b} <= {6'd4, 6'd6, 6'd10};

            // Top status banner (Y = 0..27)
            if (px_y < 9'd28) begin
                if (any_err)
                    {video_data_r, video_data_g, video_data_b} <= {6'd56, 6'd6, 6'd6};
                else if (pass_cnt > 16'd0)
                    {video_data_r, video_data_g, video_data_b} <= {6'd6, 6'd48, 6'd14};
                else
                    {video_data_r, video_data_g, video_data_b} <= {6'd8, 6'd24, 6'd52};
            end
            // Row 0 (Y = 36..51): Pass Counter [15:0]
            else if (px_y >= 9'd36 && px_y < 9'd52) begin
                logic b;
                if (px_x >= 9'd16 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= (pass_cnt > 0) ? {6'd8, 6'd54, 6'd16} : {6'd16, 6'd32, 6'd56};
                else if (bit_led(px_x, px_y - 9'd36, pass_cnt, b))
                    {video_data_r, video_data_g, video_data_b} <= b ? {6'd60, 6'd60, 6'd16} : {6'd12, 6'd14, 6'd20};
            end
            // Row 1 (Y = 60..75): Rank 0 W9825G6KH-6 (32 MiB) Status + Err Count
            else if (px_y >= 9'd60 && px_y < 9'd76) begin
                logic b;
                if (px_x >= 9'd16 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= (err_r0 == 0) ? {6'd8, 6'd54, 6'd16} : {6'd60, 6'd8, 6'd8};
                else if (bit_led(px_x, px_y - 9'd60, err_r0, b))
                    {video_data_r, video_data_g, video_data_b} <= b ? {6'd63, 6'd10, 6'd10} : {6'd10, 6'd24, 6'd14};
            end
            // Row 2 (Y = 84..99): Rank 1 W9825G6KH-6 (32 MiB) Status + Err Count
            else if (px_y >= 9'd84 && px_y < 9'd100) begin
                logic b;
                if (px_x >= 9'd16 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= (err_r1 == 0) ? {6'd8, 6'd54, 6'd16} : {6'd60, 6'd8, 6'd8};
                else if (bit_led(px_x, px_y - 9'd84, err_r1, b))
                    {video_data_r, video_data_g, video_data_b} <= b ? {6'd63, 6'd10, 6'd10} : {6'd10, 6'd24, 6'd14};
            end
            // Row 3 (Y = 108..123): IS61WV25616 10ns Async SRAM (512 KiB) Status + Err Count
            else if (px_y >= 9'd108 && px_y < 9'd124) begin
                logic b;
                if (px_x >= 9'd16 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= (err_sram == 0) ? {6'd8, 6'd54, 6'd16} : {6'd60, 6'd8, 6'd8};
                else if (bit_led(px_x, px_y - 9'd108, err_sram, b))
                    {video_data_r, video_data_g, video_data_b} <= b ? {6'd63, 6'd10, 6'd10} : {6'd10, 6'd24, 6'd14};
            end
            // Row 4 (Y = 132..147): L1 BRAM + L2 SRAM PI ROM Cache Status + Err Count
            else if (px_y >= 9'd132 && px_y < 9'd148) begin
                logic b;
                if (px_x >= 9'd16 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= (err_cache == 0) ? {6'd8, 6'd54, 6'd16} : {6'd60, 6'd8, 6'd8};
                else if (bit_led(px_x, px_y - 9'd132, err_cache, b))
                    {video_data_r, video_data_g, video_data_b} <= b ? {6'd63, 6'd10, 6'd10} : {6'd10, 6'd24, 6'd14};
            end
            // Row 5 (Y = 164..179): Live MMCM Fine Phase Slider (center X = 160, 1px = 1 step)
            else if (px_y >= 9'd164 && px_y < 9'd180) begin
                int slider_x;
                slider_x = 160 + int'(ps_current);
                if (px_x >= 9'd64 && px_x < 9'd256) begin
                    if (int'(px_x) >= slider_x - 2 && int'(px_x) <= slider_x + 2)
                        {video_data_r, video_data_g, video_data_b} <= {6'd63, 6'd56, 6'd12};
                    else if (px_x == 9'd160)
                        {video_data_r, video_data_g, video_data_b} <= {6'd40, 6'd40, 6'd48};
                    else
                        {video_data_r, video_data_g, video_data_b} <= {6'd10, 6'd14, 6'd22};
                end
            end
            // Row 6 (Y = 196..220): 4-Slot Gamepad Active & Heartbeat Indicators
            else if (px_y >= 9'd196 && px_y < 9'd220) begin
                if (px_x >= 9'd32 && px_x < 9'd80)
                    {video_data_r, video_data_g, video_data_b} <= input_slots_0_active ? {6'd12, 6'd48, 6'd60} : {6'd10, 6'd10, 6'd14};
                else if (px_x >= 9'd96 && px_x < 9'd144)
                    {video_data_r, video_data_g, video_data_b} <= input_slots_1_active ? {6'd12, 6'd48, 6'd60} : {6'd10, 6'd10, 6'd14};
                else if (px_x >= 9'd160 && px_x < 9'd208)
                    {video_data_r, video_data_g, video_data_b} <= input_slots_2_active ? {6'd12, 6'd48, 6'd60} : {6'd10, 6'd10, 6'd14};
                else if (px_x >= 9'd224 && px_x < 9'd272)
                    {video_data_r, video_data_g, video_data_b} <= input_slots_3_active ? {6'd12, 6'd48, 6'd60} : {6'd10, 6'd10, 6'd14};
                else if (px_x >= 9'd288 && px_x < 9'd304)
                    {video_data_r, video_data_g, video_data_b} <= {6{cpu_hb ^ vid_hb ^ last_bad_got[0] ^ last_bad_exp[0]}};
            end
        end
    end

    // -------------------------------------------------------------------------
    // 6. 440 Hz AudioV0 Test Tone (hold B) & VibrateV0 Motor Test (hold B)
    // -------------------------------------------------------------------------
    logic [13:0] aud_div;
    logic [7:0]  tone_phase;
    wire         test_tone_en = input_slots_0_active && input_slots_0_buttons_b;

    always_ff @(posedge clock) begin
        if (reset) begin
            aud_div    <= 14'd0;
            tone_phase <= 8'd0;
        end else if (aud_div + 14'd12 >= 14'd15625) begin
            aud_div    <= aud_div + 14'd12 - 14'd15625;
            tone_phase <= tone_phase + 8'd2; // ~375 Hz triangle wave @ 48 kHz
        end else begin
            aud_div <= aud_div + 14'd12;
        end
    end

    wire [7:0] tri_u = tone_phase[7] ? ~tone_phase : tone_phase;
    wire signed [15:0] tone_s = signed'({tri_u[6:0], 6'd0}) - 16'sd4096;
    assign audio_left   = test_tone_en ? tone_s : 16'sd0;
    assign audio_right  = test_tone_en ? tone_s : 16'sd0;
    assign vibrate_mode = test_tone_en ? 2'd1   : 2'd0;

    wire _unused_inputs = &{
        1'b0, rd_next, rd_next_tag,
        host_commandCore_busy, host_commandCore_done, host_commandCore_error,
        input_slots_0_deviceType, input_slots_0_buttons_x, input_slots_0_buttons_y,
        input_slots_0_buttons_up, input_slots_0_buttons_down, input_slots_0_buttons_l1,
        input_slots_0_buttons_r1, input_slots_0_buttons_l2, input_slots_0_buttons_r2,
        input_slots_0_buttons_l3, input_slots_0_buttons_r3, input_slots_0_buttons_start,
        input_slots_0_buttons_select, input_slots_0_analog_leftX, input_slots_0_analog_leftY,
        input_slots_0_analog_rightX, input_slots_0_analog_rightY,
        input_slots_0_analog_leftTrigger, input_slots_0_analog_rightTrigger,
        input_slots_1_deviceType, input_slots_1_buttons_a, input_slots_1_buttons_b,
        input_slots_1_buttons_x, input_slots_1_buttons_y, input_slots_1_buttons_up,
        input_slots_1_buttons_down, input_slots_1_buttons_left, input_slots_1_buttons_right,
        input_slots_1_buttons_l1, input_slots_1_buttons_r1, input_slots_1_buttons_l2,
        input_slots_1_buttons_r2, input_slots_1_buttons_l3, input_slots_1_buttons_r3,
        input_slots_1_buttons_start, input_slots_1_buttons_select,
        input_slots_1_analog_leftX, input_slots_1_analog_leftY,
        input_slots_1_analog_rightX, input_slots_1_analog_rightY,
        input_slots_1_analog_leftTrigger, input_slots_1_analog_rightTrigger,
        input_slots_2_deviceType, input_slots_2_buttons_a, input_slots_2_buttons_b,
        input_slots_2_buttons_x, input_slots_2_buttons_y, input_slots_2_buttons_up,
        input_slots_2_buttons_down, input_slots_2_buttons_left, input_slots_2_buttons_right,
        input_slots_2_buttons_l1, input_slots_2_buttons_r1, input_slots_2_buttons_l2,
        input_slots_2_buttons_r2, input_slots_2_buttons_l3, input_slots_2_buttons_r3,
        input_slots_2_buttons_start, input_slots_2_buttons_select,
        input_slots_2_analog_leftX, input_slots_2_analog_leftY,
        input_slots_2_analog_rightX, input_slots_2_analog_rightY,
        input_slots_2_analog_leftTrigger, input_slots_2_analog_rightTrigger,
        input_slots_3_deviceType, input_slots_3_buttons_a, input_slots_3_buttons_b,
        input_slots_3_buttons_x, input_slots_3_buttons_y, input_slots_3_buttons_up,
        input_slots_3_buttons_down, input_slots_3_buttons_left, input_slots_3_buttons_right,
        input_slots_3_buttons_l1, input_slots_3_buttons_r1, input_slots_3_buttons_l2,
        input_slots_3_buttons_r2, input_slots_3_buttons_l3, input_slots_3_buttons_r3,
        input_slots_3_buttons_start, input_slots_3_buttons_select,
        input_slots_3_analog_leftX, input_slots_3_analog_leftY,
        input_slots_3_analog_rightX, input_slots_3_analog_rightY,
        input_slots_3_analog_leftTrigger, input_slots_3_analog_rightTrigger
    };
endmodule

`default_nettype wire
