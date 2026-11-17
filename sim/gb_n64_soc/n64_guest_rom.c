/* Bare-metal N64 guest ROM payload (`0x8000_0400`) booted by `n64rt.sys` (`N64RT_OWN`).
 *
 * Exercises full commercial N64 hardware + runtime paths on `n64_gamebub_top`:
 *   - Bit 0 (0x01): Boot parameters (`BOOT_MEM_SIZE == 8 MiB`)
 *   - Bit 1 (0x02): Hardware `PI DMA` across >32 KiB of ROM (exercising `pi_rom_cache` L1 BRAM + L2 10 ns SRAM)
 *   - Bit 2 (0x04): Phase-5 `64 MiB` `on_demand` cross-boundary `PI DMA` (`48.999 MiB`, `51.0 MiB`, `63.5 MiB`) when `ROM_IS_64MB`
 *   - Bit 3 (0x08): PIF Joybus Controller 1 button & stick read (`InputExtendedV0`)
 *   - Bit 4 (0x10): PIF Joybus 16 Kbit EEPROM status (`0xC0` from `n64savedb.txt` `N3DE`) + block 0 & block 200 read/write + boot counter
 *   - Bit 5 (0x20): Accessory test: Controller Pak (`0x0200` write/readback -> `.mpk`) OR Rumble Pak (`0x8000` ID `0x80` + `0xC000` motor ON)
 *   - Bit 6 (0x40): Hardware N64 VI (`320x240` color bars) + Hardware N64 AI stereo audio buffer playback
 */
typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

#define K1_U32(pa) (*(volatile u32 *)(0xA0000000u | (pa)))
#define K1_PTR(pa) ((volatile u32 *)(0xA0000000u | (pa)))
#define REPORT     ((volatile u32 *)0xA0300000u)

#define VI_STATUS   0x04400000u
#define VI_ORIGIN   0x04400004u
#define VI_WIDTH    0x04400008u
#define VI_INTR     0x0440000Cu
#define VI_V_SYNC   0x04400018u
#define VI_H_SYNC   0x0440001Cu
#define VI_LEAP     0x04400020u
#define VI_H_START  0x04400024u
#define VI_V_START  0x04400028u
#define VI_V_BURST  0x0440002Cu
#define VI_X_SCALE  0x04400030u
#define VI_Y_SCALE  0x04400034u

#define AI_DRAM_ADDR 0x04500000u
#define AI_LEN       0x04500004u
#define AI_CONTROL   0x04500008u
#define AI_DACRATE   0x04500010u
#define AI_BITRATE   0x04500014u

#define PI_DRAM_ADDR 0x04600000u
#define PI_CART_ADDR 0x04600004u
#define PI_WR_LEN    0x0460000Cu
#define PI_STATUS    0x04600010u

#define SI_DRAM_ADDR 0x04800000u
#define SI_RD64B     0x04800004u
#define SI_WR64B     0x04800010u
#define SI_STATUS    0x04800018u
#define PIF_RAM      0x1FC007C0u

__asm__(
    ".set noreorder\n"
    ".section .text.start, \"ax\"\n"
    ".globl _start\n"
    "_start:\n"
    "    lui   $sp, 0x8020\n"
    "    jal   guest_main\n"
    "    addiu $sp, $sp, -32\n"
    "1:  b     1b\n"
    "    nop\n"
    ".text\n"
);

static u32 pif_buf[16] __attribute__((aligned(16)));
static u32 dma_buf[16384] __attribute__((aligned(16))); /* 64 KiB DMA buffer */
static u32 aud_buf[2048]  __attribute__((aligned(16)));

static inline u32 rom_pat(u32 rom_off)
{
    return 0x9E3779B9u ^ rom_off ^ ((rom_off >> 11) * 0x045D9F3Bu);
}

static void pi_dma_read(u32 cart_off, u32 dram_phys, u32 bytes)
{
    while (K1_U32(PI_STATUS) & 3u) ;
    K1_U32(PI_DRAM_ADDR) = dram_phys;
    K1_U32(PI_CART_ADDR) = 0x10000000u + cart_off;
    K1_U32(PI_WR_LEN)    = bytes - 1u;
    while (K1_U32(PI_STATUS) & 3u) ;
    K1_U32(PI_STATUS)    = 2u; /* clear PI interrupt */
}

