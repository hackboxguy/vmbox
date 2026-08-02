#!/bin/sh
# Build the private RH850 command-line runtime into the immutable VMBOX rootfs.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
BUILD_DIR=/tmp/rh850-flash-tools-build

[ -f "$SOURCE_DIR/CMakeLists.txt" ] || {
    echo "ERROR: RH850 tools source is incomplete: $SOURCE_DIR" >&2
    exit 1
}

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"

install -D -m 0644 "$SOURCE_DIR/packaging/99-rh850-bluebox.rules" \
    /etc/udev/rules.d/99-rh850-bluebox.rules
addgroup -S plugdev 2>/dev/null || true
addgroup admin plugdev 2>/dev/null || true

rm -rf "$BUILD_DIR"
