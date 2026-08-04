#!/bin/sh
# Build the reviewed XC3SPROG source used by the private Spartan-7 backend.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
BUILD_DIR=/tmp/fpga-xc3sprog-build

[ -f "$SOURCE_DIR/CMakeLists.txt" ] && [ -f "$SOURCE_DIR/xusb_xp2.hex" ] && \
    [ -f "$SOURCE_DIR/bscan_spi/xc7s50csga324-1.bit" ] || {
    echo "ERROR: XC3SPROG source is incomplete" >&2
    exit 1
}

# These are runtime tools, not compiler dependencies.  The base image already
# provides lsusb; fxload is required for the XPC2 firmware bootstrap.
apk add --no-cache fxload

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DFPGA_FLASHER_RESTRICTED_ASSETS=ON \
    -DUSE_FTD2XX=OFF
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"

[ -x /usr/libexec/fpga-flasher/xc3sprog-spartan7 ] || {
    echo "ERROR: the restricted FPGA backend was not installed" >&2
    exit 1
}
rm -rf "$BUILD_DIR"