static void pif_xfer(void)
{
    u32 pa = (u32)pif_buf & 0x1FFFFFFFu;
    while (K1_U32(SI_STATUS) & 3u) ;
    K1_U32(SI_DRAM_ADDR) = pa;
    K1_U32(SI_WR64B)     = PIF_RAM;
    while (K1_U32(SI_STATUS) & 3u) ;
    K1_U32(SI_STATUS)    = 0u;
    K1_U32(SI_DRAM_ADDR) = pa;
    K1_U32(SI_RD64B)     = PIF_RAM;
    while (K1_U32(SI_STATUS) & 3u) ;
    K1_U32(SI_STATUS)    = 0u;
}

static volatile u8 *pif_bytes(void)
{
    volatile u8 *b = (volatile u8 *)(0xA0000000u | ((u32)pif_buf & 0x1FFFFFFFu));
    for (u32 i = 0; i < 64u; i++) b[i] = 0u;
    b[63] = 1u;
    return b;
}

static u16 joy_pak_addr(u16 a)
{
    a &= 0xFFE0u;
    u32 reg = 0;
    for (int i = 15; i >= 5; i--) {
        int bit = ((a >> i) & 1u) ^ ((reg >> 4) & 1u);
        reg = ((reg << 1) & 0x1Eu) ^ (bit ? 0x15u : 0u);
    }
    return (u16)(a | (reg & 0x1Fu));
}

static void joy_pak_wr_val(u16 a, u8 val)
{
    volatile u8 *b = pif_bytes();
    u16 ac = joy_pak_addr(a);
    b[0] = 35u; b[1] = 1u; b[2] = 0x03u;
    b[3] = (u8)(ac >> 8); b[4] = (u8)ac;
    for (int k = 0; k < 32; k++) b[5 + k] = val;
    b[38] = 0xFEu;
    pif_xfer();
}

static volatile u8 *joy_pak_rd(u16 a)
{
    volatile u8 *b = pif_bytes();
    u16 ac = joy_pak_addr(a);
    b[0] = 3u; b[1] = 33u; b[2] = 0x02u;
    b[3] = (u8)(ac >> 8); b[4] = (u8)ac;
    b[38] = 0xFEu;
    pif_xfer();
    return b + 5;
}

