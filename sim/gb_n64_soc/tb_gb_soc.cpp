// Full-SoC End-to-End Verilator Testbench (`sim/gb_n64_soc/tb_gb_soc.cpp`)
//
// Instantiates `gb_soc_tb_top` (`n64_gamebub_top` / `n64_mem_diag_top`) with:
//   - Cycle-accurate dual-rank Winbond W9825G6KH-6 (64 MiB @ 125 MHz) + AC assertions
//   - Cycle-accurate ISSI IS61WV25616EDBLL-10TLI (512 KiB @ 10 ns) + AC/glitch assertions
//   - Exact 93.75 MHz (`clk_cpu`, 3:2) / 62.5 MHz (`clk_sys`) / 125 MHz (`clk_sys2x`, 2:1) /
//     25 MHz (`clk_vid`, 2:5) clock tree stepping
//   - Full Game Bub MCU `HostV0` BFM (`commandHost`, `host_mem`, `settings.json`,
//     eager `FileWriteStart`/`FileReadStart`, and Phase-5 `commandCore` `0x0400..0x0404`)
//   - `VideoV0` (320x240 RGB666 frame capture), `AudioV0` (48 kHz), and `VibrateV0` checkers

#include "Vgb_soc_tb_top.h"
#include "verilated.h"

#include <cassert>
#include <cinttypes>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vgb_soc_tb_top *dut = nullptr;

static long g_cyc2x       = 0; // 125.0 MHz ticks (8.0 ns each)
static long g_sys         = 0; //  62.5 MHz ticks (16.0 ns each)
static long g_cpu_t       = 0; //  sub-tick cursor for 3:2 93.75 MHz CPU clock
static int  g_vid_phase   = 0; //  0..4 divider for 25.0 MHz clk_vid
static long g_ac_errors   = 0;
static long g_test_errors = 0;

static constexpr long SDR_PS   = 8000;
static constexpr int  TB_CPU_N = 3;
static constexpr int  TB_CPU_M = 2;

static void fail_msg(long *cnt, const char *tag, const char *fmt, ...) {
    (*cnt)++;
    if (*cnt <= 24) {
        fprintf(stderr, "[%s FAIL @ sys=%ld cyc2x=%ld] ", tag, g_sys, g_cyc2x);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(stderr, fmt, ap);
        va_end(ap);
        fprintf(stderr, "\n");
    }
}

#define AC_ERR(...)   fail_msg(&g_ac_errors,   "AC",   __VA_ARGS__)
#define TEST_ERR(...) fail_msg(&g_test_errors, "TEST", __VA_ARGS__)

static long cyc_of(double ns) {
    return (long)((ns * 1000.0 + SDR_PS - 1) / SDR_PS);
}

// ============================================================================
// 1. Dual Winbond W9825G6KH-6 (2 x 32 MiB = 64 MiB) Model + AC Assertions
// ============================================================================
struct W9825Chip {
    int rank_id = 0;
    std::vector<uint16_t> mem;
    int  opened[4] = {0, 0, 0, 0};
    int  rows[4]   = {0, 0, 0, 0};
    long t_act[4]  = {-1000, -1000, -1000, -1000};
    long t_pre[4]  = {-1000, -1000, -1000, -1000};
    long t_wr[4]   = {-1000, -1000, -1000, -1000};
    long t_ref     = -1000;
    long t_mrs     = -1000;
    long t_actany  = -1000;
    long wburst    = -1;

    long     pend_c[8] = {-1, -1, -1, -1, -1, -1, -1, -1};
    uint16_t pend_v[8] = {0};
    int      pend_b[8] = {0};

    long cnt_rd = 0, cnt_wr = 0;

    explicit W9825Chip(int id) : rank_id(id), mem(4u * 8192u * 512u, 0) {}

    static uint32_t key(int ba, int row, int col) {
        return ((uint32_t)(ba & 3) << 22) | ((uint32_t)(row & 0x1fff) << 9) | (uint32_t)(col & 0x1ff);
    }

    void store_half(uint32_t k, uint16_t dq, int dm) {
        uint16_t v = mem[k];
        if (!(dm & 1)) v = (v & 0xff00u) | (dq & 0x00ffu);
        if (!(dm & 2)) v = (v & 0x00ffu) | (dq & 0xff00u);
        mem[k] = v;
    }

    void step_and_check() {
        static const long N_RCD = cyc_of(18.0);
        static const long N_RP  = cyc_of(18.0);
        static const long N_RAS = cyc_of(42.0);
        static const long N_RC  = cyc_of(60.0);
        static const long N_RFC = cyc_of(60.0);
        static const long N_RRD = cyc_of(12.0);
        static const long N_WR  = cyc_of(16.0);
        static const long N_MRD = 2;

        const int  ba  = dut->sdram_ba & 3;
        const int  a   = dut->sdram_a & 0x1fff;
        const int  dm  = dut->sdram_dm & 3;
        const bool oe  = dut->sdram_dq_oe != 0;
        const uint16_t dq = dut->sdram_dq_out;
        const bool cke = ((dut->sdram_cke >> rank_id) & 1) != 0;
        const bool sel = ((dut->sdram_cs_n >> rank_id) & 1) == 0;

        if (wburst >= 0) {
            if (!oe) AC_ERR("SDRAM rank %d: write beat 2 without oe", rank_id);
            store_half((uint32_t)wburst, dq, dm);
            wburst = -1;
        }
        for (int i = 0; i < 8; i++) {
            if (pend_c[i] == g_cyc2x && oe)
                AC_ERR("SDRAM rank %d: DQ bus contention", rank_id);
        }
        if (!cke || !sel) return;

        const int cmd = ((dut->sdram_ras_n & 1) << 2) |
                        ((dut->sdram_cas_n & 1) << 1) |
                        (dut->sdram_we_n & 1);
        if (cmd != 7 && (g_cyc2x - t_ref) < N_RFC) AC_ERR("SDRAM rank %d: tRFC violation", rank_id);
        if (cmd != 7 && (g_cyc2x - t_mrs) < N_MRD) AC_ERR("SDRAM rank %d: tMRD violation", rank_id);

        switch (cmd) {
            case 3:
                if (opened[ba]) AC_ERR("SDRAM rank %d: ACT open bank %d", rank_id, ba);
                if (g_cyc2x - t_pre[ba] < N_RP) AC_ERR("SDRAM rank %d: tRP violation", rank_id);
                if (g_cyc2x - t_actany < N_RRD) AC_ERR("SDRAM rank %d: tRRD violation", rank_id);
                if (g_cyc2x - t_act[ba] < N_RC)  AC_ERR("SDRAM rank %d: tRC violation", rank_id);
                opened[ba] = 1; rows[ba] = a; t_act[ba] = g_cyc2x; t_actany = g_cyc2x;
                break;
            case 2:
                for (int b = 0; b < 4; b++) {
                    if ((a & 0x400) || b == ba) {
                        if (opened[b] && (g_cyc2x - t_act[b]) < N_RAS) AC_ERR("SDRAM rank %d: tRAS violation", rank_id);
                        if (opened[b] && (g_cyc2x - t_wr[b])  < N_WR)  AC_ERR("SDRAM rank %d: tWR violation", rank_id);
                        opened[b] = 0; t_pre[b] = g_cyc2x;
                    }
                }
                break;
            case 4: {
                if (!opened[ba]) AC_ERR("SDRAM rank %d: WRITE closed bank %d", rank_id, ba);
                if ((g_cyc2x - t_act[ba]) < N_RCD) AC_ERR("SDRAM rank %d: tRCD violation", rank_id);
                if (a & 0x600) AC_ERR("SDRAM rank %d: WRITE bad col 0x%x", rank_id, a);
                int col = a & 0x1ff;
                store_half(key(ba, rows[ba], col), dq, dm);
                wburst   = (long)key(ba, rows[ba], col ^ 1);
                t_wr[ba] = g_cyc2x + 1;
                cnt_wr++;
                break;
            }
            case 5: {
                if (!opened[ba]) AC_ERR("SDRAM rank %d: READ closed bank %d", rank_id, ba);
                if ((g_cyc2x - t_act[ba]) < N_RCD) AC_ERR("SDRAM rank %d: tRCD violation", rank_id);
                if (a & 0x600) AC_ERR("SDRAM rank %d: READ bad col 0x%x", rank_id, a);
                int col = a & 0x1ff;
                for (int k = 0; k < 2; k++) {
                    int s = (int)((g_cyc2x + 3 + k) & 7);
                    pend_c[s] = g_cyc2x + 3 + k;
                    pend_v[s] = mem[key(ba, rows[ba], col ^ k)];
                    pend_b[s] = ba;
                }
                cnt_rd++;
                break;
            }
            case 1:
                for (int b = 0; b < 4; b++) if (opened[b]) AC_ERR("SDRAM rank %d: REF open bank", rank_id);
                t_ref = g_cyc2x;
                break;
            case 0:
                t_mrs = g_cyc2x;
                break;
            case 7:
                break;
            default:
                AC_ERR("SDRAM rank %d: illegal cmd %d", rank_id, cmd);
                break;
        }
    }
};

