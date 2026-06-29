#!/bin/bash
#
# build-dngtoolkit-ova.sh - One-command DNG Toolkit VMBOX OVA builder.
#
# Runs the full pipeline (base rootfs -> app partition -> disk image -> OVA)
# that is otherwise done by hand. Modelled on build-image.sh.
#
# Prerequisite: clone with submodules so apps/dngtoolkit-webapp (incl. its .git,
# which feeds the generated build version) is present:
#   git clone --recursive https://github.com/hackboxguy/vmbox.git
#
# Usage (run as a NORMAL user; it calls sudo internally where needed):
#   ./build-dngtoolkit-ova.sh --version=1.0.2
#   ./build-dngtoolkit-ova.sh --version=1.0.2 --clean --start
#
# Do NOT run this whole script under sudo: the final VirtualBox import must run
# as your user (VBoxManage VMs are per-user). Steps that need root use sudo.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"

# ---- Defaults (match the documented 7-step dngtoolkit flow) ----------------
VERSION="1.0.2"
OUTPUT_DIR="/tmp/alpine-build"
PACKAGES_FILE="${SCRIPT_DIR}/packages-dngtoolkit.txt"
OS_PART_SIZE="500M"
DATA_PART_SIZE="4096M"
APP_PART_SIZE="500M"
VM_NAME=""              # default derived from version below
CLEAN=false
EXPORT_OVA=true
START_VM=false

show_usage() {
    cat <<EOF
DNG Toolkit VMBOX OVA builder

Usage: $0 [OPTIONS]

  --version=VER     Image/app version (default: ${VERSION})
  --output=DIR      Build artifact dir (default: ${OUTPUT_DIR})
  --packages=FILE   App package list (default: packages-dngtoolkit.txt)
  --ospart=SIZE     OS partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE   Data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE    App partition size (default: ${APP_PART_SIZE})
  --vmname=NAME     VirtualBox VM name (default: vmbox-dngtoolkit-v<version>)
  --clean           Remove the output dir before building (fresh build)
  --no-ova          Register the VM but skip OVA export
  --start           Start the VM headless after building
  --help, -h        Show this help
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --version=*)   VERSION="${arg#*=}" ;;
        --output=*)    OUTPUT_DIR="${arg#*=}" ;;
        --packages=*)  PACKAGES_FILE="${arg#*=}" ;;
        --ospart=*)    OS_PART_SIZE="${arg#*=}" ;;
        --datapart=*)  DATA_PART_SIZE="${arg#*=}" ;;
        --apppart=*)   APP_PART_SIZE="${arg#*=}" ;;
        --vmname=*)    VM_NAME="${arg#*=}" ;;
        --clean)       CLEAN=true ;;
        --no-ova)      EXPORT_OVA=false ;;
        --start)       START_VM=true ;;
        --help|-h)     show_usage ;;
        *)             echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
    esac
done

[ -n "$VM_NAME" ] || VM_NAME="vmbox-dngtoolkit-v${VERSION}"

ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
APP_OUT_DIR="${OUTPUT_DIR}/app"
APP_CONTENT_DIR="${APP_OUT_DIR}/app"            # build-app-partition writes <out>/app
RAW_IMAGE="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"

# ---- Pre-flight checks (so build.sh never hits its interactive prompt) ------
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run this as a normal user, not root. It calls sudo internally;" >&2
    echo "       the final VirtualBox import must run as your user." >&2
    exit 1
fi

if [ ! -e "${SCRIPT_DIR}/apps/dngtoolkit-webapp/.git" ]; then
    echo "ERROR: apps/dngtoolkit-webapp/.git not found." >&2
    echo "       Clone with --recursive (or run: git submodule update --init --recursive)." >&2
    echo "       The submodule .git is also required for the generated build version." >&2
    exit 1
fi

if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: packages file not found: $PACKAGES_FILE" >&2
    exit 1
fi

command -v VBoxManage >/dev/null 2>&1 || {
    echo "ERROR: VBoxManage not found. Install VirtualBox to register/export the VM." >&2
    exit 1
}

if [ "$CLEAN" = true ] && [ -e "$OUTPUT_DIR" ]; then
    echo ">>> Cleaning ${OUTPUT_DIR}"
    sudo rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

avail_mb=$(df -BM "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')
if [ "${avail_mb:-0}" -lt 4096 ]; then
    echo "ERROR: need >=4 GB free in $(dirname "$OUTPUT_DIR") (have ${avail_mb}MB)." >&2
    exit 1
fi

echo "=================================================="
echo "  DNG Toolkit OVA build"
echo "  version : ${VERSION}"
echo "  vm name : ${VM_NAME}"
echo "  output  : ${OUTPUT_DIR}"
echo "  parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} app=${APP_PART_SIZE}"
echo "=================================================="

# ---- 1) Base rootfs ---------------------------------------------------------
echo ">>> [1/5] Base rootfs"
sudo "${SCRIPT_DIR}/build.sh" \
    --mode=base \
    --output="$OUTPUT_DIR" \
    --version="$VERSION"

# ---- 2) App partition (SquashFS /app) with the DNG Toolkit webapp -----------
echo ">>> [2/5] App partition (dngtoolkit-webapp)"
sudo "${SCRIPT_DIR}/scripts/build-app-partition.sh" \
    --packages="$PACKAGES_FILE" \
    --output="$APP_OUT_DIR" \
    --rootfs="$ROOTFS_DIR"

# ---- 3) Disk image (os + data + app partitions) -----------------------------
echo ">>> [3/5] Disk image"
sudo "${SCRIPT_DIR}/scripts/03-create-image.sh" \
    --rootfs="$ROOTFS_DIR" \
    --output="$OUTPUT_DIR" \
    --ospart="$OS_PART_SIZE" \
    --datapart="$DATA_PART_SIZE" \
    --apppart="$APP_PART_SIZE" \
    --appdir="$APP_CONTENT_DIR"

# ---- 4) Hand artifacts back to the current user -----------------------------
echo ">>> [4/5] chown artifacts to $(id -un)"
sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"

# ---- 5) Register VirtualBox VM (+ optional OVA) -----------------------------
[ "$EXPORT_OVA" = true ] && echo ">>> [5/5] VirtualBox import + OVA" || echo ">>> [5/5] VirtualBox import"
convert_args=(
    --input="$RAW_IMAGE"
    --vmname="$VM_NAME"
    --appdir="$APP_CONTENT_DIR"
    --force
)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)

"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

if [ "$START_VM" = true ]; then
    echo ">>> Starting ${VM_NAME} (headless)"
    VBoxManage startvm "$VM_NAME" --type headless
fi

echo ""
echo "Done. VM '${VM_NAME}' registered."
[ "$EXPORT_OVA" = true ] && echo "OVA exported under ${OUTPUT_DIR} (see 04-convert-to-vbox.sh output above)."
