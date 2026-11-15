// rsp_dpram: DMEM's memory -- 4 KiB as four banks of 256 words, a word of
// each 16-byte line in each (bank k holds the line's bytes 4k .. 4k + 3), so
// any 16 bytes from a word's start are one access: each bank has its own row
// (a_row[k]). A write enable per byte, by the byte's place in its line
// (a_we[b]: byte b, address mod 16 = b), the data the same way (byte b in
// a_dat_w[127 - 8b -: 8]); the read data, in that order too, the cycle after
// the row. Port b reads a word (the RDP's XBUS reads), the cycle after its
// address. On Artix-7 each bank uses two 18-bit TDP RAMB18E1 primitives
// (8 x RAMB18E1 = 4.0 Block RAM tiles total) with hardware byte write enables;
// in simulation the same behaviour in plain SystemVerilog, one array of 1024
// words in address order (the testbenches read DMEM there).
`default_nettype none

module rsp_dpram (
    input  wire          clk,
    input  wire  [31:0]  a_row,             // bank k's row in [8k +: 8]
    input  wire  [15:0]  a_we,
    input  wire  [127:0] a_dat_w,
    output logic [127:0] a_dat_r,
    input  wire  [9:0]   b_adr,
    output logic [31:0]  b_dat_r
);
`ifdef VERILATOR
    logic [31:0] mem [0:1023] /* verilator public_flat_rd */;
    always_ff @(posedge clk) begin
        for (int k = 0; k < 4; k++) begin
            for (int i = 0; i < 4; i++)
                if (a_we[4 * k + i]) mem[{a_row[8 * k +: 8], 2'(k)}][31 - 8 * i -: 8] <= a_dat_w[127 - 32 * k - 8 * i -: 8];
            a_dat_r[127 - 32 * k -: 32] <= mem[{a_row[8 * k +: 8], 2'(k)}];
        end
        b_dat_r <= mem[b_adr];
    end
`else
    logic [1:0]  b_k;
    logic [31:0] qb [4];
    always_ff @(posedge clk) b_k <= b_adr[1:0];
    assign b_dat_r = qb[b_k];

    genvar k;
    generate for (k = 0; k < 4; k++) begin : bank
        wire [7:0]  row_a = a_row[8 * k +: 8];
        wire [31:0] w_dat = a_dat_w[127 - 32 * k -: 32];
        wire [31:0] r_dat;
        assign a_dat_r[127 - 32 * k -: 32] = r_dat;

        // Upper halfword [31:16]: WEA[1] -> [31:24] (byte 4k+0), WEA[0] -> [23:16] (byte 4k+1)
        RAMB18E1 #(
            .DOA_REG        (0),
            .DOB_REG        (0),
            .RAM_MODE       ("TDP"),
            .READ_WIDTH_A   (18),
            .READ_WIDTH_B   (18),
            .WRITE_WIDTH_A  (18),
            .WRITE_WIDTH_B  (18),
            .WRITE_MODE_A   ("READ_FIRST"),
            .WRITE_MODE_B   ("READ_FIRST")
        ) ram_hi (
            .CLKARDCLK      (clk),
            .CLKBWRCLK      (clk),
            .ENARDEN        (1'b1),
            .ENBWREN        (1'b1),
            .REGCEAREGCE    (1'b1),
            .REGCEB         (1'b1),
            .RSTRAMARSTRAM  (1'b0),
            .RSTRAMB        (1'b0),
            .RSTREGARSTREG  (1'b0),
            .RSTREGB        (1'b0),
            .ADDRARDADDR    ({2'b00, row_a, 4'b0000}),
            .ADDRBWRADDR    ({2'b00, b_adr[9:2], 4'b0000}),
            .DIADI          (w_dat[31:16]),
            .DIBDI          (16'd0),
            .DIPADIP        (2'b00),
            .DIPBDIP        (2'b00),
            .WEA            ({a_we[4 * k + 0], a_we[4 * k + 1]}),
            .WEBWE          (4'b0000),
            .DOADO          (r_dat[31:16]),
            .DOBDO          (qb[k][31:16]),
            .DOPADOP        (),
            .DOPBDOP        ()
        );

        // Lower halfword [15:0]: WEA[1] -> [15:8] (byte 4k+2), WEA[0] -> [7:0] (byte 4k+3)
        RAMB18E1 #(
            .DOA_REG        (0),
            .DOB_REG        (0),
            .RAM_MODE       ("TDP"),
            .READ_WIDTH_A   (18),
            .READ_WIDTH_B   (18),
            .WRITE_WIDTH_A  (18),
            .WRITE_WIDTH_B  (18),
            .WRITE_MODE_A   ("READ_FIRST"),
            .WRITE_MODE_B   ("READ_FIRST")
        ) ram_lo (
            .CLKARDCLK      (clk),
            .CLKBWRCLK      (clk),
            .ENARDEN        (1'b1),
            .ENBWREN        (1'b1),
            .REGCEAREGCE    (1'b1),
            .REGCEB         (1'b1),
            .RSTRAMARSTRAM  (1'b0),
            .RSTRAMB        (1'b0),
            .RSTREGARSTREG  (1'b0),
            .RSTREGB        (1'b0),
            .ADDRARDADDR    ({2'b00, row_a, 4'b0000}),
            .ADDRBWRADDR    ({2'b00, b_adr[9:2], 4'b0000}),
            .DIADI          (w_dat[15:0]),
            .DIBDI          (16'd0),
            .DIPADIP        (2'b00),
            .DIPBDIP        (2'b00),
            .WEA            ({a_we[4 * k + 2], a_we[4 * k + 3]}),
            .WEBWE          (4'b0000),
            .DOADO          (r_dat[15:0]),
            .DOBDO          (qb[k][15:0]),
            .DOPADOP        (),
            .DOPBDOP        ()
        );
    end endgenerate
`endif
endmodule
`default_nettype wire
