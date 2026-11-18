/* touch_ios.m - the touch controls and the BACK menu on iOS (2026-11-18): a port of the Android port's
 * TouchOverlay.java, SideMenu.java and OrtaActivity's menu pages (packaging/android), the same layout, settings and
 * behaviour:
 *   - the controls: a floating stick (it centres where the thumb lands in the left part), A B X Y right, LT / RT in the
 *     top corners, WHITE / BLACK above the face buttons, START bottom centre; BACK, L3 / R3, the D-pad and a fixed
 *     right stick exist too, hidden until shown. Placed in points from the screen's corners (Android: dp), drawn
 *     under the camera cut-out like the Android port. Their state goes to the virtual gamepad (touchpad_ios.c).
 *   - modes: Automatic (a real gamepad's input hides them, a touch shows them again), Always, Off.
 *   - the editor: drag a button to move it, a second finger pinches it to resize; BACK (the menu swipe) ends it.
 *   - the BACK menu slides in from the left over the running game (Android: the back gesture; iOS has none, so a
 *     swipe in from the left screen edge, as the maintainer's "like Dolphin" asked): Back to the game, Controls >,
 *     Boot animation >, About and licences. The Android port's Graphics driver page has no iOS counterpart.
 *     Touch: tap a line, a value line steps on each tap. A gamepad: up / down move, left / right step, A chooses,
 *     B goes back, START closes; the game sees no input while it is open (toolkit xbox_InputBindSuppress).
 *   - per device in NSUserDefaults under the Android keys ("touch.x0" ... "touch.mode").
 * SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <SDL3/SDL.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "touchpad_ios.h"
#include "ios_app.h"

/* toolkit src/input (not included: their Win32 types clash with Objective-C's BOOL) */
extern void xbox_InputBindSuppress(int on);
extern int xbox_InputPadsMerged(void);
extern int xbox_InputSwapPorts(int a, int b);
extern void xbox_InputPadName(int port, char *buf, size_t size);

/* ── the controls (TouchOverlay.java) ────────────────────────────────────────────────────────────────────────── */

enum { T_A, T_B, T_X, T_Y, T_WHITE, T_BLACK, T_START, T_LT, T_RT, T_STICK, T_BACK, T_L3, T_R3, T_UP, T_DOWN, T_LEFT,
       T_RIGHT, T_RSTICK, T_N };
enum { MODE_AUTO, MODE_ALWAYS, MODE_OFF };
static NSString *const k_names[T_N] = { @"A", @"B", @"X", @"Y", @"WHITE", @"BLACK", @"START", @"LT", @"RT", @"STICK",
    @"BACK", @"L3", @"R3", @"D-PAD UP", @"D-PAD DOWN", @"D-PAD LEFT", @"D-PAD RIGHT", @"RIGHT STICK" };
static NSString *const k_labels[T_N] = { @"A", @"B", @"X", @"Y", @"WHITE", @"BLACK", @"START", @"LT", @"RT", @"",
    @"BACK", @"L3", @"R3", @"▲", @"▼", @"◀", @"▶", @"" };
/* x, y (points; negative = from the right / bottom; START / BACK: x from the centre), radius - Android's dp */
static const float k_defaults[T_N][3] = {
    { -110, -70, 34 }, { -50, -130, 34 }, { -170, -130, 34 }, { -110, -190, 34 },
    { -200, -260, 26 }, { -110, -270, 26 }, { 0, -36, 26 }, { 70, 48, 34 }, { -70, 48, 34 }, { 150, -150, 70 },
    { -80, -36, 26 }, { 150, -270, 24 }, { -300, -200, 24 }, { 250, -170, 22 }, { 250, -70, 22 }, { 200, -120, 22 },
    { 300, -120, 22 }, { -300, -100, 50 },
};
static BOOL hidden_by_default(int i) { return i > T_STICK; }
static BOOL centred(int i) { return i == T_START || i == T_BACK; }

@interface OrtaTouchOverlay : UIView
@property (nonatomic) int mode, opacity;
@property (nonatomic) float scale, sensitivity;
@property (nonatomic) BOOL editing, padActive;
- (void)resetLayout;
- (BOOL)isHiddenButton:(int)i;
- (void)setHiddenButton:(int)i hidden:(BOOL)h;
- (void)gamepadUsed;
- (void)touchedWhileHidden;
- (void)releaseAll;
- (void)updateVisibility;
@end

@implementation OrtaTouchOverlay {
    float _cx[T_N], _cy[T_N], _r[T_N], _sc[T_N];
    BOOL _hidden[T_N];
    __unsafe_unretained UITouch *_owner[T_N];
    CGPoint _stickO;
    float _stickX, _stickY, _rstickX, _rstickY;
    int _drag;
    CGPoint _dragD;
    float _pinchStart, _pinchScale;
    __unsafe_unretained UITouch *_dragTouch;
}

