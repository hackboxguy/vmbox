#!/bin/sh
# Build disptool, the host side of the QVue register interface over the debug
# UART (rh850-uart-host runs it). Only the binary is installed, not the CMake install
# rules, which carry the Pi test framework and scripts; of those the image needs only
# measure-display.sh, the colour sweep MCU-Tools' Analyze Gamut shares with the Pi.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
BUILD_DIR=/tmp/disptool-build

[ -f "$SOURCE_DIR/src/CMakeLists.txt" ] || {
    echo "ERROR: disptool source is incomplete: $SOURCE_DIR" >&2
    exit 1
}

cmake -S "$SOURCE_DIR/src" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j"$(nproc)"
install -D -m 0755 "$BUILD_DIR/disptool" /usr/bin/disptool
install -D -m 0755 "$SOURCE_DIR/display-test-framework/measure-display.sh" \
    /usr/share/display-test-framework/measure-display.sh
rm -rf "$BUILD_DIR"
