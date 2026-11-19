/* ios_app.m - see ios_app.h. SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <SDL3/SDL.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>
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
    /* user-interactive like the main thread: the default class runs on the efficiency cores with coalesced timers */
    pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
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

static int s_native_lines;            /* the screen's short side in pixels (1320 on an iPhone 18 Pro Max) */

static int s_crop_y;                  /* rows of 480 the present cuts off at the top and the bottom (main.c) */

void orta_ios_set_crop_y(int lines)
{
    s_crop_y = lines > 0 && lines < 120 ? lines : 0;
}

/* the frame's lines that put the rows shown 1:1 on the screen's pixels: 1320 x 480 / 448 = 1414 with Orta's 16 + 16
 * cut off (the 448 in between become the screen's 1320) */
int orta_ios_native_lines(void)
{
    if (s_crop_y > 0 && s_native_lines > 0)
        return (s_native_lines * 480 + (480 - 2 * s_crop_y) / 2) / (480 - 2 * s_crop_y);
    return s_native_lines;
}

/* The touch controls over the game's window: SDL makes that window later, on the NV2A thread's request (toolkit
 * nv2a_vk.c), so a main-thread timer looks for it (made with SDL_WINDOW_VULKAN) and attaches the controls once -
 * the Android port shows them from the game's start on, never over the installer (setGameRunning). */
static void overlay_when_window(void)
{
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        int n = 0, i;
        SDL_Window **w = SDL_GetWindows(&n);
        for (i = 0; w && i < n; i++)
            if (SDL_GetWindowFlags(w[i]) & SDL_WINDOW_VULKAN) {
                touchpad_overlay_attach(w[i]);
                [t invalidate];
                break;
            }
        SDL_free(w);
    }];
}

/* ── the display's refresh for FRAME PACING Display (toolkit host_vblank.c, iOS branch) ──────────────────────
 * A CADisplayLink on a thread of its own (its own run loop: the main thread's may be busy) asks for 120 Hz - the app
 * may use it (Info.plist CADisableMinimumFrameDurationOnPhone) - and counts refreshes; the toolkit's pacing thread
 * waits on the count. The guest's 60 Hz is then every 2nd refresh and each frame stays exactly two refreshes. */
@interface OrtaVBlank : NSObject
- (void)tick:(CADisplayLink *)l;
@end
static pthread_mutex_t s_vb_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_vb_cv = PTHREAD_COND_INITIALIZER;
static uint64_t s_vb_n;
static volatile int s_vb_running;
@implementation OrtaVBlank
- (void)tick:(CADisplayLink *)l
{
    (void)l;
    pthread_mutex_lock(&s_vb_mx);
    s_vb_n++;
    pthread_cond_broadcast(&s_vb_cv);
    pthread_mutex_unlock(&s_vb_mx);
}
@end

static void *vblank_thread(void *u)
{
    (void)u;
    pthread_setname_np("display link");
    @autoreleasepool {
        OrtaVBlank *t = [OrtaVBlank new];
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:t selector:@selector(tick:)];
        if (@available(iOS 15.0, *))
            l.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
        [l addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        fprintf(stderr, "[IOS] display link: up to %ld Hz\n", (long)UIScreen.mainScreen.maximumFramesPerSecond);
        for (;;)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
    }
    return NULL;
}

int xr_ios_vblank_open(void)
{
    if (!s_vb_running) {
        pthread_t t;
        pthread_attr_t at;
        int rc;
        s_vb_running = 1;
        pthread_attr_init(&at);
        pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
        rc = pthread_create(&t, &at, vblank_thread, NULL);
        pthread_attr_destroy(&at);
        if (rc != 0) {
            s_vb_running = 0;
            return 0;
        }
        pthread_detach(t);
    }
    return 1;
}

/* the next refresh; 0 when none came in 250 ms (in the background the link stops: the pacing falls back to its
 * timer and binds again with the next window / display change) */
int xr_ios_vblank_wait(void)
{
    struct timespec ts;
    uint64_t start;
    int ok = 1;
    pthread_mutex_lock(&s_vb_mx);
    start = s_vb_n;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 250000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    while (s_vb_n == start && ok)
        ok = pthread_cond_timedwait(&s_vb_cv, &s_vb_mx, &ts) == 0 || s_vb_n != start;
    pthread_mutex_unlock(&s_vb_mx);
    return s_vb_n != start;
}

void xr_ios_vblank_close(void)
{
}

/* ── the disc image at the first start (the Android launcher's "choose the disc image" in the system picker) ── */