static NSUserDefaults *prefs(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *key(NSString *k, int i) { return i < 0 ? [@"touch." stringByAppendingString:k]
                                                         : [NSString stringWithFormat:@"touch.%@%d", k, i]; }
static float pref_f(NSString *k, float def) { id v = [prefs() objectForKey:k]; return v ? [v floatValue] : def; }

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _drag = -1;
        [self load];
    }
    return self;
}

- (void)defaults
{
    for (int i = 0; i < T_N; i++) { _cx[i] = k_defaults[i][0]; _cy[i] = k_defaults[i][1]; _r[i] = k_defaults[i][2]; }
}

- (void)load
{
    [self defaults];
    for (int i = 0; i < T_N; i++) {
        _cx[i] = pref_f(key(@"x", i), _cx[i]);
        _cy[i] = pref_f(key(@"y", i), _cy[i]);
        id h = [prefs() objectForKey:key(@"h", i)];
        _hidden[i] = h ? [h boolValue] : hidden_by_default(i);
        _sc[i] = pref_f(key(@"s", i), 1.0f);
    }
    _scale = pref_f(key(@"gscale", -1), 1.0f);
    _sensitivity = pref_f(key(@"sens", -1), 1.0f);
    _mode = (int)pref_f(key(@"mode", -1), MODE_AUTO);
    _opacity = (int)pref_f(key(@"opacity", -1), 50);
}

- (void)save
{
    NSUserDefaults *d = prefs();
    for (int i = 0; i < T_N; i++) {
        [d setFloat:_cx[i] forKey:key(@"x", i)];
        [d setFloat:_cy[i] forKey:key(@"y", i)];
        [d setBool:_hidden[i] forKey:key(@"h", i)];
        [d setFloat:_sc[i] forKey:key(@"s", i)];
    }
    [d setFloat:_scale forKey:key(@"gscale", -1)];
    [d setFloat:_sensitivity forKey:key(@"sens", -1)];
    [d setInteger:_mode forKey:key(@"mode", -1)];
    [d setInteger:_opacity forKey:key(@"opacity", -1)];
}

- (void)resetLayout
{
    [self defaults];
    _scale = 1.0f;
    for (int i = 0; i < T_N; i++) { _hidden[i] = hidden_by_default(i); _sc[i] = 1.0f; }
    [self save];
    [self setNeedsDisplay];
}

- (void)setMode:(int)m { _mode = m; [self save]; [self updateVisibility]; }
- (void)setOpacity:(int)o { _opacity = o; [self save]; [self setNeedsDisplay]; }
- (void)setScale:(float)s { _scale = s; [self save]; [self setNeedsDisplay]; }
- (void)setSensitivity:(float)s { _sensitivity = s; [self save]; }
- (BOOL)isHiddenButton:(int)i { return _hidden[i]; }
- (void)setHiddenButton:(int)i hidden:(BOOL)h { _hidden[i] = h; [self save]; [self setNeedsDisplay]; }
- (void)setEditing:(BOOL)e { _editing = e; [self updateVisibility]; [self setNeedsDisplay]; }

- (void)updateVisibility
{
    BOOL show = _editing || _mode == MODE_ALWAYS || (_mode == MODE_AUTO && !_padActive);
    self.hidden = !show;
}

/* a real gamepad was used: Automatic hides the controls (and releases everything) */
- (void)gamepadUsed
{
    if (_padActive || _mode != MODE_AUTO || _editing || self.hidden)
        return;
    _padActive = YES;
    [self releaseAll];
    [self updateVisibility];
    touchpad_enable(0);
}

/* a touch while Automatic hid them: back */
- (void)touchedWhileHidden
{
    if (!_padActive || _mode != MODE_AUTO)
        return;
    _padActive = NO;
    touchpad_enable(1);
    [self updateVisibility];
}

- (float)rad:(int)i { return _r[i] * _sc[i] * _scale; }
- (float)px:(int)i
{
    float w = (float)self.bounds.size.width;
    return centred(i) ? w / 2 + _cx[i] : _cx[i] >= 0 ? _cx[i] : w + _cx[i];
}
- (float)py:(int)i { float h = (float)self.bounds.size.height; return _cy[i] >= 0 ? _cy[i] : h + _cy[i]; }

- (int)hitX:(float)x y:(float)y
{
    for (int i = 0; i < T_N; i++) {
        if ((_hidden[i] && !_editing) || i == T_STICK)
            continue;
        float dx = x - [self px:i], dy = y - [self py:i], rr = [self rad:i] + (i == T_RSTICK ? 0 : 12);
        if (dx * dx + dy * dy <= rr * rr)
            return i;
    }
    /* the stick zone: the left 40 % of the screen, lower 75 % (floating), or its rest place in edit mode */
    if (!_hidden[T_STICK] || _editing) {
        if (_editing) {
            float dx = x - [self px:T_STICK], dy = y - [self py:T_STICK], rr = [self rad:T_STICK];
            if (dx * dx + dy * dy <= rr * rr)
                return T_STICK;
        } else if (x < self.bounds.size.width * 0.4f && y > self.bounds.size.height * 0.25f) {
            return T_STICK;
        }
    }
    return -1;
}

