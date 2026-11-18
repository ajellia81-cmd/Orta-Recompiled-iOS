/* overlay_ios.m - the touch controls over SDL's view on iOS (2026-11-18), after the Android port's TouchOverlay.java:
 * a floating stick on the left half, A B X Y, WHITE / BLACK, LT / RT, START and BACK. The state goes to the virtual
 * gamepad (touchpad_ios.c) on every change. Touches outside the controls fall through to SDL's view.
 * As in the Lost World iOS port: the controls keep inside the safe area (rounded corners, the camera cut-out), and a
 * connected game controller hides them (and detaches the touch pad) until it is gone again; hidden, nothing is
 * drawn.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <SDL3/SDL.h>
#include <math.h>

#include "touchpad_ios.h"

typedef struct { uint32_t bit; const char *label; CGFloat x, y, r; } OrtaButton;   /* centre in view fractions */

static const OrtaButton k_buttons[] = {
    { TP_A, "A", 0.88, 0.78, 0.055 }, { TP_B, "B", 0.95, 0.62, 0.055 },
    { TP_X, "X", 0.81, 0.62, 0.055 }, { TP_Y, "Y", 0.88, 0.46, 0.055 },
    { TP_WHITE, "W", 0.73, 0.40, 0.040 }, { TP_BLACK, "K", 0.73, 0.56, 0.040 },
    { TP_LT, "LT", 0.06, 0.12, 0.050 }, { TP_RT, "RT", 0.94, 0.12, 0.050 },
    { TP_START, "START", 0.56, 0.90, 0.045 }, { TP_BACK, "BACK", 0.44, 0.90, 0.045 },
};
#define N_BUTTONS (sizeof k_buttons / sizeof k_buttons[0])

@interface OrtaOverlay : UIView
@end

@implementation OrtaOverlay {
    UITouch *_stickTouch;
    CGPoint _stickOrigin, _stickPos;
    NSMutableDictionary<NSValue *, NSNumber *> *_held;   /* touch -> button bit */
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.opaque = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _held = [NSMutableDictionary dictionary];
    }
    return self;
}

- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }

- (CGFloat)unit { return MIN([self safe].size.width, [self safe].size.height); }

- (CGPoint)centre:(unsigned)i
{
    CGRect r = [self safe];
    return CGPointMake(r.origin.x + k_buttons[i].x * r.size.width, r.origin.y + k_buttons[i].y * r.size.height);
}

- (void)safeAreaInsetsDidChange
{
    [super safeAreaInsetsDidChange];
    [self setNeedsDisplay];
}

- (int)buttonAt:(CGPoint)p
{
    for (unsigned i = 0; i < N_BUTTONS; i++) {
        CGPoint c = [self centre:i];
        CGFloat dx = p.x - c.x, dy = p.y - c.y;
        CGFloat r = k_buttons[i].r * [self unit] * 1.9;    /* a forgiving hit area */
        if (dx * dx + dy * dy <= r * r)
            return (int)i;
    }
    return -1;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    (void)e;
    return [self buttonAt:p] >= 0 || p.x < [self safe].origin.x + [self safe].size.width * 0.45;
}

