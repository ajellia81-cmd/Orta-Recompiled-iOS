# The iOS app (packaging/ios, 2026-11-18): the game for iPhone / iPad, for LiveContainer. Built on macOS by
# tools/build_ios.sh (and .github/workflows/ios.yml on GitHub's macOS runners) - not by hand:
#
#   cmake -S packaging/ios -B <out> -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64
#         -DSDL3_SRC=<SDL3 source> -DXR_TOOLKIT=<toolkit, patched> -DMOLTENVK_LIB=<libMoltenVK.a, ios-arm64>
#         -DVULKAN_INCLUDE=<holds vulkan/vulkan.h> -Dglslang_DIR=<iOS glslang>/lib/cmake/glslang
#         [-DRECOMP_GEN_DIR=<the lift's generated C>]
#
# As the PC build (CMakeLists.txt at the repo root): the toolkit runtime + the generated C + the port's sources in
# one executable - iOS lets an app run no code it did not bring. The generated C comes from the player's own
# default.xbe (the lift runs on the build machine); the disc's files go to the phone (Documents/game, Files app).
# Without RECOMP_GEN_DIR only the compile check is built (target orta_ios_check: the runtime and the port's sources
# for iOS, nothing linked).
cmake_minimum_required(VERSION 3.24)
project(orta_ios C CXX OBJC)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "packaging/ios is for -DCMAKE_SYSTEM_NAME=iOS (tools/build_ios.sh)")
endif()
foreach(v SDL3_SRC XR_TOOLKIT MOLTENVK_LIB VULKAN_INCLUDE glslang_DIR)
    if(NOT ${v})
        message(FATAL_ERROR "-D${v}=... missing (tools/build_ios.sh passes it)")
    endif()
endforeach()
set(CMAKE_C_STANDARD 11)
set(REPO ${CMAKE_CURRENT_SOURCE_DIR}/../..)
set(ORTA_BUNDLE_ID "io.github.almostdrownedrat.orta" CACHE STRING "the app's bundle identifier")
set(ORTA_VERSION "0.1.0" CACHE STRING "the app's version")

# SDL3, static
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(${SDL3_SRC} sdl3 EXCLUDE_FROM_ALL)

# MoltenVK is the app's Vulkan (no loader on iOS): what nv2a_vk's find_package(Vulkan) takes, and SDL finds
# vkGetInstanceProcAddr in the process itself
set(Vulkan_INCLUDE_DIR ${VULKAN_INCLUDE} CACHE PATH "" FORCE)
set(Vulkan_LIBRARY ${MOLTENVK_LIB} CACHE FILEPATH "" FORCE)

# The toolkit, as the root CMakeLists.txt sets it up: Vulkan only, no D3D11
add_compile_definitions(RECOMP_ICALL_FEEDBACK)
set(XBOXRECOMP_VULKAN ON CACHE BOOL "" FORCE)
set(XBOXRECOMP_D3D11 OFF CACHE BOOL "" FORCE)
add_subdirectory(${XR_TOOLKIT} xboxrecomp EXCLUDE_FROM_ALL)
set(ORTA_TK_LIBS xbox_kernel xbox_dsound xbox_input xbox_usb xbox_apu xbox_video xbox_nv2a_vk xbox_bootvideo
    xbox_install_ui)

# the window / taskbar icon of the PC build (main.c includes it)
file(READ ${REPO}/assets/icon_64.bmp _icon HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," _icon "${_icon}")
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/port/port_icon.h
     "/* generated from assets/icon_64.bmp (packaging/ios) */\nstatic const unsigned char g_port_icon_bmp[] = {${_icon}};\n")

set(ORTA_PORT_SRC ${REPO}/src/main.c ${REPO}/src/input.c ${REPO}/src/settings.c ${REPO}/src/vk_check.c
    ${REPO}/src/platform/host_linux.c)
set(ORTA_IOS_SRC src/ios_app.m src/touchpad_ios.c src/overlay_ios.m)
set(ORTA_DEFS ORTA_VULKAN=1 ORTA_INSTALLER=1 ORTA_BOOTVIDEO=1 _GNU_SOURCE)

function(orta_setup t)
    target_include_directories(${t} PRIVATE ${REPO}/src ${CMAKE_CURRENT_SOURCE_DIR}/src
                               ${CMAKE_CURRENT_BINARY_DIR}/port ${XR_TOOLKIT}/include ${ARGN})
    target_compile_definitions(${t} PRIVATE ${ORTA_DEFS})
    target_compile_options(${t} PRIVATE $<$<COMPILE_LANGUAGE:C>:-w> $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)
endfunction()

if(NOT RECOMP_GEN_DIR)
    # compile check (workflow mode "check"): everything but recomp_manual.c, which needs the lift's headers
    add_library(orta_ios_check STATIC ${ORTA_PORT_SRC} ${ORTA_IOS_SRC})
    orta_setup(orta_ios_check)
    target_link_libraries(orta_ios_check PRIVATE ${ORTA_TK_LIBS} SDL3::SDL3)
    return()
endif()

file(GLOB ORTA_GEN_SRC CONFIGURE_DEPENDS ${RECOMP_GEN_DIR}/*.c)
if(NOT ORTA_GEN_SRC)
    message(FATAL_ERROR "no generated C in ${RECOMP_GEN_DIR} - the lift did not run (tools/build_ios.sh)")
endif()
add_executable(OrtaRecomp MACOSX_BUNDLE ${ORTA_PORT_SRC} ${REPO}/src/recomp_manual.c ${ORTA_GEN_SRC} ${ORTA_IOS_SRC})
orta_setup(OrtaRecomp ${RECOMP_GEN_DIR})
target_link_libraries(OrtaRecomp PRIVATE ${ORTA_TK_LIBS} SDL3::SDL3 ${MOLTENVK_LIB}
    "-framework Metal" "-framework QuartzCore" "-framework IOSurface" "-framework UIKit" "-framework Foundation"
    "-framework CoreGraphics" "-framework GameController" "-framework CoreHaptics" "-framework AVFoundation"
    "-framework CoreMotion" "-framework AudioToolbox" "-framework CoreAudio" c++)
# SDL looks vkGetInstanceProcAddr up with dlsym: keep it; crash reports name the generated function (dladdr)
target_link_options(OrtaRecomp PRIVATE "-Wl,-u,_vkGetInstanceProcAddr" "-Wl,-export_dynamic")
set_target_properties(OrtaRecomp PROPERTIES
    OUTPUT_NAME OrtaRecomp
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    MACOSX_BUNDLE_GUI_IDENTIFIER ${ORTA_BUNDLE_ID}
    MACOSX_BUNDLE_EXECUTABLE_NAME OrtaRecomp
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${ORTA_VERSION}
    MACOSX_BUNDLE_BUNDLE_VERSION ${ORTA_VERSION})