/* touches outside the controls fall through to SDL's view (Android: not consumed) */
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    (void)e;
    return _editing || [self hitX:(float)p.x y:(float)p.y] >= 0;
}

- (void)moveRStick:(CGPoint)p
{
    float max = [self rad:T_RSTICK] / _sensitivity;
    float dx = ((float)p.x - [self px:T_RSTICK]) / max, dy = ((float)p.y - [self py:T_RSTICK]) / max;
    float len = sqrtf(dx * dx + dy * dy);
    if (len > 1) { dx /= len; dy /= len; }
    _rstickX = dx; _rstickY = dy;
}

- (void)send
{
    uint32_t b = 0;
    for (int i = 0; i < T_N; i++)
        if (_owner[i] && i != T_LT && i != T_RT && i != T_STICK && i != T_RSTICK)
            b |= 1u << i;
    touchpad_set(b, _stickX, _stickY, _owner[T_LT] ? 1.0f : 0.0f, _owner[T_RT] ? 1.0f : 0.0f, _rstickX, _rstickY);
}

- (void)releaseAll
{
    for (int i = 0; i < T_N; i++) _owner[i] = nil;
    _stickX = _stickY = _rstickX = _rstickY = 0;
    [self send];
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    if (_editing) { [self editTouches:touches event:e phase:0]; return; }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        int c = [self hitX:(float)p.x y:(float)p.y];
        if (c < 0)
            continue;
        _owner[c] = t;
        if (c == T_STICK) { _stickO = p; _stickX = _stickY = 0; }
        if (c == T_RSTICK) [self moveRStick:p];
    }
    [self send];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    if (_editing) { [self editTouches:touches event:e phase:1]; return; }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (_owner[T_STICK] == t) {
            float max = [self rad:T_STICK] / _sensitivity;   /* higher sensitivity: full deflection sooner */
            float dx = (float)(p.x - _stickO.x) / max, dy = (float)(p.y - _stickO.y) / max;
            float len = sqrtf(dx * dx + dy * dy);
            if (len > 1) { dx /= len; dy /= len; }
            _stickX = dx; _stickY = dy;
        }
        if (_owner[T_RSTICK] == t) [self moveRStick:p];
    }
    [self send];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    if (_editing) { [self editTouches:touches event:e phase:2]; return; }
    for (UITouch *t in touches)
        for (int i = 0; i < T_N; i++)
            if (_owner[i] == t) {
                _owner[i] = nil;
                if (i == T_STICK) _stickX = _stickY = 0;
                if (i == T_RSTICK) _rstickX = _rstickY = 0;
            }
    [self send];
    [self setNeedsDisplay];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { [self touchesEnded:touches withEvent:e]; }

