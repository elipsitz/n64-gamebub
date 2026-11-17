// Physical Game Boy (DMG/CGB) cartridge bus controller for N64 Transfer Pak.
// Adapted from MIRLO64's `rtl/soc/gb_cart.sv` for Game Bub's `CartridgePortV0`.
//
// Electrical & safety rules on Game Bub Rev4:
//   - `sw_present` is the 2-FF synchronized `CartridgePortV0.switch` input
//     (`1` = 5 V DMG/CGB cartridge shell inserted; `0` = empty slot or 3.3 V
//     notched GBA cartridge).
//   - When `!sw_present`, `gb_on` is forced low and any register access answers
//     immediately with `0xFF` without driving any cartridge pin (`cart_oe_n = 1`
//     at the top level), keeping an empty slot or 3.3 V GBA cartridge completely
//     isolated.
//   - When `sw_present` is high and `on` is `0` (idle / reset), `/RST` is held
//     low (open-drain at top level), `PHI`, `/WR`, `/RD`, `/CS` are held high,
//     and `A[15:0]` + `D[7:0]` remain inputs, protecting battery-backed SRAM.
//   - When `sw_present && on`: `/RST` is released, `A[15:0]` is driven, and
//     `PHI` runs at `clk / 64` (`976.6 kHz` = `1.024 us` at `62.5 MHz`).
//   - Until `trust` is set by `n64rt_pak.c` (after validating the 48-byte
//     Nintendo logo CRC and header checksum at `0x0100..0x014F`), `/CS` and
//     `/WR` are blocked so untrusted cartridges never see writes or SRAM CS.
`default_nettype none

module gb_cart (
    input  wire         clk,
    input  wire         rst,
    input  wire         sw_present,     // synchronized DMG/CGB cartridge switch (1 = 5V GB/GBC cart in slot)
    input  wire         on,             // cartridge out of reset, bus driven
    input  wire         trust,          // /CS and writes allowed (header verified as Game Boy)
    input  wire         start,          // 1-cycle access strobe (when !busy)
    input  wire         we,
    input  wire  [15:0] addr,
    input  wire  [7:0]  wdata,
    output logic        busy,
    output logic [7:0]  rdata,

    // Cartridge bus signals (mapped to CartridgePortV0 at top level)
    output logic        gb_on,          // 1 = release open-drain nRST, 0 = hold nRST low
    output wire         gb_a_dir,       // address bank direction outward
    output wire         gb_a_oe,        // address bank output enable
    output logic [15:0] gb_a,
    output logic [7:0]  gb_d_o,
    output wire         gb_d_dir,       // data bank direction outward
    output wire         gb_d_oe,        // data bank output enable
    input  wire  [7:0]  gb_d_i,
    output logic        gb_phi,
    output logic        gb_wr_n,
    output logic        gb_rd_n,
    output logic        gb_cs_n
);
    logic [5:0] t;
    logic       pend, act, a_we, a_ok;
    logic [7:0] a_wdata;
    (* ASYNC_REG = "TRUE" *) logic [7:0] d1, d2;
    logic       on_d, dw, dw_d;

    assign gb_a_dir = gb_on || on_d;
    assign gb_a_oe  = gb_on && on_d;
    assign gb_d_dir = dw || dw_d;
    assign gb_d_oe  = dw && dw_d;

    initial begin
        gb_on   = 1'b0;
        on_d    = 1'b0;
        dw      = 1'b0;
        dw_d    = 1'b0;
        gb_phi  = 1'b1;
        gb_wr_n = 1'b1;
        gb_rd_n = 1'b1;
        gb_cs_n = 1'b1;
        busy    = 1'b0;
        pend    = 1'b0;
        act     = 1'b0;
        t       = 6'd0;
        gb_a    = 16'd0;
        gb_d_o  = 8'd0;
        rdata   = 8'hFF;
    end

    always_ff @(posedge clk) begin
        d1   <= gb_d_i;
        d2   <= d1;
        on_d <= gb_on;
        dw_d <= dw;

        if (rst || !sw_present) begin
            gb_on   <= 1'b0;
            on_d    <= 1'b0;
            dw      <= 1'b0;
            dw_d    <= 1'b0;
            t       <= 6'd0;
            pend    <= 1'b0;
            act     <= 1'b0;
            busy    <= 1'b0;
            gb_a    <= 16'd0;
            gb_d_o  <= 8'd0;
            gb_phi  <= 1'b1;
            gb_wr_n <= 1'b1;
            gb_rd_n <= 1'b1;
            gb_cs_n <= 1'b1;
            if (rst || start || pend || act)
                rdata <= 8'hFF;
        end else begin
            if (start && !busy) begin
                pend    <= 1'b1;
                busy    <= 1'b1;
                a_we    <= we;
                a_ok    <= trust;
                a_wdata <= wdata;
                gb_a    <= addr;
            end

            if (!gb_on) begin
                // Off: wait for `on`; answer any access immediately with 0xFF
                t       <= 6'd0;
                gb_phi  <= 1'b1;
                gb_wr_n <= 1'b1;
                gb_rd_n <= 1'b1;
                gb_cs_n <= 1'b1;
                dw      <= 1'b0;
                act     <= 1'b0;
                if (pend) begin
                    pend  <= 1'b0;
                    busy  <= 1'b0;
                    rdata <= 8'hFF;
                end
                if (on)
                    gb_on <= 1'b1;
            end else begin
                t <= t + 6'd1;
                if (t == 6'd0)  gb_phi <= 1'b1;
                if (t == 6'd32) gb_phi <= 1'b0;
                if (t == 6'd63) begin
                    // End of PHI cycle: launch pending access or shut bus down cleanly
                    act     <= 1'b0;
                    gb_cs_n <= 1'b1;
                    gb_phi  <= 1'b1;
                    if (pend) begin
                        pend    <= 1'b0;
                        act     <= 1'b1;
                        gb_cs_n <= !(a_ok && gb_a >= 16'hA000 && gb_a < 16'hFE00);
                    end else if (!on) begin
                        gb_on <= 1'b0;
                    end
                end

                if (act) begin
                    if (a_we) begin
                        if (t == 6'd8  && a_ok) begin gb_d_o <= a_wdata; dw <= 1'b1; end
                        if (t == 6'd16 && a_ok) gb_wr_n <= 1'b0;
                        if (t == 6'd48)         gb_wr_n <= 1'b1;
                        if (t == 6'd56)         dw      <= 1'b0;
                    end else begin
                        if (t == 6'd4)  gb_rd_n <= 1'b0;
                        if (t == 6'd58) rdata   <= d2;
                        if (t == 6'd60) gb_rd_n <= 1'b1;
                    end
                    if (t == 6'd62)
                        busy <= 1'b0;
                end
            end
        end
    end
endmodule

`default_nettype wire
