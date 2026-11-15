// The monitor level's own memory (MIRLO_MON): 2 KiB at 0xFFFF_8000 on the
// game CPU's device bus. Single 512 x 32-bit byte-enabled Block RAM (0.5 RAMB36E1).
`default_nettype none

module mon_ram (
    input  wire         clk,
    input  wire         we,
    input  wire  [8:0]  a,
    input  wire  [31:0] wd,
    input  wire  [3:0]  be,
    output logic [31:0] rd
);
    (* ram_style = "block" *) logic [31:0] m [0:511];
    always_ff @(posedge clk) begin
        for (int g = 0; g < 4; g++)
            if (we && be[g]) m[a][8 * g +: 8] <= wd[8 * g +: 8];
        rd <= m[a];
    end
endmodule
`default_nettype wire
