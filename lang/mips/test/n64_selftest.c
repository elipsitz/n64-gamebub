/* Game Bub N64 Self-Contained Hardware Diagnostic (`N64SelfTestCore`).
 *
 * Boots directly from embedded BRAM -> SDRAM 0x4000_0000 when `SELF_TEST_MODE = 1`
 * (or when loaded into Slot 0) without requiring any external .z64 ROM on SD card.
 *
 * Exercises and validates every N64 & Game Bub hardware subsystem:
 *   1. VR4300 64-bit integer ALU (`DADDU`/`DSLL32`/`DMULTU`/`DDIVU`) + `COP1` IEEE-754 FPU
 *   2. Dual-rank 64 MiB `W9825G6KH-6` SDRAM (Rank 0 & Rank 1 CS isolation) + 512 KiB 10 ns SRAM
 *   3. Reality Signal Processor (`rsp_top`, 8 SIMD lanes): RDRAM->IMEM/DMEM DMA + `LQV`/`VADD`/`SQV` + DMEM->RDRAM DMA
 *   4. Reality Display Processor (`rdp_top` + `rdp_dpc`): hardware Gouraud-shaded triangle rasterization into RDRAM
 *   5. N64 VI scanout (`n64_video`) + `n64_video_gb_downsampler` (320x240 RGB666 @ 60 Hz)
 *   6. 48 kHz stereo audio synthesis (`apf_audio`) + 4-slot `InputExtendedV0` inspector + `VibrateV0` haptic rumble (hold A/B)
 */
#include <stdint.h>
#include <generated/csr.h>
#include <generated/soc.h>
#include <layout.h>
#include <system.h>
#include "vishadow_cmds.h"

static void putc_(char c)
{
    for (unsigned i = 0; i < 65536u && uart_txfull_read(); i++) ;
    if (!uart_txfull_read()) uart_rxtx_write((uint8_t)c);
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]); }

#define SP_REG ((volatile uint32_t *)0x20000000u)
#define SP_PC  (*(volatile uint32_t *)0x20000020u)
#define DPC    ((volatile uint32_t *)0x20000040u)

#define W 320u
#define H 240u
#define FB0_PHYS 0x00100000u
#define FB1_PHYS 0x00140000u
#define DL_PHYS  0x00350000u

static inline uint16_t rgba5551(uint32_t r5, uint32_t g5, uint32_t b5)
{
    return (uint16_t)(((r5 & 31u) << 11) | ((g5 & 31u) << 6) | ((b5 & 31u) << 1) | 1u);
}