/* the editor: one finger drags a button, a second finger pinches it */
- (void)editTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)e phase:(int)phase
{
    NSArray<UITouch *> *all = [[e touchesForView:self] allObjects];
    if (phase == 0) {
        if (_drag < 0) {
            UITouch *t = touches.anyObject;
            CGPoint p = [t locationInView:self];
            _drag = [self hitX:(float)p.x y:(float)p.y];
            _dragTouch = t;
            _pinchStart = 0;
            if (_drag >= 0) _dragD = CGPointMake([self px:_drag] - p.x, [self py:_drag] - p.y);
        } else if (all.count == 2) {
            CGPoint a = [all[0] locationInView:self], b = [all[1] locationInView:self];
            _pinchStart = (float)hypot(a.x - b.x, a.y - b.y);
            _pinchScale = _sc[_drag];
        }
    } else if (phase == 1 && _drag >= 0) {
        if (_pinchStart > 0 && all.count >= 2) {
            CGPoint a = [all[0] locationInView:self], b = [all[1] locationInView:self];
            float d = (float)hypot(a.x - b.x, a.y - b.y);
            _sc[_drag] = fmaxf(0.5f, fminf(2.5f, _pinchScale * d / _pinchStart));
        } else if (_pinchStart == 0 && _dragTouch) {
            CGPoint p = [_dragTouch locationInView:self];
            float nx = (float)(p.x + _dragD.x), ny = (float)(p.y + _dragD.y);
            float w = (float)self.bounds.size.width, h = (float)self.bounds.size.height;
            int c = _drag;
            if (centred(c)) _cx[c] = nx - w / 2;
            else _cx[c] = nx < w / 2 ? nx : nx - w;
            _cy[c] = ny < h / 2 ? ny : ny - h;
        }
        [self setNeedsDisplay];
    } else if (phase == 2) {
        BOOL drag_ended = [touches containsObject:_dragTouch];
        if (drag_ended || all.count <= touches.count) {
            _drag = -1;
            _dragTouch = nil;
            [self save];
        }
    }
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef g = UIGraphicsGetCurrentContext();
    float al = _editing ? 200.0f / 255.0f : _opacity / 100.0f;
    UIFont *font = [UIFont boldSystemFontOfSize:15];
    (void)rect;
    CGContextSetLineWidth(g, 2);
    for (int i = 0; i < T_N; i++) {
        if (_hidden[i] && !_editing)
            continue;
        float x = [self px:i], y = [self py:i], rr = [self rad:i];
        BOOL down = _owner[i] != nil;
        if (i == T_STICK || i == T_RSTICK) {
            float ox = x, oy = y, sx = i == T_STICK ? _stickX : _rstickX, sy = i == T_STICK ? _stickY : _rstickY;
            if (i == T_STICK && _owner[T_STICK]) { ox = (float)_stickO.x; oy = (float)_stickO.y; }
            CGContextSetRGBFillColor(g, 1, 1, 1, al / 3);
            CGContextFillEllipseInRect(g, CGRectMake(ox - rr, oy - rr, 2 * rr, 2 * rr));
            CGContextSetRGBStrokeColor(g, 1, 1, 1, (i == T_RSTICK && _hidden[i]) ? al / 3 : al);
            CGContextStrokeEllipseInRect(g, CGRectMake(ox - rr, oy - rr, 2 * rr, 2 * rr));
            CGContextSetRGBFillColor(g, 1, 1, 1, al);
            float k = rr * 0.45f, kx = ox + sx * rr, ky = oy + sy * rr;
            CGContextFillEllipseInRect(g, CGRectMake(kx - k, ky - k, 2 * k, 2 * k));
            continue;
        }
        if (down) CGContextSetRGBFillColor(g, 1, 1, 1, al);
        else CGContextSetRGBFillColor(g, 40 / 255.0, 40 / 255.0, 40 / 255.0, al / 2);
        CGContextSetRGBStrokeColor(g, 1, 1, 1, _hidden[i] ? al / 3 : al);
        if (i == T_LT || i == T_RT || i == T_START || i == T_WHITE || i == T_BLACK || i == T_BACK || i == T_L3 ||
            i == T_R3) {
            UIBezierPath *b = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x - rr * 1.4f, y - rr * 0.7f,
                                                                                  rr * 2.8f, rr * 1.4f)
                                                         cornerRadius:rr * 0.5f];
            [b fill];
            [b stroke];
        } else {
            CGContextFillEllipseInRect(g, CGRectMake(x - rr, y - rr, 2 * rr, 2 * rr));
            CGContextStrokeEllipseInRect(g, CGRectMake(x - rr, y - rr, 2 * rr, 2 * rr));
        }
        NSDictionary *at = @{ NSFontAttributeName: font,
                              NSForegroundColorAttributeName: down ? [UIColor colorWithWhite:0 alpha:al]
                                                                   : [UIColor colorWithWhite:1 alpha:al] };
        CGSize ls = [k_labels[i] sizeWithAttributes:at];
        [k_labels[i] drawAtPoint:CGPointMake(x - ls.width / 2, y - ls.height / 2) withAttributes:at];
    }
    if (_editing) {
        NSString *s = @"Drag a button to move it, pinch it with two fingers to resize - swipe in from the left when done";
        NSDictionary *at = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
                              NSForegroundColorAttributeName: UIColor.whiteColor };
        CGSize ls = [s sizeWithAttributes:at];
        [s drawAtPoint:CGPointMake((self.bounds.size.width - ls.width) / 2, 40) withAttributes:at];
    }
}
@end

/* ── the BACK menu (SideMenu.java) ───────────────────────────────────────────────────────────────────────────── */

@interface OrtaItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *(^value)(void);   /* nil: a plain line */
@property (nonatomic, copy) void (^step)(int dir);       /* a value line */
@property (nonatomic, copy) void (^run)(void);           /* a plain line */
@end
@implementation OrtaItem
@end

typedef NSArray<OrtaItem *> *(^OrtaPage)(void);

static OrtaItem *item(NSString *t, void (^run)(void))
{
    OrtaItem *i = [OrtaItem new];
    i.title = t;
    i.run = run;
    return i;
}
static OrtaItem *value_item(NSString *t, NSString *(^value)(void), void (^step)(int))
{
    OrtaItem *i = [OrtaItem new];
    i.title = t;
    i.value = value;
    i.step = step;
    return i;
}

@interface OrtaSideMenu : UIView
@property (nonatomic, readonly) BOOL open;
@property (nonatomic, copy) void (^onClosed)(void);
- (void)openWith:(NSString *)title page:(OrtaPage)page;
- (void)push:(NSString *)title page:(OrtaPage)page;
- (void)back;
- (void)close;
- (void)refresh;
- (void)padMove:(int)d;
- (void)padStep:(int)d;
- (void)padChoose;
@end

