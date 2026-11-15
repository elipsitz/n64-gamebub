// n64_video_gb_downsampler: Bridges Mirlo's n64_video scan-out (25.000 MHz clk_vid,
// 640x240 progressive or 640x480 woven RGB888) to Game Bub's HandheldTop VideoV0
// interface (62.500 MHz clk_sys, 320x240 RGB666).
//
// Features:
//  - Progressive 640x240 (!vga_woven): pairs consecutive active pixels (2*x, 2*x+1)
//    ignoring vga_skip duplicate clocks; blends (r0 + r1 + 1) >> 1 when horiz_blend_en
//    is set, or selects crisp even pixel r0 when clear.
//  - Woven 640x480 hi-res (vga_woven): stores horizontally blended even lines
//    (src_y[0] == 0) in a single 320 x 24-bit BRAM line buffer (0.5 RAMB36E1), and
//    vertically + horizontally supersamples odd lines (src_y[0] == 1) into 240
//    progressive 320-pixel output lines.
//  - RGB888 -> RGB666 quantization with optional 2x2 Bayer ordered dither (dither_en)
//    and saturating clamp at 63 (255 -> 63 with zero overflow wrap).
//  - Dual-clock Gray-coded 32-deep distributed-RAM FIFO crossing clk_vid -> clk_sys,
//    driving HandheldTop.scala's exact edge contract (vblank & hblank drop together
//    before line 0, 320 single-cycle dataEnable pulses per line, hblank 0->1 after
//    pixel 319, and vblank 0->1 after line 239 or early vsync).
`default_nettype none

module n64_video_gb_downsampler (
    // 25.000 MHz video scan-out domain (from n64_video)
    input  wire        clk_vid,
    input  wire        rst_vid,
    input  wire [7:0]  vga_r,
    input  wire [7:0]  vga_g,
    input  wire [7:0]  vga_b,
    input  wire        vga_de,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        vga_hsync,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        vga_vsync,
    input  wire        vga_skip,
    input  wire        vga_woven,

    // 62.500 MHz system clock domain (Game Bub VideoV0)
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        horiz_blend_en,
    input  wire        dither_en,

    output logic [5:0] video_data_r,
    output logic [5:0] video_data_g,
    output logic [5:0] video_data_b,
    output logic       video_dataEnable,
    output logic       video_hblank,
    output logic       video_vblank
);

    localparam logic [1:0] TAG_PIX   = 2'b00;
    localparam logic [1:0] TAG_EOL   = 2'b01;
    localparam logic [1:0] TAG_VSYNC = 2'b10;

    // -------------------------------------------------------------------------
    // Shared CDC FIFO reset synchronization (ensures wptr and rptr reset together)
    // -------------------------------------------------------------------------
    wire rst_any = rst_vid | rst_sys;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_vid_sync, rst_sys_sync;
    always_ff @(posedge clk_vid or posedge rst_any) begin
        if (rst_any) rst_vid_sync <= 2'b11;
        else         rst_vid_sync <= {rst_vid_sync[0], 1'b0};
    end
    always_ff @(posedge clk_sys or posedge rst_any) begin
        if (rst_any) rst_sys_sync <= 2'b11;
        else         rst_sys_sync <= {rst_sys_sync[0], 1'b0};
    end
    wire v_rst = rst_vid_sync[1];
    wire s_rst = rst_sys_sync[1];

    // -------------------------------------------------------------------------
    // Control option synchronizers (clk_sys -> clk_vid)
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [1:0] hblend_sync, dither_sync;
    always_ff @(posedge clk_vid) begin
        if (v_rst) begin
            hblend_sync <= 2'b11;
            dither_sync <= 2'b11;
        end else begin
            hblend_sync <= {hblend_sync[0], horiz_blend_en};
            dither_sync <= {dither_sync[0], dither_en};
        end
    end
    wire hblend_v = hblend_sync[1];
    wire dither_v = dither_sync[1];

    // -------------------------------------------------------------------------
    // Helper functions: 8-bit pair average & 8->6-bit Bayer-dithered quantizer
    // -------------------------------------------------------------------------
    function automatic logic [7:0] avg8(input logic [7:0] a, input logic [7:0] b, input logic en);
        logic [8:0] sum;
        sum = {1'b0, a} + {1'b0, b} + 9'd1;
        return en ? sum[8:1] : a;
    endfunction

    function automatic logic [5:0] quant6(input logic [7:0] c8, input logic [1:0] d);
        logic [8:0] s;
        s = {1'b0, c8} + {7'd0, d};
        return (s > 9'd252) ? 6'd63 : s[7:2];
    endfunction

    // -------------------------------------------------------------------------
    // clk_vid (25 MHz): Horizontal + Vertical Downsampler & Even-Line Buffer
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [23:0] even_line_buf [0:319];
    logic [23:0] even_rgb;

    logic        vga_de_d, vga_vsync_d;
    logic        in_frame, frame_done;
    logic        woven_latched;
    logic [8:0]  src_y;        // 0..239 progressive, 0..479 woven
    logic        src_x_odd;    // 0: even source pixel (2*x), 1: odd source pixel (2*x+1)
    logic [8:0]  out_x;        // 0..320
    logic [7:0]  r_even, g_even, b_even;

    wire  woven_cur = in_frame ? woven_latched : vga_woven;
    wire  px_valid  = !vga_vsync && vga_de && !vga_skip && !frame_done && (out_x < 9'd320);

    wire [7:0] h_r8 = avg8(r_even, vga_r, hblend_v);
    wire [7:0] h_g8 = avg8(g_even, vga_g, hblend_v);
    wire [7:0] h_b8 = avg8(b_even, vga_b, hblend_v);

    wire       ebuf_we  = px_valid && src_x_odd && woven_cur && !src_y[0];
    wire       ebuf_ren = px_valid && !src_x_odd;

    always_ff @(posedge clk_vid) begin
        if (ebuf_we)
            even_line_buf[out_x] <= {h_r8, h_g8, h_b8};
        if (ebuf_ren)
            even_rgb <= even_line_buf[out_x];
    end

    wire [7:0] final_r8 = woven_cur ? avg8(even_rgb[23:16], h_r8, hblend_v) : h_r8;
    wire [7:0] final_g8 = woven_cur ? avg8(even_rgb[15:8],  h_g8, hblend_v) : h_g8;
    wire [7:0] final_b8 = woven_cur ? avg8(even_rgb[7:0],   h_b8, hblend_v) : h_b8;

    wire [7:0] out_y_cur = woven_cur ? src_y[8:1] : src_y[7:0];
    wire [1:0] bayer2x2  = dither_v ? {out_y_cur[0] ^ out_x[0], out_y_cur[0]} : 2'd0;

    wire [5:0] q_r6 = quant6(final_r8, bayer2x2);
    wire [5:0] q_g6 = quant6(final_g8, bayer2x2);
    wire [5:0] q_b6 = quant6(final_b8, bayer2x2);

    // Dual-clock Gray-code FIFO (32 x 20-bit distributed LUTRAM)
    (* ram_style = "distributed" *) logic [19:0] cdc_mem [0:31];
    logic [5:0] wptr_bin, wptr_gray;
    logic [5:0] rptr_bin, rptr_gray;
    (* ASYNC_REG = "TRUE" *) logic [5:0] rptr_gray_s1, rptr_gray_s2;
    (* ASYNC_REG = "TRUE" *) logic [5:0] wptr_gray_s1, wptr_gray_s2;

    wire fifo_full  = (wptr_gray == {~rptr_gray_s2[5:4], rptr_gray_s2[3:0]});
    wire fifo_empty = (rptr_gray == wptr_gray_s2);

    wire emit_pix   = px_valid && src_x_odd && (!woven_cur || src_y[0]);
    wire emit_vsync = vga_vsync && !vga_vsync_d;
    wire fifo_push  = (emit_vsync || emit_pix) && !fifo_full;

    wire [1:0]  push_tag = emit_vsync ? TAG_VSYNC : ((out_x == 9'd319) ? TAG_EOL : TAG_PIX);
    wire [19:0] fifo_din = emit_vsync ? {TAG_VSYNC, 18'd0} : {push_tag, q_r6, q_g6, q_b6};
    wire [5:0]  wptr_bin_next = wptr_bin + 6'd1;

    always_ff @(posedge clk_vid) begin
        if (v_rst) begin
            vga_de_d      <= 1'b0;
            vga_vsync_d   <= 1'b0;
            in_frame      <= 1'b0;
            frame_done    <= 1'b0;
            woven_latched <= 1'b0;
            src_y         <= 9'd0;
            src_x_odd     <= 1'b0;
            out_x         <= 9'd0;
            r_even        <= 8'd0;
            g_even        <= 8'd0;
            b_even        <= 8'd0;
            wptr_bin      <= 6'd0;
            wptr_gray     <= 6'd0;
            rptr_gray_s1  <= 6'd0;
            rptr_gray_s2  <= 6'd0;
        end else begin
            vga_de_d     <= vga_de;
            vga_vsync_d  <= vga_vsync;
            rptr_gray_s1 <= rptr_gray;
            rptr_gray_s2 <= rptr_gray_s1;

            if (fifo_push) begin
                cdc_mem[wptr_bin[4:0]] <= fifo_din;
                wptr_bin  <= wptr_bin_next;
                wptr_gray <= (wptr_bin_next >> 1) ^ wptr_bin_next;
            end

            if (vga_vsync) begin
                in_frame   <= 1'b0;
                frame_done <= 1'b0;
                src_y      <= 9'd0;
                src_x_odd  <= 1'b0;
                out_x      <= 9'd0;
            end else begin
                if (!in_frame && vga_de && !vga_de_d) begin
                    in_frame      <= 1'b1;
                    woven_latched <= vga_woven;
                end

                if (px_valid) begin
                    if (!src_x_odd) begin
                        r_even    <= vga_r;
                        g_even    <= vga_g;
                        b_even    <= vga_b;
                        src_x_odd <= 1'b1;
                    end else begin
                        src_x_odd <= 1'b0;
                        out_x     <= out_x + 9'd1;
                    end
                end

                // End of active source line
                if (vga_de_d && !vga_de) begin
                    src_x_odd <= 1'b0;
                    out_x     <= 9'd0;
                    if (!frame_done) begin
                        if (src_y == (woven_cur ? 9'd479 : 9'd239))
                            frame_done <= 1'b1;
                        else
                            src_y <= src_y + 9'd1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // clk_sys (62.5 MHz): Game Bub VideoV0 Frame & Line Output Sequencer
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_VBLANK = 2'd0,
        S_ACTIVE = 2'd1,
        S_HBLANK = 2'd2
    } sys_state_t;

    sys_state_t st;
    logic [8:0] sys_x;
    logic [7:0] sys_y;
    logic       eol_pending;

    wire [19:0] fifo_dout = cdc_mem[rptr_bin[4:0]];
    wire [1:0]  dout_tag  = fifo_dout[19:18];
    wire [17:0] dout_rgb  = fifo_dout[17:0];

    logic       fifo_pop;
    always_comb begin
        fifo_pop = 1'b0;
        unique case (st)
            S_VBLANK: begin
                // Discard TAG_VSYNC tokens; hold first active pixel until S_ACTIVE drops vblank/hblank
                if (!fifo_empty && (dout_tag == TAG_VSYNC))
                    fifo_pop = 1'b1;
            end
            S_ACTIVE: begin
                if (!eol_pending && !fifo_empty)
                    fifo_pop = 1'b1;
            end
            S_HBLANK: begin
                // Pop early TAG_VSYNC if frame ended before 240 lines; hold line's first pixel until S_ACTIVE
                if (!fifo_empty && (dout_tag == TAG_VSYNC))
                    fifo_pop = 1'b1;
            end
            default: fifo_pop = 1'b0;
        endcase
    end

    wire [5:0] rptr_bin_next = rptr_bin + 6'd1;

    always_ff @(posedge clk_sys) begin
        if (s_rst) begin
            rptr_bin         <= 6'd0;
            rptr_gray        <= 6'd0;
            wptr_gray_s1     <= 6'd0;
            wptr_gray_s2     <= 6'd0;
            st               <= S_VBLANK;
            sys_x            <= 9'd0;
            sys_y            <= 8'd0;
            eol_pending      <= 1'b0;
            video_data_r     <= 6'd0;
            video_data_g     <= 6'd0;
            video_data_b     <= 6'd0;
            video_dataEnable <= 1'b0;
            video_hblank     <= 1'b1;
            video_vblank     <= 1'b1;
        end else begin
            wptr_gray_s1 <= wptr_gray;
            wptr_gray_s2 <= wptr_gray_s1;

            if (fifo_pop) begin
                rptr_bin  <= rptr_bin_next;
                rptr_gray <= (rptr_bin_next >> 1) ^ rptr_bin_next;
            end

            video_dataEnable <= 1'b0;

            unique case (st)
                S_VBLANK: begin
                    video_vblank <= 1'b1;
                    video_hblank <= 1'b1;
                    sys_x        <= 9'd0;
                    sys_y        <= 8'd0;
                    eol_pending  <= 1'b0;
                    if (!fifo_empty && (dout_tag != TAG_VSYNC)) begin
                        // Line 0 starts: drop BOTH vblank and hblank simultaneously
                        video_vblank <= 1'b0;
                        video_hblank <= 1'b0;
                        st           <= S_ACTIVE;
                    end
                end

                S_ACTIVE: begin
                    if (eol_pending) begin
                        eol_pending  <= 1'b0;
                        video_hblank <= 1'b1;
                        if (sys_y == 8'd239) begin
                            video_vblank <= 1'b1;
                            sys_y        <= 8'd0;
                            st           <= S_VBLANK;
                        end else begin
                            sys_y <= sys_y + 8'd1;
                            st    <= S_HBLANK;
                        end
                    end else if (!fifo_empty) begin
                        if (dout_tag == TAG_VSYNC) begin
                            // Early vsync (mode switch or shortened PAL/blank frame): close frame cleanly
                            video_hblank <= 1'b1;
                            video_vblank <= 1'b1;
                            sys_x        <= 9'd0;
                            sys_y        <= 8'd0;
                            st           <= S_VBLANK;
                        end else begin
                            {video_data_r, video_data_g, video_data_b} <= dout_rgb;
                            video_dataEnable <= 1'b1;
                            sys_x            <= sys_x + 9'd1;
                            if ((dout_tag == TAG_EOL) || (sys_x == 9'd319))
                                eol_pending <= 1'b1;
                        end
                    end
                end

                S_HBLANK: begin
                    video_hblank <= 1'b1;
                    video_vblank <= 1'b0;
                    sys_x        <= 9'd0;
                    eol_pending  <= 1'b0;
                    if (!fifo_empty) begin
                        if (dout_tag == TAG_VSYNC) begin
                            // Early vsync between lines (< 240 lines): close frame cleanly
                            video_vblank <= 1'b1;
                            sys_y        <= 8'd0;
                            st           <= S_VBLANK;
                        end else begin
                            // Next active line (1..239) begins
                            video_hblank <= 1'b0;
                            st           <= S_ACTIVE;
                        end
                    end
                end

                default: begin
                    video_vblank <= 1'b1;
                    video_hblank <= 1'b1;
                    st           <= S_VBLANK;
                end
            endcase
        end
    end

endmodule
`default_nettype wire