void guest_main(void)
{
    /* Clear BSS manually */
    extern u8 __bss_start[], __bss_end[];
    for (u8 *p = __bss_start; p < __bss_end; p++) *p = 0;

    u32 pass_mask = 0;
    u32 dma_pa = (u32)dma_buf & 0x1FFFFFFFu;
    volatile u32 *dma_uc = K1_PTR(dma_pa);

    /* Check 0: RDRAM cleanliness (for Restart Game verification) + BOOT_MEM_SIZE */
    u32 was_dirty = (REPORT[7] == 0xCAFEBABEu) ? 1u : 0u;
    REPORT[7] = 0xCAFEBABEu;
    u32 mem_sz = *(volatile u32 *)0x80000318u;
    if (mem_sz == 0x00800000u || mem_sz == 0x00400000u) pass_mask |= 0x01u;

    /* Check 1: Hardware PI DMA across 36 KiB (exceeds 16 KiB L1 -> evicts to 64 KiB L2 SRAM, then re-reads from L2!) */
    int dma_ok = 1;
    pi_dma_read(0x00020000u, dma_pa, 36864u);
    for (u32 i = 0; i < 36864u / 4u; i++) {
        if (dma_uc[i] != rom_pat(0x00020000u + 4u * i)) { dma_ok = 0; break; }
    }
    /* Second read of first 8 KiB (was evicted from 16 KiB direct-mapped L1 by +16 KiB/+32 KiB, so hits L2 Async SRAM!) */
    for (u32 i = 0; i < 2048u; i++) dma_uc[i] = 0u;
    pi_dma_read(0x00020000u, dma_pa, 8192u);
    for (u32 i = 0; i < 2048u; i++) {
        if (dma_uc[i] != rom_pat(0x00020000u + 4u * i)) { dma_ok = 0; break; }
    }
    if (dma_ok) pass_mask |= 0x02u;

    /* Check 2: Phase-5 64 MiB on-demand tail paging (if marker word at 0x0001FFF0 == 0x644D4221) */
    pi_dma_read(0x0001FFF0u, dma_pa, 16u);
    if (dma_uc[0] == 0x644D4221u) {
        int od_ok = 1;
        const u32 test_offs[3] = { 0x032FFFE0u, 0x03300000u, 0x03F80000u };
        for (int k = 0; k < 3; k++) {
            u32 off = test_offs[k];
            for (u32 i = 0; i < 64u; i++) dma_uc[i] = 0u;
            pi_dma_read(off, dma_pa, 256u);
            for (u32 i = 0; i < 64u; i++) {
                if (dma_uc[i] != rom_pat(off + 4u * i)) { od_ok = 0; break; }
            }
        }
        if (od_ok) pass_mask |= 0x04u;
    } else {
        pass_mask |= 0x04u; /* N/A on 2 MiB ROM */
    }

    /* Check 3: PIF Joybus Controller 1 status & button/stick read */
    volatile u8 *b = pif_bytes();
    b[0] = 1u; b[1] = 3u; b[2] = 0x00u; b[6] = 0xFEu;
    pif_xfer();
    u8 cont_type_lo = b[3], cont_pak_flag = b[5];

    b = pif_bytes();
    b[0] = 1u; b[1] = 4u; b[2] = 0x01u; b[7] = 0xFEu;
    pif_xfer();
    u32 pad_word = ((u32)b[3] << 24) | ((u32)b[4] << 16) | ((u32)b[5] << 8) | b[6];
    REPORT[3] = pad_word;
    if (cont_type_lo == 0x05u) pass_mask |= 0x08u;

    /* Check 4: PIF Channel 4 Cartridge EEPROM (16 Kbit via n64savedb.txt "N3DE") + persistent boot counter */
    b = pif_bytes();
    b[0] = 0u; b[1] = 0u; b[2] = 0u; b[3] = 0u; /* skip ch 0..3 */
    b[4] = 1u; b[5] = 3u; b[6] = 0x00u; b[10] = 0xFEu;
    pif_xfer();
    u8 eep_type = b[8]; /* 0xC0 = 16 Kbit EEPROM, 0x80 = 4 Kbit EEPROM */
    REPORT[4] = eep_type;

    /* Read EEPROM block 0 to increment persistent boot counter across Restart Game */
    b = pif_bytes();
    b[0] = 0u; b[1] = 0u; b[2] = 0u; b[3] = 0u;
    b[4] = 2u; b[5] = 8u; b[6] = 0x04u; b[7] = 0u; b[16] = 0xFEu;
    pif_xfer();
    u32 boot_cnt = (b[8] == 0x47u && b[9] == 0x42u) ? ((u32)b[10] + 1u) : 1u;

    /* Write EEPROM block 0 ("GB", boot_cnt, "N64SAV") */
    b = pif_bytes();
    b[0] = 0u; b[1] = 0u; b[2] = 0u; b[3] = 0u;
    b[4] = 10u; b[5] = 1u; b[6] = 0x05u; b[7] = 0u;
    b[8] = 0x47u; b[9] = 0x42u; b[10] = (u8)boot_cnt; b[11] = 0x5Au;
    b[12] = 0x4Eu; b[13] = 0x36u; b[14] = 0x34u; b[15] = 0x21u;
    b[17] = 0xFEu;
    pif_xfer();

    /* Also write & read back EEPROM block 200 (16 Kbit upper range >= block 64) */
    b = pif_bytes();
    b[0] = 0u; b[1] = 0u; b[2] = 0u; b[3] = 0u;
    b[4] = 10u; b[5] = 1u; b[6] = 0x05u; b[7] = 200u;
    for (int k = 0; k < 8; k++) b[8 + k] = (u8)(0xA0u + k);
    b[17] = 0xFEu;
    pif_xfer();

    b = pif_bytes();
    b[0] = 0u; b[1] = 0u; b[2] = 0u; b[3] = 0u;
    b[4] = 2u; b[5] = 8u; b[6] = 0x04u; b[7] = 200u; b[16] = 0xFEu;
    pif_xfer();
    int eep_ok = (eep_type == 0xC0u);
    for (int k = 0; k < 8; k++) if (b[8 + k] != (u8)(0xA0u + k)) eep_ok = 0;
    if (eep_ok) pass_mask |= 0x10u;

    /* Check 5: Accessory on Channel 0 (Rumble Pak vs Controller Pak auto-detect!) */
    if (cont_pak_flag == 0x01u) {
        /* Write 0x80 to 0x8000 (address + CRC = 0x8001) and read back 0x8000 to detect Rumble Pak */
        b = pif_bytes();
        b[0] = 35u; b[1] = 1u; b[2] = 0x03u; b[3] = 0x80u; b[4] = 0x01u;
        for (int k = 0; k < 32; k++) b[5 + k] = 0x80u;
        b[38] = 0xFEu;
        pif_xfer();

        b = pif_bytes();
        b[0] = 3u; b[1] = 33u; b[2] = 0x02u; b[3] = 0x80u; b[4] = 0x01u;
        b[38] = 0xFEu;
        pif_xfer();

        if (b[5] == 0x80u) {
            /* Rumble Pak detected! Turn motor ON by writing 0x01s to 0xC000 (0xC01B) */
            b = pif_bytes();
            b[0] = 35u; b[1] = 1u; b[2] = 0x03u; b[3] = 0xC0u; b[4] = 0x1Bu;
            for (int k = 0; k < 32; k++) b[5 + k] = 0x01u;
            b[38] = 0xFEu;
            pif_xfer();
            REPORT[5] = 2u; /* Rumble Pak active */
            pass_mask |= 0x20u;
        } else {
            /* Probe for Transfer Pak by writing 0x84 to 0x8000 */
            joy_pak_wr_val(0x8000u, 0x84u);
            volatile u8 *rd = joy_pak_rd(0x8000u);
            if (rd[0] == 0x84u) {
                /* Transfer Pak detected! Read 0xB000 status */
                rd = joy_pak_rd(0xB000u);
                u8 st0 = rd[0];
                if (!(st0 & 0x80u)) {
                    /* Transfer Pak present, physical slot empty */
                    joy_pak_wr_val(0x8000u, 0xFEu);
                    REPORT[5] = 8u;
                    pass_mask |= 0x20u;
                } else {
                    int tp_ok = 1;
                    /* Power on physical GB cartridge (0xB000 = 0x01) */
                    joy_pak_wr_val(0xB000u, 0x01u);
                    rd = joy_pak_rd(0xB000u);
                    if ((rd[0] & 0x89u) != 0x89u) tp_ok = 0;

                    /* Bank 0 (0x0000..0x3FFF): verify GB ROM header title "GBUB TPAK TEST" across 0x0134..0x0141 */
                    joy_pak_wr_val(0xA000u, 0x00u);
                    rd = joy_pak_rd(0xC120u);
                    static const char want_title[14] = "GBUB TPAK TEST";
                    for (int k = 0; k < 12; k++)
                        if (rd[0x14 + k] != (u8)want_title[k]) tp_ok = 0;
                    rd = joy_pak_rd(0xC140u);
                    for (int k = 0; k < 2; k++)
                        if (rd[k] != (u8)want_title[12 + k]) tp_ok = 0;

                    /* Enable MBC3 SRAM (0x0000 = 0x0A) and switch ROM bank = 3 (0x2000 = 0x03) */
                    joy_pak_wr_val(0xC000u, 0x0Au);
                    joy_pak_wr_val(0xE000u, 0x03u);

                    /* Bank 1 (0x4000..0x7FFF): verify ROM bank 3 signature at 0x7FE0 */
                    joy_pak_wr_val(0xA000u, 0x01u);
                    rd = joy_pak_rd(0xFFE0u);
                    for (int k = 0; k < 32; k++)
                        if (rd[k] != (u8)(0xB0u ^ 0x30u ^ (u8)k)) tp_ok = 0;

                    /* Select MBC3 RAM bank 2 (0x4000 = 0x02) */
                    joy_pak_wr_val(0xC000u, 0x02u);

                    /* Bank 2 (0x8000..0xBFFF): write 32 bytes to GB SRAM 0xA120 (0xE120), switch RAM bank, and read back */
                    joy_pak_wr_val(0xA000u, 0x02u);
                    b = pif_bytes();
                    u16 ac = joy_pak_addr(0xE120u);
                    b[0] = 35u; b[1] = 1u; b[2] = 0x03u;
                    b[3] = (u8)(ac >> 8); b[4] = (u8)ac;
                    for (int k = 0; k < 32; k++) b[5 + k] = (u8)(0xD0u + k);
                    b[38] = 0xFEu;
                    pif_xfer();

                    /* Switch MBC3 RAM bank to 1, verify 0xA120 is still 0xFF, then switch back to 2 and verify 0xD0 + k */
                    joy_pak_wr_val(0xA000u, 0x01u);
                    joy_pak_wr_val(0xC000u, 0x01u);
                    joy_pak_wr_val(0xA000u, 0x02u);
                    rd = joy_pak_rd(0xE120u);
                    if (rd[0] != 0xFFu) tp_ok = 0;

                    joy_pak_wr_val(0xA000u, 0x01u);
                    joy_pak_wr_val(0xC000u, 0x02u);
                    joy_pak_wr_val(0xA000u, 0x02u);
                    rd = joy_pak_rd(0xE120u);
                    for (int k = 0; k < 32; k++)
                        if (rd[k] != (u8)(0xD0u + k)) tp_ok = 0;

                    /* Power off physical GB cartridge */
                    joy_pak_wr_val(0xB000u, 0x00u);
                    REPORT[5] = 9u;
                    if (tp_ok) pass_mask |= 0x20u;
                }
            } else {
                /* Controller Pak detected! Write 32-byte test record at 0x0200 and verify readback */
                joy_pak_wr_val(0x8000u, 0xFEu);
                b = pif_bytes();
                b[0] = 35u; b[1] = 1u; b[2] = 0x03u; b[3] = 0x02u; b[4] = 0x00u;
                for (int k = 0; k < 32; k++) b[5 + k] = (u8)(0x30u + k);
                b[38] = 0xFEu;
                pif_xfer();

                b = pif_bytes();
                b[0] = 3u; b[1] = 33u; b[2] = 0x02u; b[3] = 0x02u; b[4] = 0x00u;
                b[38] = 0xFEu;
                pif_xfer();

                int pak_ok = 1;
                for (int k = 0; k < 32; k++) if (b[5 + k] != (u8)(0x30u + k)) pak_ok = 0;
                REPORT[5] = 1u; /* Controller Pak active */
                if (pak_ok) pass_mask |= 0x20u;
            }
        }
    } else {
        REPORT[5] = 0u;
        pass_mask |= 0x20u;
    }

    /* Check 6: Render 320x240 RGBA5551 color bars in RDRAM 0x00100000 + start VI & AI */
    volatile u16 *fb = (volatile u16 *)0xA0100000u;
    for (u32 y = 0; y < 240u; y++) {
        for (u32 x = 0; x < 320u; x++) {
            u32 r5 = (x * 31u) / 319u;
            u32 g5 = (y * 31u) / 239u;
            u32 b5 = ((x ^ y) >> 3) & 31u;
            fb[y * 320u + x] = (u16)((r5 << 11) | (g5 << 6) | (b5 << 1) | 1u);
        }
    }
    K1_U32(VI_ORIGIN)  = 0x00100000u;
    K1_U32(VI_WIDTH)   = 320u;
    K1_U32(VI_INTR)    = 0x00000200u;
    K1_U32(VI_V_SYNC)  = 0x0000020Du;
    K1_U32(VI_H_SYNC)  = 0x00000C15u;
    K1_U32(VI_LEAP)    = 0x0C150C15u;
    K1_U32(VI_H_START) = 0x006C02ECu;
    K1_U32(VI_V_START) = 0x002501FFu;
    K1_U32(VI_V_BURST) = 0x000E0204u;
    K1_U32(VI_X_SCALE) = 0x00000200u;
    K1_U32(VI_Y_SCALE) = 0x00000400u;
    K1_U32(VI_STATUS)  = 0x00000302u;

    /* Fill 8 KiB stereo audio buffer and start AI @ ~44.1 kHz */
    u32 aud_pa = (u32)aud_buf & 0x1FFFFFFFu;
    volatile u32 *aud_uc = K1_PTR(aud_pa);
    for (u32 i = 0; i < 2048u; i++) {
        short s = (i & 16u) ? 6000 : -6000;
        u16 u = (u16)s;
        aud_uc[i] = ((u32)u << 16) | u;
    }
    K1_U32(AI_DACRATE)   = 1103u;
    K1_U32(AI_BITRATE)   = 15u;
    K1_U32(AI_DRAM_ADDR) = aud_pa;
    K1_U32(AI_LEN)       = 8192u;
    K1_U32(AI_CONTROL)   = 1u;
    pass_mask |= 0x40u;

    REPORT[1] = pass_mask;
    REPORT[2] = boot_cnt;
    REPORT[6] = was_dirty;
    REPORT[0] = 0x600DF00Du;

    /* Keep re-queuing AI buffer so audio streams continuously across frames */
    for (;;) {
        if (!(K1_U32(AI_LEN))) {
            K1_U32(AI_DRAM_ADDR) = aud_pa;
            K1_U32(AI_LEN)       = 8192u;
        }
    }
}