@implementation OrtaSideMenu {
    UIView *_scrim, *_panel;
    UILabel *_header;
    UIScrollView *_scroll;
    UIStackView *_list;
    NSMutableArray *_titles, *_pages;
    NSArray<OrtaItem *> *_items;
    NSMutableArray<UIButton *> *_rows;
    NSInteger _sel;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.hidden = YES;
        _scrim = [[UIView alloc] initWithFrame:self.bounds];
        _scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        _scrim.alpha = 0;
        [_scrim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
        [self addSubview:_scrim];
        _panel = [[UIView alloc] init];
        _panel.backgroundColor = [UIColor colorWithRed:0x18 / 255.0 green:0x1C / 255.0 blue:0x24 / 255.0 alpha:0.95];
        [self addSubview:_panel];
        _header = [[UILabel alloc] init];
        _header.textColor = [UIColor colorWithRed:0xE8 / 255.0 green:0xB0 / 255.0 blue:0x4A / 255.0 alpha:1];
        _header.font = [UIFont boldSystemFontOfSize:18];
        [_panel addSubview:_header];
        _scroll = [[UIScrollView alloc] init];
        [_panel addSubview:_scroll];
        _list = [[UIStackView alloc] init];
        _list.axis = UILayoutConstraintAxisVertical;
        [_scroll addSubview:_list];
        _titles = [NSMutableArray array];
        _pages = [NSMutableArray array];
        _rows = [NSMutableArray array];
    }
    return self;
}

/* about a third of a landscape screen, at least 300 points, never more than 85 % (Android's rule); the panel's
 * content keeps out of the cut-out's side (the panel itself reaches the edge) */
- (CGFloat)panelWidth
{
    CGFloat w = self.bounds.size.width;
    return MIN(w * 0.85, MAX(300 + self.safeAreaInsets.left, w * 0.34));
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat pw = [self panelWidth], h = self.bounds.size.height, l = self.safeAreaInsets.left;
    _panel.frame = CGRectMake(_open ? 0 : -pw, 0, pw, h);
    _header.frame = CGRectMake(20 + l, 20, pw - 40 - l, 30);
    _scroll.frame = CGRectMake(l, 60, pw - l, h - 72);
    CGSize fit = [_list systemLayoutSizeFittingSize:CGSizeMake(pw - l, 0)
                      withHorizontalFittingPriority:UILayoutPriorityRequired
                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    _list.frame = CGRectMake(0, 0, pw - l, fit.height);
    _scroll.contentSize = CGSizeMake(pw - l, fit.height);
}

- (void)openWith:(NSString *)title page:(OrtaPage)page
{
    [_titles removeAllObjects];
    [_pages removeAllObjects];
    [_titles addObject:title];
    [_pages addObject:page];
    [self show:0];
    if (_open)
        return;
    _open = YES;
    xbox_InputBindSuppress(1);              /* the game sees no input while the menu is open */
    self.hidden = NO;
    [self.superview bringSubviewToFront:self];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    CGFloat pw = [self panelWidth];
    _panel.frame = CGRectMake(-pw, 0, pw, self.bounds.size.height);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_panel.frame = CGRectMake(0, 0, pw, self.bounds.size.height);
        self->_scrim.alpha = 1;
    } completion:nil];
}

- (void)close
{
    if (!_open)
        return;
    _open = NO;
    xbox_InputBindSuppress(0);
    CGFloat pw = [self panelWidth];
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_panel.frame = CGRectMake(-pw, 0, pw, self.bounds.size.height);
        self->_scrim.alpha = 0;
    } completion:^(BOOL done) {
        (void)done;
        if (!self->_open)
            self.hidden = YES;
    }];
    if (_onClosed)
        _onClosed();
}

- (void)push:(NSString *)title page:(OrtaPage)page
{
    [_titles addObject:title];
    [_pages addObject:page];
    [self show:0];
}

- (void)back
{
    if (_pages.count > 1) {
        [_titles removeLastObject];
        [_pages removeLastObject];
        [self show:0];
    } else {
        [self close];
    }
}

- (void)refresh { [self show:_sel]; }

- (void)show:(NSInteger)cursor
{
    OrtaPage p = _pages.lastObject;
    NSMutableArray<OrtaItem *> *items = [p() mutableCopy];
    __weak OrtaSideMenu *me = self;
    _header.text = _titles.lastObject;
    if (_pages.count > 1)
        [items addObject:item(@"‹  Back", ^{ [me back]; })];
    _items = items;
    for (UIView *v in _rows) [v removeFromSuperview];
    [_rows removeAllObjects];
    for (NSUInteger i = 0; i < items.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleLabel.font = [UIFont systemFontOfSize:16];
        b.titleLabel.numberOfLines = 0;
        b.contentEdgeInsets = UIEdgeInsetsMake(10, 20, 10, 20);
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [_list addArrangedSubview:b];
        [_rows addObject:b];
    }
    _sel = MAX(0, MIN(cursor, (NSInteger)items.count - 1));
    if (_sel == 0)
        _scroll.contentOffset = CGPointZero;
    [self paint];
    [self setNeedsLayout];
}