@interface OrtaDiscPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic) BOOL done;
@property (nonatomic, strong) NSURL *url;
@end
@implementation OrtaDiscPicker
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)c;
    self.url = urls.firstObject;
    self.done = YES;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c { (void)c; self.done = YES; }
@end

int orta_ios_game_dir_has_image(const char *game_dir)
{
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(game_dir) error:nil]) {
        NSString *e = f.pathExtension.lowercaseString;
        if ([e isEqualToString:@"iso"] || [e isEqualToString:@"xiso"])
            return 1;
    }
    return 0;
}

int orta_ios_pick_disc(char *out, size_t n)
{
    OrtaDiscPicker *d = [OrtaDiscPicker new];
    UIWindow *win = nil;
    UIViewController *vc = [UIViewController new];
    UIDocumentPickerViewController *p;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class]) {
            win = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)sc];
            break;
        }
    if (!win)
        win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    vc.view.backgroundColor = UIColor.blackColor;
    win.rootViewController = vc;
    win.windowLevel = UIWindowLevelAlert;
    [win makeKeyAndVisible];
    /* opened in place, not copied: an image is several GB; the installer reads it from there (xr_game_setup's
     * image_path - never deleted, it is the player's file) */
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeDiskImage, UTTypeData ]
                                                                    asCopy:NO];
    p.delegate = d;
    p.allowsMultipleSelection = NO;
    [vc presentViewController:p animated:YES completion:nil];
    while (!d.done) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
            SDL_PumpEvents();
        }
    }
    win.hidden = YES;
    out[0] = 0;
    if (!d.url)
        return 0;
    if (![d.url startAccessingSecurityScopedResource])      /* kept open: the installer reads it next */
        fprintf(stderr, "[IOS] the picked image is not security scoped (reading it may fail)\n");
    snprintf(out, n, "%s", d.url.fileSystemRepresentation);
    fprintf(stderr, "[IOS] disc image picked: %s\n", out);
    return 1;
}

void orta_ios_start(void)
{
    /* MoltenVK: compile shaders / pipelines on every core (fewer and shorter hitches when a scene first appears) */
    setenv("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", "1", 0);
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
    {
        /* SDL3's display mode is in points with its pixel density: the pixels are the two multiplied */
        const SDL_DisplayMode *dm = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
        if (dm && dm->w > 0 && dm->h > 0) {
            float d = dm->pixel_density > 0.0f ? dm->pixel_density : 1.0f;
            int pw = (int)(dm->w * d + 0.5f), ph = (int)(dm->h * d + 0.5f);
            s_native_lines = pw < ph ? pw : ph;
            fprintf(stderr, "[IOS] screen %dx%d pixels (%dx%d points x %.2f)\n", pw > ph ? pw : ph,
                    s_native_lines, dm->w > dm->h ? dm->w : dm->h, dm->w > dm->h ? dm->h : dm->w, d);
        }
    }
    /* the screen stays on (Android: FLAG_KEEP_SCREEN_ON - the first start's install takes minutes, and a game
     * played with a pad touches nothing) */
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    touchpad_init();
    xbox_InputSetPadPriority(touchpad_pad_priority);   /* a real pad stays player 1's first choice */
    overlay_when_window();
}

void orta_ios_seed_caches(const char *data_dir)
{
    static const char *const names[] = { "progcache.bin", "vkspirv.bin", "vkpipes.bin", "vkpipes_vi.bin" };
    @autoreleasepool {
        NSString *seed = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"seed"];
        NSString *dst = [NSString stringWithUTF8String:data_dir];
        NSFileManager *fm = NSFileManager.defaultManager;
        unsigned i;
        for (i = 0; i < sizeof names / sizeof names[0]; i++) {
            NSString *n = [NSString stringWithUTF8String:names[i]];
            NSString *from = [seed stringByAppendingPathComponent:n], *to = [dst stringByAppendingPathComponent:n];
            NSError *err = nil;
            if (![fm fileExistsAtPath:from])
                continue;
            if ([fm fileExistsAtPath:to]) {
                fprintf(stderr, "[IOS] cache seed: data/%s is there - kept\n", names[i]);
                continue;
            }
            if ([fm copyItemAtPath:from toPath:to error:&err])
                fprintf(stderr, "[IOS] cache seed: data/%s from the app (%llu KB)\n", names[i],
                        [[fm attributesOfItemAtPath:to error:nil] fileSize] / 1024ull);
            else
                fprintf(stderr, "[IOS] cache seed: data/%s not copied (%s)\n", names[i],
                        err.localizedDescription.UTF8String);
        }
    }
}
