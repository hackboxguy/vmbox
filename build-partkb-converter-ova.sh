#!/bin/bash
#
# build-partkb-converter-ova.sh - One-command partkb converter VMBOX OVA builder (partkb VM plan §7, §8).
#
# Pipeline: base rootfs -> runtime packages (python3, py3-pymupdf, py3-httpx, py3-yaml, py3-jsonschema, git,
# sqlite) -> app partition (partkb at the tag pinned in packages-partkb-converter.txt) -> disk image -> VirtualBox VM
# (+ OVA). A copy of build-sbd-configurator-ova.sh with the converter's differences:
#   - hostname partkb-converter (the dashboard login cookie becomes session-partkb-converter, so it does not collide
#     with a configurator VM reached on the same host);
#   - data partition 16 GB in a dynamically allocated VDI (the raw image is sparse; the VDI grows with use);
#   - no direct app port: the web UI listens on 127.0.0.1:8009 and is reached only through the dashboard proxy
#     (/app/partkb-converter/), so 04-convert-to-vbox.sh gets no --appdir and forwards no app port;
#   - 2 vCPU, 2 GB RAM.
#
# State 2026-10-25: partkb has no CMake install yet and the pinned tag partkb-0.3.0 does not exist (the partkb
# session's web-app step 5). --skip-tag-check runs steps 1-2 and stops at the app step with that error.
#
# The app comes from the git submodule apps/partkb (private repo: clone vmbox with --recursive, or run
# git submodule update --init apps/partkb apps/text-to-block).
#
# Usage (run as a NORMAL user; it calls sudo internally where needed):
#   ./build-partkb-converter-ova.sh --version=0.1.0 --clean
#   ./build-partkb-converter-ova.sh --version=0.1.0 --dry-run
#
# After boot: dashboard http://localhost:8000 -> Applications -> partkb converter (proxied at /app/partkb-converter/).
# Data: /data/app-data/partkb-converter/ (store, data, library, packages, jobs); key and settings in
# /data/app-config/partkb-converter/ (cleared by factory reset).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"

VERSION="0.1.0"
OUTPUT_DIR="/tmp/partkb-converter-vmbox-build"
PACKAGES_FILE="${SCRIPT_DIR}/packages-partkb-converter.txt"
SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-partkb-converter-system.txt"
APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-partkb-converter.txt"
OS_PART_SIZE="700M"
DATA_PART_SIZE="16384M"
APP_PART_SIZE="300M"
VM_MEMORY_MB="2048"
VM_CPUS="2"
SKIP_TAG_CHECK=false
VM_NAME=""
CLEAN=false
EXPORT_OVA=true
START_VM=false
DRY_RUN=false

show_usage() {
    cat <<EOF
partkb converter VMBOX OVA builder

Usage: $0 [OPTIONS]

  --version=VER     Image version (default: ${VERSION}); the app version is the pinned partkb tag
  --output=DIR      Build artifact dir (default: ${OUTPUT_DIR})
  --packages=FILE   App package list (default: packages-partkb-converter.txt)
  --ospart=SIZE     OS partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE   Data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE    App partition size (default: ${APP_PART_SIZE})
  --vmname=NAME     VirtualBox VM name (default: vmbox-partkb-converter-v<version>)
  --clean           Remove the output dir before building (fresh build)
  --dry-run         Print the plan and the checks, change nothing
  --no-ova          Register the VM but skip OVA export
  --start           Start the VM headless after building
  --skip-tag-check  Do not stop at the pre-flight when the pinned tag is missing (the app step then fails)
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
        --dry-run)     DRY_RUN=true ;;
        --no-ova)      EXPORT_OVA=false ;;
        --start)       START_VM=true ;;
        --skip-tag-check) SKIP_TAG_CHECK=true ;;
        --help|-h)     show_usage ;;
        *)             echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
    esac
done

[ -n "$VM_NAME" ] || VM_NAME="vmbox-partkb-converter-v${VERSION}"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
APP_OUT_DIR="${OUTPUT_DIR}/app"
APP_CONTENT_DIR="${APP_OUT_DIR}/app"            # build-app-partition writes <out>/app
RAW_IMAGE="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"

