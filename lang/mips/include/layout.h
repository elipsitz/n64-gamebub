/* Layout 8 (Game Bub): 64 MiB SDRAM + 512 KiB SRAM.
 * SDRAM holds:
 *   0x4000_0000 .. 0x400F_FFFF  (1 MiB)   n64rt.sys runtime (File ID 3)
 *   0x4010_0000 .. 0x434F_FFFF  (52 MiB)  resident N64 ROM  (File ID 0)
 *   0x4350_0000 .. 0x436F_FFFF  (2 MiB)   RDP 32-bit shadow plane
 *   0x4370_0000 .. 0x437F_FFFF  (1 MiB)   RDP hidden coverage plane
 *   0x4380_0000 .. 0x43FF_FFFF  (8 MiB)   N64 RDRAM
 * SRAM (0x3410_0000 .. 0x3417_FFFF, 512 KiB) holds:
 *   0x3410_8000 .. 0x3412_7FFF  (128 KiB) four 32 KiB Controller Paks (File ID 2 = slot 0)
 *   0x3413_0000 .. 0x3413_FFFF  (64 KiB)  n64savedb.txt (File ID 4)
 *   0x3414_0000 .. 0x3415_FFFF  (128 KiB) cartridge save: EEPROM / SRAM / FlashRAM (File ID 1)
 *   0x3416_0000 .. 0x3416_0FFF  (4 KiB)   FlashRAM page buffer & status words
 *   0x3416_2000 .. 0x3416_3FFF  (8 KiB)   Restart Game .data snapshot */
#ifndef __LAYOUT_H
#define __LAYOUT_H

#define LAYOUT_MARK             0x4D4C0008      /* "ML", layout 8 (Game Bub) */
#define LAYOUT_MARK_OFS         8

#define LAYOUT_FILE_PSRAM       0x00100000      /* all ROM bytes live in SDRAM starting at 1 MiB */
#define LAYOUT_ROM_RESIDENT_MAX 0x03400000      /* 52 MiB resident ROM window in SDRAM */
#define LAYOUT_FILE_MAX         0x04100000      /* end of the maximum 64 MiB ROM (1 MiB + 64 MiB) */
#define LAYOUT_SLOT_BRIDGE      0x00000000

/* Nonvolatile saves, Controller Paks, save DB, and restart snapshot in 512 KiB SRAM */
#define LAYOUT_SAVEDB           0x34130000      /* n64savedb.txt (File ID 4, up to 64 KiB, read-only) */
#define LAYOUT_SAVEDB_SLOT      4
#define LAYOUT_SAVEDB_MAX       0x00010000
#define LAYOUT_CPAK             0x34108000      /* Controller Pak 1..4 (32 KiB each; File ID 2 backs Pak 1) */
#define LAYOUT_CPAK_SLOT        2
#define LAYOUT_PAK_BYTES        0x8000
#define LAYOUT_PAK_CAPACITY     4               /* four 32 KiB Controller Paks reserved (0x34108000..0x34127FFF) */
#define LAYOUT_SAVE             0x34140000      /* File ID 1: EEPROM (512B/2KiB), SRAM (32KiB), or FlashRAM (128KiB) */
#define LAYOUT_SAVE_MAX         0x00020000
#define LAYOUT_SAVE_AUX         0x34160000      /* FlashRAM 128B page buffer and, at +0x100, status word pair */
#define LAYOUT_RESTART          0x34162000      /* Restart Game .data snapshot (8 KiB in SRAM, preserves 52 MiB ROM) */
#define LAYOUT_FREE             0x34164000      /* unused SRAM up to 0x34180000 */

/* 64 MiB SDRAM upper planes (above the 52 MiB ROM window 0x4010_0000..0x434F_FFFF) */
#define LAYOUT_SHADOW           0x43500000      /* 2 MiB RDP shadow plane (32-bit video output) */
#define LAYOUT_SHADOW_BYTES     0x00200000
#define LAYOUT_HID              0x43700000      /* 1 MiB RDP hidden coverage plane */
#define LAYOUT_RDRAM            0x43800000      /* 8 MiB N64 RDRAM */

/* Legacy Pocket Transfer Pak (SD), GameShark, and save-state placeholders kept harmlessly
 * so shared runtime translation units (n64rt_gbvirt.c, n64rt_cheat.c, n64rt_state.c) compile cleanly. */
#define LAYOUT_GBSAVE           0x42D00000
#define LAYOUT_GBSAVE_SLOT      5
#define LAYOUT_GBSAVE_MAX       0x00021000
#define LAYOUT_GS_PARAM         0x42D30000
#define LAYOUT_GS               0x42D40000
#define LAYOUT_GS_SLOT          7
#define LAYOUT_GS_MAX           0x00010000
#define LAYOUT_GBSAVE2          0x42D50000
#define LAYOUT_GBSAVE2_SLOT     6
#define LAYOUT_GBROM2           0x42E00000
#define LAYOUT_GBROM2_SLOT      9
#define LAYOUT_GBROM            0x43100000
#define LAYOUT_GBROM_SLOT       8
#define LAYOUT_GBROM_MAX        0x00300000
#define LAYOUT_STATE            0x42300000
#define LAYOUT_STATE_BYTES      0x00A00000

#endif
