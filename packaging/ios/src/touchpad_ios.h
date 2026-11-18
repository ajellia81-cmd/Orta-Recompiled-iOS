/* touchpad_ios.h - the touch controls as one virtual SDL gamepad on iOS (touchpad_ios.c: the pad, overlay_ios.m: the
 * controls drawn over SDL's view). SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef ORTA_TOUCHPAD_IOS_H
#define ORTA_TOUCHPAD_IOS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The overlay's buttons, the same bits as the Android port's TouchOverlay (touchpad.c's map). */
enum {
    TP_A = 1 << 0, TP_B = 1 << 1, TP_X = 1 << 2, TP_Y = 1 << 3, TP_WHITE = 1 << 4, TP_BLACK = 1 << 5,
    TP_START = 1 << 6, TP_LT = 1 << 7, TP_RT = 1 << 8, TP_STICK = 1 << 9, TP_BACK = 1 << 10, TP_L3 = 1 << 11,
    TP_R3 = 1 << 12, TP_UP = 1 << 13, TP_DOWN = 1 << 14, TP_LEFT = 1 << 15, TP_RIGHT = 1 << 16
};

struct SDL_Window;

/* after SDL_Init(SDL_INIT_GAMEPAD): the virtual pad attached unless a real pad is there */
void touchpad_init(void);
/* the overlay's state (main thread): buttons as above, axes -1..1, triggers 0..1 */
void touchpad_set(uint32_t buttons, float lx, float ly, float lt, float rt, float rx, float ry);
/* a real pad was used / the screen was touched: the virtual pad off / on (mode "automatic") */
void touchpad_enable(int on);
/* external pads 10, the touch pad 0 - for the toolkit's xbox_InputSetPadPriority */
int touchpad_pad_priority(const char *name);

/* overlay_ios.m (main thread): the controls over the window's view, and off again */
void touchpad_overlay_attach(struct SDL_Window *win);
void touchpad_overlay_detach(void);

#ifdef __cplusplus
}
#endif
#endif