/* 1. VR4300 64-bit integer (including SDL/SDR/LDL/LDR) + COP1 single & double FPU self-test */
static int test_cpu_fpu(void)
{
    uint32_t hi_out = 0, lo_out = 0;
    __asm__ volatile(
        ".set push\n"
        ".set noreorder\n"
        ".set mips3\n"
        "li     $t0, 0x12345678\n"
        "dsll   $t0, $t0, 16\n"
        "ori    $t0, $t0, 0x9ABC\n"
        "dsll   $t0, $t0, 16\n"
        "ori    $t0, $t0, 0xDEF0\n"         /* t0 = 0x12345678_9ABCDEF0 */
        "li     $t1, 1000\n"
        "ddivu  $zero, $t0, $t1\n"
        "mflo   $t2\n"                      /* quotient = 0x0004A90B_E587DE6E */
        "mfhi   $t3\n"                      /* remainder = 320 */
        "dsrl32 %0, $t2, 0\n"
        "sll    %1, $t3, 0\n"
        ".set pop\n"
        : "=r"(hi_out), "=r"(lo_out)
        :
        : "t0", "t1", "t2", "t3", "hi", "lo"
    );
    if (hi_out != 0x0004A90Bu || lo_out != 320u) return 0;

    /* Test unaligned 64-bit SDL/SDR + LDL/LDR across byte offsets 1..7 */
    volatile uint8_t *ua_buf = (volatile uint8_t *)0xA0052000u;
    for (uint32_t off = 1u; off < 8u; off++) {
        for (uint32_t k = 0; k < 24u; k++) ua_buf[k] = (uint8_t)(0xE0u + k);
        uint32_t out_hi = 0, out_lo = 0;
        __asm__ volatile(
            ".set push\n"
            ".set noreorder\n"
            ".set mips3\n"
            "li     $t0, 0x01234567\n"
            "dsll   $t0, $t0, 16\n"
            "ori    $t0, $t0, 0x89AB\n"
            "dsll   $t0, $t0, 16\n"
            "ori    $t0, $t0, 0xCDEF\n"
            "sdl    $t0, 0(%2)\n"
            "sdr    $t0, 7(%2)\n"
            "ldl    $t1, 0(%2)\n"
            "ldr    $t1, 7(%2)\n"
            "dsrl32 %0, $t1, 0\n"
            "sll    %1, $t1, 0\n"
            ".set pop\n"
            : "=r"(out_hi), "=r"(out_lo)
            : "r"(ua_buf + off)
            : "t0", "t1", "memory"
        );
        if (out_hi != 0x01234567u || out_lo != 0x89ABCDEFu) return 0;
        if (ua_buf[off - 1u] != (uint8_t)(0xE0u + off - 1u)) return 0;
        if (ua_buf[off + 8u] != (uint8_t)(0xE0u + off + 8u)) return 0;
    }

    volatile float fa = 3.5f, fb = 4.25f, fc = -1.875f;
    float fres = fa * fb + fc;              /* 14.875 - 1.875 = 13.0 */
    union { float f; uint32_t u; } conv = { fres };
    if (conv.u != 0x41500000u) return 0;

    /* Test hardware COP1 double-precision FPU (cvt.d.w + mul.d + sqrt.d + cvt.w.d -> sqrt(9.0 * 16.0) = 12) */
    uint32_t d_int_out = 0;
    __asm__ volatile(
        ".set push\n"
        ".set noreorder\n"
        ".set doublefloat\n"
        "li      $t0, 9\n"
        "li      $t1, 16\n"
        "mtc1    $t0, $f0\n"
        "mtc1    $t1, $f2\n"
        "nop\n"
        "cvt.d.w $f0, $f0\n"
        "cvt.d.w $f2, $f2\n"
        "mul.d   $f4, $f0, $f2\n"
        "sqrt.d  $f6, $f4\n"
        "cvt.w.d $f8, $f6\n"
        "mfc1    %0, $f8\n"
        "nop\n"
        ".set pop\n"
        : "=r"(d_int_out)
        :
        : "t0", "t1", "$f0", "$f1", "$f2", "$f3", "$f4", "$f5", "$f6", "$f7", "$f8"
    );
    return d_int_out == 12u;
}

/* 2. Dual-rank 64 MiB SDRAM + 512 KiB 10 ns SRAM + L1/L2 PI ROM Cache self-test */
static int test_memory(void)
{
    volatile uint32_t *r0   = (volatile uint32_t *)0x40200000u; /* SDRAM Rank 0 (Cartridge ROM + 1 MiB) */
    volatile uint32_t *r1   = (volatile uint32_t *)0x42000000u; /* SDRAM Rank 1 (Cartridge ROM + 31 MiB) */
    volatile uint32_t *sram = (volatile uint32_t *)0x34100000u; /* 10 ns Async SRAM */

    for (uint32_t i = 0; i < 256u; i++) {
        r0[i]   = 0xA5A50000u ^ (i * 0x01010101u);
        r1[i]   = 0x5A5A0000u ^ (i * 0x03030303u);
        sram[i] = 0xC3C30000u ^ (i * 0x07070707u);
    }
    flush_cpu_dcache();
    for (uint32_t i = 0; i < 256u; i++) {
        if (r0[i]   != (0xA5A50000u ^ (i * 0x01010101u))) return 0;
        if (r1[i]   != (0x5A5A0000u ^ (i * 0x03030303u))) return 0;
        if (sram[i] != (0xC3C30000u ^ (i * 0x07070707u))) return 0;
    }

    /* Exercise Cartridge ROM L1 + L2 Async SRAM cache (0x30100000 & 0x31F00000 collide in L1, distinct in L2!) */
    volatile uint32_t *rom_a = (volatile uint32_t *)0x30100000u; /* maps to SDRAM 0x40200000 */
    volatile uint32_t *rom_b = (volatile uint32_t *)0x31F00000u; /* maps to SDRAM 0x42000000 */
    if (rom_a[7] != (0xA5A50000u ^ (7u * 0x01010101u))) return 0; /* cold miss -> fills L1 + L2 */
    if (rom_b[7] != (0x5A5A0000u ^ (7u * 0x03030303u))) return 0; /* evicts rom_a from L1, keeps in L2 */
    if (rom_a[3] != (0xA5A50000u ^ (3u * 0x01010101u))) return 0; /* L1 miss + L2 Async SRAM hit! */
    return 1;
}

