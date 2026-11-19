#!/usr/bin/env bash
# build_ios.sh - builds OrtaRecomp.ipa for iPhone and iPad (unsigned: for LiveContainer, or to sign yourself with
# Sideloadly / AltStore / Xcode). The twin of tools/build_android.sh; the shape follows the Lost World iOS port
# (platform/ios/build.sh there). On a Mac with Xcode, Python 3.11+, CMake 3.24+ and Ninja
# (brew install cmake ninja python), or on GitHub's macOS runners (.github/workflows/ios.yml):
#
#   tools/build_ios.sh [path/to/default.xbe]
#
# default.xbe (the PAL disc's, SHA-1 57213ff3...) is looked for as the argument, in ORTA_XBE, then in the repo
# root. It is only read to build: the game's code is lifted from it and compiled into the app. The app carries
# nothing else of the game - the disc image goes to the phone (Files app: the app's game/ folder; the first start
# extracts it, as on PC and Android).
# ORTA_IOS_CHECK=1: no XBE, no lift - only the compile check (the toolkit runtime and the port's sources for iOS).
#
# Steps: [1] the lift (toolkit tools, capstone 5.0.7 as the toolkit's CI), [2] SDL3 / Vulkan-Headers / glslang for
# iOS / MoltenVK, [3] the toolkit v1.1.1 + packaging/ios/toolkit/*.patch, [4] the game cross-compiled for arm64 iOS,
# [5] out/ios/OrtaRecomp.ipa (ad hoc signed; LiveContainer signs it again).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

XBE=${1:-${ORTA_XBE:-$ROOT/default.xbe}}
CHECK=${ORTA_IOS_CHECK:-}
DEPS=${ORTA_IOS_DEPS:-$ROOT/build/ios/deps}
TK=${XBOXRECOMP_DIR:-$ROOT/build/ios/xboxrecomp-option-c}
BUNDLE_ID=${ORTA_BUNDLE_ID:-io.github.almostdrownedrat.orta}
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
IOS_MIN=16.0
SDL_TAG=release-3.4.18
GLSLANG_TAG=16.6.0
MVK_TAG=${MOLTENVK_VERSION:-v1.4.2}
VKH_TAG=v1.4.368
TK_TAG=v1.1.1
XBE_SHA1=57213ff35a19807def664f9018cc2923815dfa1f

fail() { echo; echo "Build failed: $*"; exit 1; }
clone() { [ -d "$3/.git" ] || git clone -q --depth 1 --branch "$2" "$1" "$3"; }

# ---- tools
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "the iOS SDK was not found: install Xcode, open it once, then: sudo xcode-select -s /Applications/Xcode.app"
command -v cmake >/dev/null || fail "cmake not found (brew install cmake)"
command -v ninja >/dev/null || fail "ninja not found (brew install ninja)"
PY=""
for p in python3.13 python3.12 python3.11 python3; do
    if command -v "$p" >/dev/null && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then PY=$p; break; fi
done
[ -n "$PY" ] || fail "Python 3.11 or later not found (brew install python) - the lift reads its config with tomllib"
mkdir -p "$DEPS/src" build/ios

