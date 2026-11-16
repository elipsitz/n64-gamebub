// Top-level verification harness for the Game Bub N64 memory subsystem:
//   sdr_arb_gb + sdr_ctrl_w9825 + sdr_phy_x7 + gb_sram_ctrl + pi_rom_cache
`default_nettype none

module mem_tb_top #(
    parameter int SDR_T_INIT = 200
) (
    input  wire         clk,            // 62.5 MHz (16.0 ns)
    input  wire         rst,
    input  wire         clk2x,          // 125.0 MHz (8.0 ns)
    input  wire         rst2x,
    input  wire         clk2x_90,

    output wire         sdr_ready,
    output wire         sram_ready,

    // ---- sdr_arb_gb 6-port stimulus (Port 4 muxed with pi_rom_cache when cache_use_p4=1)
    input  wire         cache_use_p4,
    input  wire  [5:0]  tb_p_valid,
    input  wire  [5:0]  tb_p_we,
    input  wire  [23:0] tb_p_addr_0,
    input  wire  [23:0] tb_p_addr_1,
    input  wire  [23:0] tb_p_addr_2,
    input  wire  [23:0] tb_p_addr_3,
    input  wire  [23:0] tb_p_addr_4,
    input  wire  [23:0] tb_p_addr_5,
    input  wire  [31:0] tb_p_wdata_0,
    input  wire  [31:0] tb_p_wdata_1,
    input  wire  [31:0] tb_p_wdata_2,
    input  wire  [31:0] tb_p_wdata_3,
    input  wire  [31:0] tb_p_wdata_4,
    input  wire  [31:0] tb_p_wdata_5,
    input  wire  [3:0]  tb_p_be_0,
    input  wire  [3:0]  tb_p_be_1,
    input  wire  [3:0]  tb_p_be_2,
    input  wire  [3:0]  tb_p_be_3,
    input  wire  [3:0]  tb_p_be_4,
    input  wire  [3:0]  tb_p_be_5,
    input  wire  [5:0]  tb_p_urgent,
    input  wire         tb_apf_force,
    output wire  [5:0]  tb_p_ready,
    output wire  [5:0]  tb_p_rvalid,
    output wire  [31:0] tb_p_rdata,

    // ---- arbiter / cache observability for hmap, lookahead, and SDRAM traffic assertions
    output wire         obs_arb_req_valid,
    output wire  [23:0] obs_arb_req_addr,
    output wire         obs_arb_req_ready,
    output wire         obs_arb_la_valid,
    output wire  [23:0] obs_arb_la_addr,
    output wire         obs_cache_m_valid,
    output wire         obs_cache_m_ready,
    output wire         obs_cache_l2_valid,
    output wire         obs_cache_l2_we,
    output wire         obs_cache_l2_ack,

    // ---- pi_rom_cache upstream port
    input  wire         rom_inv_all,
    input  wire         rom_req,
    input  wire  [23:0] rom_addr,
    output wire         rom_ack,
    output wire  [31:0] rom_rdata,

    // ---- gb_sram_ctrl Port 0 (Host) & Port 1 (SoC) + optional Port 2 override
    input  wire         h_valid,
    input  wire         h_we,
    input  wire  [16:0] h_addr,
    input  wire  [31:0] h_wdata,
    input  wire  [3:0]  h_be,
    output wire         h_ack,
    output wire  [31:0] h_rdata,

    input  wire         x_valid,
    input  wire         x_we,
    input  wire  [16:0] x_addr,
    input  wire  [31:0] x_wdata,
    input  wire  [3:0]  x_be,
    output wire         x_ack,
    output wire  [31:0] x_rdata,

    input  wire         tb_l2_override,
    input  wire         tb_l2_valid,
    input  wire         tb_l2_we,
    input  wire  [16:0] tb_l2_addr,
    input  wire  [31:0] tb_l2_wdata,
    output wire         tb_l2_ack,
    output wire  [31:0] tb_l2_rdata,

    // ---- External Dual-Rank W9825G6KH-6 SDRAM pins
    output wire  [12:0] sdram_a,
    output wire  [1:0]  sdram_ba,
    output wire  [1:0]  sdram_cs_n,
    output wire  [1:0]  sdram_cke,
    output wire         sdram_ras_n,
    output wire         sdram_cas_n,
    output wire         sdram_we_n,
    output wire  [1:0]  sdram_dm,
    input  wire  [15:0] sdram_dq_in,
    output wire  [15:0] sdram_dq_out,
    output wire         sdram_dq_oe,
    output wire         sdram_clock,

    // ---- External IS61WV25616EDBLL-10TLI Async SRAM pins
    output wire         sram_ceN,
    output wire         sram_weN,
    output wire         sram_oeN,
    output wire  [1:0]  sram_writeMaskN,
    output wire  [17:0] sram_address,
    input  wire  [15:0] sram_dataIn,
    output wire  [15:0] sram_dataOut,
    output wire         sram_dataDir
);

// ---- Cache <-> SDRAM Port 4 & L2 SRAM Port 2 wires
wire        c_m_valid, c_m_ready, c_m_rvalid;
wire [23:0] c_m_addr;
wire        c_l2_valid, c_l2_we, c_l2_ack;
wire [16:0] c_l2_addr;
wire [31:0] c_l2_wdata, c_l2_rdata;

// ---- Pack 6 arbiter ports
logic [5:0]       p_valid, p_we, p_urgent;
logic [5:0][23:0] p_addr;
logic [5:0][31:0] p_wdata;
logic [5:0][3:0]  p_be;
wire  [5:0]       p_ready, p_rvalid;
wire  [31:0]      p_rdata;

always_comb begin
    p_valid  = tb_p_valid;
    p_we     = tb_p_we;
    p_urgent = tb_p_urgent;

    p_addr[0]  = tb_p_addr_0;  p_wdata[0] = tb_p_wdata_0;  p_be[0] = tb_p_be_0;
    p_addr[1]  = tb_p_addr_1;  p_wdata[1] = tb_p_wdata_1;  p_be[1] = tb_p_be_1;
    p_addr[2]  = tb_p_addr_2;  p_wdata[2] = tb_p_wdata_2;  p_be[2] = tb_p_be_2;
    p_addr[3]  = tb_p_addr_3;  p_wdata[3] = tb_p_wdata_3;  p_be[3] = tb_p_be_3;
    p_addr[4]  = tb_p_addr_4;  p_wdata[4] = tb_p_wdata_4;  p_be[4] = tb_p_be_4;
    p_addr[5]  = tb_p_addr_5;  p_wdata[5] = tb_p_wdata_5;  p_be[5] = tb_p_be_5;

    if (cache_use_p4) begin
        p_valid[4]  = c_m_valid;
        p_we[4]     = 1'b0;
        p_addr[4]   = c_m_addr;
        p_wdata[4]  = 32'd0;
        p_be[4]     = 4'hF;
        p_urgent[4] = 1'b0;
    end
end

assign tb_p_ready  = cache_use_p4 ? {p_ready[5],  1'b0, p_ready[3:0]}  : p_ready;
assign tb_p_rvalid = cache_use_p4 ? {p_rvalid[5], 1'b0, p_rvalid[3:0]} : p_rvalid;
assign tb_p_rdata  = p_rdata;

assign c_m_ready  = cache_use_p4 && p_ready[4];
assign c_m_rvalid = cache_use_p4 && p_rvalid[4];

// ---- Arbiter <-> SDRAM Controller <-> PHY
wire        rq_valid, rq_we, rq_ready;
wire [23:0] rq_addr;
wire [31:0] rq_wdata;
wire [3:0]  rq_be;
wire [2:0]  rq_tag;
wire        la_valid;
wire [23:0] la_addr;
wire        rd_valid, rd_next;
wire [31:0] rd_data;
wire [2:0]  rd_tag, rd_next_tag;

wire [3:0]  dfi_cs_n, dfi_ba, dfi_wm;
wire [1:0]  dfi_cke, dfi_ras_n, dfi_cas_n, dfi_we_n;
wire [25:0] dfi_addr;
wire        dfi_wren, dfi_rden, dfi_rv;
wire [31:0] dfi_wd, dfi_rd;

wire [15:0] sdram_dq_tri_unused, sram_data_tri_unused;
wire _unused_ok = &{1'b0, rd_next, rd_next_tag, sdram_dq_tri_unused, sram_data_tri_unused};

sdr_arb_gb #(
    .N(6),
    .MAXB(16),
    .APF_PREEMPT(1)
) u_arb (
    .clk       (clk),
    .rst       (rst),
    .p_valid   (p_valid),
    .p_we      (p_we),
    .p_addr    (p_addr),
    .p_wdata   (p_wdata),
    .p_be      (p_be),
    .p_urgent  (p_urgent),
    .apf_force (tb_apf_force && !cache_use_p4),
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

sdr_ctrl_w9825 #(
    .T_INIT(SDR_T_INIT),
    .T_REFI(480),
    .AHEAD(1)
) u_ctrl (
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

sdr_phy_x7 u_phy (
    .clk          (clk),
    .rst          (rst),
    .clk2x        (clk2x),
    .rst2x        (rst2x),
    .clk2x_90     (clk2x_90),
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
    .sdram_dm     (sdram_dm),
    .sdram_dq_in  (sdram_dq_in),
    .sdram_dq_out (sdram_dq_out),
    .sdram_dq_oe  (sdram_dq_oe),
    .sdram_dq_tri (sdram_dq_tri_unused),
    .sdram_clock  (sdram_clock)
);

// ---- Async SRAM Controller
wire        s_l2_valid = tb_l2_override ? tb_l2_valid : c_l2_valid;
wire        s_l2_we    = tb_l2_override ? tb_l2_we    : c_l2_we;
wire [16:0] s_l2_addr  = tb_l2_override ? tb_l2_addr  : c_l2_addr;
wire [31:0] s_l2_wdata = tb_l2_override ? tb_l2_wdata : c_l2_wdata;
wire        s_l2_ack;
wire [31:0] s_l2_rdata;

assign tb_l2_ack  = tb_l2_override && s_l2_ack;
assign tb_l2_rdata = s_l2_rdata;
assign c_l2_ack   = !tb_l2_override && s_l2_ack;
assign c_l2_rdata = s_l2_rdata;

gb_sram_ctrl u_sram (
    .clk             (clk),
    .rst             (rst),
    .clk2x           (clk2x),
    .rst2x           (rst2x),
    .ready           (sram_ready),
    .h_valid         (h_valid),
    .h_we            (h_we),
    .h_addr          (h_addr),
    .h_wdata         (h_wdata),
    .h_be            (h_be),
    .h_ack           (h_ack),
    .h_rdata         (h_rdata),
    .x_valid         (x_valid),
    .x_we            (x_we),
    .x_addr          (x_addr),
    .x_wdata         (x_wdata),
    .x_be            (x_be),
    .x_ack           (x_ack),
    .x_rdata         (x_rdata),
    .l2_valid        (s_l2_valid),
    .l2_we           (s_l2_we),
    .l2_addr         (s_l2_addr),
    .l2_wdata        (s_l2_wdata),
    .l2_ack          (s_l2_ack),
    .l2_rdata        (s_l2_rdata),
    .sram_ceN        (sram_ceN),
    .sram_weN        (sram_weN),
    .sram_oeN        (sram_oeN),
    .sram_writeMaskN (sram_writeMaskN),
    .sram_address    (sram_address),
    .sram_dataIn     (sram_dataIn),
    .sram_dataOut    (sram_dataOut),
    .sram_dataDir    (sram_dataDir),
    .sram_dataTri    (sram_data_tri_unused)
);

// ---- L1 + L2 PI ROM Cache
pi_rom_cache #(
    .L2_BASE(17'h1A000)
) u_rom_cache (
    .clk       (clk),
    .rst       (rst),
    .inv_all   (rom_inv_all),
    .rom_req   (rom_req),
    .rom_addr  (rom_addr),
    .rom_ack   (rom_ack),
    .rom_rdata (rom_rdata),
    .m_valid   (c_m_valid),
    .m_addr    (c_m_addr),
    .m_ready   (c_m_ready),
    .m_rvalid  (c_m_rvalid),
    .m_rdata   (p_rdata),
    .l2_valid  (c_l2_valid),
    .l2_we     (c_l2_we),
    .l2_addr   (c_l2_addr),
    .l2_wdata  (c_l2_wdata),
    .l2_ack    (c_l2_ack),
    .l2_rdata  (c_l2_rdata)
);

assign obs_arb_req_valid  = rq_valid;
assign obs_arb_req_addr   = rq_addr;
assign obs_arb_req_ready  = rq_ready;
assign obs_arb_la_valid   = la_valid;
assign obs_arb_la_addr    = la_addr;
assign obs_cache_m_valid  = c_m_valid;
assign obs_cache_m_ready  = c_m_ready;
assign obs_cache_l2_valid = c_l2_valid;
assign obs_cache_l2_we    = c_l2_we;
assign obs_cache_l2_ack   = c_l2_ack;

endmodule
`default_nettype wire