- (void)paint
{
    for (NSUInteger i = 0; i < _rows.count; i++) {
        OrtaItem *it = _items[i];
        NSString *v = it.value ? it.value() : nil;
        NSString *t = v ? [NSString stringWithFormat:@"%@:  ‹ %@ ›", it.title, v] : it.title;
        [_rows[i] setTitle:t forState:UIControlStateNormal];
        [_rows[i] setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _rows[i].backgroundColor = (NSInteger)i == _sel
            ? [UIColor colorWithRed:0xE8 / 255.0 green:0xB0 / 255.0 blue:0x4A / 255.0 alpha:0.25] : UIColor.clearColor;
    }
    if (_sel >= 0 && _sel < (NSInteger)_rows.count)
        [_scroll scrollRectToVisible:_rows[_sel].frame animated:NO];
}

- (void)activate:(int)dir
{
    if (_sel < 0 || _sel >= (NSInteger)_items.count)
        return;
    OrtaItem *it = _items[_sel];
    NSArray *before = _items;
    if (it.value && it.step) it.step(dir);
    else if (it.run) it.run();
    if (_open && _items == before)
        [self paint];
}

- (void)tapped:(UIButton *)b { _sel = b.tag; [self activate:+1]; }
- (void)padMove:(int)d { if (_items.count) { _sel = (_sel + d + (NSInteger)_items.count) % (NSInteger)_items.count; [self paint]; } }
- (void)padStep:(int)d { if (_sel >= 0 && _sel < (NSInteger)_items.count && _items[_sel].value) [self activate:d]; }
- (void)padChoose { [self activate:+1]; }
@end

/* ── the app's side: pages, the menu swipe, gamepad use, boot animation import ──────────────────────────────── */

static OrtaTouchOverlay *s_overlay;
static OrtaSideMenu *s_menu;
static SDL_JoystickID s_touch_pad_id;            /* the virtual pad's id: its events are not "a gamepad was used" */

static NSString *pct(float f) { return [NSString stringWithFormat:@"%d %%", (int)lroundf(f * 100)]; }

static NSString *boot_path(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"media/boot.mpg"];
}

@interface OrtaBootPicker : NSObject <UIDocumentPickerDelegate>
@end
@implementation OrtaBootPicker
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)c;
    NSURL *u = urls.firstObject;
    NSString *to = boot_path();
    NSError *err = nil;
    BOOL scoped = [u startAccessingSecurityScopedResource];
    [NSFileManager.defaultManager createDirectoryAtPath:to.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager removeItemAtPath:to error:nil];
    if (![NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:to] error:&err])
        SDL_Log("[MENU] boot animation import failed: %s", err.localizedDescription.UTF8String);
    else
        SDL_Log("[MENU] boot animation imported (%s)", u.lastPathComponent.UTF8String);
    if (scoped) [u stopAccessingSecurityScopedResource];
}
@end
static OrtaBootPicker *s_boot_picker;

static UIViewController *top_controller(void)
{
    UIViewController *vc = s_overlay.window.rootViewController;
    while (vc.presentedViewController)
        vc = vc.presentedViewController;
    return vc;
}

static void pick_boot_video(void)
{
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeMPEG, UTTypeMovie, UTTypeData ]
                                                                   asCopy:YES];
    s_boot_picker = [OrtaBootPicker new];
    p.delegate = s_boot_picker;
    [top_controller() presentViewController:p animated:YES completion:nil];
}

static OrtaPage hide_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        NSMutableArray *l = [NSMutableArray array];
        for (int i = 0; i < T_N; i++) {
            const int b = i;
            [l addObject:value_item(k_names[b], ^NSString *(void) { return [s_overlay isHiddenButton:b] ? @"hidden" : @"shown"; },
                                    ^(int d) { (void)d; [s_overlay setHiddenButton:b hidden:![s_overlay isHiddenButton:b]]; })];
        }
        return l;
    };
}

/* which controller is which player (toolkit agent-l/pads): Orta merges every controller into player 1, so the page
 * lists them; a multi-player title would move a pad to player 1 from here */
static OrtaPage pad_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        NSMutableArray *l = [NSMutableArray array];
        int merged = xbox_InputPadsMerged(), n = 0;
        if (merged)
            [l addObject:item(@"Every controller plays as player 1", nil)];
        for (int port = 0; port < 4; port++) {
            char name[256];
            xbox_InputPadName(port, name, sizeof name);
            if (!name[0])
                continue;
            NSString *nm = @(name);
            NSString *kind = [nm isEqualToString:@"Orta touch controls"] ? @"touch" : @"external";
            NSString *t = [NSString stringWithFormat:@"%@%@  (%@)%@", merged ? @"" : [NSString stringWithFormat:@"Player %d:  ", port + 1],
                                                     nm, kind, merged || port == 0 ? @"" : @"  - make player 1"];
            const int p = port;
            [l addObject:item(t, ^{ if (!merged && p != 0) { xbox_InputSwapPorts(p, 0); [s_menu refresh]; } })];
            n++;
        }
        if (n == 0)
            [l addObject:item(@"No controller connected", nil)];
        return l;
    };
}

