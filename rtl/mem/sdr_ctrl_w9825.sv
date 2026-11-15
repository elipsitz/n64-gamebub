// Dual-rank SDR SDRAM controller for Game Bub's 2x Winbond W9825G6KH-6
// (64 MiB total: 2 ranks x 4 banks x 8,192 rows x 512 columns x 16 bits)
// behind sdr_phy_x7 (half rate: one 32-bit word = one BL2 burst = one sys
// cycle of data at 62.5 MHz sys / 125.0 MHz sys2x).
//
// 32-bit word address req_addr[23:0] (64 MiB):
//   q_rank = req_addr[23]                 (0 -> Rank 0 cs_n=2'b10, 1 -> Rank 1 cs_n=2'b01)
//   q_row  = req_addr[22:10]              (13-bit row, 8,192 rows)
//   q_bank = {req_addr[23], req_addr[9:8]}(3-bit logical bank: 8 independent open-page banks)
//   q_col  = {1'b0, req_addr[7:0], 1'b0}  (9-bit column A[8:0] = {req_addr[7:0], 1'b0}, A[10]=0)
//
// Global commands (MRS, REF, and precharge-all with A[10]=1) assert cs_n=2'b00
// so both SDRAM devices initialize, mode-set, precharge-all, and auto-refresh
// simultaneously. Bank-specific commands (ACT, RD, WR, single-bank PRE) select
// only the target rank on phase 0 and speculative lookahead phase 1.
`default_nettype none

module sdr_ctrl_w9825 #(
    parameter int T_INIT = 12600,       // 200 us power-up wait (@ 62.5 MHz = 201.6 us)
    parameter int T_REFI = 480,         // 7.68 us <= 7.8125 us (64 ms / 8192 rows)
    parameter int T_RFC  = 6,           // >= 60 ns tRFC
    parameter int T_RP   = 2,           // >= 18 ns tRP  (worst phase1->phase0 = 24 ns)
    parameter int T_RCD  = 2,           // >= 18 ns tRCD (worst phase1->phase0 = 24 ns)
    parameter int T_RAS  = 4,           // >= 42 ns tRAS (worst phase1->phase0 = 56 ns)
    parameter int T_WR   = 2,           // >= 16 ns tWR  (after second beat = 24 ns)
    parameter int T_R2W  = 3,           // read -> write DQ bus turnaround
    parameter int T_W2R  = 2,           // write -> read turnaround
    parameter int T_MRD  = 3,           // >= 2 tCK mode register set delay
    parameter int T_IDLE = 6,           // idle cycles before speculative phase-1 close
    parameter bit AHEAD  = 1,           // phase-1 speculative bank precharge/activate
    parameter int RL     = 5,           // sys cycles from dfi_rddata_en to dfi_rddata
    parameter int TAGW   = 3
) (
    input  wire              clk,
    input  wire              rst,
    output logic             ready,          // hardware init sequence completed
    // requests: held until req_ready
    input  wire              req_valid,
    input  wire              req_we,
    input  wire  [23:0]      req_addr,       // 32-bit word address (64 MiB)
    input  wire  [31:0]      req_wdata,
    input  wire  [3:0]       req_be,         // byte enables (writes)
    input  wire  [TAGW-1:0]  req_tag,
    output logic             req_ready,
    // speculative lookahead hint from arbiter
    input  wire              la_valid,
    input  wire  [23:0]      la_addr,
    // read data returned in request order
    output logic             rd_valid,
    output logic [31:0]      rd_data,
    output logic [TAGW-1:0]  rd_tag,
    output logic             rd_next,
    output logic [TAGW-1:0]  rd_next_tag,
    // DFI interface to sdr_phy_x7 (two phases: [0] = phase 0, [1] = phase 1)
    output logic [3:0]       dfi_cs_n,       // {cmd1_cs_n[1:0], cmd_cs_n[1:0]}
    output logic [1:0]       dfi_cke,
    output logic [1:0]       dfi_ras_n,
    output logic [1:0]       dfi_cas_n,
    output logic [1:0]       dfi_we_n,
    output logic [25:0]      dfi_addr,       // {cmd1_a[12:0], cmd_a[12:0]}
    output logic [3:0]       dfi_ba,         // {cmd1_ba[1:0], cmd_ba[1:0]}
    output logic             dfi_wrdata_en,
    output logic [31:0]      dfi_wrdata,
    output logic [3:0]       dfi_wrdata_mask,
    output logic             dfi_rddata_en,
    input  wire  [31:0]      dfi_rddata,
    input  wire              dfi_rddata_valid
);

wire _unused_ok = &{1'b0, dfi_rddata_valid, la_addr[7:0]};

// ---- command encodings {ras_n, cas_n, we_n}
localparam logic [2:0] C_NOP = 3'b111,
                       C_ACT = 3'b011,
                       C_RD  = 3'b101,
                       C_WR  = 3'b100,
                       C_PRE = 3'b010,
                       C_REF = 3'b001,
                       C_MRS = 3'b000;

// Phase 0 command
logic [2:0]  cmd;
logic [1:0]  cmd_cs_n;
logic [12:0] cmd_a;
logic [1:0]  cmd_ba;
logic        cmd_wr, cmd_rd;

// Phase 1 speculative command
logic [2:0]  cmd1;
logic [1:0]  cmd1_cs_n;
logic [12:0] cmd1_a;
logic [1:0]  cmd1_ba;

always_comb begin
    dfi_cs_n        = {cmd1_cs_n, cmd_cs_n};
    dfi_ras_n       = {cmd1[2], cmd[2]};
    dfi_cas_n       = {cmd1[1], cmd[1]};
    dfi_we_n        = {cmd1[0], cmd[0]};
    dfi_addr        = {cmd1_a, cmd_a};
    dfi_ba          = {cmd1_ba, cmd_ba};
    dfi_wrdata_en   = cmd_wr;
    dfi_wrdata      = req_wdata;
    dfi_wrdata_mask = ~req_be;
    dfi_rddata_en   = cmd_rd;
end

// ---- address decomposition for W9825G6KH-6 (512 cols = A[8:0], 8192 rows = A[12:0])
wire        q_rank = req_addr[23];
wire [12:0] q_row  = req_addr[22:10];
wire [2:0]  q_bank = {q_rank, req_addr[9:8]};
wire [9:0]  q_col  = {1'b0, req_addr[7:0], 1'b0};

wire        l_rank = la_addr[23];
wire [12:0] l_row  = la_addr[22:10];
wire [2:0]  l_bank = {l_rank, la_addr[9:8]};

// ---- 8-bank open-page state and saturating cycle timers
logic [7:0]  open;
logic [12:0] row [8];

function automatic int imax(input int x, input int y);
    return x > y ? x : y;
endfunction

localparam int CW = $clog2(imax(imax(imax(T_RAS, T_IDLE), imax(T_R2W, T_W2R)),
                                imax(imax(T_RCD, T_RP), T_WR)) + 1);

logic [CW-1:0] c_act [8], c_pre [8], c_wr [8], c_use [8];
logic [CW-1:0] c_rd, c_wrany;
logic          act1_d;

function automatic logic [CW-1:0] sat(input logic [CW-1:0] v);
    return &v ? v : v + 1'b1;
endfunction

// ---- init / refresh sequencing
typedef enum logic [3:0] {
    S_POWER, S_PRE1, S_MRS1, S_PRE2, S_REF1, S_REF2, S_MRS2,
    S_RUN, S_RPRE, S_RREF
} st_t;

st_t         st;
logic [13:0] wait_c;
logic [9:0]  refi_c;
logic        ref_due;
logic        all_closable;

always_comb begin
    all_closable = 1'b1;
    for (int b = 0; b < 8; b++) begin
        if (open[b] && !(c_act[b] >= CW'(T_RAS) && c_wr[b] >= CW'(T_WR)))
            all_closable = 1'b0;
    end
end

// ---- phase 0 command decision
always_comb begin
    cmd      = C_NOP;
    cmd_cs_n = 2'b11;
    cmd_a    = '0;
    cmd_ba   = '0;
    cmd_wr   = 1'b0;
    cmd_rd   = 1'b0;
    req_ready = 1'b0;

    if (wait_c == 14'd0) begin
        case (st)
            S_PRE1, S_PRE2: begin
                cmd      = C_PRE;
                cmd_a    = 13'h400;
                cmd_cs_n = 2'b00;
            end
            S_MRS1: begin
                cmd      = C_MRS;
                cmd_a    = 13'h131; // CL=3, BL=2
                cmd_cs_n = 2'b00;
            end
            S_MRS2: begin
                cmd      = C_MRS;
                cmd_a    = 13'h031; // CL=3, BL=2, standard mode
                cmd_cs_n = 2'b00;
            end
            S_REF1, S_REF2: begin
                cmd      = C_REF;
                cmd_cs_n = 2'b00;
            end
            S_RPRE: begin
                if (all_closable) begin
                    cmd      = C_PRE;
                    cmd_a    = 13'h400;
                    cmd_cs_n = 2'b00;
                end
            end
            S_RREF: begin
                cmd      = C_REF;
                cmd_cs_n = 2'b00;
            end
            S_RUN: begin
                if (!ref_due && req_valid) begin
                    if (open[q_bank] && row[q_bank] == q_row) begin
                        if (c_act[q_bank] >= CW'(T_RCD) &&
                            (req_we ? (c_rd >= CW'(T_R2W)) : (c_wrany >= CW'(T_W2R)))) begin
                            cmd       = req_we ? C_WR : C_RD;
                            cmd_cs_n  = q_bank[2] ? 2'b01 : 2'b10;
                            cmd_a     = {3'd0, q_col};
                            cmd_ba    = q_bank[1:0];
                            cmd_wr    = req_we;
                            cmd_rd    = !req_we;
                            req_ready = 1'b1;
                        end
                    end else if (open[q_bank]) begin
                        if (c_act[q_bank] >= CW'(T_RAS) && c_wr[q_bank] >= CW'(T_WR)) begin
                            cmd      = C_PRE;
                            cmd_cs_n = q_bank[2] ? 2'b01 : 2'b10;
                            cmd_ba   = q_bank[1:0];
                        end
                    end else if (c_pre[q_bank] >= CW'(T_RP) && !act1_d) begin
                        cmd      = C_ACT;
                        cmd_cs_n = q_bank[2] ? 2'b01 : 2'b10;
                        cmd_a    = q_row;
                        cmd_ba   = q_bank[1:0];
                    end
                end
            end
            default: ;
        endcase
    end
end

// ---- phase 1 speculative lookahead command decision
always_comb begin
    cmd1   = C_NOP;
    cmd1_a = '0;
    cmd1_ba = l_bank[1:0];

    if (AHEAD && st == S_RUN && wait_c == 14'd0 && !ref_due && la_valid &&
        !(req_valid && q_bank == l_bank)) begin
        if (open[l_bank]) begin
            if (row[l_bank] != l_row &&
                c_use[l_bank] >= CW'(T_IDLE) &&
                c_act[l_bank] >= CW'(T_RAS) &&
                c_wr[l_bank]  >= CW'(T_WR)) begin
                cmd1 = C_PRE;
            end
        end else if (c_pre[l_bank] >= CW'(T_RP) && cmd != C_ACT) begin
            cmd1   = C_ACT;
            cmd1_a = l_row;
        end
    end

    cmd1_cs_n = (cmd1 == C_NOP) ? 2'b11 : (l_bank[2] ? 2'b01 : 2'b10);
end

// ---- sequential state and per-bank timers
always_ff @(posedge clk) begin
    if (rst) begin
        st      <= S_POWER;
        wait_c  <= 14'(T_INIT);
        refi_c  <= '0;
        ref_due <= 1'b0;
        ready   <= 1'b0;
        dfi_cke <= 2'b00;
        open    <= 8'h00;
        c_rd    <= '1;
        c_wrany <= '1;
        act1_d  <= 1'b0;
        for (int b = 0; b < 8; b++) begin
            c_act[b] <= '1;
            c_pre[b] <= '1;
            c_wr[b]  <= '1;
            c_use[b] <= '1;
            row[b]   <= '0;
        end
    end else begin
        dfi_cke <= 2'b11;

        // Global read/write turnaround timers
        c_rd    <= (cmd == C_RD) ? CW'(1) : sat(c_rd);
        c_wrany <= (cmd == C_WR) ? CW'(1) : sat(c_wrany);

        // Per-bank (0..7 across both ranks) timing counters
        for (int b = 0; b < 8; b++) begin
            c_act[b] <= ((cmd == C_ACT && q_bank == 3'(b)) ||
                         (cmd1 == C_ACT && l_bank == 3'(b))) ? CW'(1) : sat(c_act[b]);
            c_pre[b] <= ((cmd == C_PRE && (cmd_a[10] || q_bank == 3'(b))) ||
                         (cmd1 == C_PRE && l_bank == 3'(b))) ? CW'(1) : sat(c_pre[b]);
            c_wr[b]  <= (cmd == C_WR && q_bank == 3'(b)) ? CW'(1) : sat(c_wr[b]);
            c_use[b] <= ((cmd == C_WR || cmd == C_RD) && q_bank == 3'(b)) ? CW'(1) : sat(c_use[b]);
        end
        act1_d <= (cmd1 == C_ACT);

        // Open-page tracking (phase 0 and phase 1 never target the same 3-bit bank)
        if (cmd == C_ACT) begin
            open[q_bank] <= 1'b1;
            row[q_bank]  <= cmd_a;
        end
        if (cmd == C_PRE) begin
            if (cmd_a[10]) open <= 8'h00;
            else           open[q_bank] <= 1'b0;
        end
        if (cmd1 == C_ACT) begin
            open[l_bank] <= 1'b1;
            row[l_bank]  <= cmd1_a;
        end
        if (cmd1 == C_PRE) begin
            open[l_bank] <= 1'b0;
        end

        // Refresh interval counter
        if (st != S_RUN && st != S_RPRE && st != S_RREF) begin
            refi_c <= '0;
        end else if (refi_c == 10'(T_REFI - 1)) begin
            refi_c  <= '0;
            ref_due <= 1'b1;
        end else begin
            refi_c <= refi_c + 10'd1;
        end

        // Init / refresh FSM sequencing
        if (wait_c != 14'd0) begin
            wait_c <= wait_c - 14'd1;
        end else begin
            case (st)
                S_POWER: st <= S_PRE1;
                S_PRE1:  begin st <= S_MRS1; wait_c <= 14'(T_RP);  end
                S_MRS1:  begin st <= S_PRE2; wait_c <= 14'(T_MRD); end
                S_PRE2:  begin st <= S_REF1; wait_c <= 14'(T_RP);  end
                S_REF1:  begin st <= S_REF2; wait_c <= 14'(T_RFC); end
                S_REF2:  begin st <= S_MRS2; wait_c <= 14'(T_RFC); end
                S_MRS2:  begin st <= S_RUN;  wait_c <= 14'(T_MRD); ready <= 1'b1; end
                S_RUN:   if (ref_due && !(cmd == C_RD || cmd == C_WR)) st <= S_RPRE;
                S_RPRE:  if (cmd == C_PRE) begin st <= S_RREF; wait_c <= 14'(T_RP); end
                S_RREF:  begin st <= S_RUN;  wait_c <= 14'(T_RFC); ref_due <= 1'b0; end
                default: st <= S_POWER;
            endcase
        end
    end
end

// ---- read data return pipeline (RL sys cycles after dfi_rddata_en)
logic [RL-1:0]   rd_sr;
logic [TAGW-1:0] tag_sr [RL];

always_ff @(posedge clk) begin
    if (rst) rd_sr <= '0;
    else     rd_sr <= {rd_sr[RL-2:0], cmd_rd};
    tag_sr[0] <= req_tag;
    for (int i = 1; i < RL; i++) tag_sr[i] <= tag_sr[i - 1];
end

assign rd_valid    = rd_sr[RL-1];
assign rd_data     = dfi_rddata;
assign rd_tag      = tag_sr[RL-1];
assign rd_next     = rd_sr[RL-2];
assign rd_next_tag = tag_sr[RL-2];

endmodule
`default_nettype wire
