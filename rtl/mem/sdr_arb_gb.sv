// Multi-port SDRAM arbiter for Game Bub's 2x W9825G6KH-6 (9-bit columns).
//
// Round-robin across N ports with burst hold up to MAXB words, urgent priority
// tier (CPU + RSP DMA + low scanout FIFO), optional Port 4 preemption for host
// bridge accesses, and 1-cycle speculative next-port lookahead (`la_*`) so
// sdr_ctrl_w9825 can precharge/activate the upcoming bank on phase 1.
//
// `hmap` remaps the RDP hidden-bit plane (words 0xDC_0000..0xDF_FFFF) for
// W9825G6KH-6's 9-bit column geometry:
//   - An RDRAM image word at byte address B[22:0] (word 0xE0_0000 + B[22:2])
//     sits in Rank 1 bank B[11:10] (word bits [9:8]).
//   - Its hidden word, plane word B[22:5] at 0xDC_0000 + B[22:5], carries
//     B[11:10] in word bits a[6:5].
//   - Placing a[6:5] ^ 2'b10 into bits [9:8] (the bank) and moving the plane's
//     original bits a[9:8] into [6:5] (with a[7] kept at bit [7]) forms a
//     strict bijection on 0xDC_0000..0xDF_FFFF while guaranteeing that an image
//     span and its hidden words always sit two banks apart.
`default_nettype none

module sdr_arb_gb #(
    parameter int N           = 6,
    parameter int MAXB        = 16,
    parameter bit APF_PREEMPT = 1
) (
    input  wire                clk,
    input  wire                rst,
    input  wire  [N-1:0]       p_valid,
    input  wire  [N-1:0]       p_we,
    input  wire  [N-1:0][23:0] p_addr,
    input  wire  [N-1:0][31:0] p_wdata,
    input  wire  [N-1:0][3:0]  p_be,
    input  wire  [N-1:0]       p_urgent,
    input  wire                apf_force,
    output logic [N-1:0]       p_ready,
    output logic [N-1:0]       p_rvalid,
    output logic [31:0]        p_rdata,
    // to sdr_ctrl_w9825
    output logic               req_valid,
    output logic               req_we,
    output logic [23:0]        req_addr,
    output logic [31:0]        req_wdata,
    output logic [3:0]         req_be,
    output logic [2:0]         req_tag,
    input  wire                req_ready,
    output logic               la_valid,
    output logic [23:0]        la_addr,
    input  wire                rd_valid,
    input  wire  [31:0]        rd_data,
    input  wire  [2:0]         rd_tag
);

function automatic logic [23:0] hmap(input logic [23:0] a);
    return (a[23:18] == 6'b110111) ? {a[23:10], a[6:5] ^ 2'b10, a[7], a[9:8], a[4:0]} : a;
endfunction

logic [N-1:0][23:0] p_phys;
always_comb begin
    for (int i = 0; i < N; i++) p_phys[i] = hmap(p_addr[i]);
end

localparam int IW = $clog2(N);
logic [IW-1:0] cur;
logic          held;
logic [4:0]    beats;

// First requesting port around the ring after `c` (`c` itself last): {found, port}.
function automatic logic [IW:0] ring(input logic [N-1:0] v, input logic [IW-1:0] c);
    logic f;
    logic [IW-1:0] p;
    logic [N-1:0] after_cur, candidates;
    f = 1'b0;
    p = c;
    for (int i = 0; i < N; i++) after_cur[i] = v[i] && (IW'(i) > c);
    candidates = (|after_cur) ? after_cur : v;
    for (int i = N - 1; i >= 0; i--) begin
        if (candidates[i]) begin
            p = IW'(i);
            f = 1'b1;
        end
    end
    return {f, p};
endfunction

// Grant selection
logic [IW-1:0] pick;
logic          any;
logic [N-1:0]  urgent_valid;
logic [IW:0]   rn;
wire           _unused_ok = &{1'b0, rn[IW]};

always_comb begin
    any          = |p_valid;
    urgent_valid = p_valid & p_urgent;
    rn           = ring((|urgent_valid) ? urgent_valid : p_valid, cur);
    if (APF_PREEMPT && (N > 4) && p_valid[4] && apf_force)
        pick = IW'(4);
    else if (held && p_valid[cur] && beats < 5'(MAXB))
        pick = cur;
    else
        pick = rn[IW-1:0];
end

// Next other requesting port (excluding `cur`) for phase-1 bank lookahead
logic [IW:0]  ro;
logic [N-1:0] p_oth, urgent_oth;

always_comb begin
    p_oth      = p_valid;
    p_oth[cur] = 1'b0;
    urgent_oth = p_oth & p_urgent;
    ro         = ring((|urgent_oth) ? urgent_oth : p_oth, cur);
end

always_ff @(posedge clk) begin
    la_valid <= !rst && ro[IW];
    la_addr  <= p_phys[ro[IW-1:0]];
end

// Request pipeline stage
wire load = any && (!req_valid || req_ready);

always_comb begin
    p_ready = '0;
    if (load) p_ready[pick] = 1'b1;
end

always_ff @(posedge clk) begin
    if (rst) begin
        req_valid <= 1'b0;
        req_we    <= 1'b0;
        req_addr  <= '0;
        req_wdata <= '0;
        req_be    <= '0;
        req_tag   <= '0;
        cur       <= '0;
        held      <= 1'b0;
        beats     <= '0;
    end else begin
        if (req_valid && req_ready)
            req_valid <= 1'b0;
        if (load) begin
            req_valid <= 1'b1;
            req_we    <= p_we[pick];
            req_addr  <= p_phys[pick];
            req_wdata <= p_wdata[pick];
            req_be    <= p_be[pick];
            req_tag   <= 3'(pick);
            beats     <= (held && pick == cur) ? (beats + 5'd1) : 5'd1;
            cur       <= pick;
            held      <= 1'b1;
        end else if (!p_valid[cur]) begin
            held <= 1'b0;
        end
    end
end

always_comb begin
    p_rvalid = '0;
    if (rd_valid && ({29'd0, rd_tag} < N))
        p_rvalid[rd_tag[IW-1:0]] = 1'b1;
end

assign p_rdata = rd_data;

endmodule
`default_nettype wire
