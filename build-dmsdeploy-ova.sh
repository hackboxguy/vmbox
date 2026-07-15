#!/bin/bash
#
# build-dmsdeploy-ova.sh - Build the AGX DMS deployment VMBOX OVA.
#
# The appliance flashes a Jetson board (one image serves the supported carrier variants)
# into a working system. Modelled on build-dngtoolkit-ova.sh, with four deltas that
# matter:
#
#   1. The APP partition carries a multi-GB payload (the pruned L4T flash tree, incl. a
#      prebuilt system.img, plus an Ubuntu chroot). It is injected into the app staging dir
#      directly -- NOT built from a git repo via packages-*.txt -- so the blob never passes
#      through the Alpine build chroot.
#   2. APP SquashFS uses zstd, not the default xz. xz on several GB takes tens of minutes.
#   3. USB 3.0 (xHCI) + a VID 0955 filter, so the VM can capture the Jetson in recovery mode.
#      xHCI is ~2x faster than EHCI on the APP write (measured: ~26 min vs ~49 min for a 12 GB
#      image -- USB is the bottleneck, not eMMC), so we take it. It was NOT usable earlier:
#      flash.sh used to reset the board back into RCM partway through the flash, and VirtualBox's
#      re-capture of the re-enumerated device is reliable on Linux but FAILS on Windows (tegrarcm
#      then blocks forever on a dead USB handle -- "BootRom is not running"). jetson-flash.sh now
#      presets the board identity so flash.sh NEVER reboots the board mid-flash: the whole flash
#      is one continuous USB session with no re-enumeration -- which was the *exact* thing that
#      broke xHCI on Windows. With that gone, xHCI is safe on both hosts. If a Windows host ever
#      regresses here, the fallback is one line: --usb=2 (EHCI), slower but re-capture-free by
#      being the controller the board natively speaks. NOTE the guest controller type is
#      independent of the physical host port: a board on a USB 3 port or a USB-C dock attaches
#      fine to either guest controller. This REQUIRES the VirtualBox Extension Pack on the host.
#   4. Sizes and the free-space gate are scaled for the payload.
#
# Usage (run as a NORMAL user; it calls sudo internally where needed):
#   ./build-dmsdeploy-ova.sh --payload=/path/to/payload/app --version=0.1.0
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"

VERSION="0.1.0"
OUTPUT_DIR="${VMBOX_OUTPUT_DIR:-/tmp/alpine-build}"
# NOTE: on hosts where /tmp is tmpfs, the multi-GB payload will not fit there. Point
# --output=DIR (or VMBOX_OUTPUT_DIR) at real disk in that case.
PAYLOAD_DIR=""                     # staged APP content (see stage-payload.sh)
OS_PART_SIZE="700M"
DATA_PART_SIZE="8192M"             # holds the overlay uppers + flash working files
APP_PART_SIZE="7168M"              # holds the zstd-compressed payload
VM_NAME=""
VM_MEMORY=2048
CLEAN=false
EXPORT_OVA=true

show_usage() {
    cat <<EOF
AGX DMS deployment OVA builder

Usage: $0 --payload=DIR [OPTIONS]

  --payload=DIR     Staged APP content (contains manifest.json + dms-deploy/)  [required]
  --version=VER     Image version (default: ${VERSION})
  --output=DIR      Build artifact dir (default: ${OUTPUT_DIR})
  --ospart=SIZE     OS partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE   Data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE    App partition size (default: ${APP_PART_SIZE})
  --memory=MB       VM memory (default: ${VM_MEMORY})
  --vmname=NAME     VM name (default: vmbox-dmsdeploy-v<version>)
  --clean           Remove the output dir first
  --no-ova          Register the VM but skip OVA export
  --help, -h        Show this help
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --payload=*)  PAYLOAD_DIR="${arg#*=}" ;;
        --version=*)  VERSION="${arg#*=}" ;;
        --output=*)   OUTPUT_DIR="${arg#*=}" ;;
        --ospart=*)   OS_PART_SIZE="${arg#*=}" ;;
        --datapart=*) DATA_PART_SIZE="${arg#*=}" ;;
        --apppart=*)  APP_PART_SIZE="${arg#*=}" ;;
        --memory=*)   VM_MEMORY="${arg#*=}" ;;
        --vmname=*)   VM_NAME="${arg#*=}" ;;
        --clean)      CLEAN=true ;;
        --no-ova)     EXPORT_OVA=false ;;
        --help|-h)    show_usage ;;
        *)            echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
    esac