# ---- Pre-flight checks -------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "run this as a normal user, not root (it calls sudo; VirtualBox VMs are per-user)."
for f in "$PACKAGES_FILE" "$SYSTEM_RUNTIME_PACKAGES_FILE" "$APP_SYSTEM_PACKAGES_FILE" \
         "${SCRIPT_DIR}/packages/partkb-runtime-dependencies-hook.sh"; do
    [ -f "$f" ] || fail "missing: $f"
done

app_line="$(grep -v '^[[:space:]]*#' "$PACKAGES_FILE" | grep -m1 '^partkb-converter|' || true)"
[ -n "$app_line" ] || fail "no partkb-converter line in $PACKAGES_FILE"
APP_REPO="$(echo "$app_line" | cut -d'|' -f2)"
APP_TAG="$(echo "$app_line" | cut -d'|' -f3)"
PROJECT_ROOT="$SCRIPT_DIR"
APP_REPO="$(eval echo "$APP_REPO")"   # file://${PROJECT_ROOT}/apps/partkb (git submodule)
if [[ "$APP_REPO" == file://* ]] && [ ! -e "${APP_REPO#file://}/.git" ]; then
    fail "${APP_REPO#file://} is empty: clone vmbox with --recursive, or run: git submodule update --init apps/partkb"
fi
[ -e "${SCRIPT_DIR}/apps/text-to-block/.git" ] || \
    fail "apps/text-to-block is empty (partkb installs its schema / validator): git submodule update --init apps/text-to-block"

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
echo "  partkb converter OVA build$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
echo "  version : ${VERSION}"
echo "  app     : ${APP_REPO} @ ${APP_TAG}"
echo "  vm name : ${VM_NAME}"
echo "  output  : ${OUTPUT_DIR}"
echo "  parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} (dynamic VDI) app=${APP_PART_SIZE}"
echo "  vm      : ${VM_CPUS} vCPU, ${VM_MEMORY_MB} MB; forwards: dashboard 8000, ssh, web terminal (no app port)"
echo "=================================================="

if [ "$DRY_RUN" = true ]; then
    echo "Checks:"
    check_tag || true
    command -v VBoxManage >/dev/null 2>&1 && echo "  VBoxManage found" || echo "  WARNING: VBoxManage not found"
    echo "Plan:"
    echo "  1 sudo build.sh --mode=base (hostname partkb-converter)"
    echo "  2 sudo scripts/02-build-packages.sh --packages=$(basename "$SYSTEM_RUNTIME_PACKAGES_FILE")"
    echo "  3 sudo scripts/build-app-partition.sh --packages=$(basename "$PACKAGES_FILE")"
    echo "  4 sudo scripts/03-create-image.sh"
    echo "  5 chown, 6 scripts/04-convert-to-vbox.sh$([ "$EXPORT_OVA" = true ] && echo ' --export-ova')"
    exit 0
fi

if ! check_tag; then
    [ "$SKIP_TAG_CHECK" = true ] || fail "the pinned tag is not on the remote (--skip-tag-check builds up to the app step)"
    echo "  --skip-tag-check: continuing; the app step will fail on the missing tag"
fi
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
    --hostname=partkb-converter

echo ">>> [2/6] Runtime packages (python3, py3-pymupdf, py3-httpx, py3-yaml, py3-jsonschema, git, sqlite)"
sudo "${SCRIPT_DIR}/scripts/02-build-packages.sh" \
    --rootfs="$ROOTFS_DIR" \
    --packages="$SYSTEM_RUNTIME_PACKAGES_FILE" \
    --version="$VERSION"

echo ">>> [3/6] App partition (partkb-converter @ ${APP_TAG})"
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
    --memory="$VM_MEMORY_MB"
    --cpus="$VM_CPUS"
    --force                                       # no --appdir: no direct port forward for 8009 (VM plan §7.4)
)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)
"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

if [ "$START_VM" = true ]; then
    echo ">>> Starting ${VM_NAME} (headless)"
    VBoxManage startvm "$VM_NAME" --type headless
fi

echo ""
echo "Done. VM '${VM_NAME}' registered."
echo "Open http://localhost:8000 -> Applications -> partkb converter (no direct port; through the dashboard only)."
if [ "$EXPORT_OVA" = true ]; then
    echo "OVA exported under ${OUTPUT_DIR} (see 04-convert-to-vbox.sh output above)."
fi
