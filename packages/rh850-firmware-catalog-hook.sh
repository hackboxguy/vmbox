#!/bin/sh
# Validate and install the private RH850 firmware catalogue into the VM rootfs.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
FIRMWARE_DIR="$SOURCE_DIR/firmware"
DEST_DIR=/usr/share/rh850-flasher
INSTALLER="$SOURCE_DIR/tools/install_rh850_firmware_catalog.py"

[ -f "$FIRMWARE_DIR/catalog.json" ] && [ -f "$INSTALLER" ] || {
    echo "ERROR: RH850 firmware catalogue installer inputs are incomplete" >&2
    exit 1
}

exec python3 "$INSTALLER" \
    --catalog "$FIRMWARE_DIR/catalog.json" \
    --source-root "$FIRMWARE_DIR" \
    --destination "$DEST_DIR"