- (void)send
{
    uint32_t b = 0;
    float lx = 0, ly = 0, lt, rt;
    for (NSNumber *n in _held.allValues)
        b |= n.unsignedIntValue;
    if (_stickTouch) {
        CGFloat range = [self unit] * 0.14;
        lx = (float)fmax(-1.0, fmin(1.0, (_stickPos.x - _stickOrigin.x) / range));
        ly = (float)fmax(-1.0, fmin(1.0, (_stickPos.y - _stickOrigin.y) / range));
    }
    lt = (b & TP_LT) ? 1.0f : 0.0f;
    rt = (b & TP_RT) ? 1.0f : 0.0f;
    touchpad_set(b, lx, ly, lt, rt, 0, 0);
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    (void)e;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        int i = [self buttonAt:p];
        if (i >= 0)
            _held[[NSValue valueWithNonretainedObject:t]] = @(k_buttons[i].bit);
        else if (!_stickTouch && p.x < [self safe].origin.x + [self safe].size.width * 0.45) {
            _stickTouch = t;
            _stickOrigin = _stickPos = p;
        }
    }
    [self send];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    (void)e;
    for (UITouch *t in touches) {
        if (t == _stickTouch) {
            _stickPos = [t locationInView:self];
        } else {
            int i = [self buttonAt:[t locationInView:self]];   /* sliding onto another button presses that one */
            NSValue *k = [NSValue valueWithNonretainedObject:t];
            if (_held[k] || i >= 0) {
                if (i >= 0) _held[k] = @(k_buttons[i].bit); else [_held removeObjectForKey:k];
            }
        }
    }
    [self send];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    (void)e;
    for (UITouch *t in touches) {
        if (t == _stickTouch)
            _stickTouch = nil;
        [_held removeObjectForKey:[NSValue valueWithNonretainedObject:t]];
    }
    [self send];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    [self touchesEnded:touches withEvent:e];
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef g = UIGraphicsGetCurrentContext();
    uint32_t b = 0;
    NSDictionary *attr = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:[self unit] * 0.035],
                            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.85] };
    (void)rect;
    for (NSNumber *n in _held.allValues)
        b |= n.unsignedIntValue;
    for (unsigned i = 0; i < N_BUTTONS; i++) {
        CGFloat r = k_buttons[i].r * [self unit];
        CGPoint m = [self centre:i];
        CGRect c = CGRectMake(m.x - r, m.y - r, 2 * r, 2 * r);
        NSString *l = @(k_buttons[i].label);
        CGSize ls = [l sizeWithAttributes:attr];
        CGContextSetRGBFillColor(g, 1, 1, 1, (b & k_buttons[i].bit) ? 0.45 : 0.18);
        CGContextFillEllipseInRect(g, c);
        CGContextSetRGBStrokeColor(g, 1, 1, 1, 0.5);
        CGContextSetLineWidth(g, 2);
        CGContextStrokeEllipseInRect(g, c);
        [l drawAtPoint:CGPointMake(CGRectGetMidX(c) - ls.width / 2, CGRectGetMidY(c) - ls.height / 2)
            withAttributes:attr];
    }
    if (_stickTouch) {
        CGFloat R = [self unit] * 0.14, r = [self unit] * 0.06;
        CGContextSetRGBFillColor(g, 1, 1, 1, 0.12);
        CGContextFillEllipseInRect(g, CGRectMake(_stickOrigin.x - R, _stickOrigin.y - R, 2 * R, 2 * R));
        CGContextSetRGBFillColor(g, 1, 1, 1, 0.4);
        CGContextFillEllipseInRect(g, CGRectMake(_stickPos.x - r, _stickPos.y - r, 2 * r, 2 * r));
    }
}
@end

static OrtaOverlay *s_overlay;
static NSTimer *s_front;
static id s_pad_on, s_pad_off;

/* a game controller connected: the touch controls go (view hidden, touch pad detached); the last one gone: back */
static void pads_changed(void)
{
    BOOL pad = GCController.controllers.count > 0;
    if (!s_overlay || s_overlay.hidden == pad)
        return;
    s_overlay.hidden = pad;
    if (pad)
        touchpad_set(0, 0, 0, 0, 0, 0, 0);
    touchpad_enable(!pad);
    SDL_Log("[TOUCH] %s", pad ? "game controller connected: touch controls hidden" : "touch controls shown");
}

void touchpad_overlay_attach(SDL_Window *win)
{
    UIWindow *w = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                                                             SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    UIView *host = w.rootViewController.view ? w.rootViewController.view : w;
    touchpad_init();
    if (!host || s_overlay)
        return;
    s_overlay = [[OrtaOverlay alloc] initWithFrame:host.bounds];
    [host addSubview:s_overlay];
    s_pad_on = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
    s_pad_off = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil
                 queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
    pads_changed();
    /* SDL adds its Metal view when the Vulkan surface is made (later, on demand, again after a display change):
     * keep the controls the top view */
    s_front = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        UIView *sup = s_overlay.superview;
        if (sup && sup.subviews.lastObject != s_overlay)
            [sup bringSubviewToFront:s_overlay];
    }];
}

void touchpad_overlay_detach(void)
{
    [s_front invalidate];
    s_front = nil;
    if (s_pad_on) [NSNotificationCenter.defaultCenter removeObserver:s_pad_on];
    if (s_pad_off) [NSNotificationCenter.defaultCenter removeObserver:s_pad_off];
    s_pad_on = s_pad_off = nil;
    [s_overlay removeFromSuperview];
    s_overlay = nil;
}
