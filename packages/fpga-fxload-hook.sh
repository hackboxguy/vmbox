#!/bin/sh
# Build the pinned FXLoad source used to bootstrap the XPC2 adapter firmware.
set -eu
SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
BUILD_DIR=/tmp/fpga-fxload-build
[ -f "$SOURCE_DIR/CMakeLists.txt" ] && [ -f "$SOURCE_DIR/CLI11/LICENSE" ] || { echo "ERROR: pinned FXLoad source or submodule is incomplete" >&2; exit 1; }
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"
/usr/bin/fxload --help >/dev/null
