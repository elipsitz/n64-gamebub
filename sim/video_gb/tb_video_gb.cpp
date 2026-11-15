#include "Vvideo_gb_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <deque>

static constexpr int OUT_W = 320;
static constexpr int OUT_H = 240;
static constexpr int OUT_PIXELS = OUT_W * OUT_H;
static constexpr size_t RDRAM_WORDS = 2u << 20; // 8 MiB in 32-bit words

struct Pixel6 {
    uint8_t r, g, b;
    bool operator==(const Pixel6 &o) const { return r == o.r && g == o.g && b == o.b; }
    bool operator!=(const Pixel6 &o) const { return !(*this == o); }
};

static inline uint8_t avg8(uint8_t a, uint8_t b, bool en) {
    return en ? uint8_t((uint16_t(a) + uint16_t(b) + 1u) >> 1) : a;
}

static inline uint8_t quant6(uint8_t c8, int out_x, int out_y, bool dither_en) {
    uint16_t bayer = dither_en ? uint16_t((((out_y & 1) ^ (out_x & 1)) << 1) | (out_y & 1)) : 0u;
    uint16_t s = uint16_t(c8) + bayer;
    return (s > 252u) ? 63u : uint8_t(s >> 2);
}

struct Sim {
    Vvideo_gb_tb_top *dut;
    std::vector<uint32_t> rdram;
    std::deque<std::pair<uint64_t, uint32_t>> rd_pipe;
    uint64_t sys_cyc = 0;

    // Exact HandheldTop.scala capture state
    int fb_x = 0;
    int fb_y = 0;
    int fb_write_idx = 1;
    int last_complete_idx = 0;
    bool prev_vblank = true;
    bool prev_hblank = true;
    bool frame_started = false;

    Pixel6 fb[2][OUT_PIXELS];
    bool   written[2][OUT_PIXELS];
    int    px_count_cur = 0;
    int    last_px_count = 0;
    int    frames_completed = 0;
    int    protocol_errors = 0;
    bool   saw_woven_active = false;

    Sim() : rdram(RDRAM_WORDS, 0) {
        dut = new Vvideo_gb_tb_top;
        std::memset(fb, 0, sizeof(fb));
        std::memset(written, 0, sizeof(written));
    }
    ~Sim() {
        dut->final();
        delete dut;
    }

    void on_sys_posedge() {
        // 1. Sample outputs BEFORE posedge update (synchronous to clk_sys)
        const bool vb = dut->video_vblank;
        const bool hb = dut->video_hblank;
        const bool de = dut->video_dataEnable;
        const uint8_t r6 = dut->video_data_r & 0x3Fu;
        const uint8_t g6 = dut->video_data_g & 0x3Fu;
        const uint8_t b6 = dut->video_data_b & 0x3Fu;

        const bool vblank_edge = vb && !prev_vblank;
        const bool hblank_edge = hb && !prev_hblank;

        if (!dut->rst_sys) {
            if (de) {
                if (vb || hb) {
                    printf("PROTOCOL ERROR: dataEnable=1 while vblank=%d hblank=%d (x=%d y=%d)\n",
                           vb, hb, fb_x, fb_y);
                    protocol_errors++;
                }
                if (!frame_started) {
                    frame_started = true;
                    px_count_cur = 0;
                    std::memset(written[fb_write_idx], 0, sizeof(written[0]));
                    if (fb_x != 0 || fb_y != 0) {
                        printf("PROTOCOL ERROR: first active pixel of frame at (%d, %d), expected (0, 0)!\n",
                               fb_x, fb_y);
                        protocol_errors++;
                    }
                }
                if (fb_x < 0 || fb_x >= OUT_W || fb_y < 0 || fb_y >= OUT_H) {
                    printf("PROTOCOL ERROR: out-of-bounds write at (%d, %d)\n", fb_x, fb_y);
                    protocol_errors++;
                } else {
                    int addr = fb_y * OUT_W + fb_x;
                    if (written[fb_write_idx][addr]) {
                        printf("PROTOCOL ERROR: duplicate pixel write at (%d, %d)\n", fb_x, fb_y);
                        protocol_errors++;
                    }
                    fb[fb_write_idx][addr] = {r6, g6, b6};
                    written[fb_write_idx][addr] = true;
                    px_count_cur++;
                }
            }

            if (vblank_edge) {
                if (frame_started) {
                    last_complete_idx = fb_write_idx;
                    last_px_count = px_count_cur;
                    fb_write_idx ^= 1;
                    frames_completed++;
                }
                frame_started = false;
            }

            // Exact HandheldTop.scala coordinate update
            if (vb) {
                fb_x = 0;
                fb_y = 0;
            } else if (hb) {
                if (hblank_edge) {
                    if (frame_started && fb_x != OUT_W) {
                        printf("PROTOCOL ERROR: hblank_edge at fb_x=%d (expected %d) on line %d\n",
                               fb_x, OUT_W, fb_y);
                        protocol_errors++;
                    }
                    fb_x = 0;
                    fb_y++;
                }
            } else if (de) {
                fb_x++;
            }
        }

        prev_vblank = vb;
        prev_hblank = hb;

        // 2. Drive RDRAM read port (pipelined 3-cycle SDRAM read latency)
        const bool req_accept = dut->m_valid && dut->m_ready;
        const uint32_t req_addr = dut->m_addr & (RDRAM_WORDS - 1u);
        if (!dut->rst_sys && req_accept) {
            rd_pipe.push_back({sys_cyc + 3, rdram[req_addr]});
        }
    }

