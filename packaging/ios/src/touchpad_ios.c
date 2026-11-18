/* touchpad_ios.c - the touch controls as one virtual SDL gamepad on iOS (2026-11-18), after the Android port's
 * packaging/android/app/jni/loader/touchpad.c: the toolkit's input (option-c src/input/xinput_device.c) sees an
 * ordinary SDL gamepad - A/B/X/Y = SOUTH/EAST/WEST/NORTH, WHITE / BLACK = the shoulder buttons, LT / RT = the trigger
 * axes, the floating stick = the left stick. overlay_ios.m draws the controls and calls touchpad_set (main thread).
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <SDL3/SDL.h>
#include <string.h>

#include "touchpad_ios.h"

static SDL_AtomicInt s_ready;
static SDL_JoystickID s_id;
static SDL_Joystick *s_joy;
static SDL_Mutex *s_mx;

static void attach(void)
{
    SDL_VirtualJoystickDesc d;
    if (s_id)
        return;
    SDL_INIT_INTERFACE(&d);
    d.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    d.naxes = SDL_GAMEPAD_AXIS_COUNT;
    d.nbuttons = 14;
    d.axis_mask = (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY) |
                  (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY) |
                  (1u << SDL_GAMEPAD_AXIS_LEFT_TRIGGER) | (1u << SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    d.button_mask = (1u << SDL_GAMEPAD_BUTTON_SOUTH) | (1u << SDL_GAMEPAD_BUTTON_EAST) |
                    (1u << SDL_GAMEPAD_BUTTON_WEST) | (1u << SDL_GAMEPAD_BUTTON_NORTH) |
                    (1u << SDL_GAMEPAD_BUTTON_BACK) | (1u << SDL_GAMEPAD_BUTTON_START) |
                    (1u << SDL_GAMEPAD_BUTTON_LEFT_STICK) | (1u << SDL_GAMEPAD_BUTTON_RIGHT_STICK) |
                    (1u << SDL_GAMEPAD_BUTTON_LEFT_SHOULDER) | (1u << SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER) |
                    (1u << SDL_GAMEPAD_BUTTON_DPAD_UP) | (1u << SDL_GAMEPAD_BUTTON_DPAD_DOWN) |
                    (1u << SDL_GAMEPAD_BUTTON_DPAD_LEFT) | (1u << SDL_GAMEPAD_BUTTON_DPAD_RIGHT);
    d.name = "Orta touch controls";
    s_id = SDL_AttachVirtualJoystick(&d);
    s_joy = s_id ? SDL_OpenJoystick(s_id) : NULL;
    SDL_Log("[TOUCH] virtual gamepad %s (id %u)", s_joy ? "attached" : "failed", (unsigned)s_id);
}

static void detach(void)
{
    if (!s_id)
        return;
    if (s_joy)
        SDL_CloseJoystick(s_joy);
    SDL_DetachVirtualJoystick(s_id);
    s_joy = NULL;
    s_id = 0;
    SDL_Log("[TOUCH] virtual gamepad detached (a real gamepad is used)");
}

void touchpad_init(void)
{
    if (SDL_GetAtomicInt(&s_ready))
        return;
    s_mx = SDL_CreateMutex();
    SDL_InitSubSystem(SDL_INIT_GAMEPAD);
    if (!SDL_HasGamepad())
        attach();
    SDL_SetAtomicInt(&s_ready, 1);
}

void touchpad_enable(int on)
{
    if (!SDL_GetAtomicInt(&s_ready))
        return;
    SDL_LockMutex(s_mx);
    if (on) attach(); else detach();
    SDL_UnlockMutex(s_mx);
}

void touchpad_set(uint32_t b, float lx, float ly, float lt, float rt, float rx, float ry)
{
    /* overlay bit i -> the virtual JOYSTICK button (SDL numbers only the masked buttons, in SDL_GamepadButton
     * order: SOUTH 0, EAST 1, WEST 2, NORTH 3, BACK 4, START 5, LEFT_STICK 6, RIGHT_STICK 7, LEFT_SHOULDER 8,
     * RIGHT_SHOULDER 9, DPAD_UP 10, DOWN 11, LEFT 12, RIGHT 13 - see the Android port's touchpad.c) */
    static const signed char map[17] = {
        0 /* A */, 1 /* B */, 2 /* X */, 3 /* Y */, 9 /* WHITE */, 8 /* BLACK */, 5 /* START */, -1 /* LT */,
        -1 /* RT */, -1 /* STICK */, 4 /* BACK */, 6 /* L3 */, 7 /* R3 */, 10, 11, 12, 13,
    };
    int i;
    if (!SDL_GetAtomicInt(&s_ready))
        return;
    SDL_LockMutex(s_mx);
    if (!s_joy)
        attach();
    if (s_joy) {
        for (i = 0; i < 17; i++)
            if (map[i] >= 0)
                SDL_SetJoystickVirtualButton(s_joy, map[i], (b >> i) & 1);
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_LEFTX, (Sint16)(lx * 32767));
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_LEFTY, (Sint16)(ly * 32767));
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_RIGHTX, (Sint16)(rx * 32767));
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_RIGHTY, (Sint16)(ry * 32767));
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, (Sint16)(-32768 + (int)(lt * 65535)));
        SDL_SetJoystickVirtualAxis(s_joy, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, (Sint16)(-32768 + (int)(rt * 65535)));
    }
    SDL_UnlockMutex(s_mx);
}

int touchpad_pad_priority(const char *name)
{
    /* iOS tells no built-in pads apart (no handheld with its own controls): every real pad above the touch pad */
    if (!name || !strcmp(name, "Orta touch controls"))
        return 0;
    return 10;
}
