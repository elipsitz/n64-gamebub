// Two-level Read-Only Cartridge ROM Cache (16 KiB L1 BRAM + 64 KiB L2 SRAM).
//
// Sits in `clk` (62.5 MHz) in front of read-only Cartridge ROM accesses
// (`rom_addr` in 24'h04_0000..24'hD3_FFFF, `!rom_we`):
//
//   - L1 Cache: 256 lines x 16 words (64 bytes/line = 16 KiB total)
//       * `l1_data`: 4096 x 32b (`4 x RAMB36E1`)
//       * `l1_tag` : 256 x 12b  (`0.5 x RAMB18E1`, stores `addr[23:12]`)
//       * `l1_valid`: 256-bit FF vector cleared in 1 cycle on `rst || inv_all`
//       * Latency: 2-cycle handshake (`C_IDLE` synchronous BRAM read ->
//         `C_LOOKUP` tag hit & `rom_ack = 1`), even while background L2
//         writeback is draining.
//
//   - L2 Cache: 1024 lines x 16 words (64 bytes/line = 64 KiB total)
//       * Data stored in external Async SRAM (`gb_sram_ctrl` Port 2) at word
//         offsets `L2_BASE` (`17'h1A000 .. 17'h1DFFF`, bytes `0x68000..0x77FFF`)
//       * `l2_tag` : 1024 x 10b (`0.5 x RAMB36E1`, stores `addr[23:14]`)
//       * `l2_valid`: 1024-bit FF vector cleared in 1 cycle on `rst || inv_all`
//       * On L1 miss + L2 hit: refills the 16-word line into L1 directly from
//         L2 SRAM with ZERO SDRAM traffic (preserving open RDRAM pages).
//       * On L1 miss + L2 miss: bursts all 16 words sequentially from SDRAM
//         (`m_valid`, `m_addr = {q_addr[23:4], beat[3:0]}`), fills L1 BRAM,
//         returns `rom_ack`, and writes all 16 words into L2 SRAM via a 16-word
//         staging buffer (`fill_buf`).
`default_nettype none

module pi_rom_cache #(
    parameter logic [16:0] L2_BASE = 17'h1A000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         inv_all,    // 1-cycle full L1 + L2 invalidation

    // Upstream read-only ROM port (held until rom_ack)
    input  wire         rom_req,
    input  wire  [23:0] rom_addr,
    output logic        rom_ack,
    output logic [31:0] rom_rdata,

    // Downstream SDRAM arbiter port (read-only burst of 16 words)
    output logic        m_valid,
    output logic [23:0] m_addr,
    input  wire         m_ready,
    input  wire         m_rvalid,
    input  wire  [31:0] m_rdata,

    // Downstream L2 Async SRAM port (gb_sram_ctrl Port 2)
    output logic        l2_valid,
    output logic        l2_we,
    output logic [16:0] l2_addr,
    output logic [31:0] l2_wdata,
    input  wire         l2_ack,
    input  wire  [31:0] l2_rdata
);

typedef enum logic [2:0] {
    C_IDLE,
    C_LOOKUP,
    C_WAIT_WB,
    C_L2_CHECK,
    C_L2_FILL,
    C_SDR_FILL,
    C_DONE
} cst_t;

cst_t        st;
logic [23:0] q_addr;
logic [31:0] fill_word;
logic        fill_inv;

// ---- L1 BRAM data (4096 x 32b = 16 KiB) & tags (256 x 12b) + 256-bit FF valid
(* ram_style = "block" *) logic [31:0] l1_data [0:4095];
(* ram_style = "block" *) logic [11:0] l1_tag  [0:255];
logic [255:0] l1_valid;

logic        l1_data_we;
logic [11:0] l1_data_waddr, l1_data_raddr;
logic [31:0] l1_data_wdata, l1_rd_q;

logic        l1_tag_we;
logic [7:0]  l1_tag_waddr, l1_tag_raddr;
logic [11:0] l1_tag_wdata, l1_tag_q;
logic        l1_val_q;

always_ff @(posedge clk) begin
    if (l1_data_we)
        l1_data[l1_data_waddr] <= l1_data_wdata;
    l1_rd_q <= l1_data[l1_data_raddr];
end

always_ff @(posedge clk) begin
    if (l1_tag_we)
        l1_tag[l1_tag_waddr] <= l1_tag_wdata;
    l1_tag_q <= l1_tag[l1_tag_raddr];
end

// ---- L2 tag BRAM (1024 x 10b) + 1024-bit FF valid + 16-word writeback buffer
(* ram_style = "block" *)       logic [9:0]  l2_tag   [0:1023];
(* ram_style = "distributed" *) logic [31:0] fill_buf [0:15];
logic [1023:0] l2_valid_vec;

logic       l2_tag_we;
logic [9:0] l2_tag_waddr, l2_tag_raddr;
logic [9:0] l2_tag_wdata, l2_tag_q;
logic       l2_val_q;

always_ff @(posedge clk) begin
    if (l2_tag_we)
        l2_tag[l2_tag_waddr] <= l2_tag_wdata;
    l2_tag_q <= l2_tag[l2_tag_raddr];
end

// ---- Refill & L2 background writeback counters
logic [4:0]  req_cnt, rd_cnt;
logic [3:0]  l2_rd_beat;

logic        wb_busy, wb_req_q, wb_inv;
logic [4:0]  wb_cnt;
logic [9:0]  wb_l2_idx;
logic [16:0] wb_addr_q;
logic [31:0] wb_wdata_q;

always_ff @(posedge clk) begin
    if (st == C_SDR_FILL && m_rvalid)
        fill_buf[rd_cnt[3:0]] <= m_rdata;
end

// ---- Hit detection
wire l1_hit = l1_val_q && !inv_all && (l1_tag_q == q_addr[23:12]);
wire l2_hit = l2_val_q && !inv_all && (l2_tag_q == q_addr[23:14]);

// ---- Synchronous BRAM read address muxes
always_comb begin
    l1_data_raddr = rom_addr[11:0];
    l1_tag_raddr  = rom_addr[11:4];
    l2_tag_raddr  = (st == C_WAIT_WB) ? q_addr[13:4] : rom_addr[13:4];
end

// ---- L1 & L2 BRAM write enables / data
always_comb begin
    l1_data_we    = 1'b0;
    l1_data_waddr = {q_addr[11:4], 4'd0};
    l1_data_wdata = 32'd0;

    l1_tag_we     = 1'b0;
    l1_tag_waddr  = q_addr[11:4];
    l1_tag_wdata  = q_addr[23:12];

    l2_tag_we     = 1'b0;
    l2_tag_waddr  = q_addr[13:4];
    l2_tag_wdata  = q_addr[23:14];

    if (st == C_L2_FILL && l2_ack) begin
        l1_data_we    = 1'b1;
        l1_data_waddr = {q_addr[11:4], l2_rd_beat};
        l1_data_wdata = l2_rdata;
        if (l2_rd_beat == 4'd15)
            l1_tag_we = 1'b1;
    end else if (st == C_SDR_FILL && m_rvalid) begin
        l1_data_we    = 1'b1;
        l1_data_waddr = {q_addr[11:4], rd_cnt[3:0]};
        l1_data_wdata = m_rdata;
        if (rd_cnt == 5'd15)
            l1_tag_we = 1'b1;
    end

    // Write L2 tag when starting a new SDRAM refill (valid bit is set only once all 16 words land in SRAM)
    if ((st == C_LOOKUP && !l1_hit && !wb_busy && !l2_hit) ||
        (st == C_L2_CHECK && !l2_hit)) begin
        l2_tag_we = 1'b1;
    end
end

// ---- Upstream & Downstream port outputs
assign rom_ack   = (st == C_LOOKUP && l1_hit) || (st == C_DONE);
assign rom_rdata = (st == C_LOOKUP) ? l1_rd_q : fill_word;

assign m_valid   = (st == C_SDR_FILL) && (req_cnt < 5'd16);
assign m_addr    = {q_addr[23:4], req_cnt[3:0]};

always_comb begin
    if (st == C_L2_FILL) begin
        l2_valid = 1'b1;
        l2_we    = 1'b0;
        l2_addr  = L2_BASE + {3'd0, q_addr[13:4], l2_rd_beat};
        l2_wdata = 32'd0;
    end else begin
        l2_valid = wb_req_q;
        l2_we    = 1'b1;
        l2_addr  = wb_addr_q;
        l2_wdata = wb_wdata_q;
    end
end

// ---- Main Cache FSM & Background L2 Writeback Engine
wire start_sdr_fill = (st == C_LOOKUP && !l1_hit && !wb_busy && !l2_hit) ||
                      (st == C_L2_CHECK && !l2_hit);
wire wb_data_avail  = (st == C_SDR_FILL) ? (wb_cnt < rd_cnt) : 1'b1;

always_ff @(posedge clk) begin
    if (rst) begin
        st         <= C_IDLE;
        q_addr     <= 24'd0;
        fill_word  <= 32'd0;
        fill_inv   <= 1'b0;
        l1_val_q   <= 1'b0;
        l2_val_q   <= 1'b0;
        req_cnt    <= 5'd0;
        rd_cnt     <= 5'd0;
        l2_rd_beat <= 4'd0;
        wb_busy    <= 1'b0;
        wb_req_q   <= 1'b0;
        wb_inv     <= 1'b0;
        wb_cnt     <= 5'd0;
        wb_l2_idx  <= 10'd0;
        wb_addr_q     <= 17'd0;
        wb_wdata_q    <= 32'd0;
        l1_valid      <= '0;
        l2_valid_vec  <= '0;
    end else begin
        // 1-cycle global invalidation of L1 and L2 valid vectors
        if (inv_all) begin
            l1_valid     <= '0;
            l2_valid_vec <= '0;
            fill_inv     <= 1'b1;
            wb_inv       <= 1'b1;
        end

        // Background L2 SRAM writeback engine
        if (start_sdr_fill) begin
            wb_busy   <= 1'b1;
            wb_req_q  <= 1'b0;
            wb_inv    <= inv_all;
            wb_cnt    <= 5'd0;
            wb_l2_idx <= q_addr[13:4];
            if (!inv_all)
                l2_valid_vec[q_addr[13:4]] <= 1'b0;
        end else if (wb_busy) begin
            if (wb_req_q) begin
                if (l2_ack) begin
                    wb_req_q <= 1'b0;
                    if (wb_inv || inv_all) begin
                        wb_busy <= 1'b0;
                    end else if (wb_cnt == 5'd15) begin
                        wb_busy                 <= 1'b0;
                        l2_valid_vec[wb_l2_idx] <= 1'b1;
                    end else begin
                        wb_cnt <= wb_cnt + 5'd1;
                    end
                end
            end else begin
                if (wb_inv || inv_all) begin
                    wb_busy <= 1'b0;
                end else if (wb_data_avail) begin
                    wb_req_q   <= 1'b1;
                    wb_addr_q  <= L2_BASE + {3'd0, wb_l2_idx, wb_cnt[3:0]};
                    wb_wdata_q <= fill_buf[wb_cnt[3:0]];
                end
            end
        end

        // Main cache controller FSM
        case (st)
            C_IDLE: begin
                if (rom_req) begin
                    q_addr   <= rom_addr;
                    l1_val_q <= l1_valid[rom_addr[11:4]] && !inv_all;
                    l2_val_q <= l2_valid_vec[rom_addr[13:4]] && !inv_all;
                    st       <= C_LOOKUP;
                end
            end
            C_LOOKUP: begin
                if (l1_hit || !rom_req) begin
                    st <= C_IDLE;
                end else if (wb_busy) begin
                    st <= C_WAIT_WB;
                end else if (l2_hit) begin
                    l2_rd_beat <= 4'd0;
                    fill_inv   <= inv_all;
                    if (!inv_all)
                        l1_valid[q_addr[11:4]] <= 1'b0;
                    st <= C_L2_FILL;
                end else begin
                    req_cnt  <= 5'd0;
                    rd_cnt   <= 5'd0;
                    fill_inv <= inv_all;
                    if (!inv_all)
                        l1_valid[q_addr[11:4]] <= 1'b0;
                    st <= C_SDR_FILL;
                end
            end
            C_WAIT_WB: begin
                if (!wb_busy) begin
                    l2_val_q <= l2_valid_vec[q_addr[13:4]] && !inv_all;
                    st       <= C_L2_CHECK;
                end
            end
            C_L2_CHECK: begin
                if (l2_hit) begin
                    l2_rd_beat <= 4'd0;
                    fill_inv   <= inv_all;
                    if (!inv_all)
                        l1_valid[q_addr[11:4]] <= 1'b0;
                    st <= C_L2_FILL;
                end else begin
                    req_cnt  <= 5'd0;
                    rd_cnt   <= 5'd0;
                    fill_inv <= inv_all;
                    if (!inv_all)
                        l1_valid[q_addr[11:4]] <= 1'b0;
                    st <= C_SDR_FILL;
                end
            end
            C_L2_FILL: begin
                if (l2_ack) begin
                    if (l2_rd_beat == q_addr[3:0])
                        fill_word <= l2_rdata;
                    if (l2_rd_beat == 4'd15) begin
                        if (!(fill_inv || inv_all))
                            l1_valid[q_addr[11:4]] <= 1'b1;
                        st <= C_DONE;
                    end else begin
                        l2_rd_beat <= l2_rd_beat + 4'd1;
                    end
                end
            end
            C_SDR_FILL: begin
                if (m_valid && m_ready)
                    req_cnt <= req_cnt + 5'd1;
                if (m_rvalid) begin
                    if (rd_cnt[3:0] == q_addr[3:0])
                        fill_word <= m_rdata;
                    if (rd_cnt == 5'd15) begin
                        if (!(fill_inv || inv_all))
                            l1_valid[q_addr[11:4]] <= 1'b1;
                        st <= C_DONE;
                    end else begin
                        rd_cnt <= rd_cnt + 5'd1;
                    end
                end
            end
            C_DONE: begin
                st <= C_IDLE;
            end
            default: st <= C_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