    void update_rdram_outputs() {
        dut->m_ready = 1;
        if (!rd_pipe.empty() && rd_pipe.front().first <= sys_cyc) {
            dut->m_rvalid = 1;
            dut->m_rdata = rd_pipe.front().second;
            rd_pipe.pop_front();
        } else {
            dut->m_rvalid = 0;
            dut->m_rdata = 0;
        }
    }

    // Advance one 4 ns sub-tick:
    //   clk_sys (62.5 MHz, 16 ns period): toggles every 2 sub-ticks (rising at sub % 4 == 2)
    //   clk_vid (25.0 MHz, 40 ns period): toggles every 5 sub-ticks (rising at sub % 10 == 5)
    uint64_t sub_tick = 0;
    void step_4ns() {
        sub_tick++;
        bool sys_toggle = (sub_tick % 2 == 0);
        bool vid_toggle = (sub_tick % 5 == 0);
        if (!sys_toggle && !vid_toggle) return;

        bool next_sys = sys_toggle ? !dut->clk_sys : dut->clk_sys;
        bool next_vid = vid_toggle ? !dut->clk_vid : dut->clk_vid;

        bool sys_pos = (!dut->clk_sys && next_sys);
        bool vid_pos = (!dut->clk_vid && next_vid);

        dut->eval();
        if (sys_pos) on_sys_posedge();

        dut->clk_sys = next_sys;
        dut->clk_vid = next_vid;
        dut->eval();

        if (vid_pos && dut->vga_de && dut->vga_woven)
            saw_woven_active = true;

        if (sys_pos) {
            sys_cyc++;
            update_rdram_outputs();
            dut->eval();
        }
    }

    void run_until_next_frame(uint64_t max_sys_cycles = 3000000) {
        int target = frames_completed + 1;
        uint64_t start = sys_cyc;
        while (frames_completed < target && (sys_cyc - start) < max_sys_cycles) {
            step_4ns();
        }
    }
};

static inline uint32_t pack_rgba8888(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t(r) << 24) | (uint32_t(g) << 16) | (uint32_t(b) << 8) | 0xFFu;
}

