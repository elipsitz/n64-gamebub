/* The N64 controller from Game Bub's built-in controls or docked gamepads and the core's settings: n64rt_pad_map(), a pure
 * function (no hardware), so that lang/n64rt/test/pad_test.py can verify every combination of settings and inputs on the host.
 *
 * Game Bub InputExtendedV0 splits cleanly into:
 *   - Handheld / stickless pads (`!analog`: deviceType 1 Handheld, or deviceType 2 DigitalGamepad without stick data):
 *     * A/B/Start -> N64 A/B/Start, L -> N64 Z, D-Pad -> N64 Analog Stick, Y -> C-Left, X -> C-Right
 *     * "Handheld R Mode" (`set0[14:10]`, 0x70000004): 0 Normal N64 R, 1 R+ABXY = C-Btns (default), 2 R+DPad = 60% Walk, 3 R = N64 L
 *     * "Handheld Select" (`set1[3:0]`, 0x70000038 mask 0xFFFFFFF0):
 *         0  Shift Layer (default): holding Select suppresses D-Pad/ABXY/L/R from their normal outputs and maps
 *            Select + L -> N64 L, Select + R -> N64 R, Select + D-Pad -> N64 D-Pad, Select + X/B/Y/A -> C-Up/Down/Left/Right, Select + Start -> Start
 *         11 Classic C-Down: Select -> C-Down, Start -> Start
 *         12 Sel+Start macro: Select+Start -> Start, Start alone -> C-Up, Select alone -> C-Down
 *   - Docked Analog Gamepads (`analog`: deviceType 3, or deviceType 2 reporting active analog stick bytes):
 *     * Native 1:1 layout with zero modifier interference (`Handheld R Mode` and `Select Shift` do not hijack docked inputs)
 *     * Left Stick -> N64 Analog Stick (with radial deadzone `set1[9:5]`), Right Stick -> C-Buttons (`set1[14:10]`)
 *     * "Docked Triggers" (`set1[4]`, 0x70000038 mask 0xFFFFFFEF):
 *         0   Standard (default): L1 -> N64 L, R1 -> N64 R, L2/LT -> N64 Z, R2/RT -> N64 Z
 *         16  MIRLO Legacy: L1 -> N64 Z, L2/LT -> N64 L, R1 -> N64 R, R2/RT -> C-Up
 *     * "N64 D-Pad" (`set1[23:22]`, 0x70000030): 0 Auto (Gamepad D-Pad on docked `analog` pads, Off on handheld), 1 Always D-Pad, 2 L Stick, 3 R Stick */
#ifndef N64RT_PAD_H
#define N64RT_PAD_H
#include <stdint.h>

#define CONT_A 0x8000u
#define CONT_B 0x4000u
#define CONT_G 0x2000u          /* Z */
#define CONT_START 0x1000u
#define CONT_UP 0x0800u
#define CONT_DOWN 0x0400u
#define CONT_LEFT 0x0200u
#define CONT_RIGHT 0x0100u
#define CONT_L 0x0020u
#define CONT_R 0x0010u
#define CONT_E 0x0008u          /* C-up */
#define CONT_D 0x0004u          /* C-down */
#define CONT_C 0x0002u          /* C-left */
#define CONT_F 0x0001u          /* C-right */
/* APF_INPUT's keys */
#define KEY_DPAD_UP    (1u << 0)
#define KEY_DPAD_DOWN  (1u << 1)
#define KEY_DPAD_LEFT  (1u << 2)
#define KEY_DPAD_RIGHT (1u << 3)
#define KEY_A      (1u << 4)
#define KEY_B      (1u << 5)
#define KEY_X      (1u << 6)
#define KEY_Y      (1u << 7)
#define KEY_L1     (1u << 8)
#define KEY_R1     (1u << 9)
#define KEY_L2     (1u << 10)
#define KEY_R2     (1u << 11)
#define KEY_SELECT (1u << 14)
#define KEY_START  (1u << 15)
#define KEY_TYPE(k) ((k) >> 28)          /* 1 Pocket, 2 dock pad without analog, 3 dock pad with analog */

/* a stick's two bytes (0x80 centred; Y up is the byte's low end) as the N64's stick, -80 .. 80 each: a radial dead zone (dzc: the
 * setting's code) -- nothing within that distance of the centre, past it the deflection linear from the zone's edge to the end of
 * the range, along the stick's own direction (an axis-by-axis zone would snap a slight angle onto the axes) */