done

[ -n "$VM_NAME" ] || VM_NAME="vmbox-dmsdeploy-v${VERSION}"

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run as a normal user, not root (the VirtualBox import must be yours)." >&2
    exit 1
fi
[ -n "$PAYLOAD_DIR" ] || { echo "ERROR: --payload=DIR is required (see --help)" >&2; exit 1; }
[ -d "$PAYLOAD_DIR/dms-deploy" ] || {
    echo "ERROR: $PAYLOAD_DIR does not look like a staged payload (no dms-deploy/)." >&2; exit 1; }

command -v VBoxManage >/dev/null 2>&1 || { echo "ERROR: VBoxManage not found." >&2; exit 1; }

# USB 2/3 passthrough is not optional here -- it is how the appliance reaches the board.
# Fail now with a clear message rather than at flash time with a confusing one.
if ! VBoxManage list extpacks 2>/dev/null | grep -qE "Oracle (VM )?VirtualBox Extension Pack"; then
    echo "ERROR: the VirtualBox Extension Pack is not installed on this host." >&2
    echo "       It is required for USB 2.0/3.0 passthrough, without which the VM cannot" >&2
    echo "       flash a Jetson. Install the pack matching VirtualBox $(VBoxManage --version | sed 's/[_r].*//')." >&2
    exit 1
fi

ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
RAW_IMAGE="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"

if [ "$CLEAN" = true ] && [ -e "$OUTPUT_DIR" ]; then
    echo ">>> Cleaning ${OUTPUT_DIR}"
    sudo rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# The payload is staged as root (built in a container), so parts of it are unreadable to
# this user. Plain `du` would exit nonzero on those, and under `set -o pipefail` that would
# abort the whole script silently. Use sudo, and don't let a du hiccup kill the build.
payload_mb=$( { sudo du -sm "$PAYLOAD_DIR" 2>/dev/null || true; } | tail -1 | cut -f1 )
[ -n "$payload_mb" ] || payload_mb=8192   # fall back to a sane over-estimate
# raw image + VDI + OVA are each roughly a full copy on top of the payload itself.
need_mb=$(( payload_mb * 3 + 4096 ))
avail_mb=$(df -BM "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')
if [ "${avail_mb:-0}" -lt "$need_mb" ]; then
    echo "ERROR: need ~${need_mb}MB free in ${OUTPUT_DIR} (payload is ${payload_mb}MB); have ${avail_mb}MB." >&2
    exit 1
fi

echo "=================================================="
echo "  AGX DMS deployment OVA"
echo "  version : ${VERSION}"
echo "  vm name : ${VM_NAME}"
echo "  payload : ${PAYLOAD_DIR} (${payload_mb} MB uncompressed)"
echo "  parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} app=${APP_PART_SIZE}"
echo "=================================================="

echo ">>> [1/4] Base Alpine rootfs"
sudo "${SCRIPT_DIR}/build.sh" --mode=base --output="$OUTPUT_DIR" --version="$VERSION"

echo ">>> [2/4] Disk image (payload -> APP partition, zstd SquashFS)"
sudo env APP_SQUASHFS_COMP=zstd APP_SQUASHFS_LEVEL=19 \
    "${SCRIPT_DIR}/scripts/03-create-image.sh" \
    --rootfs="$ROOTFS_DIR" \
    --output="$OUTPUT_DIR" \
    --ospart="$OS_PART_SIZE" \
    --datapart="$DATA_PART_SIZE" \
    --apppart="$APP_PART_SIZE" \
    --appdir="$PAYLOAD_DIR"

echo ">>> [3/4] chown artifacts to $(id -un)"
sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"

echo ">>> [4/4] VirtualBox import (USB3 + Jetson filter)"
convert_args=(
    --input="$RAW_IMAGE"
    --vmname="$VM_NAME"
    --appdir="$PAYLOAD_DIR"
    --memory="$VM_MEMORY"
    --usb=3
    --jetson
    --force
)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)
"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

echo
echo "Done. VM '${VM_NAME}' registered."
echo "The HOST running this VM needs the VirtualBox Extension Pack, and the Jetson must be"
echo "in recovery mode (VID 0955) for the filter to capture it."