static W9825Chip g_sdr[2] = { W9825Chip(0), W9825Chip(1) };

static uint32_t hmap(uint32_t a) {
    if ((a >> 18) == 0x37u) {
        uint32_t hi = (a >> 10) & 0x3FFFu;
        uint32_t b65 = ((a >> 5) & 3u) ^ 2u;
        uint32_t b7  = (a >> 7) & 1u;
        uint32_t b98 = (a >> 8) & 3u;
        uint32_t lo  = a & 0x1Fu;
        return (hi << 10) | (b65 << 8) | (b7 << 7) | (b98 << 5) | lo;
    }
    return a & 0xFFFFFFu;
}

static uint32_t sdr_peek_word(uint32_t log_w) {
    uint32_t pw = hmap(log_w);
    int rank = (pw >> 23) & 1;
    int row  = (pw >> 10) & 0x1fff;
    int ba   = (pw >> 8)  & 3;
    int col0 = (pw & 0xff) << 1;
    uint16_t lo = g_sdr[rank].mem[W9825Chip::key(ba, row, col0)];
    uint16_t hi = g_sdr[rank].mem[W9825Chip::key(ba, row, col0 | 1)];
    return ((uint32_t)hi << 16) | lo;
}

static void sdr_poke_word(uint32_t log_w, uint32_t val) {
    uint32_t pw = hmap(log_w);
    int rank = (pw >> 23) & 1;
    int row  = (pw >> 10) & 0x1fff;
    int ba   = (pw >> 8)  & 3;
    int col0 = (pw & 0xff) << 1;
    g_sdr[rank].mem[W9825Chip::key(ba, row, col0)]     = (uint16_t)(val & 0xffffu);
    g_sdr[rank].mem[W9825Chip::key(ba, row, col0 | 1)] = (uint16_t)(val >> 16);
}

static void sdram_bus_step() {
    g_sdr[0].step_and_check();
    g_sdr[1].step_and_check();
    bool drv[2] = {false, false};
    uint16_t val[2] = {0, 0};
    for (int r = 0; r < 2; r++) {
        for (int i = 0; i < 8; i++) {
            if (g_sdr[r].pend_c[i] == g_cyc2x) {
                drv[r] = true; val[r] = g_sdr[r].pend_v[i]; g_sdr[r].pend_c[i] = -1;
            }
        }
    }
    if (drv[0] && drv[1]) AC_ERR("SDRAM Rank 0 & 1 contention");
    dut->sdram_dq_in = drv[0] ? val[0] : (drv[1] ? val[1] : 0xBEEFu);
}

// ============================================================================
// 2. ISSI IS61WV25616EDBLL-10TLI (512 KiB, 10 ns) Async SRAM Model + AC Checks
// ============================================================================
struct AsyncSramModel {
    std::vector<uint16_t> mem;
    bool     we_active      = false;
    long     we_start_cyc   = -1000;
    uint32_t latched_addr   = 0;
    uint16_t latched_dout   = 0;
    uint8_t  latched_mask_n = 3;
    uint32_t prev_addr      = 0xFFFFFFFFu;
    bool     prev_rd_en     = false;
    int      rd_stable_cycs = 0;
    bool     was_ce_n       = true;
    uint32_t was_addr       = 0;
    uint16_t was_dout       = 0;
    uint8_t  was_mask_n     = 3;
    bool     was_dir        = false;
    long     cnt_l2_reads   = 0;

    AsyncSramModel() : mem(262144u, 0xFF00u) {
        std::fill(mem.begin(), mem.end(), 0xFFFFu);
    }

    void step() {
        const bool     ce_n   = dut->sram_ceN != 0;
        const bool     we_n   = dut->sram_weN != 0;
        const bool     oe_n   = dut->sram_oeN != 0;
        const uint8_t  mask_n = dut->sram_writeMaskN & 3;
        const uint32_t addr   = dut->sram_address & 0x3FFFFu;
        const uint16_t dout   = dut->sram_dataOut;
        const bool     dir    = dut->sram_dataDir != 0;

        if (!ce_n && !oe_n && we_n && (mask_n != 3) && dir)
            AC_ERR("SRAM DQ contention");

        const bool wr_now = (!ce_n && !we_n);
        if (wr_now) {
            if (!oe_n || !dir || mask_n == 3) AC_ERR("SRAM bad write control signals");
            if (!we_active) {
                if (was_ce_n || was_addr != addr || was_dout != dout || was_mask_n != mask_n || !was_dir)
                    AC_ERR("SRAM write setup < 8ns");
                we_active = true; we_start_cyc = g_cyc2x;
                latched_addr = addr; latched_dout = dout; latched_mask_n = mask_n;
            } else {
                if (addr != latched_addr || dout != latched_dout || mask_n != latched_mask_n)
                    AC_ERR("SRAM write GLITCH while WE#=0");
            }
        } else if (we_active) {
            if ((g_cyc2x - we_start_cyc) * 8.0 < 7.0) AC_ERR("SRAM tWP < 7ns");
            if (addr != latched_addr || dout != latched_dout || mask_n != latched_mask_n || ce_n || !dir)
                AC_ERR("SRAM write hold violation on WE# rise");
            uint16_t cur = mem[latched_addr];
            if (!(latched_mask_n & 2)) cur = (cur & 0x00FFu) | (latched_dout & 0xFF00u);
            if (!(latched_mask_n & 1)) cur = (cur & 0xFF00u) | (latched_dout & 0x00FFu);
            mem[latched_addr] = cur;
            we_active = false;
        }

        const bool rd_now = (!ce_n && !oe_n && we_n && (mask_n == 0));
        if (rd_now) {
            if (prev_rd_en && addr == prev_addr) {
                rd_stable_cycs++;
                if (rd_stable_cycs == 2 && addr >= (0x1A000u << 1)) cnt_l2_reads++;
            } else {
                rd_stable_cycs = 1;
            }
            dut->sram_dataIn = (rd_stable_cycs >= 2) ? mem[addr] : (uint16_t)0xBAD0u;
        } else {
            rd_stable_cycs   = 0;
            dut->sram_dataIn = 0xDEADu;
        }
        prev_rd_en = rd_now; prev_addr = addr;
        was_ce_n = ce_n; was_addr = addr; was_dout = dout; was_mask_n = mask_n; was_dir = dir;
    }
};