static inline uint32_t n64rt_pad_isqrt(uint32_t v)
{
    uint32_t r = 0, b = 1u << 14;
    while (b) { if ((r + b) * (r + b) <= v) r += b; b >>= 1; }
    return r;
}
static inline void n64rt_pad_stick(uint32_t j, uint32_t dzc, int8_t *x, int8_t *y)
{
    const int ax = (int)(j & 0xFFu) - 128, ay = 128 - (int)((j >> 8) & 0xFFu);
    const int t = (dzc >= 1u && dzc <= 15u) ? (int)(dzc - 1u) * 13 * 128 / 200 : 13 * 128 / 100;
    const int r = (int)n64rt_pad_isqrt((uint32_t)(ax * ax + ay * ay));
    if (r <= t) { *x = 0; *y = 0; return; }
    const int den = r * (127 - t);
    int ox = ax * (r - t) * 80 / den, oy = ay * (r - t) * 80 / den;
    *x = (int8_t)(ox > 80 ? 80 : ox < -80 ? -80 : ox);
    *y = (int8_t)(oy > 80 ? 80 : oy < -80 ? -80 : oy);
}
/* the Pocket key a button setting names (0: no key) */
static inline uint32_t n64rt_pad_key(uint32_t code, uint32_t dflt)
{
    switch (code) {
    case 0:  return dflt;
    case 1:  return KEY_L1;
    case 2:  return KEY_R1;
    case 3:  return KEY_L2;
    case 4:  return KEY_R2;
    case 6:  return KEY_A;
    case 7:  return KEY_B;
    case 8:  return KEY_X;
    case 9:  return KEY_Y;
    case 10: return KEY_SELECT;
    case 11: return KEY_START;
    default: return 0;
    }
}
static inline void n64rt_pad_map(uint32_t k, uint32_t j, uint32_t set0, uint32_t set1, uint16_t *button, int8_t *stick_x, int8_t *stick_y)
{
    const uint32_t type = KEY_TYPE(k);
    /* stick bytes to believe: a type 3 pad's always, a type 2 pad's unless they are what a pad with none would send */
    const int analog = type == 3u || (type == 2u && j != 0u && j != 0xFFFFFFFFu);
    /* the dock raises the D-pad's keys too while a pad's left stick is pushed (for the Pocket's menus): when a setting reads the
     * left stick, a D-pad key that points where the stick does, past a quarter of its range, is that copy and is dropped */
    if (analog && (((set1 >> 15) & 31u) == 1u || ((set1 >> 10) & 31u) == 2u || ((set1 >> 22) & 3u) == 2u)) {
        const int lx = (int)(j & 0xFFu) - 128, ly = (int)((j >> 8) & 0xFFu) - 128;
        if (lx < -32) k &= ~KEY_DPAD_LEFT;
        if (lx > 32) k &= ~KEY_DPAD_RIGHT;
        if (ly < -32) k &= ~KEY_DPAD_UP;
        if (ly > 32) k &= ~KEY_DPAD_DOWN;
    }
    uint16_t b = 0;
    const uint32_t scode = set1 & 15u;          /* Handheld Select / Start mode (`set1[3:0]`) */
    const int legacy_trig = (set1 & 0x10u) != 0u; /* Docked Triggers (`set1[4]`): 0 Standard, 1 MIRLO Legacy */

    /* Handheld Shift Layer (when `!analog` and `scode == 0` and Select held): exposes N64 L, R, D-Pad, and all 4 C-Buttons cleanly */
    if (!analog && scode == 0u && (k & KEY_SELECT) != 0u) {
        if (k & KEY_L1)         b |= CONT_L;
        if (k & KEY_R1)         b |= CONT_R;
        if (k & KEY_DPAD_UP)    b |= CONT_UP;
        if (k & KEY_DPAD_DOWN)  b |= CONT_DOWN;
        if (k & KEY_DPAD_LEFT)  b |= CONT_LEFT;
        if (k & KEY_DPAD_RIGHT) b |= CONT_RIGHT;
        if (k & KEY_X)          b |= CONT_E;
        if (k & KEY_B)          b |= CONT_D;
        if (k & KEY_Y)          b |= CONT_C;
        if (k & KEY_A)          b |= CONT_F;
        if (k & KEY_START)      b |= CONT_START;
        *button = b;
        *stick_x = 0;
        *stick_y = 0;
        return;
    }

    const uint32_t rm = (set0 >> 10) & 31u;     /* Handheld R Mode (`set0[14:10]`): applies only when `!analog` */
    const int face = !analog && (rm == 1u);
    const int half = !analog && (rm == 2u);
    const int r_is_l = !analog && (rm == 3u);
    const uint32_t mkey = (face || half || r_is_l) ? KEY_R1 : 0u;
    const int rmod = (k & mkey) != 0u;
    k &= ~mkey;
    if (rmod && face) {
        if (k & KEY_X) b |= CONT_E;
        if (k & KEY_B) b |= CONT_D;
        if (k & KEY_Y) b |= CONT_C;
        if (k & KEY_A) b |= CONT_F;
        k &= ~(KEY_A | KEY_B | KEY_X | KEY_Y);
    }
    if (rmod && r_is_l) b |= CONT_L;

    if (scode >= 12u && scode <= 15u) {         /* Start macro (`12` = Select+Start, etc.) */
        static const uint16_t chords[4] = { KEY_SELECT | KEY_START, KEY_Y | KEY_X, KEY_SELECT | KEY_R2, KEY_SELECT | KEY_Y };
        const uint32_t chord = chords[scode - 12u];
        if ((k & chord) == chord) { b |= CONT_START; k &= ~chord; }
        else if (k & KEY_START) b |= CONT_E;
    } else if (scode == 0u) {
        if (k & KEY_START) b |= CONT_START;
        k &= ~(KEY_START | KEY_SELECT);         /* Select is Shift on handheld, free/clean on docked */
    } else {
        const uint32_t skey = n64rt_pad_key(scode, KEY_START);
        if (k & skey) b |= CONT_START;
        if (skey != KEY_START && (k & KEY_START)) b |= CONT_E;
        k &= ~skey;
    }

    if (k & KEY_A) b |= CONT_A;
    if (k & KEY_B) b |= CONT_B;

    if (analog && !legacy_trig) {               /* Standard Docked Gamepad triggers: L1=L, R1=R, L2/R2=Z */
        if (k & KEY_L1) b |= CONT_L;
        if (k & KEY_R1) b |= CONT_R;
        if (k & (KEY_L2 | KEY_R2)) b |= CONT_G;
    } else {                                    /* Handheld (`!analog`) or MIRLO Legacy Docked triggers */
        if (k & KEY_L1) b |= CONT_G;
        if (k & KEY_L2) b |= CONT_L;
        if (k & KEY_R1) b |= CONT_R;
        if (k & KEY_R2) b |= CONT_E;
    }

    if (scode != 0u && (k & KEY_SELECT)) b |= CONT_D;
    if (k & KEY_Y) b |= CONT_C;
    if (k & KEY_X) b |= CONT_F;
    const uint32_t cm = (set1 >> 10) & 31u;     /* C-Buttons Extra */
    if ((cm == 1u || cm == 2u) && analog) {
        const int csh = cm == 1u ? 16 : 0;
        const int rx = (int)((j >> csh) & 0xFFu) - 128, ry = (int)((j >> (csh + 8)) & 0xFFu) - 128;
        const int ax = rx < 0 ? -rx : rx, ay = ry < 0 ? -ry : ry;
        if (ax > ay) { if (ax > 64) b |= rx < 0 ? CONT_C : CONT_F; }
        else if (ay > 64) b |= ry < 0 ? CONT_E : CONT_D;
    }
    if (cm == 3u) {
        if (k & KEY_DPAD_UP) b |= CONT_E;
        if (k & KEY_DPAD_DOWN) b |= CONT_D;
        if (k & KEY_DPAD_LEFT) b |= CONT_C;
        if (k & KEY_DPAD_RIGHT) b |= CONT_F;
    }

    const uint32_t mode = (set1 >> 15) & 31u;   /* Analog Stick */
    int8_t sx = 0, sy = 0;
    int from_dpad = mode != 1u && mode != 2u && mode != 3u;
    if (!from_dpad && mode != 3u) {
        int8_t x = 0, y = 0;
        if (analog) {
            const int sh = mode == 2u ? 16 : 0;
            const uint32_t dzc = (set1 >> 5) & 31u;
            n64rt_pad_stick(j >> sh, dzc, &x, &y);
        }
        sx = x; sy = y;
        if (type != 3u && sx == 0 && sy == 0) from_dpad = 1;
    }
    if (from_dpad) {
        const int part = rmod && half;
        const int8_t d = part ? 48 : 80;
        if (k & KEY_DPAD_LEFT) sx -= d;
        if (k & KEY_DPAD_RIGHT) sx += d;
        if (k & KEY_DPAD_UP) sy += d;
        if (k & KEY_DPAD_DOWN) sy -= d;
        if (part && sx && sy) { sx = (int8_t)(sx < 0 ? -34 : 34); sy = (int8_t)(sy < 0 ? -34 : 34); }
    }
    const uint32_t dp = (set1 >> 22) & 3u;      /* N64 D-Pad: 0 Auto (Gamepad), 1 Always D-Pad, 2 L Stick, 3 R Stick */
    if (dp == 1u || (dp == 0u && analog)) {
        if (k & KEY_DPAD_UP) b |= CONT_UP;
        if (k & KEY_DPAD_DOWN) b |= CONT_DOWN;
        if (k & KEY_DPAD_LEFT) b |= CONT_LEFT;
        if (k & KEY_DPAD_RIGHT) b |= CONT_RIGHT;
    } else if (dp >= 2u && analog) {
        const int sh = dp == 3u ? 16 : 0;
        const int x = (int)((j >> sh) & 0xFFu) - 128, y = (int)((j >> (sh + 8)) & 0xFFu) - 128;
        if (x < -64) b |= CONT_LEFT;
        if (x > 64) b |= CONT_RIGHT;
        if (y < -64) b |= CONT_UP;
        if (y > 64) b |= CONT_DOWN;
    }
    *button = b;
    *stick_x = sx;
    *stick_y = sy;
}
#endif
