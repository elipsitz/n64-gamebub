// rsp_lutram: the vector registers' memory (rsp_vu) -- 32 words of 16 bytes
// in distributed LUT RAM: one clocked write with an enable per byte (we[b]:
// wd[8b +: 8]), the read in the cycle, at an address registered internally
// (ra_n is the address of the cycle to come). Implemented as 16 independent
// 8-bit distributed RAM lanes so Vivado infers RAM32M / RAM32X1D cleanly.
`default_nettype none
module rsp_lutram (
    input  wire         clk,
    input  wire [15:0]  we,
    input  wire [4:0]   wa,
    input  wire [127:0] wd,
    input  wire [4:0]   ra_n,
    output wire [127:0] q
);
    reg [4:0] ra;
    always @(posedge clk) ra <= ra_n;

    genvar b;
    generate for (b = 0; b < 16; b = b + 1) begin : lane
        (* ram_style = "distributed" *) reg [7:0] mb [0:31];
        always @(posedge clk) if (we[b]) mb[wa] <= wd[8 * b +: 8];
        assign q[8 * b +: 8] = mb[ra];
    end endgenerate
endmodule
`default_nettype wire
