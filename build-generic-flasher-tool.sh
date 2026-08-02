#!/bin/bash
# Build the private Generic Flasher VMBOX OVA from sibling private sources.
# Run as a normal user: only image construction steps use sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"

VERSION="1.0.0"
OUTPUT_DIR="/tmp/generic-flasher-vmbox-build"
OS_PART_SIZE="500M"
DATA_PART_SIZE="4096M"
APP_PART_SIZE="512M"
USB_MODE="1"
VM_NAME=""
CLEAN=false
EXPORT_OVA=true
START_VM=false

PACKAGES_FILE="${SCRIPT_DIR}/packages-generic-flasher.txt"
SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-generic-flasher-system.txt"
APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-generic-flasher.txt"

usage() {
    cat <<EOF
Generic Flasher VMBOX OVA builder

Usage: $0 [OPTIONS]

  --version=VER      Image and application version (default: ${VERSION})
  --output=DIR       Build-artifact directory (default: ${OUTPUT_DIR})
  --vmname=NAME      VirtualBox VM name (default: generic-flasher-v<version>)
  --ospart=SIZE      Root filesystem partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE    Persistent data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE     Read-only application partition size (default: ${APP_PART_SIZE})
  --usb=1|2|3        VirtualBox USB controller version (default: ${USB_MODE})
  --clean            Remove the selected output directory before building
  --no-ova           Register the VM but do not export an OVA
  --start            Start the registered VM headlessly after the build
  --help, -h         Show this help

Private source layout required beside vmbox/:
  rh850-flash-tools/  sp6bins/  web-terminal/

Initialize the private RH850 webapp submodule before building:
  git submodule update --init --recursive

The image uses an exact VirtualBox USB filter for the EEHB Bluebox
(VID 0403, PID a9a0). USB 2/3 requires a version-matched Extension Pack.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --version=*) VERSION="${arg#*=}" ;;
        --output=*) OUTPUT_DIR="${arg#*=}" ;;
        --vmname=*) VM_NAME="${arg#*=}" ;;
        --ospart=*) OS_PART_SIZE="${arg#*=}" ;;
        --datapart=*) DATA_PART_SIZE="${arg#*=}" ;;
        --apppart=*) APP_PART_SIZE="${arg#*=}" ;;
        --usb=*) USB_MODE="${arg#*=}" ;;
        --clean) CLEAN=true ;;
        --no-ova) EXPORT_OVA=false ;;
        --start) START_VM=true ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -ne 0 ] || {
    echo "ERROR: run this builder as a normal user, not root." >&2
    exit 1
}

case "$USB_MODE" in 1|2|3) ;; *) echo "ERROR: --usb must be 1, 2, or 3" >&2; exit 2 ;; esac
[ -n "$VM_NAME" ] || VM_NAME="generic-flasher-v${VERSION}"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

for source_dir in rh850-flash-tools sp6bins web-terminal; do
    [ -d "${SOURCE_ROOT}/${source_dir}" ] || {
        echo "ERROR: required private source directory is missing: ${SOURCE_ROOT}/${source_dir}" >&2
        exit 1
    }
done
for input in \
    "${PACKAGES_FILE}" \
    "${SYSTEM_RUNTIME_PACKAGES_FILE}" \
    "${APP_SYSTEM_PACKAGES_FILE}" \
    "${SOURCE_ROOT}/sp6bins/firmware/catalog.json" \
    "${SCRIPT_DIR}/apps/rh850-flasher-webapp/CMakeLists.txt" \
    "${SOURCE_ROOT}/web-terminal/CMakeLists.txt"; do
    [ -f "$input" ] || { echo "ERROR: required build input is missing: $input" >&2; exit 1; }
done
command -v VBoxManage >/dev/null 2>&1 || {
    echo "ERROR: VBoxManage is required to register or export the VM." >&2
    exit 1
}

if [ "$CLEAN" = true ] && [ -e "$OUTPUT_DIR" ]; then
    case "$OUTPUT_DIR" in
        /|"${SOURCE_ROOT}"|"${SCRIPT_DIR}")
            echo "ERROR: refusing to clean unsafe output directory: $OUTPUT_DIR" >&2
            exit 1
            ;;
    esac
    echo ">>> Cleaning ${OUTPUT_DIR}"
    sudo rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

available_mb="$(df -BM "$OUTPUT_DIR" | awk 'NR == 2 { sub(/M$/, "", $4); print $4 }')"
if [ "${available_mb:-0}" -lt 6144 ]; then
    echo "ERROR: at least 6 GB free is required under $(dirname "$OUTPUT_DIR") (have ${available_mb:-0} MB)." >&2
    exit 1
fi

echo "=================================================="
echo " Generic Flasher VMBOX build"
echo " version : ${VERSION}"
echo " vm name : ${VM_NAME}"
echo " output  : ${OUTPUT_DIR}"
echo " parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} app=${APP_PART_SIZE}"
echo " usb     : ${USB_MODE}.0"
echo "=================================================="

cd "$SCRIPT_DIR"

echo ">>> [1/6] Base root filesystem"
sudo "${SCRIPT_DIR}/build.sh" \
    --mode=base \
    --output="$OUTPUT_DIR" \
    --version="$VERSION" \
    --hostname=generic-flasher

echo ">>> [2/6] Private RH850 command runtime and firmware catalogue"
sudo "${SCRIPT_DIR}/scripts/02-build-packages.sh" \
    --rootfs="${OUTPUT_DIR}/rootfs" \
    --packages="$SYSTEM_RUNTIME_PACKAGES_FILE" \
    --version="$VERSION"

echo ">>> [3/6] Web application partition"
sudo "${SCRIPT_DIR}/scripts/build-app-partition.sh" \
    --rootfs="${OUTPUT_DIR}/rootfs" \
    --packages="$PACKAGES_FILE" \
    --system-packages="$APP_SYSTEM_PACKAGES_FILE" \
    --output="${OUTPUT_DIR}/app" \
    --version="$VERSION"

echo ">>> [4/6] Disk image"
sudo "${SCRIPT_DIR}/scripts/03-create-image.sh" \
    --rootfs="${OUTPUT_DIR}/rootfs" \
    --output="$OUTPUT_DIR" \
    --ospart="$OS_PART_SIZE" \
    --datapart="$DATA_PART_SIZE" \
    --apppart="$APP_PART_SIZE" \
    --appdir="${OUTPUT_DIR}/app/app"

echo ">>> [5/6] Returning image artifacts to $(id -un)"
sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"

echo ">>> [6/6] Registering VirtualBox VM"
convert_args=(
    --input="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"
    --vmname="$VM_NAME"
    --appdir="${OUTPUT_DIR}/app/app"
    --usb="$USB_MODE"
    --rh850-bluebox
    --force
)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)
"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

if [ "$START_VM" = true ]; then
    echo ">>> Starting ${VM_NAME}"
    VBoxManage startvm "$VM_NAME" --type headless
fi

echo "Done. Open http://localhost:8000 and launch RH850 Flasher from Applications."