static OrtaPage controls_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        NSArray *modes = @[ @"Automatic", @"Always", @"Off" ];
        return @[
            value_item(@"Touch buttons", ^NSString *(void) { return modes[s_overlay.mode]; }, ^(int d) {
                int m = (s_overlay.mode + d + 3) % 3;
                s_overlay.mode = m;
                touchpad_enable(m != MODE_OFF);
            }),
            item(@"Controllers", ^{ [s_menu push:@"Controllers" page:pad_page()]; }),
            item(@"Move and resize touch buttons", ^{ [s_menu close]; s_overlay.editing = YES; }),
            value_item(@"Button size", ^NSString *(void) { return pct(s_overlay.scale); },
                       ^(int d) { s_overlay.scale = fmaxf(0.5f, fminf(1.5f, s_overlay.scale + 0.25f * d)); }),
            item(@"Hide single touch buttons", ^{ [s_menu push:@"Hide single touch buttons" page:hide_page()]; }),
            value_item(@"Opacity", ^NSString *(void) { return [NSString stringWithFormat:@"%d %%", s_overlay.opacity]; },
                       ^(int d) { s_overlay.opacity = MAX(25, MIN(100, s_overlay.opacity + 25 * d)); }),
            value_item(@"Stick sensitivity", ^NSString *(void) { return pct(s_overlay.sensitivity); },
                       ^(int d) { s_overlay.sensitivity = fmaxf(1.0f, fminf(3.0f, s_overlay.sensitivity + 0.5f * d)); }),
            item(@"Reset touch layout", ^{ [s_overlay resetLayout]; [s_menu refresh]; }),
        ];
    };
}

/* Boot animation: media/boot.mpg (MPEG-1 + MP2) through the system picker; OPTIONS > RECOMP OPTIONS > BOOT
 * ANIMATION turns it on / off in the game */
static OrtaPage boot_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        NSString *f = boot_path();
        NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:f error:nil];
        BOOL have = at != nil;
        return @[
            item(have ? @"None" : @"None  (in use)", ^{
                if (have) { [NSFileManager.defaultManager removeItemAtPath:f error:nil]; [s_menu refresh]; }
            }),
            item(have ? [NSString stringWithFormat:@"Import file...  (in use: boot.mpg, %llu MB)", at.fileSize >> 20]
                      : @"Import file...", ^{ [s_menu close]; pick_boot_video(); }),
        ];
    };
}

/* About and licences: licenses/README.txt in the app, line by line (tools/build_ios.sh stages it with the texts) */
static OrtaPage about_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        NSMutableArray *l = [NSMutableArray array];
        NSString *p = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"licenses/README.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [l addObject:item(t, nil)];
        }
        if (!l.count) [l addObject:item(@"(no licence list in this build)", nil)];
        return l;
    };
}

static OrtaPage root_page(void)
{
    return ^NSArray<OrtaItem *> *(void) {
        BOOL boot = [NSFileManager.defaultManager fileExistsAtPath:boot_path()];
        return @[
            item(@"Back to the game", ^{ [s_menu close]; }),
            item(@"Controls", ^{ [s_menu push:@"Controls" page:controls_page()]; }),
            item(boot ? @"Boot animation: boot.mpg" : @"Boot animation: none",
                 ^{ [s_menu push:@"Boot animation" page:boot_page()]; }),
            item(@"About and licences", ^{ [s_menu push:@"About and licences" page:about_page()]; }),
        ];
    };
}

/* BACK (Android's back gesture; here the swipe in from the left edge): the menu, back one level in it, or the end
 * of the layout editor */
static void back_menu(void)
{
    if (!s_overlay)
        return;
    if (s_menu.open) { [s_menu back]; return; }
    if (s_overlay.editing) { s_overlay.editing = NO; return; }
    [s_overlay releaseAll];
    [s_menu openWith:@"Panzer Dragoon Orta Recomp" page:root_page()];
}

@interface OrtaGestures : NSObject <UIGestureRecognizerDelegate>
@end
@implementation OrtaGestures
- (void)edge:(UIScreenEdgePanGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateRecognized) back_menu(); }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b
{
    (void)a; (void)b;
    return YES;
}
@end
static OrtaGestures *s_gestures;

/* any touch on the window: Automatic brings the hidden controls back (Android: dispatchTouchEvent) - it watches
 * only, every touch still goes where it went */
