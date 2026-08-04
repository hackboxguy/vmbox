#!/bin/sh
# Validate and install private FPGA catalogue, manifest and runtime mapping.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
INPUT_DIR="$SOURCE_DIR/firmware/fpga"
INSTALLER="$SOURCE_DIR/tools/install_fpga_flasher_inputs.py"

[ -f "$INPUT_DIR/catalog.json" ] && [ -f "$INPUT_DIR/approved-artifacts.json" ] && \
    [ -f "$INPUT_DIR/runtime-config.json" ] && [ -f "$INSTALLER" ] || {
    echo "ERROR: FPGA flasher catalogue inputs are incomplete" >&2
    exit 1
}

python3 "$INSTALLER" --source-root "$INPUT_DIR" --destination /usr/share/fpga-flasher
