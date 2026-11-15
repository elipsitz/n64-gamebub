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

static inline uint32_t apf_interact_interact0_read(void) { return g_ia0; }
static inline uint32_t apf_interact_interact2_read(void) { return g_ia2; }
static inline void apf_interact_interact2_write(uint32_t v) { g_ia2 = v; }
static inline uint32_t apf_bridge_slot_id_read(void) { return g_slot_id; }
static inline void apf_bridge_slot_id_write(uint32_t v) { g_slot_id = v; }
static inline uint32_t apf_bridge_file_size_read(void) { return g_slot_sizes[g_slot_id & 15]; }
static inline void apf_bridge_file_size_write(uint32_t v) { g_slot_sizes[g_slot_id & 15] = v; }
static inline uint32_t gb_cart_id_read(void) { return 0; }
static inline void gb_cart_ctrl_write(uint32_t v) { (void)v; }
static inline void gb_cart_access_write(uint32_t v) { (void)v; }
static inline uint32_t gb_cart_access_read(void) { return 0; }
static inline void timer0_uptime_latch_write(uint32_t v) { (void)v; }
static inline uint64_t timer0_uptime_cycles_read(void) { return 12345678ULL; }

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

    printf("rumble_host: PASS\n");
    return 0;
}