static AsyncSramModel g_sram;

// ============================================================================
// 3. VideoV0 / AudioV0 / VibrateV0 / UART Monitors + Core->Host On-Demand BFM
// ============================================================================
static std::string g_uart_log;
static bool        g_saw_eot          = false;
static long        g_vid_frames       = 0;
static long        g_cur_frame_pixels = 0;
static long        g_last_frame_pixels= 0;
static long        g_nonblack_pixels  = 0;
static bool        g_prev_vblank      = true;
static bool        g_prev_hblank      = true;
static int         g_fb_x             = 0;
static int         g_fb_y             = 0;
static uint8_t     g_fb_cur[320 * 240 * 3];
static uint8_t     g_fb_latched[320 * 240 * 3];
static bool        g_fb_has_frame     = false;
static long        g_nonzero_audio    = 0;
static long        g_vibrate_cycles   = 0;
static int         g_wav_acc          = 0;
static bool        g_wav_en           = false;
static std::vector<int16_t> g_wav_pcm; // interleaved L, R @ 48,000 Hz
static std::string g_dump_dir;
static long        g_dump_every       = 0;
static std::string g_od_loading_ppm;

struct HostFile {
    bool                 present   = false;
    bool                 on_demand = false;
    uint32_t             load_addr = 0;
    std::vector<uint8_t> data;
};
static HostFile g_files[16];
static long     g_cmd_core_getsize_cnt = 0;
static long     g_cmd_core_read_cnt    = 0;

static uint32_t read_le32(const std::vector<uint8_t> &buf, size_t off) {
    uint32_t v = 0;
    for (size_t k = 0; k < 4; k++) {
        uint8_t b = (off + k < buf.size()) ? buf[off + k] : 0;
        v |= ((uint32_t)b) << (8 * k);
    }
    return v;
}

static uint32_t read_be32(const std::vector<uint8_t> &buf, size_t off) {
    uint32_t v = 0;
    for (size_t k = 0; k < 4; k++) {
        uint8_t b = (off + k < buf.size()) ? buf[off + k] : 0;
        v = (v << 8) | b;
    }
    return v;
}

// Forward decl for single sys-cycle stepper
static void step_sys_cycle();

// ============================================================================
// 4. HostV0 Primitive Transactions (synchronous to `clk_sys`)
// ============================================================================
static void host_mem_wr(uint32_t addr, uint32_t data) {
    dut->host_mem_address   = addr;
    dut->host_mem_dataWrite = data;
    dut->host_mem_write     = 1;
    dut->host_mem_enable    = 1;
    for (int t = 0; t < 2000; t++) {
        step_sys_cycle();
        if (dut->host_mem_done) break;
    }
    if (!dut->host_mem_done) TEST_ERR("host_mem_wr timeout @ 0x%08x", addr);
    dut->host_mem_enable = 0;
    dut->host_mem_write  = 0;
    step_sys_cycle();
}

static uint32_t host_mem_rd(uint32_t addr) {
    dut->host_mem_address = addr;
    dut->host_mem_write   = 0;
    dut->host_mem_enable  = 1;
    for (int t = 0; t < 2000; t++) {
        step_sys_cycle();
        if (dut->host_mem_done) break;
    }
    uint32_t val = dut->host_mem_dataRead;
    if (!dut->host_mem_done) TEST_ERR("host_mem_rd timeout @ 0x%08x", addr);
    dut->host_mem_enable = 0;
    step_sys_cycle();
    return val;
}

static uint32_t host_cmd(uint16_t cmd, uint32_t arg1 = 0, uint32_t arg2 = 0) {
    host_mem_wr(0xF0000000u, cmd);
    host_mem_wr(0xF0000004u, arg1);
    host_mem_wr(0xF0000008u, arg2);
    dut->host_commandHost_request = 1;
    for (int t = 0; t < 1000; t++) {
        step_sys_cycle();
        if (dut->host_commandHost_done) break;
    }
    if (!dut->host_commandHost_done) TEST_ERR("host_cmd 0x%04x timeout", cmd);
    dut->host_commandHost_request = 0;
    step_sys_cycle();
    return host_mem_rd(0xF0000000u);
}

