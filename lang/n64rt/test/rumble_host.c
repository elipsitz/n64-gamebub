/* Host unit test for Game Bub Rumble Pak (Joybus 0x8000/0xC000 + INTERACT2[30])
 * and 4-slot Controller Pak support in ../n64rt_pak.c:
 *   gcc -O2 -Wall -Wextra -I../../mips/include -I.. rumble_host.c -o /tmp/rumble_host && /tmp/rumble_host */
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

static uint32_t g_ia0 = 0, g_ia2 = 0;
static uint32_t g_slot_id = 0;
static uint32_t g_slot_sizes[16] = {0};
static uint32_t g_gb_hw = 0;
static uint32_t g_gb_sw = 0;
static uint32_t g_gb_ctrl = 0;
static uint8_t  g_gb_rdata = 0xFF;
static uint8_t  g_gb_rom[0x10000];
static uint8_t  g_gb_ram[0x8000];
static uint8_t  g_gb_ram_en = 0;
static uint8_t  g_gb_rom_bank = 1;
static uint8_t  g_gb_ram_bank = 0;
static uint64_t g_uptime = 12345678ULL;

static inline uint32_t apf_interact_interact0_read(void) { return g_ia0; }
static inline uint32_t apf_interact_interact2_read(void) { return g_ia2; }
static inline void apf_interact_interact2_write(uint32_t v) { g_ia2 = v; }
static inline uint32_t apf_bridge_slot_id_read(void) { return g_slot_id; }
static inline void apf_bridge_slot_id_write(uint32_t v) { g_slot_id = v; }
static inline uint32_t apf_bridge_file_size_read(void) { return g_slot_sizes[g_slot_id & 15]; }
static inline void apf_bridge_file_size_write(uint32_t v) { g_slot_sizes[g_slot_id & 15] = v; }
static inline uint32_t gb_cart_id_read(void) { return g_gb_hw ? 0x47420001u : 0u; }
static inline void gb_cart_ctrl_write(uint32_t v) {
    g_gb_ctrl = v & 3u;
    if (!(g_gb_ctrl & 1u)) {
        g_gb_ram_en = 0;
        g_gb_rom_bank = 1;
        g_gb_ram_bank = 0;
    }
}
static inline void gb_cart_access_write(uint32_t v) {
    uint32_t we = (v >> 24) & 1u;
    uint32_t a  = (v >> 8) & 0xFFFFu;
    uint8_t  wd = (uint8_t)v;
    if (!g_gb_sw || !(g_gb_ctrl & 1u)) {
        g_gb_rdata = 0xFFu;
        return;
    }
    if (we) {
        if (!(g_gb_ctrl & 2u)) return; /* TRUST bit required for writes! */
        if (a < 0x2000u) g_gb_ram_en = (wd & 0xFu) == 0xAu;
        else if (a < 0x4000u) g_gb_rom_bank = (wd & 3u) ? (wd & 3u) : 1u;
        else if (a < 0x6000u) g_gb_ram_bank = wd & 3u;
        else if (a >= 0xA000u && a < 0xC000u && g_gb_ram_en)
            g_gb_ram[((uint32_t)g_gb_ram_bank << 13) | (a & 0x1FFFu)] = wd;
    } else {
        if (a < 0x4000u) g_gb_rdata = g_gb_rom[a];
        else if (a < 0x8000u) g_gb_rdata = g_gb_rom[((uint32_t)g_gb_rom_bank << 14) | (a & 0x3FFFu)];
        else if (a >= 0xA000u && a < 0xC000u && (g_gb_ctrl & 2u) && g_gb_ram_en)
            g_gb_rdata = g_gb_ram[((uint32_t)g_gb_ram_bank << 13) | (a & 0x1FFFu)];
        else g_gb_rdata = 0xFFu;
    }
}
static inline uint32_t gb_cart_access_read(void) {
    return (g_gb_sw ? 0x40000000u : 0u) | g_gb_rdata;
}
static inline void timer0_uptime_latch_write(uint32_t v) { (void)v; }
static inline uint64_t timer0_uptime_cycles_read(void) { g_uptime += 25000ULL; return g_uptime; }

#define __GENERATED_CSR_H
#define __GENERATED_SOC_H
#define CONFIG_CLOCK_FREQUENCY 62500000u

#include "layout.h"
#include "n64rt.h"