static void fill_pattern_640x240(std::vector<uint32_t> &rdram, std::vector<Pixel6> &expected,
                                 bool hblend, bool dither) {
    expected.resize(OUT_PIXELS);
    for (int y = 0; y < 240; y++) {
        for (int x = 0; x < 320; x++) {
            uint8_t r0, g0, b0, r1, g1, b1;
            if (x < 16 && y < 16) {
                // Top-left bright white 255 clamp check (must stay 63,63,63 even with Bayer dither=3!)
                r0 = g0 = b0 = 255;
                r1 = g1 = b1 = 255;
            } else if (x >= 304 && y < 16) {
                // Top-right pure black 0 check
                r0 = g0 = b0 = 0;
                r1 = hblend ? 0 : 213; // Poison odd pixel when !hblend to prove crisp nearest-neighbor!
                g1 = hblend ? 0 : 199;
                b1 = hblend ? 0 : 251;
            } else if (x == 0 && y == 239) {
                // Bottom-left sentinel
                r0 = 252; g0 = 12; b0 = 180;
                r1 = hblend ? 252 : 77; g1 = hblend ? 12 : 240; b1 = hblend ? 180 : 3;
            } else if (x == 319 && y == 239) {
                // Bottom-right sentinel
                r0 = 20; g0 = 255; b0 = 100;
                r1 = hblend ? 60 : 250; g1 = hblend ? 255 : 5; b1 = hblend ? 140 : 9;
            } else {
                r0 = uint8_t((x * 5 + y * 3 + 17) & 0xFF);
                g0 = uint8_t((x * 3 + y * 7 + 91) & 0xFF);
                b0 = uint8_t((x * 11 + y * 2 + 43) & 0xFF);
                if (hblend) {
                    r1 = uint8_t((x * 7 + y * 5 + 200) & 0xFF);
                    g1 = uint8_t((x * 13 + y * 3 + 55) & 0xFF);
                    b1 = uint8_t((x * 2 + y * 9 + 129) & 0xFF);
                } else {
                    // Deliberately different odd column to verify horiz_blend_en=0 ignores 2*x+1
                    r1 = uint8_t(~r0);
                    g1 = uint8_t(~g0);
                    b1 = uint8_t(~b0);
                }
            }
            rdram[y * 640 + 2 * x + 0] = pack_rgba8888(r0, g0, b0);
            rdram[y * 640 + 2 * x + 1] = pack_rgba8888(r1, g1, b1);

            uint8_t hr = avg8(r0, r1, hblend);
            uint8_t hg = avg8(g0, g1, hblend);
            uint8_t hb = avg8(b0, b1, hblend);
            expected[y * OUT_W + x] = {
                quant6(hr, x, y, dither),
                quant6(hg, x, y, dither),
                quant6(hb, x, y, dither)
            };
        }
    }
}

static void fill_pattern_640x480_woven(std::vector<uint32_t> &rdram, std::vector<Pixel6> &expected,
                                       bool hblend, bool dither) {
    expected.resize(OUT_PIXELS);
    for (int y = 0; y < 240; y++) {
        for (int x = 0; x < 320; x++) {
            uint8_t r00, g00, b00, r01, g01, b01;
            uint8_t r10, g10, b10, r11, g11, b11;
            if (x < 16 && y < 16) {
                r00 = g00 = b00 = r01 = g01 = b01 = 255;
                r10 = g10 = b10 = r11 = g11 = b11 = 255;
            } else if (x == 319 && y == 239) {
                r00 = 240; g00 = 80;  b00 = 20;
                r01 = 200; g01 = 120; b01 = 60;
                r10 = 160; g10 = 160; b10 = 100;
                r11 = 120; g11 = 200; b11 = 140;
            } else {
                r00 = uint8_t((x * 7 + y * 5 + 11) & 0xFF);
                g00 = uint8_t((x * 3 + y * 11 + 67) & 0xFF);
                b00 = uint8_t((x * 9 + y * 3 + 145) & 0xFF);
                if (hblend) {
                    r01 = uint8_t((x * 5 + y * 9 + 88) & 0xFF);
                    g01 = uint8_t((x * 11 + y * 7 + 31) & 0xFF);
                    b01 = uint8_t((x * 3 + y * 13 + 210) & 0xFF);
                    r10 = uint8_t((x * 13 + y * 3 + 170) & 0xFF);
                    g10 = uint8_t((x * 5 + y * 17 + 99) & 0xFF);
                    b10 = uint8_t((x * 7 + y * 5 + 19) & 0xFF);
                    r11 = uint8_t((x * 2 + y * 7 + 233) & 0xFF);
                    g11 = uint8_t((x * 9 + y * 2 + 151) & 0xFF);
                    b11 = uint8_t((x * 15 + y * 11 + 72) & 0xFF);
                } else {
                    r01 = uint8_t(~r00); g01 = uint8_t(~g00); b01 = uint8_t(~b00);
                    r10 = uint8_t(r00 ^ 0x55); g10 = uint8_t(g00 ^ 0x55); b10 = uint8_t(b00 ^ 0x55);
                    r11 = uint8_t(r00 ^ 0xAA); g11 = uint8_t(g00 ^ 0xAA); b11 = uint8_t(b00 ^ 0xAA);
                }
            }
            rdram[(2 * y + 0) * 640 + 2 * x + 0] = pack_rgba8888(r00, g00, b00);
            rdram[(2 * y + 0) * 640 + 2 * x + 1] = pack_rgba8888(r01, g01, b01);
            rdram[(2 * y + 1) * 640 + 2 * x + 0] = pack_rgba8888(r10, g10, b10);
            rdram[(2 * y + 1) * 640 + 2 * x + 1] = pack_rgba8888(r11, g11, b11);

            uint8_t er = avg8(r00, r01, hblend);
            uint8_t eg = avg8(g00, g01, hblend);
            uint8_t eb = avg8(b00, b01, hblend);

            uint8_t or8 = avg8(r10, r11, hblend);
            uint8_t og8 = avg8(g10, g11, hblend);
            uint8_t ob8 = avg8(b10, b11, hblend);

            uint8_t vr = avg8(er, or8, hblend);
            uint8_t vg = avg8(eg, og8, hblend);
            uint8_t vb = avg8(eb, ob8, hblend);

            expected[y * OUT_W + x] = {
                quant6(vr, x, y, dither),
                quant6(vg, x, y, dither),
                quant6(vb, x, y, dither)
            };
        }
    }
}

