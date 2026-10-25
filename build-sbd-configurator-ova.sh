#!/bin/bash
#
# build-sbd-configurator-ova.sh - One-command SBD configurator (text-to-block) VMBOX OVA builder.
#
# Pipeline: base rootfs -> runtime packages (python3, py3-pillow, font-liberation, resvg) -> app partition
# (text-to-block at the tag pinned in packages-sbd-configurator.txt) -> disk image -> VirtualBox VM (+ OVA).
# Modelled on build-generic-flasher-tool.sh (runtime step) and build-dngtoolkit-ova.sh.
#
# The app comes from the git submodule apps/text-to-block (private repo: clone vmbox with --recursive, or run
# git submodule update --init apps/text-to-block); the build takes the tag pinned in packages-sbd-configurator.txt
# out of the submodule, so no GitHub login is needed inside the build chroot.
#
# Usage (run as a NORMAL user; it calls sudo internally where needed):
#   ./build-sbd-configurator-ova.sh --version=0.1.0 --clean
#   ./build-sbd-configurator-ova.sh --version=0.1.0 --dry-run
#
# After boot: dashboard http://localhost:8000 -> Applications -> SBD configurator
# (proxied at /app/sbd-configurator/), direct port http://localhost:8008 for debugging.
# User data: /data/app-data/sbd-configurator/{profiles,cost} (survives reboots and APP partition upgrades).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"

VERSION="0.1.0"
OUTPUT_DIR=""                 # default: ${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/sbd-configurator-<version>
ALLOW_TMPFS=false
PACKAGES_FILE="${SCRIPT_DIR}/packages-sbd-configurator.txt"
SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-sbd-configurator-system.txt"
APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-sbd-configurator.txt"
OS_PART_SIZE="500M"
DATA_PART_SIZE="1024M"
APP_PART_SIZE="300M"
VM_NAME=""
CLEAN=false
EXPORT_OVA=true
START_VM=false
DRY_RUN=false

show_usage() {
    cat <<EOF
SBD configurator VMBOX OVA builder

Usage: $0 [OPTIONS]

  --version=VER     Image version (default: ${VERSION}); the app version is the pinned text-to-block tag
  --output=DIR      Build artifact dir (default: \${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/sbd-configurator-<version>);
                    it also holds the VM's disk, so it must not be on tmpfs (/tmp): a reboot would lose the VM
  --allow-tmpfs     Allow an --output on tmpfs anyway (a throw-away test build)
  --packages=FILE   App package list (default: packages-sbd-configurator.txt)
  --ospart=SIZE     OS partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE   Data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE    App partition size (default: ${APP_PART_SIZE})
  --vmname=NAME     VirtualBox VM name (default: vmbox-sbd-configurator-v<version>)
  --clean           Remove the output dir before building (fresh build)
  --dry-run         Print the plan and the checks, change nothing
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
        --allow-tmpfs) ALLOW_TMPFS=true ;;
        --packages=*)  PACKAGES_FILE="${arg#*=}" ;;
        --ospart=*)    OS_PART_SIZE="${arg#*=}" ;;
        --datapart=*)  DATA_PART_SIZE="${arg#*=}" ;;
        --apppart=*)   APP_PART_SIZE="${arg#*=}" ;;
        --vmname=*)    VM_NAME="${arg#*=}" ;;
        --clean)       CLEAN=true ;;
        --dry-run)     DRY_RUN=true ;;
        --no-ova)      EXPORT_OVA=false ;;
        --start)       START_VM=true ;;
        --help|-h)     show_usage ;;
        *)             echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
    esac
done

[ -n "$VM_NAME" ] || VM_NAME="vmbox-sbd-configurator-v${VERSION}"
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/sbd-configurator-${VERSION}"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
APP_OUT_DIR="${OUTPUT_DIR}/app"
APP_CONTENT_DIR="${APP_OUT_DIR}/app"            # build-app-partition writes <out>/app
RAW_IMAGE="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"

# ---- Pre-flight checks -------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

