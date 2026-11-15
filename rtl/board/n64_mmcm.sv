`default_nettype none

// Single MMCME2_ADV synthesizing all N64 and Game Bub framework clocks from
// the 50.000 MHz reference oscillator with 0.000 ppm frequency error:
//   VCO = 50.000 MHz * 15 = 750.000 MHz
//   CLKOUT0 (/12) =  62.500 MHz : clk_sys       (N64 RCP & Game Bub system clock)
//   CLKOUT1 (/ 8) =  93.750 MHz : clk_cpu       (N64 VR4300 CPU, exact 3:2 to clk_sys)
//   CLKOUT2 (/ 6) = 125.000 MHz : clk_sys2x     (SDRAM & SRAM 2x PHY clock)
//   CLKOUT3 (/ 6) = 125.000 MHz : clk_sdram_pad (phase-shifted + runtime fine PS)
//   CLKOUT4 (/ 4) = 187.500 MHz : clk_spi       (Host MCU SPI oversampling clock)
//   CLKOUT5 (/ D) =  30.000 MHz : clk_display   (LCD DPI clock, default D=25)
//   CLKOUT6 (/30) =  25.000 MHz : clk_vid       (N64 VI timing generator, exact 2:5 to clk_sys)
module n64_mmcm #(
    parameter int   CLK_DISPLAY_DIVIDE = 25,
    parameter real  SDRAM_CLK_PHASE    = -150.0
) (
    input  wire logic               clk_in_50mhz,

    output wire logic               clk_sys,
    output wire logic               clk_cpu,
    output wire logic               clk_sys2x,
    output wire logic               clk_sdram_pad,
    output wire logic               clk_spi,
    output wire logic               clk_display,
    output wire logic               clk_vid,
    output wire logic               locked,

    // Target fine-phase offset (signed steps of 1/(56*VCO) = 23.81 ps/step)
    // Automatically stepped on clk_sys via MMCME2_ADV dynamic fine phase shift.
    input  wire logic signed [7:0]  ps_target,
    output logic signed      [7:0]  ps_current
);
    wire clk_fb_unbuf, clk_fb;
    wire clk_sys_unbuf, clk_cpu_unbuf, clk_sys2x_unbuf;
    wire clk_sdram_unbuf, clk_spi_unbuf, clk_display_unbuf, clk_vid_unbuf;

    logic ps_en = 1'b0;
    logic ps_incdec = 1'b0;
    logic ps_busy = 1'b0;
    wire  ps_done;

`ifdef VERILATOR
    logic sim_clk_sys   /* verilator public_flat_rw */ = 1'b0;
    logic sim_clk_cpu   /* verilator public_flat_rw */ = 1'b0;
    logic sim_clk_sys2x /* verilator public_flat_rw */ = 1'b0;
    logic sim_clk_vid   /* verilator public_flat_rw */ = 1'b0;

    assign clk_sys       = sim_clk_sys;
    assign clk_cpu       = sim_clk_cpu;
    assign clk_sys2x     = sim_clk_sys2x;
    assign clk_sdram_pad = sim_clk_sys2x;
    assign clk_spi       = sim_clk_sys2x;
    assign clk_display   = sim_clk_vid;
    assign clk_vid       = sim_clk_vid;
    assign locked        = 1'b1;
    assign ps_done       = ps_busy;
    wire _unused_verilator = clk_in_50mhz;
