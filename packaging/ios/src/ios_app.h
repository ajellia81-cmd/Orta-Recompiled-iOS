/* ios_app.h - the iOS app's threads (packaging/ios, 2026-11-18). SPDX-License-Identifier: GPL-3.0-or-later
 *
 * UIKit and SDL's event pump belong to the main thread, but the title's first thread never returns to the caller
 * (it runs the XBE's entry point), and the toolkit's NV2A thread makes and drives the window. So on iOS the work runs
 * on a thread of its own and the main thread stays in a loop that keeps UIKit's run loop going and pumps SDL's
 * events (touches, pads, window events, SDL_RunOnMainThread calls from the NV2A thread - toolkit nv2a_vk.c,
 * XR_VK_IOS). Used by src/main.c. */
#ifndef ORTA_IOS_APP_H
#define ORTA_IOS_APP_H

#ifdef __cplusplus
extern "C" {
#endif

/* First thing in main() (main thread): SDL's video, pads and audio started here (SDL3 wants video on the main
 * thread), landscape only, the touch controls (a virtual gamepad, drawn over the game's window as soon as there is
 * one) and the pad ranking (real pads before the touch pad). */
void orta_ios_start(void);

/* The game window's safe-area inset on its wider side, as a fraction of the window's width (0 before the window):
 * the HUD at the screen's edges keeps out of it (recomp_manual.c). */
float orta_ios_safe_x(void);

/* The screen's short side in pixels (0 before orta_ios_start): the render resolution 1:1 to the screen
 * (recomp_manual.c, main.c). */
int orta_ios_native_lines(void);

/* Runs fn(arg) on a new thread with a 16 MB stack and pumps the main thread's events until it returns; returns its
 * result. Call it on the main thread, after orta_ios_start. */
int orta_ios_run_game(int (*fn)(void *), void *arg);

#ifdef __cplusplus
}
#endif
#endif