# The output dir holds the VM's disk (VDI): on tmpfs a host reboot loses the registered VM (it did, 2026-10-25).
out_probe="$OUTPUT_DIR"
while [ ! -e "$out_probe" ] && [ "$out_probe" != "/" ]; do out_probe="$(dirname "$out_probe")"; done
out_fs="$(findmnt -no FSTYPE --target "$out_probe" 2>/dev/null || stat -f -c %T "$out_probe")"
if [ "$out_fs" = "tmpfs" ] || [[ "$OUTPUT_DIR" == /tmp/* ]]; then
    [ "$ALLOW_TMPFS" = true ] || fail "--output ${OUTPUT_DIR} is on tmpfs (${out_fs}): the VM's disk would not survive a reboot. Use the default (\${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}) or pass --allow-tmpfs for a throw-away build."
    echo "WARNING: --output on tmpfs (--allow-tmpfs): the VM is lost on reboot" >&2
fi

[ "$(id -u)" -ne 0 ] || fail "run this as a normal user, not root (it calls sudo; VirtualBox VMs are per-user)."
for f in "$PACKAGES_FILE" "$SYSTEM_RUNTIME_PACKAGES_FILE" "$APP_SYSTEM_PACKAGES_FILE" \
         "${SCRIPT_DIR}/packages/sbd-runtime-dependencies-hook.sh"; do
    [ -f "$f" ] || fail "missing: $f"
done

app_line="$(grep -v '^[[:space:]]*#' "$PACKAGES_FILE" | grep -m1 '^sbd-configurator|' || true)"
[ -n "$app_line" ] || fail "no sbd-configurator line in $PACKAGES_FILE"
APP_REPO="$(echo "$app_line" | cut -d'|' -f2)"
APP_TAG="$(echo "$app_line" | cut -d'|' -f3)"
PROJECT_ROOT="$SCRIPT_DIR"
APP_REPO="$(eval echo "$APP_REPO")"   # file://${PROJECT_ROOT}/apps/text-to-block (git submodule)
if [[ "$APP_REPO" == file://* ]] && [ ! -e "${APP_REPO#file://}/.git" ]; then
    fail "${APP_REPO#file://} is empty: clone vmbox with --recursive, or run: git submodule update --init apps/text-to-block"
fi

check_tag() {
    # The pinned tag must exist on the remote: vmbox clones it inside the chroot.
    if ! git ls-remote --exit-code --tags "$APP_REPO" "refs/tags/${APP_TAG}" >/dev/null 2>&1; then
        echo "  WARNING: tag ${APP_TAG} not found on ${APP_REPO} (push it first: git push origin ${APP_TAG})"
        return 1
    fi
    echo "  tag ${APP_TAG} found on ${APP_REPO}"
    # scripts/build-app-partition.sh clones the pinned tag itself (--branch <tag>) and fails on a missing tag, so the
    # tag need not be the tip of the default branch; report which commit the image will carry.
    local head tag
    head="$(git ls-remote "$APP_REPO" HEAD | cut -f1)"
    tag="$(git ls-remote --tags "$APP_REPO" "refs/tags/${APP_TAG}^{}" | cut -f1)"
    [ -n "$tag" ] || tag="$(git ls-remote --tags "$APP_REPO" "refs/tags/${APP_TAG}" | cut -f1)"   # lightweight tag
    [ -n "$tag" ] || { echo "  ERROR: tag ${APP_TAG} not found"; return 1; }
    if [ "$head" = "$tag" ]; then
        echo "  tag ${APP_TAG} is the tip of the default branch (${head:0:7})"
    else
        echo "  tag ${APP_TAG} is ${tag:0:7} (default branch tip ${head:0:7}); the image carries the tag"
    fi
}

echo "=================================================="
echo "  SBD configurator OVA build$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
echo "  version : ${VERSION}"
echo "  app     : ${APP_REPO} @ ${APP_TAG}"
echo "  vm name : ${VM_NAME}"
echo "  output  : ${OUTPUT_DIR}"
echo "  parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} app=${APP_PART_SIZE}"
echo "=================================================="

if [ "$DRY_RUN" = true ]; then
    echo "Checks:"
    check_tag || true
    command -v VBoxManage >/dev/null 2>&1 && echo "  VBoxManage found" || echo "  WARNING: VBoxManage not found"
    echo "Plan:"
    echo "  1 sudo build.sh --mode=base (hostname sbd-configurator)"
    echo "  2 sudo scripts/02-build-packages.sh --packages=$(basename "$SYSTEM_RUNTIME_PACKAGES_FILE")"
    echo "  3 sudo scripts/build-app-partition.sh --packages=$(basename "$PACKAGES_FILE")"
    echo "  4 sudo scripts/03-create-image.sh"
    echo "  5 chown, 6 scripts/04-convert-to-vbox.sh$([ "$EXPORT_OVA" = true ] && echo ' --export-ova')"
    exit 0
fi

check_tag || fail "the pinned tag is not on the remote"
command -v VBoxManage >/dev/null 2>&1 || fail "VBoxManage not found. Install VirtualBox to register/export the VM."

if [ "$CLEAN" = true ] && [ -e "$OUTPUT_DIR" ]; then
    echo ">>> Cleaning ${OUTPUT_DIR}"
    sudo rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

avail_mb=$(df -BM "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')
[ "${avail_mb:-0}" -ge 4096 ] || fail "need >=4 GB free in ${OUTPUT_DIR} (have ${avail_mb}MB)."

cd "$SCRIPT_DIR"

echo ">>> [1/6] Base root filesystem"
sudo "${SCRIPT_DIR}/build.sh" \
    --mode=base \
    --output="$OUTPUT_DIR" \
    --version="$VERSION" \
    --hostname=sbd-configurator

echo ">>> [2/6] Runtime packages (python3, py3-pillow, font-liberation, resvg)"
sudo "${SCRIPT_DIR}/scripts/02-build-packages.sh" \
    --rootfs="$ROOTFS_DIR" \
    --packages="$SYSTEM_RUNTIME_PACKAGES_FILE" \
    --version="$VERSION"

echo ">>> [3/6] App partition (sbd-configurator @ ${APP_TAG})"
sudo "${SCRIPT_DIR}/scripts/build-app-partition.sh" \
    --rootfs="$ROOTFS_DIR" \
    --packages="$PACKAGES_FILE" \
    --system-packages="$APP_SYSTEM_PACKAGES_FILE" \
    --output="$APP_OUT_DIR" \
    --version="$VERSION"

echo ">>> [4/6] Disk image"
sudo "${SCRIPT_DIR}/scripts/03-create-image.sh" \
    --rootfs="$ROOTFS_DIR" \
    --output="$OUTPUT_DIR" \
    --ospart="$OS_PART_SIZE" \
    --datapart="$DATA_PART_SIZE" \
    --apppart="$APP_PART_SIZE" \
    --appdir="$APP_CONTENT_DIR"

echo ">>> [5/6] Returning artifacts to $(id -un)"
sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"

echo ">>> [6/6] VirtualBox import$([ "$EXPORT_OVA" = true ] && echo ' + OVA')"
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
echo "Open http://localhost:8000 -> Applications -> SBD configurator (direct: http://localhost:8008)."
if [ "$EXPORT_OVA" = true ]; then
    echo "OVA exported under ${OUTPUT_DIR} (see 04-convert-to-vbox.sh output above)."
fi
