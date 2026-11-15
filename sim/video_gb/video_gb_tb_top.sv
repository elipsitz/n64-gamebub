// Testbench wrapper pairing Mirlo's real n64_video.sv with
// n64_video_gb_downsampler.sv across asynchronous 62.5 MHz (clk_sys) and
// 25.0 MHz (clk_vid) clock domains.
`default_nettype none

module video_gb_tb_top (
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        clk_vid,
    input  wire        rst_vid,

    // VI configuration (clk_sys)
    input  wire        enable,
    input  wire [25:0] vi_origin,
    input  wire        vi_il,
    input  wire        no_weave,
    input  wire [11:0] vi_width,
    input  wire        vi_px32,
    input  wire        vi_black,
    input  wire        vi_pal,
    input  wire        vi_out32,
    input  wire [8:0]  vi_lines,
    input  wire [9:0]  vi_px0,
    input  wire [9:0]  vi_pw,
    input  wire [7:0]  vi_y0,
    input  wire [8:0]  vi_rows,
    input  wire [10:0] vi_xs,
    input  wire [11:0] vi_ys,
    input  wire [10:0] vi_nw,

    // Downsampler controls (clk_sys)
    input  wire        horiz_blend_en,
    input  wire        dither_en,

    // RDRAM read port (clk_sys)
    output wire        m_valid,
    output wire [23:0] m_addr,
    input  wire        m_ready,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,

    // Raw n64_video outputs for monitoring
    output wire        vga_de,
    output wire        vga_vsync,
    output wire        vga_skip,
    output wire        vga_woven,

    // Game Bub VideoV0 outputs (clk_sys)
    output wire [5:0]  video_data_r,
    output wire [5:0]  video_data_g,
    output wire [5:0]  video_data_b,
    output wire        video_dataEnable,
    output wire        video_hblank,
    output wire        video_vblank
);

    wire [7:0] vga_r, vga_g, vga_b;
    wire       vga_hsync;

    n64_video #(
        .ORIGIN_MASK (24'h1FFFFF),
        .N64FB       (1'b1)
    ) u_n64_video (
        .clk         (clk_sys),
        .rst         (rst_sys),
        .clk_vid     (clk_vid),
        .rst_vid     (rst_vid),
        .enable      (enable),
        .vi_origin   (vi_origin),
        .vi_il       (vi_il),
        .no_weave    (no_weave),
        .vblank      (),
        .vi_width    (vi_width),
        .vi_px32     (vi_px32),
        .vi_black    (vi_black),
        .vi_pal      (vi_pal),
        .tv_pal      (),
        .gamma       (1'b0),
        .vi_aa       (1'b0),
        .vi_divot    (1'b0),
        .vi_dedither (1'b0),
        .vi_deblur   (1'b1),
        .vi_out32    (vi_out32),
        .crop_v      (5'd0),
        .crop_l      (2'd0),
        .crop_r      (2'd0),
        .vi_lines    (vi_lines),
        .vi_px0      (vi_px0),
        .vi_pw       (vi_pw),
        .vi_y0       (vi_y0),
        .vi_rows     (vi_rows),
        .vi_xs       (vi_xs),
        .vi_ys       (vi_ys),
        .vi_nw       (vi_nw),
        .osd_en      (1'b0),
        .fps_en      (1'b0),
        .osd_val     ('0),
        .m_valid     (m_valid),
        .m_addr      (m_addr),
        .m_urgent    (),
        .m_ready     (m_ready),
        .m_rvalid    (m_rvalid),
        .m_rdata     (m_rdata),
        .vi_line     (),
        .vi_frame    (),
        .vi_latch    (),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_de      (vga_de),
        .vga_skip    (vga_skip),
        .vga_woven   (vga_woven)
    );

    n64_video_gb_downsampler u_downsampler (
        .clk_vid          (clk_vid),
        .rst_vid          (rst_vid),
        .vga_r            (vga_r),
        .vga_g            (vga_g),
        .vga_b            (vga_b),
        .vga_de           (vga_de),
        .vga_hsync        (vga_hsync),
        .vga_vsync        (vga_vsync),
        .vga_skip         (vga_skip),
        .vga_woven        (vga_woven),
        .clk_sys          (clk_sys),
        .rst_sys          (rst_sys),
        .horiz_blend_en   (horiz_blend_en),
        .dither_en        (dither_en),
        .video_data_r     (video_data_r),
        .video_data_g     (video_data_g),
        .video_data_b     (video_data_b),
        .video_dataEnable (video_dataEnable),
        .video_hblank     (video_hblank),
        .video_vblank     (video_vblank)
    );

endmodule
`default_nettype wire
