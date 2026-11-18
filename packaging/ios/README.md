# packaging/ios

The iOS / iPadOS app (LiveContainer). How to build and install it, and what is different on iOS:
[docs/IOS.md](../../docs/IOS.md).

- `CMakeLists.txt` - the app: toolkit runtime + generated C + the port's sources + `src/` (or, without the lift, the
  compile check `orta_ios_check`); driven by `tools/build_ios.sh`
- `Info.plist.in` - landscape, Files app sharing, game controllers, iOS 16+
- `src/ios_app.m` - SDL on the main thread, the game on its own thread, the main thread pumping UIKit / SDL
- `src/overlay_ios.m`, `src/touchpad_ios.c` - the touch controls as a virtual SDL gamepad
- `toolkit/0001-xboxrecomp-ios-runtime.patch` - the toolkit's iOS branches (applied to xboxrecomp-option-c v1.1.1)
