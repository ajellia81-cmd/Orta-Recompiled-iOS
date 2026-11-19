/* ios_app.h - the iOS app's threads (packaging/ios, 2026-11-18). SPDX-License-Identifier: GPL-3.0-or-later
 *
 * UIKit and SDL's event pump belong to the main thread, but the title's first thread never returns to the caller
 * (it runs the XBE's entry point), and the toolkit's NV2A thread makes and drives the window. So on iOS the work runs
 * on a thread of its own and the main thread stays in a loop that keeps UIKit's run loop going and pumps SDL's
 * events (touches, pads, window events, SDL_RunOnMainThread calls from the NV2A thread - toolkit nv2a_vk.c,
 * XR_VK_IOS). Used by src/main.c. */
#ifndef ORTA_IOS_APP_H
#define ORTA_IOS_APP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* First thing in main() (main thread): SDL's video, pads and audio started here (SDL3 wants video on the main
 * thread), landscape only, the screen kept on, the touch controls and the BACK menu (touch_ios.m, the Android
 * port's; over the game's window as soon as there is one) and the pad ranking (real pads before the touch pad). */
void orta_ios_start(void);

/* First start, game/ empty (main.c): the system file picker for the disc image (the Android launcher's "choose the
 * disc image"); its path into out, opened in place and kept accessible for the installer. 0: cancelled. */
int orta_ios_pick_disc(char *out, size_t n);
/* 1 when game/ holds a disc image (.iso / .xiso) the installer will take */
int orta_ios_game_dir_has_image(const char *game_dir);

/* The screen's short side in pixels (0 before orta_ios_start): the render resolution 1:1 to the screen
 * (recomp_manual.c, main.c). */
int orta_ios_native_lines(void);
/* rows of 480 the present cuts off at the top and the bottom (RECOMP_PRESENT_CROP_Y): native_lines then counts the
 * whole frame's lines that put the rows in between 1:1 on the screen */
void orta_ios_set_crop_y(int lines);

/* The renderer's shader / pipeline lists shipped in the app (OrtaRecomp.app/seed: progcache.bin, vkspirv.bin,
 * vkpipes.bin) copied into data_dir where it has none yet, so the boot prewarm builds every pipeline before the
 * first frame and no scene stutters the first time it is played (host_linux.c, before the renderer starts). */
void orta_ios_seed_caches(const char *data_dir);

/* Runs fn(arg) on a new thread with a 16 MB stack and pumps the main thread's events until it returns; returns its
 * result. Call it on the main thread, after orta_ios_start. */
int orta_ios_run_game(int (*fn)(void *), void *arg);

#ifdef __cplusplus
}
#endif
#endif
