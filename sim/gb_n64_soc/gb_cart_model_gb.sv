// Cycle-accurate Game Boy (DMG/CGB) MBC3 + 32 KiB SRAM cartridge model and
// `CartridgePortV0` electrical / bus-timing checker for `sim/gb_n64_soc`.
`default_nettype none

module gb_cart_model_gb #(
    parameter int ACC   = 13,   // 208 ns @ 62.5 MHz (slow DMG mask ROM / SRAM)
    parameter int OFF   = 4,    // 64 ns bus release after /RD rises
    parameter int SU    = 2,    // 32 ns setup before /RD or /WR falls
    parameter int HOLD  = 2,    // 32 ns hold after /WR rises
    parameter int PULSE = 16    // 256 ns minimum /RD or /WR strobe width
) (
    input  wire        clk,
    input  wire        rst,

    // CartridgePortV0 connections from `n64_gamebub_top`
    input  wire        cart_switch,
    input  wire        cart_enabled,
    output logic [7:0] bank0_in,
    input  wire  [7:0] bank0_out,
    input  wire        bank0_dir,
    input  wire  [7:0] bank1_out,
    input  wire        bank1_dir,
    input  wire  [7:0] bank2_out,
    input  wire        bank2_dir,
    input  wire  [3:0] bank3_out,
    input  wire        bank3_dir,
    input  wire        pin30_out,
    input  wire        pin30_dir,
    input  wire        pin31_out,
    input  wire        pin31_dir,

    // Telemetry to C++ harness
    output logic [15:0] bus_errors,
    output logic [15:0] bus_reads,
    output logic [15:0] bus_writes
);
    logic [7:0] rom [0:65535];  // 64 KiB (4 x 16 KiB banks)
    logic [7:0] ram [0:32767];  // 32 KiB (4 x  8 KiB banks)

    // Clean-room 48-byte test vector at 0x0104..0x0133 whose IEEE CRC-32 is 0x46195417
    localparam logic [47:0][7:0] CLEAN_LOGO_VEC = {
        "GAMEBUB TRANSFER PAK CLEANROOM TEST VECTOR  ",
        8'h11, 8'hfa, 8'h19, 8'hd8
    };
    localparam logic [15:0][7:0] CLEAN_TITLE = {
        "GBUB TPAK TEST", 8'h00, 8'h00
    };

    initial begin
        int b, i;
        logic [7:0] hsum;
        for (i = 0; i < 65536; i++) rom[i] = 8'h55 ^ i[7:0];
        for (i = 0; i < 32768; i++) ram[i] = 8'hFF;

        rom[16'h0100] = 8'h00;
        rom[16'h0101] = 8'hC3;
        rom[16'h0102] = 8'h50;
        rom[16'h0103] = 8'h01;
        for (i = 0; i < 48; i++) rom[16'h0104 + i] = CLEAN_LOGO_VEC[47 - i];
        for (i = 0; i < 16; i++) rom[16'h0134 + i] = CLEAN_TITLE[15 - i];
        rom[16'h0146] = 8'h03;
        rom[16'h0147] = 8'h13; // MBC3 + RAM + BATTERY
        rom[16'h0148] = 8'h01; // 64 KiB ROM
        rom[16'h0149] = 8'h03; // 32 KiB SRAM
        rom[16'h014A] = 8'h01;
        rom[16'h014B] = 8'h33;
        rom[16'h014C] = 8'h00;

        hsum = 8'd0;
        for (i = 16'h0134; i <= 16'h014C; i++)
            hsum = hsum - rom[i] - 8'd1;
        rom[16'h014D] = hsum;

        for (b = 0; b < 4; b++) begin
            for (i = 0; i < 32; i++)
                rom[b * 16'h4000 + 16'h3FE0 + i] = 8'hB0 ^ (8'(b) << 4) ^ 8'(i);
        end
    end

    // Decode CartridgePortV0 signals when level shifters are enabled
    wire        cs_n  = (cart_enabled && bank3_dir) ? bank3_out[0] : 1'b1;
    wire        rd_n  = (cart_enabled && bank3_dir) ? bank3_out[1] : 1'b1;
    wire        wr_n  = (cart_enabled && bank3_dir) ? bank3_out[2] : 1'b1;
    wire        phi   = (cart_enabled && bank3_dir) ? bank3_out[3] : 1'b1;
    wire        a_drv = cart_enabled && bank1_dir && bank2_dir;
    wire [15:0] a_bus = a_drv ? {bank1_out, bank2_out} : 16'hFFFF;
    wire        d_drv = cart_enabled && bank0_dir;
    wire [7:0]  d_o   = bank0_out;
    // Open-drain nRST: pulled high when not actively driven low
    wire        res_n = !(cart_enabled && pin30_dir && !pin30_out);

    // MBC3 state
    logic       ram_en;
    logic [1:0] rom_bank;
    logic [1:0] ram_bank;
    logic       ram_bank_valid;

    wire       sel_rom = !a_bus[15];
    wire       sel_ram = (a_bus[15:13] == 3'b101) && !cs_n && ram_en && ram_bank_valid;
    wire [7:0] q_byte  = sel_rom
                       ? rom[a_bus[14] ? {rom_bank, a_bus[13:0]} : {2'd0, a_bus[13:0]}]
                       : ram[{ram_bank, a_bus[12:0]}];

    wire driving = cart_switch && cart_enabled && res_n && !rd_n && (sel_rom || sel_ram);

    logic [15:0] a_q;
    logic        rd_q, wr_q, cs_q, sw_d1, sw_d2, sw_d3;
    logic [7:0]  d_q;
    int          a_age, d_age, cs_age, rd_low, wr_low, since_wr, off_cnt, drv_age;

    task automatic flag_err(input string msg);
        if (bus_errors < 16'hFFFF)
            bus_errors <= bus_errors + 16'd1;
        if (bus_errors < 16'd16)
            $display("[GBCART-ERR] %s (sw=%b en=%b rst_n=%b a=%04x rd_n=%b wr_n=%b cs_n=%b d_drv=%b)",
                     msg, cart_switch, cart_enabled, res_n, a_bus, rd_n, wr_n, cs_n, d_drv);
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            bus_errors     <= 16'd0;
            bus_reads      <= 16'd0;
            bus_writes     <= 16'd0;
            bank0_in       <= 8'hFF;
            ram_en         <= 1'b0;
            rom_bank       <= 2'd1;
            ram_bank       <= 2'd0;
            ram_bank_valid <= 1'b1;
            a_q            <= 16'hFFFF;
            rd_q           <= 1'b1;
            wr_q           <= 1'b1;
            cs_q           <= 1'b1;
            d_q            <= 8'h00;
            sw_d1          <= 1'b0;
            sw_d2          <= 1'b0;
            sw_d3          <= 1'b0;
            a_age          <= 0;
            d_age          <= 0;
            cs_age         <= 0;
            rd_low         <= 0;
            wr_low         <= 0;
            since_wr       <= 1000;
            off_cnt        <= 0;
            drv_age        <= 0;
        end else begin
            sw_d1 <= cart_switch;
            sw_d2 <= sw_d1;
            sw_d3 <= sw_d2;

            a_q      <= a_bus;
            rd_q     <= rd_n;
            wr_q     <= wr_n;
            cs_q     <= cs_n;
            d_q      <= d_o;
            a_age    <= (a_bus != a_q || !a_drv) ? 0 : a_age + 1;
            cs_age   <= (cs_n != cs_q) ? 0 : cs_age + 1;
            d_age    <= (d_o != d_q || !d_drv) ? 0 : d_age + 1;
            rd_low   <= rd_n ? 0 : rd_low + 1;
            wr_low   <= wr_n ? 0 : wr_low + 1;
            since_wr <= !wr_n ? 0 : since_wr + 1;

            drv_age  <= (!driving || a_bus != a_q || cs_n != cs_q) ? 0 : drv_age + 1;
            if (driving)
                off_cnt <= OFF;
            else if (off_cnt != 0)
                off_cnt <= off_cnt - 1;

            if (driving)
                bank0_in <= (drv_age >= ACC) ? q_byte : ~q_byte;
            else if (d_drv)
                bank0_in <= d_o;
            else
                bank0_in <= 8'hFF;

            // Electrical & isolation assertions (allowing 3 cycles for 2-FF switch sync)
            if (!cart_switch && !sw_d1 && !sw_d2 && !sw_d3) begin
                if (cart_enabled || bank0_dir || bank1_dir || bank2_dir || bank3_dir || pin30_dir)
                    flag_err("CartridgePortV0 enabled or driven while cart_switch == 0");
            end
            if (pin31_dir)
                flag_err("Pin 31 (VIN) must never be driven");
            if (pin30_dir && pin30_out)
                flag_err("Pin 30 (nRST) driven push-pull high instead of open-drain");
            if (cart_enabled && (bank1_dir != bank2_dir))
                flag_err("Address bank1_dir and bank2_dir mismatch");

            // Bus timing & contention assertions while DMG/CGB cartridge is present
            if (cart_switch && sw_d3) begin
                if ((driving || off_cnt != 0) && d_drv)
                    flag_err("Bus contention on D[7:0]");
                if (!rd_n && !wr_n)
                    flag_err("/RD and /WR asserted together");
                if (!res_n && (!rd_n || !wr_n || !cs_n))
                    flag_err("Bus strobe while cartridge is in reset");
                if (res_n && !a_drv && (!rd_n || !wr_n))
                    flag_err("Bus strobe while A[15:0] is not driven");
                if ((!rd_n || !wr_n) && (a_bus != a_q || cs_n != cs_q))
                    flag_err("Address or /CS changed during active strobe");
                if (!rd_n && rd_q && a_age < SU)
                    flag_err("/RD asserted before address setup");
                if (!wr_n && wr_q && (a_age < SU || cs_age < SU || d_age < SU))
                    flag_err("/WR asserted before address, /CS, or data setup");
                if (!wr_n && !d_drv)
                    flag_err("/WR asserted without D[7:0] driven");
                if (!wr_n && !wr_q && d_o != d_q)
                    flag_err("Write data changed during /WR");
                if (wr_n && since_wr < HOLD && (a_bus != a_q || cs_n != cs_q || d_o != d_q || !d_drv))
                    flag_err("Address, /CS, or data hold violated after /WR");
                if (rd_n && !rd_q) begin
                    if (bus_reads < 16'hFFFF) bus_reads <= bus_reads + 16'd1;
                    if (rd_low < PULSE) flag_err("/RD pulse shorter than minimum");
                end
            end

            // MBC3 register & SRAM writes on rising edge of /WR
            if (!res_n || !cart_switch) begin
                ram_en         <= 1'b0;
                rom_bank       <= 2'd1;
                ram_bank       <= 2'd0;
                ram_bank_valid <= 1'b1;
            end else if (wr_n && !wr_q) begin
                if (bus_writes < 16'hFFFF) bus_writes <= bus_writes + 16'd1;
                if (cart_switch && sw_d3 && wr_low < PULSE)
                    flag_err("/WR pulse shorter than minimum");
                case (a_q[15:13])
                    3'b000: ram_en <= (d_q[3:0] == 4'hA);
                    3'b001: rom_bank <= (d_q[1:0] == 2'd0) ? 2'd1 : d_q[1:0];
                    3'b010: begin
                        ram_bank       <= d_q[1:0];
                        ram_bank_valid <= (d_q[3:0] < 4'd4);
                    end
                    3'b101: begin
                        if (!cs_q && ram_en && ram_bank_valid)
                            ram[{ram_bank, a_q[12:0]}] <= d_q;
                    end
                    default: ;
                endcase
            end
        end
    end

    wire _unused_ok = &{1'b0, phi, pin31_out};
endmodule

`default_nettype wire