static int verify_frame(const char *name, const Sim &sim, const std::vector<Pixel6> &expected) {
    int fails = 0;
    if (sim.last_px_count != OUT_PIXELS) {
        printf("FAIL [%s]: captured %d pixels, expected %d\n", name, sim.last_px_count, OUT_PIXELS);
        fails++;
    }
    int mism = 0;
    for (int y = 0; y < OUT_H; y++) {
        for (int x = 0; x < OUT_W; x++) {
            int idx = y * OUT_W + x;
            if (!sim.written[sim.last_complete_idx][idx]) {
                if (mism < 8)
                    printf("FAIL [%s]: pixel (%d, %d) was never written!\n", name, x, y);
                mism++;
                continue;
            }
            const Pixel6 &got = sim.fb[sim.last_complete_idx][idx];
            const Pixel6 &exp = expected[idx];
            if (got != exp) {
                if (mism < 8)
                    printf("FAIL [%s]: mismatch at (%d, %d): got (%u,%u,%u), expected (%u,%u,%u)\n",
                           name, x, y, got.r, got.g, got.b, exp.r, exp.g, exp.b);
                mism++;
            }
        }
    }
    // Explicitly verify white 255 -> (63, 63, 63) across top-left 16x16 patch
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            const Pixel6 &got = sim.fb[sim.last_complete_idx][y * OUT_W + x];
            if (got.r != 63 || got.g != 63 || got.b != 63) {
                printf("FAIL [%s]: white 255 clamp failed at (%d, %d): got (%u,%u,%u)\n",
                       name, x, y, got.r, got.g, got.b);
                fails++;
                break;
            }
        }
    }
    if (mism > 0) fails++;
    printf("[%s] pixels=%d/%d mismatches=%d protocol_errors=%d -> %s\n",
           name, sim.last_px_count, OUT_PIXELS, mism, sim.protocol_errors,
           (fails == 0 && sim.protocol_errors == 0) ? "PASS" : "FAIL");
    return fails + sim.protocol_errors;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Sim sim;
    auto *d = sim.dut;

    // Configure baseline 640x240 RGBA8888 progressive scan-out
    d->clk_sys = 0;
    d->clk_vid = 0;
    d->rst_sys = 1;
    d->rst_vid = 1;
    d->enable = 1;
    d->vi_origin = 0;
    d->vi_il = 0;
    d->no_weave = 0;
    d->vi_width = 640;
    d->vi_px32 = 1;
    d->vi_black = 0;
    d->vi_pal = 0;
    d->vi_out32 = 1;
    d->vi_lines = 240;
    d->vi_px0 = 0;
    d->vi_pw = 640;
    d->vi_y0 = 0;
    d->vi_rows = 240;
    d->vi_xs = 0x400;
    d->vi_ys = 0x400;
    d->vi_nw = 648;
    d->horiz_blend_en = 0;
    d->dither_en = 0;

    std::vector<Pixel6> expected;
    int total_fails = 0;

    // Hold reset for 40 sub-ticks, then release
    for (int i = 0; i < 40; i++) sim.step_4ns();
    d->rst_sys = 0;
    d->rst_vid = 0;

    // -------------------------------------------------------------------------
    // Test 1: 640x240 Progressive, horiz_blend=0, dither=0 (Crisp Nearest)
    //   Note: Frame 1 in n64_video is before the first fb_vid latch (blank),
    //   Frame 2 scans out the full RDRAM framebuffer!
    // -------------------------------------------------------------------------
    fill_pattern_640x240(sim.rdram, expected, /*hblend=*/false, /*dither=*/false);
    sim.run_until_next_frame(); // initial blank frame before first fb_vid latch
    sim.run_until_next_frame(); // active picture frame
    total_fails += verify_frame("640x240_prog_nearest_nodither", sim, expected);

    // -------------------------------------------------------------------------
    // Test 2: 640x240 Progressive, horiz_blend=1, dither=1 (Blended + Bayer 2x2)
    // -------------------------------------------------------------------------
    d->horiz_blend_en = 1;
    d->dither_en = 1;
    fill_pattern_640x240(sim.rdram, expected, /*hblend=*/true, /*dither=*/true);
    sim.run_until_next_frame(); // frame already latched before switch
    sim.run_until_next_frame(); // full blended + dithered frame
    total_fails += verify_frame("640x240_prog_hblend_bayer2x2", sim, expected);

    // -------------------------------------------------------------------------
    // Test 3: 640x480 Woven Hi-Res, horiz_blend=1, dither=1 (2x2 Box Supersample)
    // -------------------------------------------------------------------------
    d->vi_il = 1;
    d->no_weave = 0;
    d->vi_width = 640;
    d->vi_ys = 0x800;
    d->horiz_blend_en = 1;
    d->dither_en = 1;
    sim.saw_woven_active = false;
    fill_pattern_640x480_woven(sim.rdram, expected, /*hblend=*/true, /*dither=*/true);
    sim.run_until_next_frame(); // finish current progressive frame
    sim.run_until_next_frame(); // mode-announcement blank woven frame
    sim.run_until_next_frame(); // full 640x480 woven supersampled frame!
    if (!sim.saw_woven_active) {
        printf("FAIL [640x480_woven_2x2_bayer2x2]: vga_woven was never active!\n");
        total_fails++;
    }
    total_fails += verify_frame("640x480_woven_2x2_bayer2x2", sim, expected);

    // -------------------------------------------------------------------------
    // Test 4: 640x480 Woven Hi-Res, horiz_blend=0, dither=0 + live return to 640x240
    // -------------------------------------------------------------------------
    d->horiz_blend_en = 0;
    d->dither_en = 0;
    fill_pattern_640x480_woven(sim.rdram, expected, /*hblend=*/false, /*dither=*/false);
    sim.run_until_next_frame();
    sim.run_until_next_frame();
    total_fails += verify_frame("640x480_woven_nearest_nodither", sim, expected);

    // Live switch back to 640x240 progressive to verify zero frame-sync drift
    d->vi_il = 0;
    d->vi_ys = 0x400;
    d->horiz_blend_en = 1;
    d->dither_en = 1;
    fill_pattern_640x240(sim.rdram, expected, /*hblend=*/true, /*dither=*/true);
    sim.run_until_next_frame();
    sim.run_until_next_frame();
    sim.run_until_next_frame();
    total_fails += verify_frame("640x240_post_modeswitch_recovery", sim, expected);

    printf("\ntb_video_gb summary: %d total frames captured, %d protocol errors, result = %s\n",
           sim.frames_completed, sim.protocol_errors, total_fails == 0 ? "ALL PASS" : "FAILED");
    return total_fails == 0 ? 0 : 1;
}