// Service a pending `host_commandCore_request` (Phase-5 on_demand 0x0400..0x0404)
static bool g_in_cmd_core = false;
static void service_command_core_if_pending() {
    if (g_in_cmd_core || !dut->host_commandCore_request) return;
    g_in_cmd_core = true;

    dut->host_commandCore_busy = 1;
    uint32_t op   = host_mem_rd(0xF0001000u);
    uint32_t fid  = host_mem_rd(0xF0001004u) & 0xFFFFu;
    uint32_t arg2 = host_mem_rd(0xF0001008u);
    uint32_t arg3 = host_mem_rd(0xF000100Cu);
    uint32_t arg5 = host_mem_rd(0xF0001014u);

    if (op == 0x0400u) { // FileGetSize
        g_cmd_core_getsize_cnt++;
        uint32_t sz = (fid < 16 && g_files[fid].present) ? (uint32_t)g_files[fid].data.size() : 0u;
        host_mem_wr(0xF0001000u, (fid < 16 && g_files[fid].present) ? 0u : 3u);
        host_mem_wr(0xF0001004u, sz);
        host_mem_wr(0xF0001008u, 0u);
    } else if (op == 0x0401u) { // FileSetSize
        if (fid < 16 && g_files[fid].present) g_files[fid].data.resize(arg2, 0xFFu);
        host_mem_wr(0xF0001000u, 0u);
    } else if (op == 0x0402u) { // FileRead: dest=arg2, file_off=arg3, len=arg5
        g_cmd_core_read_cnt++;
        if (!g_od_loading_ppm.empty() && g_cmd_core_read_cnt == 5) {
            std::string out_path = g_od_loading_ppm;
            g_od_loading_ppm.clear();
            long target_f = g_vid_frames + 2;
            long flim = g_sys + 3000000L;
            while (g_sys < flim && g_vid_frames < target_f) step_sys_cycle();
            FILE *lfp = fopen(out_path.c_str(), "wb");
            if (lfp) {
                fprintf(lfp, "P6\n320 240\n255\n");
                fwrite(g_fb_latched, 1, sizeof(g_fb_latched), lfp);
                fclose(lfp);
            }
        }
        uint32_t dest = arg2, foff = arg3, len = arg5;
        if (fid < 16 && g_files[fid].present && foff <= g_files[fid].data.size()) {
            const auto &buf = g_files[fid].data;
            uint32_t avail = (foff + len <= buf.size()) ? len : (uint32_t)(buf.size() - foff);
            if (avail <= 65536u || dest >= 0x34100000u) {
                for (uint32_t i = 0; i < avail; i += 4u)
                    host_mem_wr(dest + i, read_le32(buf, foff + i));
            } else {
                // Fast hybrid transfer for 4 MiB resident chunks: exercise real host_mem
                // at boundaries (including offset 0 swap detection!) + backdoor interior
                for (uint32_t i = 0; i < 256u; i += 4u)
                    host_mem_wr(dest + i, read_le32(buf, foff + i));
                for (uint32_t i = 256u; i + 256u < avail; i += 4u)
                    sdr_poke_word((dest + i) >> 2, read_be32(buf, foff + i));
                for (uint32_t i = avail - 256u; i < avail; i += 4u)
                    host_mem_wr(dest + i, read_le32(buf, foff + i));
            }
            host_mem_wr(0xF0001000u, 0u);
            host_mem_wr(0xF0001004u, avail);
        } else {
            host_mem_wr(0xF0001000u, 3u);
        }
    } else if (op == 0x0403u) { // FileWrite: src=arg2, file_off=arg3, len=arg5
        uint32_t src = arg2, foff = arg3, len = arg5;
        if (fid < 16) {
            g_files[fid].present = true;
            if (g_files[fid].data.size() < foff + len) g_files[fid].data.resize(foff + len, 0xFFu);
            for (uint32_t i = 0; i < len; i += 4u) {
                uint32_t w = host_mem_rd(src + i);
                for (uint32_t k = 0; k < 4u && (i + k) < len; k++)
                    g_files[fid].data[foff + i + k] = (uint8_t)((w >> (8 * k)) & 0xFFu);
            }
        }
        host_mem_wr(0xF0001000u, 0u);
    } else if (op == 0x0404u) { // FileFlush
        host_mem_wr(0xF0001000u, 0u);
    } else {
        host_mem_wr(0xF0001000u, 2u);
    }

    dut->host_commandCore_busy = 0;
    dut->host_commandCore_done = 1;
    for (int t = 0; t < 64; t++) {
        step_sys_cycle();
        if (!dut->host_commandCore_request) break;
    }
    dut->host_commandCore_done = 0;
    step_sys_cycle();
    g_in_cmd_core = false;
}

// ============================================================================
// 5. Exact Multi-Clock Cycle Stepper (1 `clk_sys` = 2 `clk_sys2x` = 1.5 `clk_cpu`)
// ============================================================================
static void cpu_to(long now) {
    for (; g_cpu_t <= now; g_cpu_t += 2 * TB_CPU_M) {
        bool rise = ((g_cpu_t / (2 * TB_CPU_M)) % 2) == 0;
        dut->tb_clk_cpu = rise ? 1 : 0;
        if (g_cpu_t < now) dut->eval();
    }
}

static void step_half_sys(bool sys_edge) {
    cpu_to(g_cyc2x * 2L * TB_CPU_N);
    dut->tb_clk_sys2x = 1;
    if (sys_edge) dut->tb_clk_sys = 1;

    sdram_bus_step();
    g_sram.step();
    dut->eval();

    cpu_to(g_cyc2x * 2L * TB_CPU_N + TB_CPU_N);
    dut->tb_clk_sys2x = 0;
    if (!sys_edge) dut->tb_clk_sys = 0;

    if (++g_vid_phase == 5) g_vid_phase = 0;
    dut->tb_clk_vid = (g_vid_phase < 3) ? 1 : 0;
    dut->eval();

    if (!sys_edge) {
        // Sample `clk_sys` synchronous outputs once per `clk_sys` cycle
        if (dut->tb_uart_we) {
            char c = (char)dut->tb_uart_byte;
            if (c == 4) {
                g_saw_eot = true;
            } else {
                g_uart_log.push_back(c);
                if (getenv("VERBOSE_UART")) { putchar(c); if (c == '\n') fflush(stdout); }
            }
        }
        bool vb = dut->video_vblank != 0;
        bool hb = dut->video_hblank != 0;
        if (!vb && g_prev_vblank) {
            g_fb_x = 0;
            g_fb_y = 0;
            memset(g_fb_cur, 0, sizeof(g_fb_cur));
        } else if (hb && !g_prev_hblank && !vb) {
            g_fb_x = 0;
            g_fb_y++;
        }
        if (dut->video_dataEnable && !vb) {
            if (g_fb_x >= 0 && g_fb_x < 320 && g_fb_y >= 0 && g_fb_y < 240) {
                uint8_t r6 = dut->video_data_r & 0x3Fu;
                uint8_t g6 = dut->video_data_g & 0x3Fu;
                uint8_t b6 = dut->video_data_b & 0x3Fu;
                size_t idx = ((size_t)g_fb_y * 320u + (size_t)g_fb_x) * 3u;
                g_fb_cur[idx + 0] = (uint8_t)((r6 << 2) | (r6 >> 4));
                g_fb_cur[idx + 1] = (uint8_t)((g6 << 2) | (g6 >> 4));
                g_fb_cur[idx + 2] = (uint8_t)((b6 << 2) | (b6 >> 4));
            }
            g_fb_x++;
            g_cur_frame_pixels++;
            if (dut->video_data_r != 0 || dut->video_data_g != 0 || dut->video_data_b != 0)
                g_nonblack_pixels++;
        }
        if (vb && !g_prev_vblank && g_cur_frame_pixels > 0) {
            g_last_frame_pixels = g_cur_frame_pixels;
            g_cur_frame_pixels  = 0;
            g_vid_frames++;
            memcpy(g_fb_latched, g_fb_cur, sizeof(g_fb_latched));
            g_fb_has_frame = true;
            if (!g_dump_dir.empty() && g_dump_every > 0 && (g_vid_frames % g_dump_every) == 0) {
                char pbuf[512];
                snprintf(pbuf, sizeof(pbuf), "%s/frame_%04ld.ppm", g_dump_dir.c_str(), g_vid_frames);
                FILE *fp = fopen(pbuf, "wb");
                if (fp) {
                    fprintf(fp, "P6\n320 240\n255\n");
                    fwrite(g_fb_latched, 1, sizeof(g_fb_latched), fp);
                    fclose(fp);
                }
            }
        }
        g_prev_vblank = vb;
        g_prev_hblank = hb;

        if (dut->audio_left != 0 || dut->audio_right != 0) g_nonzero_audio++;
        if (dut->vibrate_mode != 0) g_vibrate_cycles++;
        if (g_wav_en) {
            g_wav_acc += 12;
            if (g_wav_acc >= 15625) {
                g_wav_acc -= 15625;
                g_wav_pcm.push_back((int16_t)dut->audio_left);
                g_wav_pcm.push_back((int16_t)dut->audio_right);
            }
        }

        g_sys++;
    }
    g_cyc2x++;
}