# ---- the toolkit (its lifter runs in [1], its runtime is compiled in [4])
echo "[0/5] Toolkit $TK_TAG + the iOS patch"
clone https://github.com/almost-drowned-rat/xboxrecomp-option-c.git "$TK_TAG" "$TK"
for p in "$ROOT"/packaging/ios/toolkit/*.patch; do
    if git -C "$TK" apply --check "$p" 2>/dev/null; then
        git -C "$TK" apply "$p"
    elif ! git -C "$TK" apply --check --reverse "$p" 2>/dev/null; then
        fail "$(basename "$p") does not apply to $TK"
    fi
done

# ---- [1/5] the lift: default.xbe -> generated C (the steps of tools/lift.ps1 / the Android lift.txt)
GEN=$ROOT/build/ios/gen
if [ -n "$CHECK" ]; then
    echo "[1/5] Compile check: no XBE, no lift"
else
    [ -f "$XBE" ] || fail "default.xbe not found ($XBE): give its path as an argument or in ORTA_XBE"
    XBE=$(cd "$(dirname "$XBE")" && pwd)/$(basename "$XBE")   # absolute: the lift runs inside the toolkit's folder
    sha=$(shasum "$XBE" | cut -d' ' -f1)
    [ "$sha" = "$XBE_SHA1" ] || fail "this default.xbe (SHA-1 $sha) is not the supported Europe (PAL) one ($XBE_SHA1)"
    echo "[1/5] Lifting default.xbe (PAL)"
    VENV=$DEPS/venv
    [ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV"
    "$VENV/bin/python" -c 'import capstone' 2>/dev/null || "$VENV/bin/pip" install -q capstone==5.0.7
    PIPE=$ROOT/build/ios/pipe
    CFG=$ROOT/config/game.toml
    rm -rf "$PIPE" "$GEN"
    mkdir -p "$PIPE/disasm" "$PIPE/func_id" "$PIPE/abi" "$PIPE/recomp" "$GEN"
    (
        cd "$TK"
        P="$VENV/bin/python"
        "$P" -m tools.xbe_parser "$XBE" --json "$PIPE/xbe.json" --quiet
        "$P" -m tools.disasm "$XBE" -o "$PIPE/disasm" --analysis-json "$PIPE/xbe.json" --force --game-config "$CFG"
        "$P" -m tools.func_id "$XBE" --functions "$PIPE/disasm/functions.json" --strings "$PIPE/disasm/strings.json" \
            --xrefs "$PIPE/disasm/xrefs.json" -o "$PIPE/func_id"
        "$P" -m tools.abi_analysis "$XBE" --disasm-dir "$PIPE/disasm" --func-id-dir "$PIPE/func_id" --output-dir "$PIPE/abi"
        "$P" -m tools.recomp "$XBE" --all --game-config "$CFG" --game-name ORTA --gen-dir "$GEN" \
            --disasm-dir "$PIPE/disasm" --func-id-dir "$PIPE/func_id" --abi-dir "$PIPE/abi" -o "$PIPE/recomp"
    ) || fail "the lift failed (see above)"
    ls "$GEN"/*.c >/dev/null 2>&1 || fail "the lift made no C files in $GEN"
    echo "      $(ls "$GEN"/*.c | wc -l | tr -d ' ') generated C files"
fi

# ---- [2/5] dependencies for iOS
echo "[2/5] SDL3, Vulkan-Headers, MoltenVK, glslang"
clone https://github.com/libsdl-org/SDL.git "$SDL_TAG" "$DEPS/src/SDL"
clone https://github.com/KhronosGroup/Vulkan-Headers.git "$VKH_TAG" "$DEPS/src/Vulkan-Headers"
MVK_DIR=$DEPS/MoltenVK-$MVK_TAG
MVK_LIB=${MOLTENVK_LIB:-}
[ -n "$MVK_LIB" ] || MVK_LIB=$(find "$MVK_DIR" -path '*static*' -path '*ios-arm64/*' -name libMoltenVK.a 2>/dev/null | grep -v simulator | head -1 || true)
if [ -z "$MVK_LIB" ]; then
    mkdir -p "$MVK_DIR"
    ok=""
    for asset in MoltenVK-ios.tar MoltenVK-all.tar; do
        if curl -fL --retry 3 -o "$MVK_DIR/$asset" "https://github.com/KhronosGroup/MoltenVK/releases/download/$MVK_TAG/$asset"; then
            tar -xf "$MVK_DIR/$asset" -C "$MVK_DIR" && rm -f "$MVK_DIR/$asset" && ok=1 && break
        fi
    done
    [ -n "$ok" ] || fail "MoltenVK could not be downloaded (or give libMoltenVK.a, static ios-arm64, in MOLTENVK_LIB)"
    MVK_LIB=$(find "$MVK_DIR" -path '*static*' -path '*ios-arm64/*' -name libMoltenVK.a | grep -v simulator | head -1 || true)
fi
[ -n "$MVK_LIB" ] || fail "no static ios-arm64 libMoltenVK.a in $MVK_DIR"
MVK_LIB=$(cd "$(dirname "$MVK_LIB")" && pwd)/$(basename "$MVK_LIB")
GL=$DEPS/glslang-ios
if [ ! -f "$GL/lib/cmake/glslang/glslang-config.cmake" ]; then
    clone https://github.com/KhronosGroup/glslang.git "$GLSLANG_TAG" "$DEPS/src/glslang"
    # the toolkit's own flags (tools/linux/build_glslang.sh): the C interface, no optimizer, no tools, no tests
    cmake -S "$DEPS/src/glslang" -B "$DEPS/glslang-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN \
        -DCMAKE_INSTALL_PREFIX="$GL" -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF -DENABLE_HLSL=OFF \
        -DGLSLANG_ENABLE_INSTALL=ON -DENABLE_SPVREMAPPER=OFF >/dev/null
    cmake --build "$DEPS/glslang-build" -j "$JOBS"
    cmake --install "$DEPS/glslang-build" >/dev/null
fi

# ---- [3/5] configure, [4/5] build
echo "[3/5] Configuring for arm64 iOS"
B=$ROOT/build/ios/build
gen_arg=()
[ -n "$CHECK" ] || gen_arg=("-DRECOMP_GEN_DIR=$GEN")
cmake -S packaging/ios -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DSDL3_SRC="$DEPS/src/SDL" -DXR_TOOLKIT="$TK" -DMOLTENVK_LIB="$MVK_LIB" \
    -DVULKAN_INCLUDE="$DEPS/src/Vulkan-Headers/include" -Dglslang_DIR="$GL/lib/cmake/glslang" \
    -DORTA_BUNDLE_ID="$BUNDLE_ID" \
    -DXR_GAME_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" -DXR_TOOLKIT_COMMIT="$TK_TAG" \
    ${gen_arg[@]+"${gen_arg[@]}"}
if [ -n "$CHECK" ]; then
    echo "[4/5] Compile check (toolkit runtime + the port's sources for iOS)"
    cmake --build "$B" --target orta_ios_check -j "$JOBS" -- -k 0   # every error in one run
    echo; echo "Compile check passed."
    exit 0
fi
echo "[4/5] Building the game for iOS"
cmake --build "$B" --target OrtaRecomp -j "$JOBS"
APP=$(find "$B" -maxdepth 3 -type d -name OrtaRecomp.app | head -1)
[ -n "$APP" ] || fail "OrtaRecomp.app was not made"

# ---- [5/5] the .ipa
echo "[5/5] Packing OrtaRecomp.ipa"
OUT=$ROOT/out/ios
STAGE=$OUT/Payload
rm -rf "$OUT" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# the renderer's shader / pipeline lists from a played game (private release "xbe", optional): seeded into data/ on
# the first start (ios_app.m orta_ios_seed_caches), so the boot prewarm has them all before the first scene
if [ -n "${ORTA_SEED_DIR:-}" ] && ls "$ORTA_SEED_DIR"/*.bin >/dev/null 2>&1; then
    mkdir -p "$STAGE/OrtaRecomp.app/seed"
    cp "$ORTA_SEED_DIR"/*.bin "$STAGE/OrtaRecomp.app/seed/"
    echo "  cache seed: $(cd "$ORTA_SEED_DIR" && ls *.bin | tr '\n' ' ')"
fi
# the app icon: ORTA_ICON (the private repo's assets/icon.png - the game's cover, never in this public repo), else
# the port's own icon
ICON_SRC=assets/icon_256.png
if [ -n "${ORTA_ICON:-}" ] && [ -f "$ORTA_ICON" ]; then ICON_SRC="$ORTA_ICON"; fi
echo "  icon: $ICON_SRC"
sips -s format png -z 120 120 "$ICON_SRC" --out "$STAGE/OrtaRecomp.app/AppIcon60x60@2x.png" >/dev/null
sips -s format png -z 180 180 "$ICON_SRC" --out "$STAGE/OrtaRecomp.app/AppIcon60x60@3x.png" >/dev/null
mkdir -p "$STAGE/OrtaRecomp.app/licenses"
cp LICENSE "$STAGE/OrtaRecomp.app/licenses/Orta-Recompiled_GPL-3.0.txt"
cp "$TK/LICENSE" "$STAGE/OrtaRecomp.app/licenses/xboxrecomp_MIT.txt"
cp "$TK/NOTICE" "$STAGE/OrtaRecomp.app/licenses/xboxrecomp_NOTICE.txt"
cp "$TK/LICENSES/LGPL-2.1.txt" "$STAGE/OrtaRecomp.app/licenses/xemu-parts_LGPL-2.1.txt"
cp "$DEPS/src/SDL/LICENSE.txt" "$STAGE/OrtaRecomp.app/licenses/SDL3_zlib.txt"
cp "$DEPS/src/glslang/LICENSE.txt" "$STAGE/OrtaRecomp.app/licenses/glslang.txt" 2>/dev/null || true
mvk_lic=$(find "$MVK_DIR" -maxdepth 3 -name LICENSE | head -1 || true)
[ -n "$mvk_lic" ] && cp "$mvk_lic" "$STAGE/OrtaRecomp.app/licenses/MoltenVK_Apache-2.0.txt"
# the BACK menu's "About and licences" (touch_ios.m) reads this list, as the APK's assets/licenses/README.txt
cat > "$STAGE/OrtaRecomp.app/licenses/README.txt" <<'LICEOF'
Orta Recompiled - iOS: the licences of everything inside this app

Orta Recompiled (this app's own code)   GPL-3.0-or-later   github.com/almost-drowned-rat/Orta-Recompiled-Android
xboxrecomp toolkit (option-c)           MIT, parts from xemu under LGPL-2.1-or-later (NOTICE lists them)
SDL3                                    zlib               github.com/libsdl-org/SDL
glslang                                 BSD / MIT / Apache-2.0   github.com/KhronosGroup/glslang
MoltenVK                                Apache-2.0         github.com/KhronosGroup/MoltenVK

The game's code in this app was made from the player's own disc on the build machine: this app is for that
player only and is never shared. Panzer Dragoon Orta is a trademark of SEGA; this project is not affiliated with
SEGA, Microsoft or Apple.
LICEOF
# ad hoc signature (LiveContainer and the sideloading tools sign it again)
codesign --force --sign - --timestamp=none "$STAGE/OrtaRecomp.app" >/dev/null 2>&1 || true
(cd "$OUT" && zip -qry OrtaRecomp.ipa Payload)
echo
echo "Done: out/ios/OrtaRecomp.ipa ($(du -h "$OUT/OrtaRecomp.ipa" | cut -f1))"
echo "LiveContainer: send it to the phone (AirDrop, Files) and add it with LiveContainer's + button."
echo "It holds code made from your own disc: keep it to yourself (a private repository, never a public release)."
