/* ios_app.m - see ios_app.h. SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <pthread.h>
#include <stdio.h>

#include "ios_app.h"
#include "touchpad_ios.h"

/* toolkit src/input/xinput_xbox.h (not included: its Win32 types clash with Objective-C's BOOL) */
extern void xbox_InputSetPadPriority(int (*prio)(const char *name));

typedef struct {
    int (*fn)(void *);
    void *arg;
    int rc;
    SDL_AtomicInt done;
} game_thread;

static void *game_entry(void *p)
{
    game_thread *g = (game_thread *)p;
    @autoreleasepool {
        g->rc = g->fn(g->arg);
    }
    SDL_SetAtomicInt(&g->done, 1);
    return NULL;
}

int orta_ios_run_game(int (*fn)(void *), void *arg)
{
    static game_thread g;
    pthread_attr_t at;
    pthread_t t;

    g.fn = fn;
    g.arg = arg;
    g.rc = 1;
    SDL_SetAtomicInt(&g.done, 0);
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 16u << 20);   /* the guest's first thread: the main thread's 1 MB is too little */
    if (pthread_create(&t, &at, game_entry, &g) != 0) {
        pthread_attr_destroy(&at);
        fprintf(stderr, "[IOS] game thread could not be started - running on the main thread\n");
        return fn(arg);
    }
    pthread_attr_destroy(&at);
    pthread_setname_np("main (event pump)");
    /* The main thread from here on: UIKit's run loop (touches, the overlay, Game Controller callbacks, GCD) and
     * SDL's queue (SDL_PumpEvents also runs the callbacks other threads queued with SDL_RunOnMainThread). The run
     * loop wait doubles as the sleep: it returns as soon as a source fires, else after 4 ms. */
    while (!SDL_GetAtomicInt(&g.done)) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004, true);
            SDL_PumpEvents();
        }
    }
    pthread_join(t, NULL);
    return g.rc;
}

/* The touch controls over the game's window: SDL makes that window later, on the NV2A thread's request (toolkit
 * nv2a_vk.c), so a main-thread timer looks for it and attaches the overlay once (overlay_ios.m keeps it on top). */
static volatile float s_safe_x;      /* the wider side's safe-area inset, as a fraction of the screen's width */

float orta_ios_safe_x(void)
{
    return s_safe_x;
}

/* The game's window (the NV2A thread's, made with SDL_WINDOW_VULKAN), or NULL; the caller SDL_free()s *list. */
static SDL_Window *game_window(SDL_Window ***list)
{
    int n = 0, i;
    SDL_Window **w = SDL_GetWindows(&n);
    *list = w;
    for (i = 0; w && i < n; i++)
        if (SDL_GetWindowFlags(w[i]) & SDL_WINDOW_VULKAN)
            return w[i];
    return NULL;
}

static void overlay_when_window(void)
{
    __block int attached = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        SDL_Window **list;
        SDL_Window *w = game_window(&list);
        (void)t;
        if (w) {
            SDL_Rect sa;
            int ww = 0, wh = 0;
            if (!attached) {
                touchpad_overlay_attach(w);
                attached = 1;
            }
            /* the safe area, for the HUD at the screen's edges (recomp_manual.c, aspect SCREEN); it changes when the
             * phone is turned the other way round */
            if (SDL_GetWindowSafeArea(w, &sa) && SDL_GetWindowSize(w, &ww, &wh) && ww > 0) {
                int l = sa.x, r = ww - sa.x - sa.w;
                float f = (float)(l > r ? l : r) / (float)ww;
                if (f != s_safe_x) {
                    s_safe_x = f;
                    fprintf(stderr, "[IOS] window %dx%d points, safe-area inset %.1f%% of the width\n", ww, wh,
                            100.0f * f);
                }
            }
        }
        SDL_free(list);
    }];
}

void orta_ios_start(void)
{
    /* (the hints and the thermal line follow the Lost World iOS port) */
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");        /* dimmed; a first swipe does not leave the game */
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");            /* touches stay touches (the overlay has them) */
    SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0");
    SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
    /* a frame rate that falls the longer one plays is the phone throttling as it heats: the log says when */
    fprintf(stderr, "[IOS] thermal state %ld at start (0 nominal .. 3 critical)\n",
            (long)NSProcessInfo.processInfo.thermalState);
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil
        queue:nil usingBlock:^(NSNotification *n) {
            (void)n;
            fprintf(stderr, "[IOS] thermal state now %ld (0 nominal .. 3 critical)\n",
                    (long)NSProcessInfo.processInfo.thermalState);
        }];
    if (!SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO))
        fprintf(stderr, "[IOS] SDL_InitSubSystem failed: %s\n", SDL_GetError());
    touchpad_init();
    xbox_InputSetPadPriority(touchpad_pad_priority);   /* a real pad stays player 1's first choice */
    overlay_when_window();
}
