#!/bin/sh
# Build the pinned OpenFPGALoader source for the Arty-Z7 SRAM-only backend.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
BACKEND_SOURCE=/tmp/build-sources/sp6bins/src/scripts/fpga-openfpgaloader-artyz7-backend.sh
BUILD_DIR=/tmp/fpga-openfpgaloader-build

[ -f "$SOURCE_DIR/CMakeLists.txt" ] && [ -f "$SOURCE_DIR/src/board.hpp" ] && \
    [ -f "$BACKEND_SOURCE" ] || {
    echo "ERROR: OpenFPGALoader or Arty-Z7 backend source is incomplete" >&2
    exit 1
}

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_UDEV=OFF \
    -DENABLE_CMSISDAP=OFF \
    -DENABLE_GOWIN_GWU2X=OFF \
    -DENABLE_LIBGPIOD=OFF \
    -DENABLE_REMOTEBITBANG=OFF
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"
install -D -m 0755 "$BACKEND_SOURCE" /usr/libexec/fpga-flasher/openfpgaloader-artyz7

/usr/bin/openFPGALoader --list-boards | grep -Eq '^[[:space:]]*arty_z7_20[[:space:]]' || {
    echo "ERROR: pinned OpenFPGALoader lacks Arty-Z7-20 support" >&2
    exit 1
}
