// Glitch-free 3-port Async SRAM controller for Game Bub's IS61WV25616EDBLL-10TLI
// (512 KiB = 256K x 16-bit, 10 ns tAA / tWC, 7 ns tWP).
//
// Clocked by synchronous 2:1 clocks `clk` (62.5 MHz, 16.0 ns) and `clk2x`
// (125.0 MHz, 8.0 ns), using the same `phase_sel` alignment scheme as
// sdr_phy_x7 (phase_sel == 0 during the first 8 ns half of each clk cycle,
// phase_sel == 1 during the second 8 ns half).
//
// Big-endian MIPS 32-bit word layout for `w_addr[16:0]` (128K x 32-bit = 512 KiB):
//   - Half 0 (`sram_address = {w_addr, 1'b0}`) -> `rdata[31:16]`:
//       UB (`sram_io[15:8]`, `writeMaskN[1]`) = byte 0 `[31:24]` (`be[3]`)
//       LB (`sram_io[7:0]`,  `writeMaskN[0]`) = byte 1 `[23:16]` (`be[2]`)
//   - Half 1 (`sram_address = {w_addr, 1'b1}`) -> `rdata[15:0]`:
//       UB (`sram_io[15:8]`, `writeMaskN[1]`) = byte 2 `[15:8]`  (`be[1]`)
//       LB (`sram_io[7:0]`,  `writeMaskN[0]`) = byte 3 `[7:0]`   (`be[0]`)
//
// Hardware AC timing on `clk2x` IOB output & input flip-flops:
//   - Reads: each 16-bit halfword holds `ceN=0, oeN=0, weN=1, writeMaskN=2'b00`
//     steady on the pins for 4 `clk2x` cycles (32.0 ns total: 24.0 ns launch-to-
//     ILOGICE2.IFF `sram_in_q` capture + 8.0 ns hold margin, giving > +9.0 ns
//     physical setup slack over `OLOGICE2 + 10 ns tAA + ILOGICE2`).
//   - Writes: each active halfword (`half_be != 2'b00`) executes 4 `clk2x`
//     subcycles (32.0 ns; inactive halfwords with `half_be == 2'b00` are skipped):
//       Subcycle 0 ( 8 ns): `ceN=0, oeN=1, weN=1, dataDir=1`, address/data/mask setup
//       Subcycles 1..2 (16 ns >= 7 ns tWP): `weN=0`, address/data/mask rock-steady
//       Subcycle 3 ( 8 ns >= 0 ns tHA/tDH): `weN=1`, address/data/mask held steady
//
// Strict fixed-priority arbitration on `clk`:
//   Port 0 (Highest): Host Bridge (`h_*`) — .sav / .mpk / n64savedb.txt load & save
//   Port 1 (Middle) : SoC Save/CPak/SaveDB (`x_*`) — mirlo_mips pa_x_valid
//   Port 2 (Lowest) : L2 PI ROM Cache (`l2_*`) — 64 KiB at 17'h1A000..17'h1DFFF
`default_nettype none

module gb_sram_ctrl (
    input  wire         clk,            // 62.5 MHz sys clock
    input  wire         rst,
    input  wire         clk2x,          // 125.0 MHz 2x clock
    input  wire         rst2x,
    output logic        ready,

    // Port 0 (Highest priority): Host Bridge
    input  wire         h_valid,
    input  wire         h_we,
    input  wire  [16:0] h_addr,
    input  wire  [31:0] h_wdata,
    input  wire  [3:0]  h_be,
    output logic        h_ack,
    output logic [31:0] h_rdata,

    // Port 1: SoC Save / Controller Pak / SaveDB
    input  wire         x_valid,
    input  wire         x_we,
    input  wire  [16:0] x_addr,
    input  wire  [31:0] x_wdata,
    input  wire  [3:0]  x_be,
    output logic        x_ack,
    output logic [31:0] x_rdata,

    // Port 2 (Lowest priority): L2 PI ROM Cache
    input  wire         l2_valid,
    input  wire         l2_we,
    input  wire  [16:0] l2_addr,
    input  wire  [31:0] l2_wdata,
    output logic        l2_ack,
    output logic [31:0] l2_rdata,

    // Game Bub SramV0 pad interface (packed into Artix-7 IOBs)
    output logic        sram_ceN,
    output logic        sram_weN,
    output logic        sram_oeN,
    output logic [1:0]  sram_writeMaskN,
    output logic [17:0] sram_address,
    input  wire  [15:0] sram_dataIn,
    output logic [15:0] sram_dataOut,
    output logic        sram_dataDir
);

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

// ---- clk-domain arbitration and transaction FSM
typedef enum logic [3:0] {
    S_INIT0,
    S_INIT1,
    S_IDLE,
    S_RD0_A,    // drive half 0 ({addr, 0}) first 16 ns
    S_RD0_B,    // hold  half 0 ({addr, 0}) second 16 ns (ILOGICE2 captures at 24 ns)
    S_RD1_A,    // latch rx_hi from sram_in_q, drive half 1 ({addr, 1}) first 16 ns
    S_RD1_B,    // hold  half 1 ({addr, 1}) second 16 ns (ILOGICE2 captures at 24 ns)
    S_RD_CAP,   // latch rx_lo from sram_in_q, return pads to idle
    S_WR0_A,    // half 0 subcycle 0 (setup, weN=1) + subcycle 1 (weN=0)
    S_WR0_B,    // half 0 subcycle 2 (weN=0) + subcycle 3 (hold, weN=1)
    S_WR1_A,    // half 1 subcycle 0 (setup, weN=1) + subcycle 1 (weN=0)
    S_WR1_B,    // half 1 subcycle 2 (weN=0) + subcycle 3 (hold, weN=1)
    S_ACK       // 1-cycle clk ack pulse with registered rdata_q
} st_t;

st_t         st;
logic [1:0]  r_port;
logic [16:0] r_addr;
logic [31:0] r_wdata;
logic [3:0]  r_be;
logic        r_last_half;
logic [31:0] rdata_q;

// Fixed-priority port selection: Port 0 (h) > Port 1 (x) > Port 2 (l2)
logic        any_req, win_we;
logic [1:0]  win_port;
logic [16:0] win_addr;
logic [31:0] win_wdata;
logic [3:0]  win_be;

always_comb begin
    any_req   = 1'b0;
    win_port  = 2'd0;
    win_we    = 1'b0;
    win_addr  = 17'd0;
    win_wdata = 32'd0;
    win_be    = 4'hF;

    if (h_valid) begin
        any_req   = 1'b1;
        win_port  = 2'd0;
        win_we    = h_we;
        win_addr  = h_addr;
        win_wdata = h_wdata;
        win_be    = h_be;
    end else if (x_valid) begin
        any_req   = 1'b1;
        win_port  = 2'd1;
        win_we    = x_we;
        win_addr  = x_addr;
        win_wdata = x_wdata;
        win_be    = x_be;
    end else if (l2_valid) begin
        any_req   = 1'b1;
        win_port  = 2'd2;
        win_we    = l2_we;
        win_addr  = l2_addr;
        win_wdata = l2_wdata;
        win_be    = 4'hF;
    end
end

// Captured read halfwords in clk2x domain
logic [15:0] rx_hi, rx_lo;

always_ff @(posedge clk) begin
    if (rst) begin
        st          <= S_INIT0;
        ready       <= 1'b0;
        r_port      <= 2'd0;
        r_addr      <= 17'd0;
        r_wdata     <= 32'd0;
        r_be        <= 4'h0;
        r_last_half <= 1'b0;
        rdata_q     <= 32'd0;
    end else begin
        case (st)
            S_INIT0: st <= S_INIT1;
            S_INIT1: begin
                ready <= 1'b1;
                st    <= S_IDLE;
            end
            S_IDLE: begin
                if (any_req) begin
                    r_port  <= win_port;
                    r_addr  <= win_addr;
                    r_wdata <= win_wdata;
                    r_be    <= win_be;
                    if (!win_we) begin
                        r_last_half <= 1'b0;
                        st          <= S_RD0_A;
                    end else if (win_be[3:2] != 2'b00) begin
                        r_last_half <= 1'b0;
                        st          <= S_WR0_A;
                    end else if (win_be[1:0] != 2'b00) begin
                        r_last_half <= 1'b1;
                        st          <= S_WR1_A;
                    end else begin
                        st <= S_ACK;
                    end
                end
            end
            S_RD0_A: begin
                st <= S_RD0_B;
            end
            S_RD0_B: begin
                r_last_half <= 1'b1;
                st          <= S_RD1_A;
            end
            S_RD1_A: begin
                st <= S_RD1_B;
            end
            S_RD1_B: begin
                st <= S_RD_CAP;
            end
            S_RD_CAP: begin
                rdata_q <= {rx_hi, rx_lo};
                st      <= S_ACK;
            end
            S_WR0_A: begin
                st <= S_WR0_B;
            end
            S_WR0_B: begin
                if (r_be[1:0] != 2'b00) begin
                    r_last_half <= 1'b1;
                    st          <= S_WR1_A;
                end else begin
                    st <= S_ACK;
                end
            end
            S_WR1_A: begin
                st <= S_WR1_B;
            end
            S_WR1_B: begin
                st <= S_ACK;
            end
            S_ACK: begin
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

assign h_ack    = (st == S_ACK) && (r_port == 2'd0);
assign x_ack    = (st == S_ACK) && (r_port == 2'd1);
assign l2_ack   = (st == S_ACK) && (r_port == 2'd2);
assign h_rdata  = rdata_q;
assign x_rdata  = rdata_q;
assign l2_rdata = rdata_q;

// ---- clk2x full-rate pad sequencing & IOB output registers
logic        nxt_ce_n, nxt_we_n, nxt_oe_n, nxt_dir;
logic [1:0]  nxt_mask_n;
logic [17:0] nxt_addr;
logic [15:0] nxt_dout;

always_comb begin
    // Default idle state (holds previous address/data to minimize PCB bus toggle)
    nxt_ce_n   = 1'b1;
    nxt_we_n   = 1'b1;
    nxt_oe_n   = 1'b1;
    nxt_dir    = 1'b0;
    nxt_mask_n = 2'b11;
    nxt_addr   = {r_addr, r_last_half};
    nxt_dout   = r_last_half ? r_wdata[15:0] : r_wdata[31:16];

    case (st)
        S_RD0_A, S_RD0_B: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b0;
            nxt_we_n   = 1'b1;
            nxt_dir    = 1'b0;
            nxt_mask_n = 2'b00;
            nxt_addr   = {r_addr, 1'b0};
        end
        S_RD1_A, S_RD1_B: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b0;
            nxt_we_n   = 1'b1;
            nxt_dir    = 1'b0;
            nxt_mask_n = 2'b00;
            nxt_addr   = {r_addr, 1'b1};
        end
        S_WR0_A: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b1;
            nxt_we_n   = phase_sel ? 1'b0 : 1'b1; // subcycle 0: setup (1), subcycle 1: pulse (0)
            nxt_dir    = 1'b1;
            nxt_mask_n = ~r_be[3:2];
            nxt_addr   = {r_addr, 1'b0};
            nxt_dout   = r_wdata[31:16];
        end
        S_WR0_B: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b1;
            nxt_we_n   = phase_sel ? 1'b1 : 1'b0; // subcycle 2: pulse (0), subcycle 3: hold (1)
            nxt_dir    = 1'b1;
            nxt_mask_n = ~r_be[3:2];
            nxt_addr   = {r_addr, 1'b0};
            nxt_dout   = r_wdata[31:16];
        end
        S_WR1_A: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b1;
            nxt_we_n   = phase_sel ? 1'b0 : 1'b1; // subcycle 0: setup (1), subcycle 1: pulse (0)
            nxt_dir    = 1'b1;
            nxt_mask_n = ~r_be[1:0];
            nxt_addr   = {r_addr, 1'b1};
            nxt_dout   = r_wdata[15:0];
        end
        S_WR1_B: begin
            nxt_ce_n   = 1'b0;
            nxt_oe_n   = 1'b1;
            nxt_we_n   = phase_sel ? 1'b1 : 1'b0; // subcycle 2: pulse (0), subcycle 3: hold (1)
            nxt_dir    = 1'b1;
            nxt_mask_n = ~r_be[1:0];
            nxt_addr   = {r_addr, 1'b1};
            nxt_dout   = r_wdata[15:0];
        end
        default: ;
    endcase
end

// Non-reset dedicated output FFs for address (clean IOB packing)
(* IOB = "TRUE" *) logic [17:0] addr_q;
always_ff @(posedge clk2x) begin
    addr_q <= nxt_addr;
end
assign sram_address = addr_q;

// Non-reset, non-CE dedicated input FFs for sram_dataIn (packs into Artix-7 ILOGICE2.IFF, ~1.48 ns pad-to-FF)
(* IOB = "TRUE" *) logic [15:0] sram_in_q = 16'h0000;
always_ff @(posedge clk2x) begin
    sram_in_q <= sram_dataIn;
end

// Dedicated output FFs (zero internal readback) for dataOut, 1-bit OE (`OLOGICE2.TFF`), and control signals.
// `(* IOB = "TRUE" *)` on `dir_q` causes Vivado synthesis to auto-replicate the 1-bit OE FF into all 16
// `OLOGICE2.TFF` BELs across unmodified `HandheldTop` (sharing `rst2x` SR with `dout_q`).
(* IOB = "TRUE" *) logic [15:0] dout_q    = 16'h0000;
(* IOB = "TRUE" *) logic        dir_q     = 1'b0;
(* IOB = "TRUE" *) logic        ce_n_q    = 1'b1;
(* IOB = "TRUE" *) logic        we_n_q    = 1'b1;
(* IOB = "TRUE" *) logic        oe_n_q    = 1'b1;
(* IOB = "TRUE" *) logic [1:0]  mask_n_q  = 2'b11;

always_ff @(posedge clk2x) begin
    if (rst2x) begin
        dout_q    <= 16'h0000;
        ce_n_q    <= 1'b1;
        we_n_q    <= 1'b1;
        oe_n_q    <= 1'b1;
        dir_q     <= 1'b0;
        mask_n_q  <= 2'b11;
        rx_hi     <= 16'h0000;
        rx_lo     <= 16'h0000;
    end else begin
        dout_q    <= nxt_dout;
        ce_n_q    <= nxt_ce_n;
        we_n_q    <= nxt_we_n;
        oe_n_q    <= nxt_oe_n;
        dir_q     <= nxt_dir;
        mask_n_q  <= nxt_mask_n;

        // Transfer half 0 from ILOGICE2.IFF (captured after 24 ns on pins) as pads switch to half 1
        if (st == S_RD1_A && !phase_sel)
            rx_hi <= sram_in_q;
        // Transfer half 1 from ILOGICE2.IFF (captured after 24 ns on pins) as pads return to idle
        if (st == S_RD_CAP && !phase_sel)
            rx_lo <= sram_in_q;
    end
end

assign sram_ceN        = ce_n_q;
assign sram_weN        = we_n_q;
assign sram_oeN        = oe_n_q;
assign sram_writeMaskN = mask_n_q;
assign sram_dataOut    = dout_q;
assign sram_dataDir    = dir_q;

endmodule
`default_nettype wire