static void step_sys_cycle() {
    step_half_sys(true);
    step_half_sys(false);
    if (!g_in_cmd_core && dut->host_commandCore_request) {
        service_command_core_if_pending();
    }
}

static bool load_bin(const char *path, std::vector<uint8_t> &out) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return false; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize((size_t)sz);
    if (sz > 0 && fread(out.data(), 1, (size_t)sz, f) != (size_t)sz) { fclose(f); return false; }
    fclose(f);
    return true;
}

static void host_write_file_eager(uint16_t fid, uint32_t base_addr, const std::vector<uint8_t> &data, bool allow_fast_interior = true) {
    host_cmd(0x0300u, fid, 0); // FileWriteStart
    size_t sz = (data.size() + 3u) & ~3u;
    if (!allow_fast_interior || sz <= 65536u || base_addr >= 0x34100000u) {
        for (size_t i = 0; i < sz; i += 4u)
            host_mem_wr(base_addr + (uint32_t)i, read_le32(data, i));
    } else {
        // Stream first 256 bytes (exercising header endianness swap!) + last 256 bytes over host_mem,
        // and populate interior directly in SDRAM model (converting .z64/.v64/.n64 to big-endian as bridge does).
        uint32_t w0 = read_le32(data, 0);
        int swap_mode = (w0 == 0x12408037u) ? 1 : (w0 == 0x80371240u) ? 2 : 0;
        auto swap_fn = [&](uint32_t le_w) -> uint32_t {
            if (swap_mode == 1) return ((le_w & 0xFFFFu) << 16) | (le_w >> 16);
            if (swap_mode == 2) return le_w;
            return ((le_w & 0xFFu) << 24) | ((le_w & 0xFF00u) << 8) | ((le_w >> 8) & 0xFF00u) | (le_w >> 24);
        };
        for (size_t i = 0; i < 256u; i += 4u)
            host_mem_wr(base_addr + (uint32_t)i, read_le32(data, i));
        for (size_t i = 256u; i + 256u < sz; i += 4u)
            sdr_poke_word((base_addr + (uint32_t)i) >> 2, swap_fn(read_le32(data, i)));
        for (size_t i = sz - 256u; i < sz; i += 4u)
            host_mem_wr(base_addr + (uint32_t)i, read_le32(data, i));
    }
    host_cmd(0x0301u, fid, (uint32_t)data.size()); // FileWriteEnd
}

static std::vector<uint8_t> host_read_file_back(uint16_t fid, uint32_t base_addr) {
    uint32_t sz = host_cmd(0x0302u, fid, 0); // FileReadStart -> returns current file size!
    std::vector<uint8_t> out(sz, 0);
    for (uint32_t i = 0; i < sz; i += 4u) {
        uint32_t w = host_mem_rd(base_addr + i);
        for (uint32_t k = 0; k < 4u && (i + k) < sz; k++)
            out[i + k] = (uint8_t)((w >> (8 * k)) & 0xFFu);
    }
    host_cmd(0x0303u, fid, 0); // FileReadEnd
    return out;
}