`else
    MMCME2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .CLKOUT4_CASCADE      ("FALSE"),
        .COMPENSATION         ("ZHOLD"),
        .STARTUP_WAIT         ("FALSE"),
        .DIVCLK_DIVIDE        (1),
        .CLKFBOUT_MULT_F      (15.000),
        .CLKFBOUT_PHASE       (0.000),
        .CLKFBOUT_USE_FINE_PS ("FALSE"),
        .CLKIN1_PERIOD        (20.000),

        .CLKOUT0_DIVIDE_F     (12.000),
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        .CLKOUT0_USE_FINE_PS  ("FALSE"),

        .CLKOUT1_DIVIDE       (8),
        .CLKOUT1_PHASE        (0.000),
        .CLKOUT1_DUTY_CYCLE   (0.500),
        .CLKOUT1_USE_FINE_PS  ("FALSE"),

        .CLKOUT2_DIVIDE       (6),
        .CLKOUT2_PHASE        (0.000),
        .CLKOUT2_DUTY_CYCLE   (0.500),
        .CLKOUT2_USE_FINE_PS  ("FALSE"),

        .CLKOUT3_DIVIDE       (6),
        .CLKOUT3_PHASE        (SDRAM_CLK_PHASE),
        .CLKOUT3_DUTY_CYCLE   (0.500),
        .CLKOUT3_USE_FINE_PS  ("TRUE"),

        .CLKOUT4_DIVIDE       (4),
        .CLKOUT4_PHASE        (0.000),
        .CLKOUT4_DUTY_CYCLE   (0.500),
        .CLKOUT4_USE_FINE_PS  ("FALSE"),

        .CLKOUT5_DIVIDE       (CLK_DISPLAY_DIVIDE),
        .CLKOUT5_PHASE        (0.000),
        .CLKOUT5_DUTY_CYCLE   (0.500),
        .CLKOUT5_USE_FINE_PS  ("FALSE"),

        .CLKOUT6_DIVIDE       (30),
        .CLKOUT6_PHASE        (0.000),
        .CLKOUT6_DUTY_CYCLE   (0.500),
        .CLKOUT6_USE_FINE_PS  ("FALSE")
    ) u_mmcm (
        .CLKFBOUT             (clk_fb_unbuf),
        .CLKFBOUTB            (),
        .CLKFBIN              (clk_fb),
        .CLKIN1               (clk_in_50mhz),
        .CLKIN2               (1'b0),
        .CLKINSEL             (1'b1),

        .CLKOUT0              (clk_sys_unbuf),
        .CLKOUT0B             (),
        .CLKOUT1              (clk_cpu_unbuf),
        .CLKOUT1B             (),
        .CLKOUT2              (clk_sys2x_unbuf),
        .CLKOUT2B             (),
        .CLKOUT3              (clk_sdram_unbuf),
        .CLKOUT3B             (),
        .CLKOUT4              (clk_spi_unbuf),
        .CLKOUT5              (clk_display_unbuf),
        .CLKOUT6              (clk_vid_unbuf),

        .DADDR                (7'h0),
        .DCLK                 (1'b0),
        .DEN                  (1'b0),
        .DI                   (16'h0),
        .DO                   (),
        .DRDY                 (),
        .DWE                  (1'b0),

        .PSCLK                (clk_sys),
        .PSEN                 (ps_en),
        .PSINCDEC             (ps_incdec),
        .PSDONE               (ps_done),

        .LOCKED               (locked),
        .CLKINSTOPPED         (),
        .CLKFBSTOPPED         (),
        .PWRDWN               (1'b0),
        .RST                  (1'b0)
    );

    BUFG u_bufg_fb      (.I(clk_fb_unbuf),      .O(clk_fb));
    BUFG u_bufg_sys     (.I(clk_sys_unbuf),     .O(clk_sys));
    BUFG u_bufg_cpu     (.I(clk_cpu_unbuf),     .O(clk_cpu));
    BUFG u_bufg_sys2x   (.I(clk_sys2x_unbuf),   .O(clk_sys2x));
    BUFG u_bufg_sdram   (.I(clk_sdram_unbuf),   .O(clk_sdram_pad));
    BUFG u_bufg_spi     (.I(clk_spi_unbuf),     .O(clk_spi));
    BUFG u_bufg_display (.I(clk_display_unbuf), .O(clk_display));
    BUFG u_bufg_vid     (.I(clk_vid_unbuf),     .O(clk_vid));
`endif

    // Automatic fine-phase-shift tracking FSM (~12 PSCLK cycles per 23.8 ps step)
    always_ff @(posedge clk_sys) begin
        ps_en <= 1'b0;
        if (!locked) begin
            ps_busy    <= 1'b0;
            ps_current <= 8'sd0;
        end else if (ps_busy) begin
            if (ps_done) begin
                ps_busy    <= 1'b0;
                ps_current <= ps_incdec ? (ps_current + 8'sd1) : (ps_current - 8'sd1);
            end
        end else if (ps_current != ps_target) begin
            ps_en     <= 1'b1;
            ps_incdec <= (ps_target > ps_current);
            ps_busy   <= 1'b1;
        end
    end
endmodule

`default_nettype wire
