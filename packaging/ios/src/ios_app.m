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
static void overlay_when_window(void)
{
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        int n = 0;
        SDL_Window **w = SDL_GetWindows(&n);
        if (w && n > 0 && (SDL_GetWindowFlags(w[n - 1]) & SDL_WINDOW_VULKAN)) {
            touchpad_overlay_attach(w[n - 1]);
            [t invalidate];
        }
        SDL_free(w);
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