/* 3. RSP 8-lane SIMD accumulator cascade + unaligned DMEM rotations + MFC2 + DMA self-test */
static int test_rsp_simd(void)
{
    volatile uint32_t *ucode = (volatile uint32_t *)0xA0050000u;
    volatile uint16_t *vdata = (volatile uint16_t *)0xA0050100u;
    volatile uint32_t *wdata = (volatile uint32_t *)0xA0050100u;

    /* Halt RSP and clear broke/interrupt bits */
    SP_REG[4] = 0x0000000Au;
    for (int i = 0; i < 8; i++) {
        vdata[i]      = (uint16_t)(100 + i * 11);       /* DMEM 0x00..0x0F: v1 */
        vdata[8 + i]  = (uint16_t)(2000 + i * 100);     /* DMEM 0x10..0x1F: v2 */
        vdata[16 + i] = (uint16_t)(3 + i);              /* DMEM 0x20..0x2F: v4 */
        vdata[24 + i] = 0u;                             /* DMEM 0x30..0x3F: out vadd */
        vdata[32 + i] = 0u;                             /* DMEM 0x40..0x4F: out VSAR mid (all 8 lanes!) */
        vdata[40 + i] = 0u;                             /* DMEM 0x50..0x5F: out SDV +0 / SDV +8 rotation! */
    }
    wdata[24] = 0x11223344u;                            /* DMEM 0x60 (+0) */
    wdata[25] = 0x55667788u;                            /* DMEM 0x64 (+4) */
    wdata[26] = 0x99AABBCCu;                            /* DMEM 0x68 (+8) */
    wdata[27] = 0xDDEEFF00u;                            /* DMEM 0x6C (+12) */
    wdata[28] = 0u; wdata[29] = 0u; wdata[30] = 0u; wdata[31] = 0u; /* DMEM 0x70..0x7F */

    int pc = 0;
    ucode[pc++] = 0x34010000u;                                                /* ori  $1, $0, 0x0000       */
    ucode[pc++] = (0x32u << 26) | (1u << 21) | (1u << 16) | (4u << 11);       /* lqv  $v1, 0($1)           */
    ucode[pc++] = 0x34010010u;                                                /* ori  $1, $0, 0x0010       */
    ucode[pc++] = (0x32u << 26) | (1u << 21) | (2u << 16) | (4u << 11);       /* lqv  $v2, 0($1)           */
    ucode[pc++] = 0x34010020u;                                                /* ori  $1, $0, 0x0020       */
    ucode[pc++] = (0x32u << 26) | (1u << 21) | (4u << 16) | (4u << 11);       /* lqv  $v4, 0($1)           */
    ucode[pc++] = 0x4A000000u  | (2u << 16) | (1u << 11) | (3u << 6) | 0x10u; /* vadd  $v3, $v1, $v2       */
    ucode[pc++] = 0x34010030u;                                                /* ori  $1, $0, 0x0030       */
    ucode[pc++] = (0x3Au << 26) | (1u << 21) | (3u << 16) | (4u << 11);       /* sqv  $v3, 0($1)           */

    /* 8-lane accumulator test: VMUDN acc = v1 * v4 (lo), then VMADH acc += (v2 * v4) << 16, then VSAR mid -> v5! */
    ucode[pc++] = 0x4A000000u  | (4u << 16) | (1u << 11) | (6u << 6) | 0x06u; /* vmudn $v6, $v1, $v4       */
    ucode[pc++] = 0x4A000000u  | (4u << 16) | (2u << 11) | (7u << 6) | 0x0Fu; /* vmadh $v7, $v2, $v4       */
    ucode[pc++] = 0x4A000000u  | (9u << 21) | (5u << 6)  | 0x1Du;             /* vsar  $v5, acc_md (e=9)   */
    ucode[pc++] = 0x34010040u;                                                /* ori  $1, $0, 0x0040       */
    ucode[pc++] = (0x3Au << 26) | (1u << 21) | (5u << 16) | (4u << 11);       /* sqv  $v5, 0($1)           */

    /* Vector store rotation test: SDV v3[0..3] to 0x50 (+0) and SDV v3[8..15] (el=8) to 0x58 (+8)! */
    ucode[pc++] = 0x34010050u;                                                /* ori  $1, $0, 0x0050       */
    ucode[pc++] = (0x3Au << 26) | (1u << 21) | (3u << 16) | (3u << 11);       /* sdv  $v3[0], 0($1)        */
    ucode[pc++] = 0x34010058u;                                                /* ori  $1, $0, 0x0058       */
    ucode[pc++] = (0x3Au << 26) | (1u << 21) | (3u << 16) | (3u << 11) | (8u << 7); /* sdv $v3[8], 0($1)   */

    /* Scalar unaligned DMEM word rotation (+4, +8, +12) + MFC2 element 12 (lane 6)! */
    ucode[pc++] = (0x23u << 26) | (0u << 21) | (8u << 16)  | 0x0064u;         /* lw   $8,  0x64($0) (+4)   */
    ucode[pc++] = (0x23u << 26) | (0u << 21) | (9u << 16)  | 0x0068u;         /* lw   $9,  0x68($0) (+8)   */
    ucode[pc++] = (0x23u << 26) | (0u << 21) | (10u << 16) | 0x006Cu;         /* lw   $10, 0x6C($0) (+12)  */
    ucode[pc++] = (0x12u << 26) | (0u << 21) | (11u << 16) | (3u << 11) | (12u << 7); /* mfc2 $11, $v3[12] */
    ucode[pc++] = (0x2Bu << 26) | (0u << 21) | (8u << 16)  | 0x0070u;         /* sw   $8,  0x70($0)        */
    ucode[pc++] = (0x2Bu << 26) | (0u << 21) | (9u << 16)  | 0x0074u;         /* sw   $9,  0x74($0)        */
    ucode[pc++] = (0x2Bu << 26) | (0u << 21) | (10u << 16) | 0x0078u;         /* sw   $10, 0x78($0)        */
    ucode[pc++] = (0x2Bu << 26) | (0u << 21) | (11u << 16) | 0x007Cu;         /* sw   $11, 0x7C($0)        */
    ucode[pc++] = 0x0000000Du;                                                /* break                     */

    /* DMA 128 bytes of data into DMEM 0x000 */
    while (SP_REG[6] & 1u) ;
    SP_REG[0] = 0x0000u;
    SP_REG[1] = 0x00050100u;
    SP_REG[2] = 128u - 1u;
    while (SP_REG[6] & 1u) ;

    /* DMA microcode into IMEM 0x1000 */
    uint32_t ulen = ((uint32_t)pc * 4u + 7u) & ~7u;
    SP_REG[0] = 0x1000u;
    SP_REG[1] = 0x00050000u;
    SP_REG[2] = ulen - 1u;
    while (SP_REG[6] & 1u) ;

    /* Run from SP_PC = 0 and wait for BREAK (status bit 1) */
    SP_PC     = 0x0000u;
    SP_REG[4] = 0x00000005u; /* clear halt + clear broke */
    for (uint32_t t = 0; t < 100000u && !(SP_REG[4] & 2u); t++) ;
    if (!(SP_REG[4] & 2u)) return 0;

    /* DMA results DMEM 0x030..0x07F -> RDRAM 0x00050130 (80 bytes) */
    SP_REG[0] = 0x0030u;
    SP_REG[1] = 0x00050130u;
    SP_REG[3] = 80u - 1u;
    while (SP_REG[6] & 1u) ;

    for (int i = 0; i < 8; i++) {
        uint16_t exp_sum = (uint16_t)((100 + i * 11) + (2000 + i * 100));
        uint16_t exp_mid = (uint16_t)((2000 + i * 100) * (3 + i));
        if (vdata[24 + i] != exp_sum) return 0; /* VADD + SQV */
        if (vdata[32 + i] != exp_mid) return 0; /* 8-lane VMUDN/VMADH/VSAR acc_m[0..7]! */
        if (vdata[40 + i] != exp_sum) return 0; /* SDV +0 / +8 st_rot[3:2] rotation! */
    }
    if (wdata[28] != 0x55667788u) return 0;     /* LW +4 x_rot[3:2]=1 */
    if (wdata[29] != 0x99AABBCCu) return 0;     /* LW +8 x_rot[3:2]=2 */
    if (wdata[30] != 0xDDEEFF00u) return 0;     /* LW +12 x_rot[3:2]=3 */
    if ((wdata[31] & 0xFFFFu) != (uint32_t)((100 + 6 * 11) + (2000 + 6 * 100))) return 0; /* MFC2 e=12 */
    return 1;
}