@interface OrtaAnyTouch : UIGestureRecognizer
@end
@implementation OrtaAnyTouch
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)touches; (void)event;
    if (s_overlay && s_overlay.hidden && !s_menu.open)
        [s_overlay touchedWhileHidden];
    self.state = UIGestureRecognizerStateFailed;
}
@end

/* SDL's events on the main thread: a real gamepad's input hides the controls (Automatic); while the menu is open the
 * pad drives it (up / down, left / right, A, B, START) */
static bool SDLCALL pad_watch(void *u, SDL_Event *e)
{
    static Uint64 last_axis;
    (void)u;
    if (!s_overlay)
        return true;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e->gbutton.which != s_touch_pad_id) {
        if (s_menu.open) {
            switch (e->gbutton.button) {
            case SDL_GAMEPAD_BUTTON_DPAD_UP:    [s_menu padMove:-1]; break;
            case SDL_GAMEPAD_BUTTON_DPAD_DOWN:  [s_menu padMove:+1]; break;
            case SDL_GAMEPAD_BUTTON_DPAD_LEFT:  [s_menu padStep:-1]; break;
            case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: [s_menu padStep:+1]; break;
            case SDL_GAMEPAD_BUTTON_SOUTH:      [s_menu padChoose]; break;
            case SDL_GAMEPAD_BUTTON_EAST:       [s_menu back]; break;
            case SDL_GAMEPAD_BUTTON_START:      [s_menu close]; break;
            default: break;
            }
        } else {
            [s_overlay gamepadUsed];
        }
    } else if (e->type == SDL_EVENT_GAMEPAD_AXIS_MOTION && e->gaxis.which != s_touch_pad_id
               && abs(e->gaxis.value) > 16000) {
        if (s_menu.open) {
            Uint64 now = SDL_GetTicks();
            if (now - last_axis >= 220 && (e->gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY || e->gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX)) {
                last_axis = now;
                if (e->gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) [s_menu padMove:e->gaxis.value > 0 ? +1 : -1];
                else [s_menu padStep:e->gaxis.value > 0 ? +1 : -1];
            }
        } else {
            [s_overlay gamepadUsed];
        }
    }
    return true;
}

void touchpad_overlay_attach(SDL_Window *win)
{
    UIWindow *w = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                                                             SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    UIView *host = w.rootViewController.view ? w.rootViewController.view : w;
    if (!host || s_overlay)
        return;
    touchpad_init();
    {   /* the virtual pad's id, so its own events are not taken for a real gamepad */
        int n = 0, i;
        SDL_JoystickID *ids = SDL_GetGamepads(&n);
        for (i = 0; ids && i < n; i++)
            if (!strcmp(SDL_GetGamepadNameForID(ids[i]) ? SDL_GetGamepadNameForID(ids[i]) : "", "Orta touch controls"))
                s_touch_pad_id = ids[i];
        SDL_free(ids);
    }
    s_overlay = [[OrtaTouchOverlay alloc] initWithFrame:host.bounds];
    [host addSubview:s_overlay];
    s_menu = [[OrtaSideMenu alloc] initWithFrame:host.bounds];
    [host addSubview:s_menu];
    s_gestures = [OrtaGestures new];
    for (UIView *v in @[ host, s_overlay ]) {
        UIScreenEdgePanGestureRecognizer *g = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:s_gestures
                                                                                                action:@selector(edge:)];
        g.edges = UIRectEdgeLeft;
        g.delegate = s_gestures;
        [v addGestureRecognizer:g];
    }
    OrtaAnyTouch *any = [[OrtaAnyTouch alloc] initWithTarget:nil action:nil];
    any.cancelsTouchesInView = NO;
    any.delaysTouchesBegan = NO;
    any.delaysTouchesEnded = NO;
    [w addGestureRecognizer:any];
    /* a gamepad already connected: Automatic starts hidden (Android setGameRunning) */
    {
        int n = 0, i;
        SDL_JoystickID *ids = SDL_GetGamepads(&n);
        for (i = 0; ids && i < n; i++)
            if (ids[i] != s_touch_pad_id)
                [s_overlay gamepadUsed];
        SDL_free(ids);
    }
    [s_overlay updateVisibility];
    SDL_AddEventWatch(pad_watch, NULL);
    /* SDL adds its Metal view when the Vulkan surface is made (and again after a display change): the controls and
     * the menu stay the top views */
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        UIView *sup = s_overlay.superview;
        if (sup && sup.subviews.lastObject != s_menu) {
            [sup bringSubviewToFront:s_overlay];
            [sup bringSubviewToFront:s_menu];
        }
    }];
    SDL_Log("[TOUCH] controls attached (mode %d, opacity %d %%); swipe in from the left edge for the menu",
            s_overlay.mode, s_overlay.opacity);
}

void touchpad_overlay_detach(void)
{
    SDL_RemoveEventWatch(pad_watch, NULL);
    [s_menu removeFromSuperview];
    [s_overlay removeFromSuperview];
    s_menu = nil;
    s_overlay = nil;
}
