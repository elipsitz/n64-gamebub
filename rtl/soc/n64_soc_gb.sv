// Game Bub Nintendo 64 SoC (`n64_soc_gb.sv`)
//
// Adapts MIRLO64's clean-room N64 architecture (`mirlo_mips`) to Game Bub Rev4:
//   - VR4300 + COP1 FPU (`mips_sys` @ 93.75 MHz `clk_cpu`, 3:2 synchronous to `clk_sys`)
//   - Reality Signal Processor (`rsp_top`, 8 SIMD lanes) + XBUS/RDRAM `rdp_dpc`
//   - Reality Display Processor (`rdp_top` @ 62.5 MHz `clk_sys`)
//   - Hardware RCP peripherals: `rcp_mi` (+ `PI2` DMA), `rcp_vi`, `rcp_ai`, `rcp_si`
//   - Dual-rank 64 MiB SDRAM (`sdr_arb_gb` + `sdr_ctrl_w9825` + `sdr_phy_x7` @ 125 MHz)
//   - Glitch-free 512 KiB 10 ns Async SRAM (`gb_sram_ctrl`) + 16KB L1 / 64KB L2 `pi_rom_cache`
//   - N64 VI scanout (`n64_video`, `FAW=11`) + `n64_video_gb_downsampler` (320x240 RGB666)
`default_nettype none

module n64_soc_gb #(
    parameter        BOOTROM    = "boot.hex",
    parameter int    SDR_T_INIT = 12600
) (
    input  wire logic        clk_sys,        //  62.500 MHz RCP & Game Bub system clock
    input  wire logic        clk_cpu,        //  93.750 MHz VR4300 CPU clock (3:2)
    input  wire logic        clk_sys2x,      // 125.000 MHz 2x SDRAM/SRAM PHY clock
    input  wire logic        clk_sdram_pad,  // 125.000 MHz phase-shifted SDRAM clock
    input  wire logic        clk_vid,        //  25.000 MHz N64 VI pixel timing clock
    input  wire logic        reset,

    // Memory readiness
    output wire logic        sdr_ready,
    output wire logic        sram_ready,

    // Bridge SDRAM master port (from gb_host_bridge / self-test loader)
    input  wire logic        br_sdr_valid,
    input  wire logic        br_sdr_we,
    input  wire logic [23:0] br_sdr_addr,
    input  wire logic [31:0] br_sdr_wdata,
    input  wire logic [3:0]  br_sdr_be,
    output wire logic        br_sdr_ready,
    output wire logic        br_sdr_rvalid,
    output wire logic [31:0] br_sdr_rdata,
    input  wire logic        br_sdr_pending,

    // Bridge SRAM master port (from gb_host_bridge)
    input  wire logic        h_sram_valid,
    input  wire logic        h_sram_we,
    input  wire logic [16:0] h_sram_addr,
    input  wire logic [31:0] h_sram_wdata,
    input  wire logic [3:0]  h_sram_be,
    output wire logic        h_sram_ack,
    output wire logic [31:0] h_sram_rdata,

    // Cache invalidation pulse (on Slot 0 write / on-demand page fill)
    input  wire logic        rom_cache_inv,

    // Mirlo Audio FIFO interface (to gb_host_bridge)
    input  wire logic [11:0] apf_audio_buffer_fill,
    output wire logic [31:0] apf_audio_bus_out,
    output wire logic        apf_audio_bus_wr,
    output wire logic        apf_audio_flush,
    output wire logic        apf_audio_playback_en,

    // Mirlo Bridge CSR interface (to gb_host_bridge)
    input  wire logic [2:0]  apf_bridge_command_result_code,
    input  wire logic        apf_bridge_complete_trigger,
    input  wire logic [31:0] apf_bridge_current_address,
    output wire logic [31:0] apf_bridge_data_offset,
    input  wire logic [31:0] apf_bridge_file_size,
    output wire logic        apf_bridge_file_size_wr,
    input  wire logic        apf_bridge_host_loaded,
    input  wire logic        apf_bridge_host_reset_n,
    output wire logic [31:0] apf_bridge_length,
    output wire logic [31:0] apf_bridge_new_file_size_data,
    output wire logic [31:0] apf_bridge_ram_data_address,
    output wire logic        apf_bridge_request_getfile,
    output wire logic        apf_bridge_request_openfile,
    output wire logic        apf_bridge_request_read,
    output wire logic        apf_bridge_request_write,
    output wire logic        apf_bridge_request_setsize,
    output wire logic        apf_bridge_request_flush,
    output wire logic [15:0] apf_bridge_slot_id,

    // Pad scanner & Interact CSRs (from gb_host_bridge)
    input  wire logic        apf_pad_clk,
    input  wire logic        apf_pad_we,
    input  wire logic [3:0]  apf_pad_wa,
    input  wire logic [31:0] apf_pad_wd,
    input  wire logic [4:0]  apf_interact_address,
    input  wire logic [31:0] apf_interact_data,
    input  wire logic        apf_interact_wr,
    output wire logic [31:0] apf_interact_q,
    output wire logic        rumble_motor_on,

    // Video filter & HUD controls (from gb_host_bridge)
    input  wire logic        vid_horiz_blend_en,
    input  wire logic        vid_dither_en,
    input  wire logic        vid_no_weave,
    input  wire logic [1:0]  vid_fps_mode,

    // Game Bub VideoV0 (320x240 RGB666 @ clk_sys)
    output wire logic [5:0]  video_data_r,
    output wire logic [5:0]  video_data_g,
    output wire logic [5:0]  video_data_b,
    output wire logic        video_dataEnable,
    output wire logic        video_vblank,
    output wire logic        video_hblank,

    // Game Bub SdramV0 (2x W9825G6KH-6 = 64 MiB)
    output wire logic        sdram_clock,
    output wire logic [1:0]  sdram_cke,
    output wire logic [1:0]  sdram_cs_n,
    output wire logic        sdram_ras_n,
    output wire logic        sdram_cas_n,
    output wire logic        sdram_we_n,
    output wire logic [1:0]  sdram_dqm,
    output wire logic [1:0]  sdram_ba,
    output wire logic [12:0] sdram_a,
    input  wire logic [15:0] sdram_dq_in,
    output wire logic [15:0] sdram_dq_out,
    output wire logic        sdram_dq_oe,
    output wire logic [15:0] sdram_dq_tri,

    // Game Bub SramV0 (IS61WV25616EDBLL-10TLI = 512 KiB, 10 ns)
    output wire logic        sram_ceN,
    output wire logic        sram_weN,
    output wire logic        sram_oeN,
    output wire logic [1:0]  sram_writeMaskN,
    output wire logic [17:0] sram_address,
    input  wire logic [15:0] sram_dataIn,
    output wire logic [15:0] sram_dataOut,
    output wire logic        sram_dataDir,
    output wire logic [15:0] sram_dataTri,

    // Optional debug / simulation tap outputs
    output wire logic        uart_tx_we,
    output wire logic [7:0]  uart_tx_byte,
    output wire logic [31:0] dbg_cpu_pc,
    output wire logic [31:0] dbg_cpu_cause,
    output wire logic [31:0] dbg_cpu_epc
);
    // -------------------------------------------------------------------------
    // 1. Synchronized Domain Resets
    // -------------------------------------------------------------------------
    wire clk = clk_sys;
    logic rst, rst2x, rst_cpu, rst_vid, rv1;
    always_ff @(posedge clk)       rst     <= reset;
    always_ff @(posedge clk_sys2x) rst2x   <= reset;
    always_ff @(posedge clk_cpu)   rst_cpu <= reset;
    always_ff @(posedge clk_vid)   begin rv1 <= reset; rst_vid <= rv1; end

    // -------------------------------------------------------------------------
    // 2. 64 MiB Dual-Rank SDRAM Subsystem (6 Arbiter Masters)
    //    0: VI scan-out   1: VR4300 CPU   2: RDP pixels/Z
    //    3: RSP DMA       4: Bridge/PI/AI/SI/ROM-cache   5: RDP command fetch
    // -------------------------------------------------------------------------
    localparam int NP = 6;
    localparam logic [NP-1:0] SN_PORTS = 6'b01_1100;

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

    logic        sn_t, sn_hold, sn_hold_s;
    always_ff @(posedge clk) begin
        sn_hold_s <= !rst && sn_hold;
        if (rst) sn_t <= 1'b0;
        else if (|(p_ready & p_we & SN_PORTS)) sn_t <= !sn_t;
    end

    sdr_arb_gb #(.N(NP), .APF_PREEMPT(1)) arb (
        .clk       (clk),
        .rst       (rst),
        .p_valid   (p_valid & ~(p_we & SN_PORTS & {NP{sn_hold_s}})),
        .p_we      (p_we),
        .p_addr    (p_addr),
        .p_wdata   (p_wdata),
        .p_be      (p_be),
        .p_urgent  (p_urgent),
        .apf_force (br_sdr_pending),
        .p_ready   (p_ready),
        .p_rvalid  (p_rvalid),
        .p_rdata   (p_rdata),
        .la_valid  (la_valid),
        .la_addr   (la_addr),
        .req_valid (rq_valid),
        .req_we    (rq_we),
        .req_addr  (rq_addr),
        .req_wdata (rq_wdata),
        .req_be    (rq_be),
        .req_tag   (rq_tag),
        .req_ready (rq_ready),
        .rd_valid  (rd_valid),
        .rd_data   (rd_data),
        .rd_tag    (rd_tag)
    );

    logic [3:0]  dfi_cs_n, dfi_ba, dfi_wm;
    logic [1:0]  dfi_cke, dfi_ras_n, dfi_cas_n, dfi_we_n;
    logic [25:0] dfi_addr;
    logic        dfi_wren, dfi_rden, dfi_rv;
    logic [31:0] dfi_wd, dfi_rd;

    sdr_ctrl_w9825 #(.T_INIT(SDR_T_INIT), .AHEAD(1'b1)) sdram (
        .clk              (clk),
        .rst              (rst),
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

    sdr_phy_x7 phy (
        .clk          (clk),
        .rst          (rst),
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
        .sdram_a      (sdram_a),
        .sdram_ba     (sdram_ba),
        .sdram_cs_n   (sdram_cs_n),
        .sdram_cke    (sdram_cke),
        .sdram_ras_n  (sdram_ras_n),
        .sdram_cas_n  (sdram_cas_n),
        .sdram_we_n   (sdram_we_n),
        .sdram_dm     (sdram_dqm),
        .sdram_dq_in  (sdram_dq_in),
        .sdram_dq_out (sdram_dq_out),
        .sdram_dq_oe  (sdram_dq_oe),
        .sdram_dq_tri (sdram_dq_tri),
        .sdram_clock  (sdram_clock)
    );

    // -------------------------------------------------------------------------
    // 3. VR4300 CPU (`mips_sys` @ 93.75 MHz) & `cpu_port` Bridge + Device Bus
    // -------------------------------------------------------------------------
    logic        s_req, s_we, s_line, s_rvalid, s_wrun;
    logic [31:0] s_addr, s_wdata, s_rdata;
    logic [3:0]  s_strb;
    logic        x_req, x_we, x_ack;
    logic [31:0] x_addr, x_wdata, x_rdata;
    logic [3:0]  x_strb;
    logic        game_irq, geom_irq, geom_run;
    logic        cpu_irq, mon_irq, mon_own, mon_rcp, mon_sp, mon_field, mon_dp;
    logic        irq_s, irq_mon_s, c_irq, c_irq_mon;
    logic        c_x_req, c_x_ack, st_valid, st_dev, st_full, st_done;
    logic [31:0] c_x_addr, c_x_rdata, st_addr, st_data;
    logic [3:0]  st_strb;

    always_ff @(posedge clk) begin
        irq_s     <= cpu_irq;
        irq_mon_s <= mon_irq;
    end

    mips_sys #(.BOOTROM(BOOTROM), .FAST(1'b1), .XWB(1'b1)) sys (
        .clk      (clk_cpu),
        .rst      (rst_cpu),
        .s_req    (s_req),
        .s_we     (s_we),
        .s_addr   (s_addr),
        .s_wdata  (s_wdata),
        .s_strb   (s_strb),
        .s_line   (s_line),
        .s_wrun   (s_wrun),
        .s_ack    (1'b0),
        .s_rvalid (s_rvalid),
        .s_rdata  (s_rdata),
        .s_busy   (1'b0),
        .x_req    (c_x_req),
        .x_we     (),
        .x_addr   (c_x_addr),
        .x_wdata  (),
        .x_strb   (),
        .x_ack    (c_x_ack),
        .x_rdata  (c_x_rdata),
        .st_valid (st_valid),
        .st_dev   (st_dev),
        .st_addr  (st_addr),
        .st_data  (st_data),
        .st_strb  (st_strb),
        .st_full  (st_full),
        .st_done  (st_done),
        .irq      (c_irq),
        .irq_mon  (c_irq_mon),
        .sn_t     (sn_t),
        .sn_line  (rq_addr[23:2]),
        .sn_hold  (sn_hold),
        .dbg_pc   (dbg_cpu_pc),
        .dbg_cause(dbg_cpu_cause),
        .dbg_epc  (dbg_cpu_epc)
    );

    cpu_port #(.PORT(1)) pc (
        .clk_c       (clk_cpu),
        .rst_c       (rst_cpu),
        .st_valid    (st_valid),
        .st_dev      (st_dev),
        .st_addr     (st_addr),
        .st_data     (st_data),
        .st_strb     (st_strb),
        .st_full     (st_full),
        .st_done     (st_done),
        .s_req       (s_req),
        .s_line      (s_line),
        .s_addr      (s_addr),
        .s_rvalid    (s_rvalid),
        .s_rdata     (s_rdata),
        .c_x_req     (c_x_req),
        .c_x_addr    (c_x_addr),
        .c_x_ack     (c_x_ack),
        .c_x_rdata   (c_x_rdata),
        .c_irq       (c_irq),
        .c_irq_mon   (c_irq_mon),
        .clk         (clk),
        .rst         (rst),
        .p_valid     (p_valid[1]),
        .p_we        (p_we[1]),
        .p_addr      (p_addr[1]),
        .p_wdata     (p_wdata[1]),
        .p_be        (p_be[1]),
        .p_ready     (p_ready[1]),
        .p_rdata     (p_rdata),
        .rd_next     (rd_next),
        .rd_next_tag (rd_next_tag),
        .x_req       (x_req),
        .x_we        (x_we),
        .x_addr      (x_addr),
        .x_wdata     (x_wdata),
        .x_strb      (x_strb),
        .x_ack       (x_ack),
        .x_rdata     (x_rdata),
        .irq         (irq_s),
        .irq_mon     (irq_mon_s)
    );
    assign p_urgent[1] = 1'b1;

    // Device bus address decoding
    wire x_regs = x_addr[31:16] == 16'hF000;
    wire x_rsp  = x_addr[31:8]  == 24'h2000_00;
    wire x_spr  = !x_addr[30] && x_addr[28:5] == 24'h20_2000;
    wire x_sppc = !x_addr[30] && x_addr[28:2] == 27'h102_0000;
    wire x_dpcr = !x_addr[30] && x_addr[28:4] == 25'h41_0000;
    wire x_mon  = x_addr[31:11] == 21'h1FFFF0;
    wire x_mi   = !x_addr[30] && x_addr[28:20] == 9'h043;
    wire x_pi   = !x_addr[30] && x_addr[28:2]  == 27'h1180004;
    wire x_vi   = !x_addr[30] && x_addr[28:20] == 9'h044;
    wire x_ai   = !x_addr[30] && x_addr[28:20] == 9'h045;
    wire x_si   = !x_addr[30] && x_addr[28:20] == 9'h048;
    wire x_pif  = !x_addr[30] && x_addr[28:20] == 9'h1FC && x_addr[10:6] == 5'h1F;

    // Cartridge Domain 2 (0x0800_0000..0x0FFF_FFFF) & raw SRAM window (0x3400_0000..0x341F_FFFF) -> Async SRAM
    // Cartridge Domain 1 ROM (0x1000_0000..0x13FF_FFFF) & runtime ROM window (0x3000_0000..0x33FF_FFFF) -> SDRAM 0x4010_0000 + o
    wire x_d2   = !x_addr[30] && x_addr[28:27] == 2'b01;
    wire x_rom  = !x_addr[30] && x_addr[28:26] == 3'b100;
    wire x_psw  = x_addr[31:26] == 6'b001100;
    wire x_psh  = x_addr[31:21] == 11'h1A0;
    wire io_ps  = x_psh || x_d2;

    logic        d2_flash, io_ack;
    logic [31:0] pa_dat_r /*verilator public_flat_rd*/;
    wire  [23:0] io_adr = x_psh              ? {5'd0, x_addr[20:2]}
                        : (x_rom || x_psw)   ? (24'h04_0000 + x_addr[25:2])
                        : d2_flash           ? 24'h05_8040
                        :                      {9'h00A, x_addr[16:2]};

    typedef enum logic [3:0] {
        X_IDLE, X_REGS, X_REGD, X_RSP, X_MON, X_MOND,
        X_MIW1, X_MIW2, X_VIR, X_VIW, X_PIF, X_PIFR, X_CART
    } xst_t;
    xst_t        xs;
    logic [31:0] mon_rd, mi_w_rd, vi_rd, ai_rd, si_rd, si_q, r_rdata, rsp_x_rdata, rx_wdata;
    logic [4:0]  rx_addr;
    logic        rx_we, rsp_h_ready, si_busy;
    logic [15:0] bus_errors;

    wire mi_op    = xs == X_IDLE && x_req && !x_ack && (x_mi || x_pi);
    wire ai_op    = xs == X_IDLE && x_req && !x_ack && x_ai;
    wire si_op    = xs == X_IDLE && x_req && !x_ack && x_si;
    wire rsp_x_go = xs == X_RSP && (!rx_we || rsp_h_ready);
    wire xr_go    = xs == X_REGS;

    mon_ram monram (
        .clk (clk),
        .we  (xs == X_MON && x_we),
        .a   (x_addr[10:2]),
        .wd  (x_wdata),
        .be  (x_strb),
        .rd  (mon_rd)
    );

    always_ff @(posedge clk) begin
        x_ack <= 1'b0;
        if (rst) begin
            xs         <= X_IDLE;
            bus_errors <= 16'd0;
        end else case (xs)
            X_IDLE: if (x_req && !x_ack) begin
                if (x_regs)      xs <= X_REGS;
                else if (x_mon)  xs <= X_MON;
                else if (x_mi || x_pi) begin if (x_we) xs <= X_MIW1; else x_ack <= 1'b1; end
                else if (x_vi)   xs <= x_we ? X_VIW : X_VIR;
                else if (x_ai)   begin if (x_we) xs <= X_MIW1; else x_ack <= 1'b1; end
                else if (x_si)   begin if (x_we) xs <= X_MIW1; else x_ack <= 1'b1; end
                else if (x_pif)  xs <= X_PIF;
                else if (x_d2 || x_rom || x_psw || x_psh) begin
                    if (x_we && (x_rom || x_psw || (x_d2 && d2_flash))) x_ack <= 1'b1;
                    else xs <= X_CART;
                end else if (x_rsp || x_spr || x_sppc || x_dpcr) begin
                    rx_wdata <= x_wdata;
                    rx_we    <= x_we;
                    xs       <= X_RSP;
                    rx_addr  <= x_rsp ? x_addr[6:2] : {x_dpcr, x_sppc, x_dpcr ? 1'b0 : x_addr[4], x_addr[3:2]};
                end else begin
                    x_ack <= 1'b1;
                    if (bus_errors != 16'hFFFF) bus_errors <= bus_errors + 16'd1;
                end
            end
            X_REGS: xs <= X_REGD;
            X_REGD: begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_MON:  xs <= X_MOND;
            X_MOND: begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_VIR:  begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_PIF:  if (!si_busy) xs <= x_we ? X_MIW2 : X_PIFR;
            X_PIFR: begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_CART: if (io_ack) begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_VIW:  xs <= X_MIW1;
            X_MIW1: xs <= X_MIW2;
            X_MIW2: begin x_ack <= 1'b1; xs <= X_IDLE; end
            X_RSP:  if (rsp_x_go) begin x_ack <= 1'b1; xs <= X_IDLE; end
            default: xs <= X_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        case (xs)
            X_IDLE:  x_rdata <= (x_mi || x_pi) ? mi_w_rd : x_ai ? ai_rd : x_si ? si_rd : 32'd0;
            X_MOND:  x_rdata <= mon_rd;
            X_VIR:   x_rdata <= vi_rd;
            X_PIFR:  x_rdata <= si_q;
            X_CART:  x_rdata <= pa_dat_r;
            X_RSP:   x_rdata <= rsp_x_rdata;
            default: x_rdata <= r_rdata;
        endcase
    end

    // -------------------------------------------------------------------------
    // 4. Mirlo CSRs (`mirlo_regs`), MI, PI2 Engine, VI, AI, SI
    // -------------------------------------------------------------------------
    logic        mi_line, mon_mi;
    logic        vi_line, vi_latch, vi_irq, vi_chg, vi_clr, vi_blk, vi_gm, mon_vi;
    logic        vi_aa, vi_dv, vi_dd, vi_il, vi_pal_rq;
    logic [25:0] vi_base;
    logic [16:0] vi_thr;
    wire  [4:0]  vid_crop_v;
    wire  [1:0]  vid_crop_r, vid_crop_l;
    wire         vid_deblur, vid_out32;

    logic        mon_ai, ai_clr, ai_chg, ai_req;
    logic        ai_irq /*verilator public_flat_rd*/, ai_fw /*verilator public_flat_rd*/,
                 ai_step_we /*verilator public_flat_rd*/, ai_ack /*verilator public_flat_rd*/;
    logic [13:0] ai_dac;
    logic [19:0] ai_step_wd /*verilator public_flat_rd*/;
    logic [31:0] ai_fd, aud_out_r;
    logic        aud_wr_r;
    logic [23:0] ai_adr;

    logic [31:0] si_wdata;
    logic        si_irq, si_clr, si_ev, si_done, si_req, si_we, si_ack;
    logic [23:0] si_adr;

    logic        d_req, d_we, d_ack, d_ps;
    logic [23:0] d_adr;
    logic [3:0]  d_sel;
    logic [31:0] d_wdata;

    logic        su_valid, su_ready, cmd_valid, cmd_ready, rdp_idle, rdp_tmem_busy;
    logic [31:0] su_data, cmd_data, rdp_sync, rdp_load;
    logic [15:0] rdp_unknown;
    logic [31:0] fb_base_csr;
    logic [11:0] fb_width, fb_ys;
    logic [7:0]  fb_y0;
    logic [8:0]  fb_rows;
    logic [9:0]  fb_px0, fb_pw;
    logic [10:0] fb_xs, fb_nw;
    logic        fb_gamma, fb_tall, fb_pal, tv_pal, fb_dma_enable, fb_vtg_enable, fb_mode, vblank;

    mirlo_regs #(.GB_CART_PRESENT(1'b0)) regs (
        .clk                    (clk),
        .rst                    (rst),
        .r_req                  (xr_go),
        .r_we                   (x_we),
        .r_addr                 (x_addr[15:0]),
        .r_wdata                (x_wdata),
        .r_rdata                (r_rdata),
        .aud_out                (aud_out_r),
        .aud_wr                 (aud_wr_r),
        .aud_playback_en        (apf_audio_playback_en),
        .aud_flush              (apf_audio_flush),
        .aud_fill               (apf_audio_buffer_fill),
        .br_request_read        (apf_bridge_request_read),
        .br_request_write       (apf_bridge_request_write),
        .br_request_getfile     (apf_bridge_request_getfile),
        .br_request_openfile    (apf_bridge_request_openfile),
        .br_request_setsize     (apf_bridge_request_setsize),
        .br_request_flush       (apf_bridge_request_flush),
        .br_slot_id             (apf_bridge_slot_id),
        .br_data_offset         (apf_bridge_data_offset),
        .br_length              (apf_bridge_length),
        .br_ram_data_address    (apf_bridge_ram_data_address),
        .br_file_size_wr        (apf_bridge_file_size_wr),
        .br_new_file_size       (apf_bridge_new_file_size_data),
        .br_file_size           (apf_bridge_file_size),
        .br_complete_trigger    (apf_bridge_complete_trigger),
        .br_current_address     (apf_bridge_current_address),
        .br_command_result_code (apf_bridge_command_result_code),
        .br_host_reset_n        (apf_bridge_host_reset_n),
        .br_host_loaded         (apf_bridge_host_loaded),
        .ss_save_t              (1'b0),
        .ss_load_t              (1'b0),
        .ss_done_t              (),
        .ss_err                 (),
        .ss_sup                 (),
        .pad_clk                (apf_pad_clk),
        .pad_we                 (apf_pad_we),
        .pad_wa                 (apf_pad_wa),
        .pad_wd                 (apf_pad_wd),
        .ia_address             (apf_interact_address),
        .ia_data                (apf_interact_data),
        .ia_wr                  (apf_interact_wr),
        .ia_q                   (apf_interact_q),
        .ia_an_mode             (),
        .ia_an_scan             (),
        .ia_an_own              (),
        .ia_crop_v              (vid_crop_v),
        .ia_crop_r              (vid_crop_r),
        .ia_crop_l              (vid_crop_l),
        .ia_out32               (vid_out32),
        .ia_deblur              (vid_deblur),
        .ia_rumble              (rumble_motor_on),
        .vblank                 (vblank),
        .fb_base                (fb_base_csr),
        .fb_width               (fb_width),
        .fb_y0                  (fb_y0),
        .fb_rows                (fb_rows),
        .fb_px0                 (fb_px0),
        .fb_pw                  (fb_pw),
        .fb_xs                  (fb_xs),
        .fb_ys                  (fb_ys),
        .fb_nw                  (fb_nw),
        .fb_tall                (fb_tall),
        .fb_gamma               (fb_gamma),
        .fb_pal                 (fb_pal),
        .tv_pal                 (tv_pal),
        .fb_dma_enable          (fb_dma_enable),
        .fb_vtg_enable          (fb_vtg_enable),
        .fb_mode                (fb_mode),
        .bus_errors             (bus_errors),
        .geom_irq               (geom_irq),
        .game_irq               (game_irq),
        .geom_run               (geom_run),
        .dbg_geom_msg           (),
        .su_valid               (su_valid),
        .su_ready               (su_ready),
        .su_data                (su_data),
        .cmd_valid              (cmd_valid),
        .cmd_ready              (cmd_ready),
        .cmd_data               (cmd_data),
        .rdp_sync_count         (rdp_sync),
        .rdp_load_count         (rdp_load),
        .rdp_unknown_ops        (rdp_unknown),
        .rdp_idle               (rdp_idle),
        .uart_we                (uart_tx_we),
        .uart_byte              (uart_tx_byte),
        .uart_txfull            (1'b0),
        .uart_rx_pop            (),
        .uart_rx_byte           (8'd0),
        .uart_rxempty           (1'b1),
        .mon_sp                 (mon_sp),
        .mon_field              (mon_field),
        .mon_dp                 (mon_dp),
        .mon_own                (mon_own),
        .mon_rcp                (mon_rcp),
        .mon_irq                (mon_irq),
        .mon_mi                 (mon_mi),
        .mi_line                (mi_line),
        .mi_w_mi                (mi_op && x_mi),
        .mi_w_pi                (mi_op && x_pi),
        .mi_w_we                (x_we),
        .mi_w_a                 (x_addr[3:2]),
        .mi_w_wd                (x_wdata),
        .mi_w_rd                (mi_w_rd),
        .d_req                  (d_req),
        .d_we                   (d_we),
        .d_adr                  (d_adr),
        .d_ps                   (d_ps),
        .d_sel                  (d_sel),
        .d_wdata                (d_wdata),
        .d_rdata                (pa_dat_r),
        .d_ack                  (d_ack),
        .io_req                 (xs == X_CART),
        .io_we                  (x_we),
        .io_adr                 (io_adr),
        .io_ps                  (io_ps && (x_rom || x_psw || x_psh || x_d2)),
        .io_wd                  (x_wdata),
        .io_be                  (x_strb),
        .io_ack                 (io_ack),
        .d2_flash               (d2_flash),
        .ps_ready               (sram_ready),
        .mon_vi                 (mon_vi),
        .vi_thr                 (vi_thr),
        .vi_irq                 (vi_irq),
        .vi_chg                 (vi_chg),
        .vi_clr                 (vi_clr),
        .mon_ai                 (mon_ai),
        .ai_irq                 (ai_irq),
        .ai_clr                 (ai_clr),
        .ai_chg                 (ai_chg),
        .ai_dac                 (ai_dac),
        .ai_step_we             (ai_step_we),
        .ai_step_wd             (ai_step_wd),
        .si_irq                 (si_irq),
        .si_clr                 (si_clr),
        .si_ev                  (si_ev),
        .si_done                (si_done),
        .sn_wr                  (),
        .sn_rd                  (),
        .sn_a                   (),
        .sn_wd                  (),
        .sn_q                   (32'd0),
        .gbc_on                 (),
        .gbc_trust              (),
        .gbc_start              (),
        .gbc_we                 (),
        .gbc_addr               (),
        .gbc_wdata              (),
        .gbc_busy               (1'b0),
        .gbc_rdata              (8'd0)
    );

    // -------------------------------------------------------------------------
    // 5. RSP (`rsp_top`, LANES=8) + `rdp_dpc` + `rdp_top`
    // -------------------------------------------------------------------------
    logic        rsp_r_valid, rsp_r_we, rsp_halted, rsp_unimpl, rsp_irq;
    logic [23:2] rsp_r_addr;
    logic [31:0] rsp_r_wdata, rsp_h_rdata;
    logic        dpc_start_we, dpc_end_we, dpc_status_we;
    logic        rsp_dpc_start_we, rsp_dpc_end_we, rsp_dpc_status_we;
    logic [31:0] dpc_wdata, rsp_dpc_wdata, dpc_status, dpc_st_raw;
    logic [23:0] dpc_start, dpc_end, dpc_end_rd, dpc_current;
    logic        dpc_start_ok;
    logic [20:0] dpc_m_addr;
    logic [9:0]  dpc_dx_addr;
    logic [31:0] dpc_dx_data;

    `ifndef MIRLO_RSP_LANES
    `define MIRLO_RSP_LANES 8
    `endif
    rsp_top #(.LANES(`MIRLO_RSP_LANES), .MULW(1'b1)) rsp (
        .clk           (clk),
        .rst           (rst),
        .h_we          (rsp_x_go && rx_we && !rx_addr[4]),
        .h_rd          (rsp_x_go && !rx_we && !rx_addr[4]),
        .h_addr        (rx_addr[3:0]),
        .h_wdata       (rx_wdata),
        .h_rdata       (rsp_h_rdata),
        .h_ready       (rsp_h_ready),
        .irq           (rsp_irq),
        .r_valid       (rsp_r_valid),
        .r_we          (rsp_r_we),
        .r_addr        (rsp_r_addr),
        .r_wdata       (rsp_r_wdata),
        .r_ready       (p_ready[3]),
        .r_rvalid      (p_rvalid[3]),
        .r_rdata       (p_rdata),
        .dpc_start_we  (rsp_dpc_start_we),
        .dpc_end_we    (rsp_dpc_end_we),
        .dpc_status_we (rsp_dpc_status_we),
        .dpc_wdata     (rsp_dpc_wdata),
        .dpc_start     ({8'd0, dpc_start}),
        .dpc_end       ({8'd0, dpc_end_rd}),
        .dpc_current   ({8'd0, dpc_current}),
        .dpc_status    (dpc_status),
        .dx_addr       (dpc_dx_addr),
        .dx_data       (dpc_dx_data),
        .halted        (rsp_halted),
        .unimpl        (rsp_unimpl),
        .tr_e          (),
        .tr_e_pc       (),
        .tr_e2         (),
        .tr_e_we       (),
        .tr_e_wr       (),
        .tr_we         (),
        .tr_wr         (),
        .tr_val        (),
        .tr_mw         (),
        .tr_v          (),
        .tr_vp         ()
    );

    assign cpu_irq     = mon_own ? (mon_mi ? mi_line : mon_rcp) : (game_irq | rsp_irq);
    assign mon_sp      = rsp_irq;
    assign p_valid[3]  = rsp_r_valid;
    assign p_we[3]     = rsp_r_we;
    assign p_addr[3]   = 24'hE0_0000 + {3'd0, rsp_r_addr[22:2]};
    assign p_wdata[3]  = rsp_r_wdata;
    assign p_be[3]     = 4'hF;
    assign p_urgent[3] = 1'b1;

    wire dpc_h_w      = rsp_x_go && rx_we && rx_addr[4];
    assign dpc_start_we  = (rsp_dpc_start_we  || (dpc_h_w && rx_addr[1:0] == 2'd0)) && dpc_start_ok;
    assign dpc_end_we    =  rsp_dpc_end_we    || (dpc_h_w && rx_addr[1:0] == 2'd1);
    assign dpc_status_we =  rsp_dpc_status_we || (dpc_h_w && rx_addr[1:0] == 2'd3);
    assign dpc_wdata     = dpc_h_w ? rx_wdata : rsp_dpc_wdata;

    rcp_dpc_view dpc_view (
        .clk       (clk),
        .rst       (rst),
        .end_we    (dpc_end_we),
        .status_we (dpc_status_we),
        .wdata     (dpc_wdata),
        .sync_full (mon_dp),
        .cmd_busy  (cmd_valid || !rdp_idle),
        .tmem_busy (rdp_tmem_busy),
        .st_raw    (dpc_st_raw),
        .cur       (dpc_current),
        .end_      (dpc_end),
        .start_ok  (dpc_start_ok),
        .st        (dpc_status)
    );

    rdp_dpc dpc (
        .clk       (clk),
        .rst       (rst),
        .start_we  (dpc_start_we),
        .end_we    (dpc_end_we),
        .status_we (dpc_status_we),
        .wdata     (dpc_wdata),
        .start     (dpc_start),
        .end_      (dpc_end),
        .end_rd    (dpc_end_rd),
        .current   (dpc_current),
        .status    (dpc_st_raw),
        .rdp_busy  (cmd_valid || !rdp_idle),
        .m_valid   (p_valid[5]),
        .m_addr    (dpc_m_addr),
        .m_ready   (p_ready[5]),
        .m_rvalid  (p_rvalid[5]),
        .m_rdata   (p_rdata),
        .dx_addr   (dpc_dx_addr),
        .dx_data   (dpc_dx_data),
        .c_valid   (su_valid),
        .c_data    (su_data),
        .c_ready   (su_ready)
    );
    assign p_we[5]     = 1'b0;
    assign p_addr[5]   = 24'hE0_0000 + {3'd0, dpc_m_addr};
    assign p_wdata[5]  = 32'd0;
    assign p_be[5]     = 4'hF;
    assign p_urgent[5] = 1'b0;

    always_comb begin
        if (!rx_addr[4]) rsp_x_rdata = rsp_h_rdata;
        else unique case (rx_addr[1:0])
            2'd0:    rsp_x_rdata = {8'd0, dpc_start};
            2'd1:    rsp_x_rdata = {8'd0, dpc_end_rd};
            2'd2:    rsp_x_rdata = {8'd0, dpc_current};
            default: rsp_x_rdata = dpc_status;
        endcase
    end

    // RDP (with 9-bit-col shadow plane at 0x4350_0000 = word 24'hD4_0000)
    logic        m_cmd_valid, m_cmd_ready, m_cmd_we, m_wdata_valid, m_wdata_ready, m_rdata_valid;
    logic [31:0] m_cmd_addr, m_wdata, m_rdata, rdp_addr;
    logic [3:0]  m_wdata_we;

    rdp_top rdp (
        .clk           (clk),
        .rst           (rst),
        .dither_off    (vid_out32),
        .shadow_en     (vid_out32),
        .cmd_valid     (cmd_valid),
        .cmd_ready     (cmd_ready),
        .cmd_data      (cmd_data),
        .m_cmd_valid   (m_cmd_valid),
        .m_cmd_ready   (m_cmd_ready),
        .m_cmd_we      (m_cmd_we),
        .m_cmd_addr    (rdp_addr),
        .m_wdata_valid (m_wdata_valid),
        .m_wdata_ready (m_wdata_ready),
        .m_wdata       (m_wdata),
        .m_wdata_we    (m_wdata_we),
        .m_rdata_valid (m_rdata_valid),
        .m_rdata       (m_rdata),
        .sync_count    (rdp_sync),
        .sync_ev       (mon_dp),
        .load_count    (rdp_load),
        .unknown_ops   (rdp_unknown),
        .idle          (rdp_idle),
        .tmem_busy     (rdp_tmem_busy)
    );

    wire [19:0] sh_n = rdp_addr[21:2];
    wire [18:0] sh_w = {sh_n[18:10] ^ {sh_n[19], 8'd0}, sh_n[8:7] ^ 2'b01, sh_n[9], sh_n[6:0]};
    assign m_cmd_addr = {
        6'd0,
        rdp_addr[24] ? (24'hD4_0000 + {5'd0, sh_w}) :
        rdp_addr[23] ? (24'hDC_0000 + {6'd0, rdp_addr[19:2]}) :
                       (24'hE0_0000 + {3'd0, rdp_addr[22:2]}),
        2'b00
    };

    port_rdp pm (
        .clk           (clk),
        .rst           (rst),
        .m_cmd_valid   (m_cmd_valid),
        .m_cmd_we      (m_cmd_we),
        .m_cmd_addr    (m_cmd_addr),
        .m_cmd_ready   (m_cmd_ready),
        .m_wdata_valid (m_wdata_valid),
        .m_wdata       (m_wdata),
        .m_wdata_we    (m_wdata_we),
        .m_wdata_ready (m_wdata_ready),
        .m_rdata_valid (m_rdata_valid),
        .m_rdata       (m_rdata),
        .p_valid       (p_valid[2]),
        .p_we          (p_we[2]),
        .p_addr        (p_addr[2]),
        .p_wdata       (p_wdata[2]),
        .p_be          (p_be[2]),
        .p_ready       (p_ready[2]),
        .p_rvalid      (p_rvalid[2]),
        .p_rdata       (p_rdata)
    );
    assign p_urgent[2] = 1'b0;

    // -------------------------------------------------------------------------
    // 6. Port 4 Shared Multiplexer (Host Bridge SDRAM + PI/AI/SI + PI ROM Cache)
    //    & 512 KiB 10 ns Async SRAM (`gb_sram_ctrl`)
    // -------------------------------------------------------------------------
    logic        pa_dma, pa_ai, pa_si, pa_ack;
    always_ff @(posedge clk) begin
        if (rst) pa_dma <= 1'b0;
        else if (pa_dma) begin
            if (pa_ack) pa_dma <= 1'b0;
        end else if ((d_req || ai_req || si_req) && !br_sdr_pending && !br_sdr_valid) begin
            pa_dma <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pa_ai <= 1'b0;
            pa_si <= 1'b0;
        end else if (!pa_dma) begin
            pa_ai <= ai_req && !d_we;
            pa_si <= !ai_req && si_req && !d_we;
        end
    end

    assign d_ack  = pa_dma && pa_ack && !pa_ai && !pa_si;
    assign ai_ack = pa_dma && pa_ack && pa_ai;
    assign si_ack = pa_dma && pa_ack && pa_si;

    wire        pd_req = pa_si ? si_req : pa_ai ? ai_req : d_req;
    wire [23:0] pd_adr = pa_si ? si_adr : pa_ai ? ai_adr : d_adr;
    wire        pd_we  = pa_si ? si_we  : (d_we && !pa_ai);
    wire [31:0] pd_wd  = pa_si ? si_wdata : d_wdata;

    // Select Async SRAM (`pa_x_sel`) vs L1/L2 ROM Cache (`pa_rom_sel`) vs direct SDRAM
    wire pa_sram_sel = !pa_ai && !pa_si && d_ps;
    wire pa_rom_sel  = !pa_ai && !pa_si && !d_ps && !pd_we &&
                       (pd_adr >= 24'h04_0000) && (pd_adr < 24'hD4_0000);
    wire pa_ext_sel  = pa_sram_sel || pa_rom_sel;

    logic        pa_x_valid, sram_x_ack, rom_ack;
    logic [31:0] sram_x_rdata, rom_rdata;
    wire         pa_x_ack   = pa_sram_sel ? sram_x_ack   : rom_ack;
    wire  [31:0] pa_x_rdata = pa_sram_sel ? sram_x_rdata : rom_rdata;

    logic        pa_sdr_valid, pa_sdr_we, pa_sdr_ready, pa_sdr_rvalid;
    logic [23:0] pa_sdr_addr;
    logic [31:0] pa_sdr_wdata;
    logic [3:0]  pa_sdr_be;

    port_apf pa (
        .clk     (clk),
        .rst     (rst),
        .cyc     (pa_dma && pd_req),
        .stb     (pa_dma),
        .we      (pd_we),
        .adr     ({6'd0, pd_adr}),
        .dat_w   (pd_wd),
        .sel     (d_sel),
        .ack     (pa_ack),
        .dat_r   (pa_dat_r),
        .x_sel   (pa_ext_sel),
        .x_valid (pa_x_valid),
        .x_ack   (pa_x_ack),
        .x_rdata (pa_x_rdata),
        .p_valid (pa_sdr_valid),
        .p_we    (pa_sdr_we),
        .p_addr  (pa_sdr_addr),
        .p_wdata (pa_sdr_wdata),
        .p_be    (pa_sdr_be),
        .p_ready (pa_sdr_ready),
        .p_rvalid(pa_sdr_rvalid),
        .p_rdata (p_rdata)
    );

    // L1 BRAM + L2 Async SRAM PI Cartridge ROM Cache
    logic        cache_m_valid, cache_m_ready, cache_m_rvalid;
    logic [23:0] cache_m_addr;
    logic        l2_valid, l2_we, l2_ack;
    logic [16:0] l2_addr;
    logic [31:0] l2_wdata, l2_rdata;

    pi_rom_cache u_pi_rom_cache (
        .clk       (clk),
        .rst       (rst),
        .inv_all   (rom_cache_inv),
        .rom_req   (pa_x_valid && pa_rom_sel),
        .rom_addr  (pa_sdr_addr),
        .rom_ack   (rom_ack),
        .rom_rdata (rom_rdata),
        .m_valid   (cache_m_valid),
        .m_addr    (cache_m_addr),
        .m_ready   (cache_m_ready),
        .m_rvalid  (cache_m_rvalid),
        .m_rdata   (p_rdata),
        .l2_valid  (l2_valid),
        .l2_we     (l2_we),
        .l2_addr   (l2_addr),
        .l2_wdata  (l2_wdata),
        .l2_ack    (l2_ack),
        .l2_rdata  (l2_rdata)
    );

    // Multiplex SDRAM Port 4 between:
    //   1. Host Bridge (`br_sdr_valid`, active when `!pa_dma`)
    //   2. `pi_rom_cache` 16-word SDRAM miss bursts (`cache_m_valid`, active during `pa_dma && pa_rom_sel`)
    //   3. Direct `port_apf` RDRAM/write accesses (`pa_sdr_valid`, active during `pa_dma && !pa_ext_sel`)
    // Track owner of in-flight SDRAM Port 4 reads (`0 = bridge`, `1 = cache`, `2 = pa_sdr`) via 32-entry tag FIFO
    logic [1:0] p4_owner_q [0:31];
    logic [4:0] p4_qw, p4_qr;
    wire  [1:0] p4_req_owner = (!pa_dma) ? 2'd0 : pa_rom_sel ? 2'd1 : 2'd2;

    assign p_valid[4]  = (!pa_dma) ? br_sdr_valid : pa_rom_sel ? cache_m_valid : pa_sdr_valid;
    assign p_we[4]     = (!pa_dma) ? br_sdr_we    : pa_rom_sel ? 1'b0          : pa_sdr_we;
    assign p_addr[4]   = (!pa_dma) ? br_sdr_addr  : pa_rom_sel ? cache_m_addr  : pa_sdr_addr;
    assign p_wdata[4]  = (!pa_dma) ? br_sdr_wdata : pa_sdr_wdata;
    assign p_be[4]     = (!pa_dma) ? br_sdr_be    : pa_rom_sel ? 4'hF          : pa_sdr_be;
    assign p_urgent[4] = 1'b0;

    assign br_sdr_ready  = (!pa_dma) && p_ready[4];
    assign cache_m_ready = pa_dma && pa_rom_sel && p_ready[4];
    assign pa_sdr_ready  = pa_dma && !pa_ext_sel && p_ready[4];

    always_ff @(posedge clk) begin
        if (rst) begin
            p4_qw <= 5'd0;
            p4_qr <= 5'd0;
        end else begin
            if (p_valid[4] && p_ready[4] && !p_we[4]) begin
                p4_owner_q[p4_qw] <= p4_req_owner;
                p4_qw <= p4_qw + 5'd1;
            end
            if (p_rvalid[4]) begin
                p4_qr <= p4_qr + 5'd1;
            end
        end
    end

    wire [1:0] p4_rsp_owner = p4_owner_q[p4_qr];
    assign br_sdr_rvalid  = p_rvalid[4] && (p4_rsp_owner == 2'd0);
    assign cache_m_rvalid = p_rvalid[4] && (p4_rsp_owner == 2'd1);
    assign pa_sdr_rvalid  = p_rvalid[4] && (p4_rsp_owner == 2'd2);
    assign br_sdr_rdata   = p_rdata;

    // 512 KiB 10 ns Async SRAM Controller
    gb_sram_ctrl u_sram_ctrl (
        .clk             (clk),
        .rst             (rst),
        .clk2x           (clk_sys2x),
        .rst2x           (rst2x),
        .ready           (sram_ready),
        .h_valid         (h_sram_valid),
        .h_we            (h_sram_we),
        .h_addr          (h_sram_addr),
        .h_wdata         (h_sram_wdata),
        .h_be            (h_sram_be),
        .h_ack           (h_sram_ack),
        .h_rdata         (h_sram_rdata),
        .x_valid         (pa_x_valid && pa_sram_sel),
        .x_we            (pa_sdr_we),
        .x_addr          (pa_sdr_addr[16:0]),
        .x_wdata         (pa_sdr_wdata),
        .x_be            (pa_sdr_be),
        .x_ack           (sram_x_ack),
        .x_rdata         (sram_x_rdata),
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

    // -------------------------------------------------------------------------
    // 7. Hardware VI, AI, SI, Scanout (`n64_video` FAW=11), & RGB666 Downsampler
    // -------------------------------------------------------------------------
    rcp_vi vi (
        .clk      (clk),
        .rst      (rst),
        .sc_line  (vi_line),
        .sc_latch (vi_latch),
        .tv_pal   (tv_pal),
        .tv_def   (fb_pal),
        .vi_pal   (vi_pal_rq),
        .thr      (vi_thr),
        .a        (x_addr[5:2]),
        .wd       (x_wdata),
        .wr_s     (xs == X_VIW),
        .rd       (vi_rd),
        .vi_clr   (vi_clr),
        .irq      (vi_irq),
        .chg      (vi_chg),
        .base     (vi_base),
        .il       (vi_il),
        .black    (vi_blk),
        .gamma    (vi_gm),
        .aa       (vi_aa),
        .divot    (vi_dv),
        .dedither (vi_dd)
    );

    rcp_ai ai (
        .clk     (clk),
        .rst     (rst),
        .a       (x_addr[4:2]),
        .wd      (x_wdata),
        .wr_s    (ai_op && x_we),
        .rd      (ai_rd),
        .clr     (ai_clr),
        .irq     (ai_irq),
        .chg     (ai_chg),
        .step_we (ai_step_we),
        .step_wd (ai_step_wd),
        .dac     (ai_dac),
        .fill    (apf_audio_buffer_fill[9:0]),
        .fw      (ai_fw),
        .fd      (ai_fd),
        .req     (ai_req),
        .adr     (ai_adr),
        .ack     (ai_ack),
        .rdata   (pa_dat_r)
    );

    rcp_si si (
        .clk     (clk),
        .rst     (rst),
        .a       (x_addr[4:2]),
        .wd      (x_wdata),
        .wr_s    (si_op && x_we),
        .rd      (si_rd),
        .clr     (si_clr),
        .irq     (si_irq),
        .ca      (x_addr[5:2]),
        .c_wr_s  (xs == X_PIF && x_we),
        .c_wd    (x_wdata),
        .c_q     (si_q),
        .c_busy  (si_busy),
        .done_we (si_done),
        .done_wd (ai_step_wd[17:0]),
        .ev      (si_ev),
        .req     (si_req),
        .we      (si_we),
        .adr     (si_adr),
        .wdata   (si_wdata),
        .ack     (si_ack),
        .rdata   (pa_dat_r)
    );

    assign apf_audio_bus_wr  = aud_wr_r || ai_fw;
    assign apf_audio_bus_out = ai_fw ? ai_fd : aud_out_r;

    wire [31:0] fb_base = mon_vi ? {6'd0, vi_base} : fb_base_csr;
    wire        fb_en   = fb_dma_enable && fb_vtg_enable && !(mon_vi && vi_blk);
    wire        vi_gam  = mon_vi ? vi_gm : fb_gamma;

    logic [7:0] vga_r, vga_g, vga_b;
    logic       vga_de, vga_hsync, vga_vsync, vga_skip, vga_woven;

    n64_video #(
        .ORIGIN_MASK (24'hFFFFFF),
        .N64FB       (1'b1),
        .FAW         (11),
        .SHADOW_BASE (24'hD4_0000),
        .COL9        (1'b1)
    ) video (
        .clk         (clk),
        .rst         (rst),
        .clk_vid     (clk_vid),
        .rst_vid     (rst_vid),
        .enable      (fb_en),
        .vi_origin   (fb_base[25:0]),
        .vi_il       (mon_vi && vi_il),
        .no_weave    (vid_no_weave),
        .vblank      (vblank),
        .vi_width    (fb_width),
        .vi_px32     (fb_tall),
        .vi_black    (1'b0),
        .vi_pal      (mon_vi ? vi_pal_rq : fb_pal),
        .tv_pal      (tv_pal),
        .gamma       (vi_gam),
        .vi_aa       (mon_vi && vi_aa),
        .vi_divot    (mon_vi && vi_dv),
        .vi_dedither (mon_vi && vi_dd),
        .vi_deblur   (vid_deblur),
        .vi_out32    (vid_out32),
        .crop_v      (vid_crop_v),
        .crop_l      (vid_crop_l),
        .crop_r      (vid_crop_r),
        .vi_lines    (9'd240),
        .vi_px0      (fb_px0),
        .vi_pw       (fb_pw),
        .vi_y0       (fb_y0),
        .vi_rows     (fb_rows),
        .vi_xs       (fb_xs),
        .vi_ys       (fb_ys),
        .vi_nw       (fb_nw),
        .osd_en      (1'b0),
        .fps_en      (1'b0),
        .osd_val     ('0),
        .m_valid     (p_valid[0]),
        .m_addr      (p_addr[0]),
        .m_urgent    (p_urgent[0]),
        .m_ready     (p_ready[0]),
        .m_rvalid    (p_rvalid[0]),
        .m_rdata     (p_rdata),
        .vi_line     (vi_line),
        .vi_frame    (mon_field),
        .vi_latch    (vi_latch),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_de      (vga_de),
        .vga_skip    (vga_skip),
        .vga_woven   (vga_woven)
    );
    assign p_we[0]    = 1'b0;
    assign p_wdata[0] = 32'd0;
    assign p_be[0]    = 4'hF;

    // Live N64 Frame Rate Measurement (1.000 s window = 62,500,000 clk_sys cycles,
    // with early 0.25 s / 0.50 s bootstrap latch during first second of boot).
    // Prioritizes VI_ORIGIN double/triple-buffer swaps; falls back to RDP SYNC_FULL
    // single-buffered renders, then active VI scanout fields on static screens.
    logic [25:0] fps_win_cyc;
    logic        fps_boot_q1, fps_boot_q2;
    logic [23:0] fps_prev_origin;
    logic        fps_dp_pend;
    logic [6:0]  fps_swap_cnt, fps_dp_cnt, fps_vi_cnt;
    logic [3:0]  fps_tens, fps_ones;

    wire  [6:0]  fps_raw_sel = (fps_swap_cnt != 7'd0) ? fps_swap_cnt
                             : (fps_dp_cnt   != 7'd0) ? fps_dp_cnt
                             :                          fps_vi_cnt;
    wire         fps_at_250ms = !fps_boot_q1 && (fps_win_cyc == 26'd15_624_999);
    wire         fps_at_500ms = !fps_boot_q2 && (fps_win_cyc == 26'd31_249_999);
    wire         fps_at_1000ms = (fps_win_cyc == 26'd62_499_999);
    wire  [8:0]  fps_scaled   = fps_at_250ms ? {fps_raw_sel, 2'b00}
                              : fps_at_500ms ? {1'b0, fps_raw_sel, 1'b0}
                              :                {2'b00, fps_raw_sel};
    wire  [6:0]  fps_clamped  = (fps_scaled > 9'd99) ? 7'd99 : fps_scaled[6:0];

    function automatic logic [7:0] to_bcd2(input logic [6:0] v);
        logic [3:0] tens;
        logic [6:0] rem;
        begin
            if      (v >= 7'd90) begin tens = 4'd9; rem = v - 7'd90; end
            else if (v >= 7'd80) begin tens = 4'd8; rem = v - 7'd80; end
            else if (v >= 7'd70) begin tens = 4'd7; rem = v - 7'd70; end
            else if (v >= 7'd60) begin tens = 4'd6; rem = v - 7'd60; end
            else if (v >= 7'd50) begin tens = 4'd5; rem = v - 7'd50; end
            else if (v >= 7'd40) begin tens = 4'd4; rem = v - 7'd40; end
            else if (v >= 7'd30) begin tens = 4'd3; rem = v - 7'd30; end
            else if (v >= 7'd20) begin tens = 4'd2; rem = v - 7'd20; end
            else if (v >= 7'd10) begin tens = 4'd1; rem = v - 7'd10; end
            else                 begin tens = 4'd0; rem = v;         end
            return {tens, rem[3:0]};
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            fps_win_cyc     <= 26'd0;
            fps_boot_q1     <= 1'b0;
            fps_boot_q2     <= 1'b0;
            fps_prev_origin <= 24'd0;
            fps_dp_pend     <= 1'b0;
            fps_swap_cnt    <= 7'd0;
            fps_dp_cnt      <= 7'd0;
            fps_vi_cnt      <= 7'd0;
            fps_tens        <= 4'd0;
            fps_ones        <= 4'd0;
        end else begin
            if (mon_dp)
                fps_dp_pend <= 1'b1;

            if (fps_at_250ms || fps_at_500ms) begin
                {fps_tens, fps_ones} <= to_bcd2(fps_clamped);
                if (fps_at_250ms) fps_boot_q1 <= 1'b1;
                if (fps_at_500ms) fps_boot_q2 <= 1'b1;
            end

            if (fps_at_1000ms) begin
                {fps_tens, fps_ones} <= to_bcd2(fps_clamped);
                fps_win_cyc  <= 26'd0;
                fps_swap_cnt <= 7'd0;
                fps_dp_cnt   <= 7'd0;
                fps_vi_cnt   <= 7'd0;
                if (vi_latch && fb_en) begin
                    fps_vi_cnt      <= 7'd1;
                    fps_prev_origin <= fb_base[23:0];
                    if (fb_base[23:0] != fps_prev_origin)
                        fps_swap_cnt <= 7'd1;
                    if (fps_dp_pend || mon_dp) begin
                        fps_dp_cnt  <= 7'd1;
                        fps_dp_pend <= 1'b0;
                    end
                end
            end else begin
                fps_win_cyc <= fps_win_cyc + 26'd1;
                if (vi_latch && fb_en) begin
                    if (fps_vi_cnt != 7'd127)
                        fps_vi_cnt <= fps_vi_cnt + 7'd1;
                    fps_prev_origin <= fb_base[23:0];
                    if ((fb_base[23:0] != fps_prev_origin) && (fps_swap_cnt != 7'd127))
                        fps_swap_cnt <= fps_swap_cnt + 7'd1;
                    if (fps_dp_pend || mon_dp) begin
                        if (fps_dp_cnt != 7'd127)
                            fps_dp_cnt <= fps_dp_cnt + 7'd1;
                        fps_dp_pend <= 1'b0;
                    end
                end
            end
        end
    end

    n64_video_gb_downsampler u_downsampler (
        .clk_vid          (clk_vid),
        .rst_vid          (rst_vid),
        .vga_r            (vga_r),
        .vga_g            (vga_g),
        .vga_b            (vga_b),
        .vga_de           (vga_de),
        .vga_hsync        (vga_hsync),
        .vga_vsync        (vga_vsync),
        .vga_skip         (vga_skip),
        .vga_woven        (vga_woven),
        .clk_sys          (clk),
        .rst_sys          (rst),
        .horiz_blend_en   (vid_horiz_blend_en),
        .dither_en        (vid_dither_en),
        .fps_mode         (vid_fps_mode),
        .fps_tens         (fps_tens),
        .fps_ones         (fps_ones),
        .video_data_r     (video_data_r),
        .video_data_g     (video_data_g),
        .video_data_b     (video_data_b),
        .video_dataEnable (video_dataEnable),
        .video_hblank     (video_hblank),
        .video_vblank     (video_vblank)
    );

    wire _unused_ok = &{1'b0, geom_irq, geom_run, fb_mode, rsp_halted, rsp_unimpl};
endmodule

`default_nettype wire