/* 4. Submit RDP hardware triangle display list into fb_phys */
static int render_rdp_scene(uint32_t fb_phys)
{
    const uint32_t n = sizeof(vishadow_cmds) / 4u;
    volatile uint32_t *dl = (volatile uint32_t *)(uintptr_t)(0xA0000000u + DL_PHYS);
    for (uint32_t i = 0; i < n; i++) {
        /* Word 3 is SET_COLOR_IMAGE DRAM address */
        dl[i] = (i == 3u) ? fb_phys : vishadow_cmds[i];
    }
    uint32_t prev_sync = rdp_sync_count_read();
    DPC[0] = DL_PHYS;
    DPC[1] = DL_PHYS + 4u * n;
    for (uint32_t t = 0; t < 2000000u; t++) {
        if (rdp_sync_count_read() != prev_sync && (rdp_status_read() & 1u)) return 1;
    }
    return 0;
}

static void fill_rect(volatile uint16_t *fb, uint32_t x0, uint32_t y0, uint32_t w, uint32_t h, uint16_t c)
{
    for (uint32_t y = y0; y < y0 + h && y < H; y++) {
        volatile uint16_t *row = fb + y * W;
        for (uint32_t x = x0; x < x0 + w && x < W; x++) row[x] = c;
    }
}