// ============================================================================
// 6. Main Test Dispatcher (`--mode diag | selftest | mipstest | n64rom | ondemand64`)
// ============================================================================
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vgb_soc_tb_top;

    std::string mode = "mipstest";
    std::string arg_file;
    std::string n64rt_path  = "lang/n64rt/build/n64rt.bin";
    std::string savedb_path = "assets/n64savedb.txt";
    int pak_setting = 1; // 1 = Controller Pak, 2 = Rumble Pak, 9 = Transfer Pak
    int cart_switch = 0; // 0 = empty/GBA, 1 = physical DMG/CGB cartridge inserted
    bool test_restart = false;
    std::string dump_ppm;
    std::string dump_wav;
    long max_frames = 0;
    long press_start_at = -1;
    int fps_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) mode = argv[++i];
        else if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) arg_file = argv[++i];
        else if (strcmp(argv[i], "--n64rt") == 0 && i + 1 < argc) n64rt_path = argv[++i];
        else if (strcmp(argv[i], "--savedb") == 0 && i + 1 < argc) savedb_path = argv[++i];
        else if (strcmp(argv[i], "--pak") == 0 && i + 1 < argc) pak_setting = atoi(argv[++i]);
        else if (strcmp(argv[i], "--cart-switch") == 0 && i + 1 < argc) cart_switch = atoi(argv[++i]);
        else if (strcmp(argv[i], "--fps-mode") == 0 && i + 1 < argc) fps_mode = atoi(argv[++i]);
        else if (strcmp(argv[i], "--od-loading-ppm") == 0 && i + 1 < argc) g_od_loading_ppm = argv[++i];
        else if (strcmp(argv[i], "--test-restart") == 0) test_restart = true;
        else if (strcmp(argv[i], "--dump-ppm") == 0 && i + 1 < argc) dump_ppm = argv[++i];
        else if (strcmp(argv[i], "--dump-dir") == 0 && i + 1 < argc) g_dump_dir = argv[++i];
        else if (strcmp(argv[i], "--dump-every") == 0 && i + 1 < argc) g_dump_every = atol(argv[++i]);
        else if (strcmp(argv[i], "--dump-wav") == 0 && i + 1 < argc) dump_wav = argv[++i];
        else if (strcmp(argv[i], "--max-frames") == 0 && i + 1 < argc) max_frames = atol(argv[++i]);
        else if (strcmp(argv[i], "--press-start-at") == 0 && i + 1 < argc) press_start_at = atol(argv[++i]);
    }
    setvbuf(stdout, nullptr, _IOLBF, 0);
    g_wav_en = !dump_wav.empty();

    // Initialize inputs & hold reset for 24 sys cycles
    dut->reset                    = 1;
    dut->host_mem_enable          = 0;
    dut->host_mem_write           = 0;
    dut->host_mem_address         = 0;
    dut->host_mem_dataWrite       = 0;
    dut->host_commandHost_request = 0;
    dut->host_commandCore_busy    = 0;
    dut->host_commandCore_done    = 0;
    dut->host_commandCore_error   = 0;
    dut->pad_active               = 0x3; // Slot 0 + Slot 1 active
    dut->pad_dev_type_0           = 3;   // AnalogGamepad
    dut->pad_btns_0               = 0;
    dut->pad_axes_0               = 0x000018E8u; // LX=-24, LY=+24
    dut->pad_trig_0               = 0;
    dut->pad_btns_1               = 0;
    dut->tb_cart_switch           = (cart_switch != 0) ? 1 : 0;
    dut->eval();

    for (int i = 0; i < 24; i++) step_sys_cycle();
    dut->reset = 0;

    // Wait for GetStatus == STATUS_SETUP (2)
    uint32_t st = 0;
    for (int tries = 0; tries < 8000; tries++) {
        st = host_cmd(0x0000u);
        if (st == 2u) break;
        for (int w = 0; w < 16; w++) step_sys_cycle();
    }
    if (st != 2u) {
        TEST_ERR("Core never reached STATUS_SETUP (got %u)", st);
        return 1;
    }

    // ------------------------------------------------------------------------
    // MODE A: `N64MemDiagCore` (`DIAG_CORE_MODE = 1`)
    // ------------------------------------------------------------------------
    if (mode == "diag") {
        host_mem_wr(0x7000002Cu, 6u); // Phase shift +6 steps
        host_cmd(0x0102u);            // SetupComplete
        host_cmd(0x0100u);            // CoreRun
        dut->pad_btns_0 = 0x0002u;    // Hold B to activate 440 Hz tone + VibrateV0

        long limit = 3500000L;
        while (g_sys < limit && dut->tb_diag_pass_cnt < 1) {
            step_sys_cycle();
        }
        if (!dump_ppm.empty() && dut->tb_diag_pass_cnt >= 1) {
            long target_f = g_vid_frames + 2;
            long flim = g_sys + 2500000L;
            while (g_sys < flim && g_vid_frames < target_f) step_sys_cycle();
        }
        if (dut->tb_diag_pass_cnt < 1) TEST_ERR("N64MemDiagCore did not complete pass 1");
        if (dut->tb_diag_any_err != 0) TEST_ERR("N64MemDiagCore reported hardware errors: 0x%x", dut->tb_diag_any_err);
        if ((int8_t)dut->tb_mmcm_ps_cur != 6) TEST_ERR("MMCM phase shift target mismatch: got %d want 6", (int8_t)dut->tb_mmcm_ps_cur);
        if (g_vid_frames < 1 || g_last_frame_pixels != 320 * 240)
            TEST_ERR("N64MemDiagCore video frame check failed (frames=%ld px=%ld)", g_vid_frames, g_last_frame_pixels);
        if (g_nonzero_audio < 10) TEST_ERR("N64MemDiagCore audio tone silent");
        if (g_vibrate_cycles < 100) TEST_ERR("N64MemDiagCore vibrate motor did not assert");

        if (g_ac_errors == 0 && g_test_errors == 0) {
            printf("[PASS] N64MemDiagCore: pass_cnt=%u err=0 ps_cur=%d frames=%ld px=%ld audio=%ld vib=%ld ac_err=%ld\n",
                   dut->tb_diag_pass_cnt, (int8_t)dut->tb_mmcm_ps_cur, g_vid_frames, g_last_frame_pixels,
                   g_nonzero_audio, g_vibrate_cycles, g_ac_errors);
        }
    }

    // ------------------------------------------------------------------------
    // MODE B: `N64SelfTestCore` (`SELF_TEST_MODE = 1`, zero SD files!)
    // ------------------------------------------------------------------------
    else if (mode == "selftest") {
        host_cmd(0x0102u);            // SetupComplete (no FileWriteStart!)
        host_cmd(0x0100u);            // CoreRun
        host_cmd(0x0200u, 1u);        // NotifyFocus(1)
        dut->pad_btns_0 = 0x0001u;    // Hold A on Slot 0 -> triggers Rumble Pak bit

        long limit = 4500000L;
        while (g_sys < limit && g_uart_log.find("SELFTEST PASS") == std::string::npos) {
            if (g_uart_log.find("SELFTEST FAIL") != std::string::npos) break;
            step_sys_cycle();
        }
        if (g_uart_log.find("SELFTEST PASS") == std::string::npos)
            TEST_ERR("N64SelfTestCore did not print SELFTEST PASS (pc=0x%08x w0=0x%08x w2=0x%08x uart='%s')",
                     dut->tb_cpu_pc, sdr_peek_word(0), sdr_peek_word(2), g_uart_log.c_str());
        if (g_vid_frames < 2 || g_last_frame_pixels != 320 * 240 || g_nonblack_pixels < 10000)
            TEST_ERR("N64SelfTestCore video check failed (frames=%ld px=%ld nonblack=%ld)",
                     g_vid_frames, g_last_frame_pixels, g_nonblack_pixels);
        if (g_nonzero_audio < 20) TEST_ERR("N64SelfTestCore 48 kHz audio silent (%ld)", g_nonzero_audio);
        if (g_vibrate_cycles < 100) TEST_ERR("N64SelfTestCore VibrateV0 did not assert (%ld)", g_vibrate_cycles);

        if (g_ac_errors == 0 && g_test_errors == 0) {
            printf("[PASS] N64SelfTestCore: frames=%ld px_per_frame=%ld nonblack=%ld audio_samples=%ld vibrate_cycs=%ld ac_err=%ld\n",
                   g_vid_frames, g_last_frame_pixels, g_nonblack_pixels, g_nonzero_audio, g_vibrate_cycles, g_ac_errors);
        }
    }

    // ------------------------------------------------------------------------
    // MODE C: MIPS Hardware Regression Binary (`cpu_test`, `mi_test`, etc.)
    // ------------------------------------------------------------------------
    else if (mode == "mipstest") {
        std::vector<uint8_t> prog;
        if (!load_bin(arg_file.c_str(), prog)) return 1;
        // Load test binary directly at 0x0000_0000 via HostV0 FileWrite
        host_write_file_eager(3, 0x00000000u, prog, true);
        host_cmd(0x0102u);
        host_cmd(0x0100u);

        long limit = 180000000L;
        while (g_sys < limit && !g_saw_eot && !(max_frames > 0 && g_vid_frames >= max_frames)) {
            step_sys_cycle();
        }
        if (!g_saw_eot && !(max_frames > 0 && g_vid_frames >= max_frames))
            TEST_ERR("mipstest %s timed out without EOT (uart='%s')", arg_file.c_str(), g_uart_log.c_str());
        if (g_uart_log.find("FAIL") != std::string::npos)
            TEST_ERR("mipstest %s reported FAIL:\n%s", arg_file.c_str(), g_uart_log.c_str());

        if (g_ac_errors == 0 && g_test_errors == 0) {
            printf("[PASS] mipstest %s (%ld sys cycs, ac_err=%ld)\n", arg_file.c_str(), g_sys, g_ac_errors);
        }
    }

    // ------------------------------------------------------------------------
    // MODE D: Commercial N64 Boot (`n64rt.sys` + `.z64`/`.v64`/`.n64` + `.sav`/`.mpk` + Rumble + Restart)
    // ------------------------------------------------------------------------
    else if (mode == "n64rom" || mode == "ondemand64") {
        bool is_ondemand = (mode == "ondemand64");
        if (!load_bin(n64rt_path.c_str(), g_files[3].data)) return 1;
        if (!load_bin(savedb_path.c_str(), g_files[4].data)) return 1;
        if (!load_bin(arg_file.c_str(), g_files[0].data)) return 1;
        g_files[0].present   = true;
        g_files[0].on_demand = is_ondemand;
        g_files[3].present   = true;
        g_files[4].present   = true;

        // Configure Controller 1 Pak (`0x7000_0000`: 1 = Controller Pak, 2 = Rumble Pak)
        host_mem_wr(0x70000000u, (uint32_t)pak_setting);
        if (fps_mode != 0) host_mem_wr(0x70000040u, (uint32_t)fps_mode);
        // Also exercise VI Deblur (`0x7000_0018`) & 32-bit Color (`0x7000_001C`) settings!
        host_mem_wr(0x70000018u, 1u);
        host_mem_wr(0x7000001Cu, 1u);

        // Pre-fill erased 2 KiB .sav and 32 KiB .mpk (all 0xFF -> bridge treats as empty new files!)
        std::vector<uint8_t> blank_sav(2048u, 0xFFu);
        std::vector<uint8_t> blank_mpk(32768u, 0xFFu);
        host_write_file_eager(1, 0x34140000u, blank_sav, false);
        host_write_file_eager(2, 0x34108000u, blank_mpk, false);
        host_write_file_eager(4, 0x34130000u, g_files[4].data, false);
        host_write_file_eager(3, 0x00000000u, g_files[3].data, true);
        if (!is_ondemand) {
            host_write_file_eager(0, 0x00100000u, g_files[0].data, true);
        }

        dut->pad_btns_0 = 0x0001u; // Hold A on Controller 1 (verified via PIF Joybus!)
        host_cmd(0x0102u);         // SetupComplete
        host_cmd(0x0100u);         // CoreRun
        host_cmd(0x0200u, 1u);     // NotifyFocus(1)

        // Wait for guest ROM to finish all checks (`REPORT[0] @ RDRAM 0x0030_0000 == 0x600DF00D`)
        const uint32_t report_w0 = (0x03800000u + 0x00300000u) >> 2;
        long limit = 25000000L;
        while (g_sys < limit && sdr_peek_word(report_w0) != 0x600DF00Du) {
            step_sys_cycle();
        }
        uint32_t magic     = sdr_peek_word(report_w0 + 0);
        uint32_t pass_mask = sdr_peek_word(report_w0 + 1);
        uint32_t boot_cnt  = sdr_peek_word(report_w0 + 2);
        uint32_t pad_word  = sdr_peek_word(report_w0 + 3);
        uint32_t eep_type  = sdr_peek_word(report_w0 + 4);
        uint32_t pak_rep   = sdr_peek_word(report_w0 + 5);

        if (magic != 0x600DF00Du || pass_mask != 0x7Fu) {
            TEST_ERR("%s (%s) guest checks failed: magic=0x%08x pass_mask=0x%02x eep=0x%02x pak=%u\nUART:\n%s",
                     mode.c_str(), arg_file.c_str(), magic, pass_mask, eep_type, pak_rep, g_uart_log.c_str());
        }
        if ((pad_word >> 24) != 0x80u) { // N64 A button = bit 15 of button halfword = 0x8000!
            TEST_ERR("PIF Joybus Controller 1 button A not seen (pad_word=0x%08x)", pad_word);
        }
        if (g_sram.cnt_l2_reads < 100) {
            TEST_ERR("pi_rom_cache L2 Async SRAM cache did not serve hits (cnt_l2_reads=%ld)", g_sram.cnt_l2_reads);
        }

        // Run 2 more VI fields so `VideoV0` scans out complete 320x240 RGB666 frames & AI streams audio!
        long target_frames = g_vid_frames + 2;
        long flim = g_sys + 3000000L;
        while (g_sys < flim && g_vid_frames < target_frames) {
            step_sys_cycle();
        }
        if (g_vid_frames < 1 || g_last_frame_pixels != 320 * 240 || g_nonblack_pixels < 10000) {
            TEST_ERR("N64 VI -> VideoV0 frame check failed (frames=%ld px=%ld nonblack=%ld)",
                     g_vid_frames, g_last_frame_pixels, g_nonblack_pixels);
        }
        if (g_nonzero_audio < 10) {
            TEST_ERR("N64 AI -> AudioV0 stereo playback silent (%ld)", g_nonzero_audio);
        }
        if (pak_setting == 2 && g_vibrate_cycles < 50) {
            TEST_ERR("Rumble Pak motor write 0xC000 did not assert VibrateV0 (%ld)", g_vibrate_cycles);
        }
        if (dut->tb_cart_bus_err != 0) {
            TEST_ERR("CartridgePortV0 / gb_cart bus timing or contention error count = %u", dut->tb_cart_bus_err);
        }
        if (pak_setting == 9) {
            if (cart_switch == 0) {
                if (pak_rep != 8u || dut->tb_cart_reads != 0u || dut->tb_cart_writes != 0u) {
                    TEST_ERR("Empty/GBA Transfer Pak isolation failed: pak_rep=%u reads=%u writes=%u",
                             pak_rep, dut->tb_cart_reads, dut->tb_cart_writes);
                }
            } else {
                if (pak_rep != 9u || dut->tb_cart_reads < 150u || dut->tb_cart_writes < 120u) {
                    TEST_ERR("Physical MBC3 Transfer Pak check failed: pak_rep=%u reads=%u writes=%u",
                             pak_rep, dut->tb_cart_reads, dut->tb_cart_writes);
                }
            }
        }
        if (is_ondemand && (g_cmd_core_getsize_cnt < 1 || g_cmd_core_read_cnt < 14)) {
            TEST_ERR("On-demand 64 MiB paging did not issue expected commandCore ops (getsize=%ld read=%ld)",
                     g_cmd_core_getsize_cnt, g_cmd_core_read_cnt);
        }

        // Optional `"Restart Game"` (`0x7000_0028`) verification:
        if (test_restart) {
            sdr_poke_word(report_w0, 0u);
            host_mem_wr(0x70000028u, 1u); // Trigger soft restart!
            long rlim = g_sys + 28000000L;
            while (g_sys < rlim && sdr_peek_word(report_w0) != 0x600DF00Du) {
                step_sys_cycle();
            }
            uint32_t boot_cnt2 = sdr_peek_word(report_w0 + 2);
            uint32_t was_dirty = sdr_peek_word(report_w0 + 6);
            if (sdr_peek_word(report_w0) != 0x600DF00Du || boot_cnt2 != 2u || was_dirty != 0u) {
                TEST_ERR("Restart Game failed: magic=0x%08x boot_cnt=%u (want 2) was_dirty=%u (want 0)",
                         sdr_peek_word(report_w0), boot_cnt2, was_dirty);
            }

            // Also verify Game Bub system-menu "Reset Game" (`CoreHalt` 0x0101 -> `CoreRun` 0x0100)!
            sdr_poke_word(report_w0, 0u);
            host_cmd(0x0101u); // CoreHalt
            host_cmd(0x0100u); // CoreRun -> triggers clean soft restart!
            long rlim2 = g_sys + 28000000L;
            while (g_sys < rlim2 && sdr_peek_word(report_w0) != 0x600DF00Du) {
                step_sys_cycle();
            }
            uint32_t boot_cnt3  = sdr_peek_word(report_w0 + 2);
            uint32_t was_dirty3 = sdr_peek_word(report_w0 + 6);
            if (sdr_peek_word(report_w0) != 0x600DF00Du || boot_cnt3 != 3u || was_dirty3 != 0u) {
                TEST_ERR("System-menu CoreHalt->CoreRun Reset failed: magic=0x%08x boot_cnt=%u (want 3) was_dirty=%u (want 0)",
                         sdr_peek_word(report_w0), boot_cnt3, was_dirty3);
            }
            if (dut->tb_cart_bus_err != 0 || (pak_setting == 9 && cart_switch != 0 && sdr_peek_word(report_w0 + 5) != 9u)) {
                TEST_ERR("Post-reset Transfer Pak check failed: bus_err=%u pak_rep=%u",
                         dut->tb_cart_bus_err, sdr_peek_word(report_w0 + 5));
            }
        }

        // Halt & verify nonvolatile `.sav` (File ID 1: 2048B 16K EEPROM) & `.mpk` (File ID 2: 32KiB) persistence!
        host_cmd(0x0101u); // CoreHalt
        std::vector<uint8_t> sav_out = host_read_file_back(1, 0x34140000u);
        if (sav_out.size() != 2048u || sav_out[0] != 0x47u || sav_out[1] != 0x42u || sav_out[200 * 8] != 0xA0u) {
            TEST_ERR(".sav persistence readback mismatch (size=%zu b0=%02x b1=%02x blk200=%02x)",
                     sav_out.size(), sav_out.empty() ? 0 : sav_out[0],
                     sav_out.size() > 1 ? sav_out[1] : 0,
                     sav_out.size() > 1600 ? sav_out[1600] : 0);
        }
        if (pak_setting == 1) {
            std::vector<uint8_t> mpk_out = host_read_file_back(2, 0x34108000u);
            if (mpk_out.size() != 32768u || mpk_out[0x200] != 0x30u || mpk_out[0x21F] != 0x4Fu) {
                TEST_ERR(".mpk persistence readback mismatch (size=%zu [0x200]=0x%02x)",
                         mpk_out.size(), mpk_out.size() > 0x200 ? mpk_out[0x200] : 0);
            }
        }

        if (g_ac_errors == 0 && g_test_errors == 0) {
            printf("[PASS] %s (%s, pak=%d, restart=%d): boot_cnt=%u l2_hits=%ld frames=%ld audio=%ld vib=%ld od_reads=%ld ac_err=%ld\n",
                   mode.c_str(), arg_file.c_str(), pak_setting, (int)test_restart,
                   sdr_peek_word(report_w0 + 2), g_sram.cnt_l2_reads, g_vid_frames,
                   g_nonzero_audio, g_vibrate_cycles, g_cmd_core_read_cnt, g_ac_errors);
        }
    }

    // ------------------------------------------------------------------------
    // MODE E: Real Commercial N64 ROM Run (`--mode realrom | realrom_od`)
    // ------------------------------------------------------------------------
    else if (mode == "realrom" || mode == "realrom_od") {
        bool is_ondemand = (mode == "realrom_od");
        if (!load_bin(n64rt_path.c_str(), g_files[3].data)) return 1;
        if (!load_bin(savedb_path.c_str(), g_files[4].data)) return 1;
        if (!load_bin(arg_file.c_str(), g_files[0].data)) return 1;
        g_files[0].present   = true;
        g_files[0].on_demand = is_ondemand;
        g_files[3].present   = true;
        g_files[4].present   = true;

        host_mem_wr(0x70000000u, (uint32_t)pak_setting);
        if (fps_mode != 0) host_mem_wr(0x70000040u, (uint32_t)fps_mode);
        std::vector<uint8_t> blank_sav(2048u, 0xFFu);
        std::vector<uint8_t> blank_mpk(32768u, 0xFFu);
        host_write_file_eager(1, 0x34140000u, blank_sav, false);
        host_write_file_eager(2, 0x34108000u, blank_mpk, false);
        host_write_file_eager(4, 0x34130000u, g_files[4].data, false);
        host_write_file_eager(3, 0x00000000u, g_files[3].data, true);
        if (!is_ondemand) {
            host_write_file_eager(0, 0x00100000u, g_files[0].data, true);
        }

        dut->pad_axes_0 = 0x00000000u; // Centered stick!
        dut->pad_btns_0 = 0u;
        host_cmd(0x0102u); // SetupComplete
        host_cmd(0x0100u); // CoreRun
        host_cmd(0x0200u, 1u);

        long target = (max_frames > 0) ? max_frames : 120L;
        long last_rep = 0;
        while (g_vid_frames < target) {
            if (press_start_at >= 0) {
                dut->pad_btns_0 = (g_vid_frames >= press_start_at && g_vid_frames < press_start_at + 6)
                                ? (1u << 14) /* Start button bit in pad_btns_0 */ : 0u;
            }
            step_sys_cycle();
            if (g_vid_frames != last_rep && (g_vid_frames % 10) == 0) {
                last_rep = g_vid_frames;
                printf("[REALROM f=%04ld] sys=%ld (%.3fs) pc=0x%08x l2=%ld r0_rw=%ld/%ld r1_rw=%ld/%ld aud_nz=%ld wav_smp=%zu ac_err=%ld\n",
                       g_vid_frames, g_sys, (double)g_sys / 62.5e6, dut->tb_cpu_pc,
                       g_sram.cnt_l2_reads,
                       g_sdr[0].cnt_rd, g_sdr[0].cnt_wr,
                       g_sdr[1].cnt_rd, g_sdr[1].cnt_wr,
                       g_nonzero_audio, g_wav_pcm.size() / 2, g_ac_errors);
                fflush(stdout);
            }
        }
        printf("[REALROM DONE] frames=%ld sys=%ld ac_err=%ld\nUART:\n%s\n",
               g_vid_frames, g_sys, g_ac_errors, g_uart_log.c_str());
    }

    if (!dump_wav.empty() && !g_wav_pcm.empty()) {
        FILE *wf = fopen(dump_wav.c_str(), "wb");
        if (wf) {
            uint32_t data_bytes = (uint32_t)(g_wav_pcm.size() * sizeof(int16_t));
            uint32_t riff_sz    = 36u + data_bytes;
            uint32_t fmt_sz     = 16u;
            uint16_t pcm_fmt    = 1u, nch = 2u, blk_align = 4u, bps = 16u;
            uint32_t srate      = 48000u, brate = srate * 4u;
            fwrite("RIFF", 1, 4, wf); fwrite(&riff_sz, 4, 1, wf); fwrite("WAVE", 1, 4, wf);
            fwrite("fmt ", 1, 4, wf); fwrite(&fmt_sz, 4, 1, wf);  fwrite(&pcm_fmt, 2, 1, wf);
            fwrite(&nch, 2, 1, wf);   fwrite(&srate, 4, 1, wf);   fwrite(&brate, 4, 1, wf);
            fwrite(&blk_align, 2, 1, wf); fwrite(&bps, 2, 1, wf);
            fwrite("data", 1, 4, wf); fwrite(&data_bytes, 4, 1, wf);
            fwrite(g_wav_pcm.data(), 1, data_bytes, wf);
            fclose(wf);
        }
    }

    if (!dump_ppm.empty() && g_fb_has_frame) {
        FILE *fp = fopen(dump_ppm.c_str(), "wb");
        if (fp) {
            fprintf(fp, "P6\n320 240\n255\n");
            fwrite(g_fb_latched, 1, sizeof(g_fb_latched), fp);
            fclose(fp);
        }
    }

    dut->final();
    delete dut;
    return (g_ac_errors == 0 && g_test_errors == 0) ? 0 : 1;
}
