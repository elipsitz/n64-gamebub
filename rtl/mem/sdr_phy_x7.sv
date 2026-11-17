// Half-rate SDR SDRAM PHY for Xilinx Artix-7 + Game Bub SdramV0 (2x W9825G6KH-6,
// 16-bit shared DQ bus, dual cs_n[1:0] & cke[1:0], CL=3, BL=2).
//
// Derived from LiteX / Mirlo sdr_phy, adapted for Xilinx 7-Series IOB packing
// and Game Bub's split SdramV0 data bus (sdram_dq_in / sdram_dq_out / sdram_dq_oe):
//   - Controller DFI outputs are registered once in `clk` (62.5 MHz) before
//     crossing into `clk2x` (125.0 MHz).
//   - `phase_sel` selects phase 0 on the first `clk2x` half of each `clk` cycle
//     and phase 1 on the second.
//   - Address, bank, dual chip-select, CKE, RAS#, CAS#, WE#, and DQM use clean
//     dedicated output registers with zero internal readback so Vivado packs
//     them directly into Artix-7 OLOGICE2 IOB flip-flops.
//   - Read data is captured across two `clk2x` stages and assembled into `clk`
//     as `{beat1, beat0}` at exact `RL = 5` `clk` cycles after `rddata_en`.
//   - `sdram_clock` is forwarded from `clk2x_90` via a 7-Series `ODDR`.
`default_nettype none

module sdr_phy_x7 (
    input  wire         clk,            // 62.5 MHz sys clock
    input  wire         rst,
    input  wire         clk2x,          // 125.0 MHz 2x PHY clock
    input  wire         rst2x,          // synchronous to clk2x
    input  wire         clk2x_90,       // phase-shifted 125.0 MHz SDRAM pad clock
    // DFI, two phases (clk domain)
    input  wire  [3:0]  cs_n,           // {p1[1:0], p0[1:0]}
    input  wire  [1:0]  cke,
    input  wire  [1:0]  ras_n,
    input  wire  [1:0]  cas_n,
    input  wire  [1:0]  we_n,
    input  wire  [25:0] addr,           // {p1[12:0], p0[12:0]}
    input  wire  [3:0]  ba,             // {p1[1:0], p0[1:0]}
    input  wire         wrdata_en,      // phase 0: drives two 16-bit beats
    input  wire  [31:0] wrdata,         // {beat1[15:0], beat0[15:0]}
    input  wire  [3:0]  wrdata_mask,    // {beat1[1:0], beat0[1:0]}, 1 = byte masked
    input  wire         rddata_en,      // phase 0
    output logic [31:0] rddata,         // {beat1[15:0], beat0[15:0]}
    output logic        rddata_valid,
    // Game Bub SdramV0 pad signals (no inout)
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_ba,
    output logic [1:0]  sdram_cs_n,
    output logic [1:0]  sdram_cke,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_dm,
    input  wire  [15:0] sdram_dq_in,
    output logic [15:0] sdram_dq_out,
    output logic        sdram_dq_oe,
    output wire         sdram_clock
);

// ---- DFI register stage (clk)
logic [3:0]  r_cs_n = 4'b1111;
logic [1:0]  r_cke  = 2'b00;
logic [1:0]  r_ras_n = 2'b11, r_cas_n = 2'b11, r_we_n = 2'b11;
logic [25:0] r_addr;
logic [3:0]  r_ba;
logic        r_wrdata_en, r_rddata_en;
logic [31:0] r_wrdata;
logic [3:0]  r_wrdata_mask;

always_ff @(posedge clk) begin
    if (rst) begin
        r_cs_n        <= 4'b1111;
        r_cke         <= 2'b00;
        r_ras_n       <= 2'b11;
        r_cas_n       <= 2'b11;
        r_we_n        <= 2'b11;
        r_addr        <= '0;
        r_ba          <= '0;
        r_wrdata_en   <= 1'b0;
        r_rddata_en   <= 1'b0;
        r_wrdata      <= '0;
        r_wrdata_mask <= '0;
    end else begin
        r_cs_n        <= cs_n;
        r_cke         <= cke;
        r_ras_n       <= ras_n;
        r_cas_n       <= cas_n;
        r_we_n        <= we_n;
        r_addr        <= addr;
        r_ba          <= ba;
        r_wrdata_en   <= wrdata_en;
        r_rddata_en   <= rddata_en;
        r_wrdata      <= wrdata;
        r_wrdata_mask <= wrdata_mask;
    end
end

// ---- phase alignment (0 on first clk2x half of each clk cycle, 1 on second)
logic phase_sel, phase_sys2x, phase_sys;
always_ff @(posedge clk) phase_sys <= rst ? 1'b0 : phase_sys2x;
always_ff @(posedge clk2x) begin
    if (rst2x) begin
        phase_sel   <= 1'b0;
        phase_sys2x <= 1'b0;
    end else begin
        phase_sys2x <= ~phase_sel;
        phase_sel   <= ~phase_sel & (phase_sys2x ^ phase_sys);
    end
end

// ---- full-rate phase mux (clk2x)
wire [1:0]  f_cs_n   = phase_sel ? r_cs_n[3:2]        : r_cs_n[1:0];
wire        f_ras_n  = phase_sel ? r_ras_n[1]         : r_ras_n[0];
wire        f_cas_n  = phase_sel ? r_cas_n[1]         : r_cas_n[0];
wire        f_we_n   = phase_sel ? r_we_n[1]          : r_we_n[0];
wire [12:0] f_addr   = phase_sel ? r_addr[25:13]      : r_addr[12:0];
wire [1:0]  f_ba     = phase_sel ? r_ba[3:2]          : r_ba[1:0];
wire [15:0] f_wrdata = phase_sel ? r_wrdata[31:16]    : r_wrdata[15:0];
wire [1:0]  f_mask   = phase_sel ? r_wrdata_mask[3:2] : r_wrdata_mask[1:0];
wire        f_rden   = phase_sel ? 1'b0               : r_rddata_en;

logic wr_en_d;
wire  f_wren = (r_wrdata_en & !phase_sel) | wr_en_d;

// Non-reset dedicated I/O FFs for address, bank, and read capture
(* IOB = "TRUE" *) logic [12:0] a_q;
(* IOB = "TRUE" *) logic [1:0]  ba_q;
(* IOB = "TRUE" *) logic [15:0] in2 = 16'h0000;
always_ff @(posedge clk2x) begin
    a_q <= f_addr;
    ba_q <= f_ba;
    in2 <= sdram_dq_in;
end
assign sdram_a  = a_q;
assign sdram_ba = ba_q;

// Dedicated output FFs (no internal readback) for control, DQM, DQ output, and 1-bit OE (`OLOGICE2.TFF`).
// `(* IOB = "TRUE" *)` on `oe_q` causes Vivado synthesis to auto-replicate the 1-bit OE FF into all 16
// `OLOGICE2.TFF` BELs across unmodified `HandheldTop` (sharing `rst2x` SR with `out_q`).
(* IOB = "TRUE" *)                      logic [15:0] out_q     = 16'h0000;
(* IOB = "TRUE" *)                      logic        oe_q      = 1'b0;
(* IOB = "TRUE", DONT_TOUCH = "TRUE" *) logic [1:0]  cs_n_q    = 2'b11;
(* IOB = "TRUE", DONT_TOUCH = "TRUE" *) logic [1:0]  cke_q     = 2'b00;
(* IOB = "TRUE" *)                      logic [1:0]  dm_q      = 2'b00;
(* IOB = "TRUE" *)                      logic        ras_n_q   = 1'b1;
(* IOB = "TRUE" *)                      logic        cas_n_q   = 1'b1;
(* IOB = "TRUE" *)                      logic        we_n_q    = 1'b1;
logic [15:0] f_rddata, rddata_d;
logic        f_rdvalid;
logic [4:0]  rden_sr;

always_ff @(posedge clk2x) begin
    if (rst2x) begin
        out_q     <= 16'h0000;
        cs_n_q    <= 2'b11;
        cke_q     <= 2'b00;
        ras_n_q   <= 1'b1;
        cas_n_q   <= 1'b1;
        we_n_q    <= 1'b1;
        dm_q      <= 2'b00;
        oe_q      <= 1'b0;
        f_rddata  <= 16'h0000;
        rddata_d  <= 16'h0000;
        rden_sr   <= 5'd0;
        f_rdvalid <= 1'b0;
        wr_en_d   <= 1'b0;
    end else begin
        out_q     <= f_wrdata;
        cs_n_q    <= f_cs_n;
        cke_q     <= r_cke;
        ras_n_q   <= f_ras_n;
        cas_n_q   <= f_cas_n;
        we_n_q    <= f_we_n;
        dm_q      <= {2{f_wren}} & f_mask;
        oe_q      <= f_wren;
        f_rddata  <= in2;
        rddata_d  <= f_rddata;
        rden_sr   <= {rden_sr[3:0], f_rden};
        f_rdvalid <= rden_sr[4];
        wr_en_d   <= r_wrdata_en & !phase_sel;
    end
end

assign sdram_cs_n   = cs_n_q;
assign sdram_cke    = cke_q;
assign sdram_ras_n  = ras_n_q;
assign sdram_cas_n  = cas_n_q;
assign sdram_we_n   = we_n_q;
assign sdram_dm     = dm_q;
assign sdram_dq_out = out_q;
assign sdram_dq_oe  = oe_q;

// ---- return read data into clk domain (RL = 5 clk cycles after rddata_en)
always_ff @(posedge clk) begin
    if (rst) begin
        rddata       <= 32'h0000_0000;
        rddata_valid <= 1'b0;
    end else begin
        rddata       <= {f_rddata, rddata_d};
        rddata_valid <= f_rdvalid;
    end
end

// ---- forward phase-shifted SDRAM clock
`ifdef VERILATOR
assign sdram_clock = clk2x_90;
`else
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT(1'b0),
    .SRTYPE("SYNC")
) clk_out (
    .Q(sdram_clock),
    .C(clk2x_90),
    .CE(1'b1),
    .D1(1'b1),
    .D2(1'b0),
    .R(1'b0),
    .S(1'b0)
);
`endif

endmodule
`default_nettype wire