int main(void)
{
    puts_("\nGame Bub N64 Self-Test starting...\n");

    /* Initialize RDRAM hidden coverage plane to 0xFFFFFFFF */
    for (uint32_t a = 0; a < 0x00080000u; a += 4u)
        *(volatile uint32_t *)(uintptr_t)(LAYOUT_HID + a) = 0xFFFFFFFFu;

    int ok_cpu = test_cpu_fpu();
    int ok_mem = test_memory();
    int ok_rsp = test_rsp_simd();
    int ok_rdp = render_rdp_scene(FB0_PHYS);

    /* Verify RDP actually wrote shaded pixels into RDRAM */
    volatile uint16_t *fb0_uc = (volatile uint16_t *)(uintptr_t)(0xA0000000u + FB0_PHYS);
    uint32_t nonzero_px = 0;
    for (uint32_t i = 32u * W; i < 200u * W; i += 7u) {
        if (fb0_uc[i] != 0u && fb0_uc[i] != 0x2108u) nonzero_px++;
    }
    if (nonzero_px < 64u) ok_rdp = 0;

    puts_("  CPU/FPU: "); puts_(ok_cpu ? "PASS\n" : "FAIL\n");
    puts_("  MEM64M : "); puts_(ok_mem ? "PASS\n" : "FAIL\n");
    puts_("  RSP8   : "); puts_(ok_rsp ? "PASS\n" : "FAIL\n");
    puts_("  RDP3D  : "); puts_(ok_rdp ? "PASS\n" : "FAIL\n");

    /* Configure N64 VI scanout (320x240 RGBA5551 -> n64_video_gb_downsampler RGB666) */
    video_framebuffer_vtg_mode_write(1u);
    video_framebuffer_window_write(240u << 16);
    video_framebuffer_hwindow_write(640u << 16);
    video_framebuffer_scale_write(0x200u | (0x400u << 16));
    video_framebuffer_rowwords_write(168u);
    video_framebuffer_width_write(W);
    video_framebuffer_dma_base_write(LAYOUT_RDRAM + FB0_PHYS);
    video_framebuffer_vtg_enable_write(1u);
    video_framebuffer_dma_enable_write(1u);

    /* Enable 48 kHz audio playback FIFO */
    apf_audio_buffer_flush_write(1u);
    apf_audio_playback_en_write(1u);

    /* 16-entry quarter-wave sine lookup for pleasant 375 Hz + 562.5 Hz stereo chord */
    static const int16_t tri_wave[32] = {
           0,  1200,  2350,  3400,  4300,  5000,  5450,  5650,
        5650,  5450,  5000,  4300,  3400,  2350,  1200,     0,
           0, -1200, -2350, -3400, -4300, -5000, -5450, -5650,
       -5650, -5450, -5000, -4300, -3400, -2350, -1200,     0
    };
    uint32_t aud_phase_l = 0, aud_phase_r = 0;
    uint32_t frame = 0;
    int reported = 0;

    for (;;) {
        uint32_t back_phys = (frame & 1u) ? FB1_PHYS : FB0_PHYS;
        volatile uint16_t *fb = (volatile uint16_t *)(uintptr_t)(0xA0000000u + back_phys);

        /* Hardware RDP pass: background + Gouraud triangles */
        (void)render_rdp_scene(back_phys);

        /* Top HUD bar: 4 subsystem status badges (Green = PASS, Red = FAIL) */
        const uint16_t c_pass = rgba5551(3, 27, 8);
        const uint16_t c_fail = rgba5551(29, 4, 4);
        fill_rect(fb,  12u, 6u, 68u, 14u, ok_cpu ? c_pass : c_fail);
        fill_rect(fb,  88u, 6u, 68u, 14u, ok_mem ? c_pass : c_fail);
        fill_rect(fb, 164u, 6u, 68u, 14u, ok_rsp ? c_pass : c_fail);
        fill_rect(fb, 240u, 6u, 68u, 14u, ok_rdp ? c_pass : c_fail);

        /* Animated frame-counter progress bar + 4-slot gamepad & analog stick HUD */
        uint32_t k1 = apf_input_cont1_key_read(), j1 = apf_input_cont1_joy_read();
        uint32_t k2 = apf_input_cont2_key_read();
        uint32_t k3 = apf_input_cont3_key_read();
        uint32_t k4 = apf_input_cont4_key_read();

        uint16_t c_on  = rgba5551(6, 22, 30);
        uint16_t c_off = rgba5551(5, 6, 9);
        fill_rect(fb,  16u, 218u, 48u, 14u, (k1 >> 28) ? c_on : c_off);
        fill_rect(fb,  76u, 218u, 48u, 14u, (k2 >> 28) ? c_on : c_off);
        fill_rect(fb, 136u, 218u, 48u, 14u, (k3 >> 28) ? c_on : c_off);
        fill_rect(fb, 196u, 218u, 48u, 14u, (k4 >> 28) ? c_on : c_off);

        /* Live analog crosshair box at bottom-right (X = 256..304, Y = 196..234) */
        fill_rect(fb, 260u, 200u, 44u, 32u, rgba5551(3, 4, 7));
        int32_t sx = (int32_t)((int8_t)((j1 & 0xFFu) ^ 0x80u)) / 8;
        int32_t sy = (int32_t)((int8_t)(((j1 >> 8) & 0xFFu) ^ 0x80u)) / 10;
        uint32_t cx = (uint32_t)(280 + sx);
        uint32_t cy = (uint32_t)(214 + sy);
        fill_rect(fb, cx, cy, 5u, 5u, rgba5551(31, 28, 6));

        /* Moving frame heartbeat indicator */
        fill_rect(fb, 12u + ((frame * 4u) % 288u), 23u, 12u, 4u, rgba5551(31, 31, 31));

        /* Pulse Rumble Pak motor (INTERACT2[30]) when A (bit 4) or B (bit 5) is held */
        int btn_rumble = ((k1 >> 4) & 3u) != 0u;
        uint32_t ia2 = apf_interact_interact2_read();
        uint32_t want_ia2 = btn_rumble ? (ia2 | (1u << 30)) : (ia2 & ~(1u << 30));
        if (ia2 != want_ia2) apf_interact_interact2_write(want_ia2);

        /* Top up 48 kHz audio FIFO so tone plays glitch-free */
        while (apf_audio_buffer_fill_read() < 512u) {
            int16_t sl = tri_wave[(aud_phase_l >> 8) & 31u];
            int16_t sr = tri_wave[(aud_phase_r >> 8) & 31u];
            aud_phase_l += 64u;
            aud_phase_r += 96u;
            apf_audio_out_write(((uint32_t)(uint16_t)sr << 16) | (uint16_t)sl);
        }

        /* Swap framebuffer and wait for next vblank */
        video_framebuffer_dma_base_write(LAYOUT_RDRAM + back_phys);
        (void)apf_video_video_read(); /* clear VBLANK_TRIGGERED */
        for (uint32_t w = 0; w < 1200000u; w++) {
            if (apf_audio_buffer_fill_read() < 256u) {
                int16_t sl = tri_wave[(aud_phase_l >> 8) & 31u];
                int16_t sr = tri_wave[(aud_phase_r >> 8) & 31u];
                aud_phase_l += 64u;
                aud_phase_r += 96u;
                apf_audio_out_write(((uint32_t)(uint16_t)sr << 16) | (uint16_t)sl);
            }
            if (apf_video_video_read() & 2u) break;
        }

        frame++;
        if (!reported && frame >= 2u) {
            reported = 1;
            if (ok_cpu && ok_mem && ok_rsp && ok_rdp) {
                puts_("SELFTEST PASS (frame=");
                puthex(frame);
                puts_(")\n");
            } else {
                puts_("SELFTEST FAIL\n");
            }
        }
    }
}