void n64rt_log(const char *fmt, ...) { (void)fmt; }
int  n64rt_gbv_look(int n) { (void)n; return 0; }
u32  n64rt_gbv_id(int n) { (void)n; return 0; }
void n64rt_gbv_power(int n, int on) { (void)n; (void)on; }
void n64rt_gbv_block(int n, u32 addr) { (void)n; (void)addr; }
u8   n64rt_gbv_read(int n, u32 addr) { (void)n; (void)addr; return 0; }
void n64rt_gbv_write(int n, u32 addr, u8 value) { (void)n; (void)addr; (void)value; }
void n64rt_gbv_resume(int n, u64 delta) { (void)n; (void)delta; }
void n64rt_gbv_make(int n) { (void)n; }

#include "n64rt_pak.c"

int main(void) {
    void *mapped = mmap((void *)(uintptr_t)(LAYOUT_CPAK & ~0xFFFUL), 0x24000,
                        PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    assert(mapped != MAP_FAILED);
    memset((void *)(uintptr_t)LAYOUT_CPAK, 0xFF, 4 * 0x8000);
    g_ia2 = 0x40000000u; /* Verify n64rt_pak_init clears stuck motor bit 30 */
    n64rt_pak_init();
    assert((g_ia2 & 0x40000000u) == 0);

    /* 1. Rumble Pak (k == 2 on Controller 1) */
    g_ia0 = 2u;
    assert(n64rt_pak_kind(0) == N64RT_PAK_RUMBLE);
    assert(n64rt_pak_kind(1) == N64RT_PAK_NONE);

    u8 blk[32];
    memset(blk, 0xFE, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 1) == 0);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 0) == 0);
    for (int i = 0; i < 32; i++) assert(blk[i] == 0x00);

    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0);

    memset(blk, 0x80, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 1) == 0);
    memset(blk, 0, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 0) == 0);
    for (int i = 0; i < 32; i++) assert(blk[i] == 0x80);

    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0x40000000u);

    memset(blk, 0xAA, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 0) == 0);
    for (int i = 0; i < 32; i++) assert(blk[i] == 0x00);

    memset(blk, 0x00, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0);

    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0x40000000u);
    memset(blk, 0xFE, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0);

    /* 2. Menu hot-switch away from Rumble Pak while motor ON -> immediately clears motor */
    memset(blk, 0x80, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 1) == 0);
    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    assert((g_ia2 & 0x40000000u) == 0x40000000u);
    g_ia0 = 0u; /* Switched to None */
    assert(n64rt_pak_rw(0, 0xC000u, blk, 0) == 1);
    assert((g_ia2 & 0x40000000u) == 0);

    /* 3. All 4 Controller Paks (k == 7) */
    g_ia0 = 7u;
    for (int ch = 0; ch < 4; ch++) {
        assert(n64rt_pak_kind(ch) == N64RT_PAK_CONTROLLER);
        assert(n64rt_pak_rw(ch, 0x0020u, blk, 0) == 0);
        assert((blk[25] & 1u) == 1u);
        memset(blk, 0x30 + ch, 32);
        assert(n64rt_pak_rw(ch, 0x0500u, blk, 1) == 0);
    }
    assert(g_slot_sizes[LAYOUT_CPAK_SLOT] == 0x8000u);
    for (int ch = 0; ch < 4; ch++) {
        memset(blk, 0, 32);
        assert(n64rt_pak_rw(ch, 0x0500u, blk, 0) == 0);
        for (int i = 0; i < 32; i++) assert(blk[i] == (uint8_t)(0x30 + ch));
    }

    /* 4. Physical Cartridge Transfer Pak on Controller 1 (k == 9) */
    g_gb_hw = 1u;
    g_gb_sw = 0u; /* Start with empty slot */
    g_ia0   = 9u;
    n64rt_pak_init();
    assert(n64rt_pak_kind(0) == N64RT_PAK_TRANSFER);
    assert(n64rt_pak_kind(1) == N64RT_PAK_NONE);

    memset(blk, 0x84, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 1) == 0);
    memset(blk, 0, 32);
    assert(n64rt_pak_rw(0, 0x8000u, blk, 0) == 0);
    assert(blk[0] == 0x84u);
    assert(n64rt_pak_rw(0, 0xB000u, blk, 0) == 0);
    assert((blk[0] & 0x80u) == 0u); /* No cartridge inserted */

    /* Build clean-room MBC3 GB image with CRC-32 == 0x46195417 at 0x104..0x133 */
    memset(g_gb_rom, 0x55, sizeof g_gb_rom);
    memset(g_gb_ram, 0xFF, sizeof g_gb_ram);
    static const char clean_logo_str[] = "GAMEBUB TRANSFER PAK CLEANROOM TEST VECTOR  ";
    static const uint8_t clean_logo_crc[4] = { 0x11, 0xfa, 0x19, 0xd8 };
    g_gb_rom[0x100] = 0x00; g_gb_rom[0x101] = 0xC3; g_gb_rom[0x102] = 0x50; g_gb_rom[0x103] = 0x01;
    memcpy(&g_gb_rom[0x104], clean_logo_str, 44);
    memcpy(&g_gb_rom[0x130], clean_logo_crc, 4);
    memcpy(&g_gb_rom[0x134], "GBTP TEST       ", 16);
    g_gb_rom[0x147] = 0x13; /* MBC3 + RAM + BATTERY */
    g_gb_rom[0x148] = 0x01; /* 64 KiB ROM */
    g_gb_rom[0x149] = 0x03; /* 32 KiB RAM */
    uint8_t hsum = 0;
    for (uint32_t i = 0x134; i <= 0x14C; i++) hsum = (uint8_t)(hsum - g_gb_rom[i] - 1u);
    g_gb_rom[0x14D] = hsum;
    for (uint32_t b = 0; b < 4; b++) g_gb_rom[b * 0x4000u + 0x3FE0u] = (uint8_t)(0xB0u + b);

    /* Hot-insert physical GB cartridge after >1 s uptime */
    g_gb_sw = 1u;
    g_uptime += 70000000ULL;
    assert(n64rt_pak_rw(0, 0xB000u, blk, 0) == 0);
    assert((blk[0] & 0xC0u) == 0xC0u); /* Cartridge present (0x80) + changed/inserted (0x40) */

    /* Power on cartridge (0xB000 = 0x01) -> verify TRUST enabled (g_gb_ctrl == 3) */
    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xB000u, blk, 1) == 0);
    assert(g_gb_ctrl == 3u);
    assert(n64rt_pak_rw(0, 0xB000u, blk, 0) == 0);
    assert((blk[0] & 0x8Du) == 0x8Du);

    /* Read header title at bank 0 (0x0120..0x013F -> 0xC120) */
    memset(blk, 0x00, 32);
    assert(n64rt_pak_rw(0, 0xA000u, blk, 1) == 0);
    assert(n64rt_pak_rw(0, 0xC120u, blk, 0) == 0);
    assert(memcmp(&blk[0x14], "GBTP TEST", 9) == 0);

    /* Switch MBC3 ROM bank to 3, read 0x7FE0 (Transfer Pak bank 1, 0xFFE0) */
    memset(blk, 0x03, 32);
    assert(n64rt_pak_rw(0, 0xE000u, blk, 1) == 0); /* 0x2000 in GB space */
    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xA000u, blk, 1) == 0);
    assert(n64rt_pak_rw(0, 0xFFE0u, blk, 0) == 0);
    assert(blk[0] == 0xB3u);

    /* Enable MBC3 SRAM (0x0000 = 0x0A), select RAM bank 2 (0x4000 = 2), write & read 0xA100 */
    memset(blk, 0x00, 32);
    assert(n64rt_pak_rw(0, 0xA000u, blk, 1) == 0);
    memset(blk, 0x0A, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0);
    memset(blk, 0x01, 32);
    assert(n64rt_pak_rw(0, 0xA000u, blk, 1) == 0);
    memset(blk, 0x02, 32);
    assert(n64rt_pak_rw(0, 0xC000u, blk, 1) == 0); /* 0x4000 in GB space */
    memset(blk, 0x02, 32);
    assert(n64rt_pak_rw(0, 0xA000u, blk, 1) == 0);
    for (int i = 0; i < 32; i++) blk[i] = (uint8_t)(0xE0u + i);
    assert(n64rt_pak_rw(0, 0xE100u, blk, 1) == 0); /* 0xA100 in GB space */
    memset(blk, 0, 32);
    assert(n64rt_pak_rw(0, 0xE100u, blk, 0) == 0);
    for (int i = 0; i < 32; i++) assert(blk[i] == (uint8_t)(0xE0u + i));

    /* Live physical cartridge pull while powered on -> immediate 0x40 pulled status & bus off */
    g_gb_sw = 0u;
    assert(n64rt_pak_rw(0, 0xB000u, blk, 0) == 0);
    assert(blk[0] == 0x41u); /* bit 7 clear (no cart), bit 6 set (pulled), bit 0 set (pak access) */
    assert(g_gb_ctrl == 0u);

    printf("rumble_host (incl. Transfer Pak): PASS\n");
    return 0;
}
