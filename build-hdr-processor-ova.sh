#!/bin/bash
#
# build-hdr-processor-ova.sh - One-command HDR processor VMBOX OVA builder (sdr-hdr-shootout-demo prompt v4 §5).
#
# Pipeline: base rootfs -> runtime packages (python3, py3-numpy, py3-flask, ffmpeg, hdr10plus_tool) -> app partition
# (the web app of sdr-hdr-shootout-demo at the tag pinned in packages-hdr-processor.txt, with the generator and the
# profile creator from its tools/) -> disk image (DATA seeded with the master clip) -> VirtualBox VM (+ OVA).
# A copy of build-partkb-converter-ova.sh with the HDR processor's differences:
#   - hostname hdr-processor (dashboard cookie session-hdr-processor-<version>);
#   - data partition 32 GB in a dynamically allocated VDI: masters (Peru 1.4 GB), jobs (a full clip ~0.5 GB plus
#     the work files during a render);
#   - the master clip seeded into /data/app-data/hdr-processor/masters/ (--master, default ../tmp-docs/peru-hdr10+.mp4
#     when present; --no-master: an empty Masters list, the Upload tab is the way in);
#   - no direct app port: the web UI listens on 127.0.0.1:8011, reached only through the dashboard proxy
#     (/app/hdr-processor/);
#   - 8 vCPU, 8 GB RAM (the generator's LUT workers and the x264 / x265 render);
#   - its own NAT host ports: dashboard 8020, web terminal 8023, SSH 2224 (guest 8000 / 8003 / 22), next to the
#     configurator (8000 / 8003 / 2222) and the converter (8010 / 8013 / 2223).
#
# The app comes from the git submodule apps/sdr-hdr-shootout-demo (git submodule update --init apps/sdr-hdr-shootout-demo;
# the pinned tag must be in that checkout).
#
# Usage (run as a NORMAL user; it calls sudo internally where needed):
#   ./build-hdr-processor-ova.sh --version=0.1.0 --clean
#   ./build-hdr-processor-ova.sh --version=0.1.0 --dry-run
#
# After boot: dashboard http://localhost:8020 -> Applications -> HDR processor (proxied at /app/hdr-processor/).
# Data: /data/app-data/hdr-processor/ (masters, jobs, uploads); config /data/app-config/hdr-processor/config.json.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"

VERSION="0.1.0"
OUTPUT_DIR=""                 # default: ${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/hdr-processor-<version>
ALLOW_TMPFS=false
PACKAGES_FILE="${SCRIPT_DIR}/packages-hdr-processor.txt"
SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-hdr-processor-system.txt"
APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-hdr-processor.txt"
OS_PART_SIZE="1200M"          # ffmpeg with its libraries (~230 MB installed) on top of the base
DATA_PART_SIZE="32768M"
APP_PART_SIZE="300M"
VM_MEMORY_MB="8192"
VM_CPUS="8"
HOST_DASHBOARD_PORT="8020"    # NAT host ports (guest 8000 / 8003 / 22); see the 04-convert-to-vbox.sh call
HOST_WEBTERMINAL_PORT="8023"
HOST_SSH_PORT="2224"
MASTER="${SCRIPT_DIR}/../tmp-docs/peru-hdr10+.mp4"   # seeded master (only if present; --master / --no-master)
MASTER_NAME=""                # its name on the VM (default: the file name, '+' -> 'plus')
SKIP_TAG_CHECK=false
VM_NAME=""
REPLACE_VM=false
CLEAN=false
EXPORT_OVA=true
START_VM=false
DRY_RUN=false

show_usage() {
    cat <<EOF
HDR processor VMBOX OVA builder

Usage: $0 [OPTIONS]

  --version=VER     Image version (default: ${VERSION}); the app version is the pinned sdr-hdr-shootout-demo tag
  --output=DIR      Build artifact dir (default: \${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/hdr-processor-<version>);
                    it also holds the VM's disk, so it must not be on tmpfs (/tmp): a reboot would lose the VM
  --allow-tmpfs     Allow an --output on tmpfs anyway (a throw-away test build)
  --packages=FILE   App package list (default: packages-hdr-processor.txt)
  --master=PATH     Master clip seeded into /data/app-data/hdr-processor/masters/ (default: ../tmp-docs/peru-hdr10+.mp4
                    when present)
  --master-name=N   Its file name on the VM (default: the file name with '+' as 'plus')
  --no-master       Seed nothing: the Masters list starts empty
  --ospart=SIZE     OS partition size (default: ${OS_PART_SIZE})
  --datapart=SIZE   Data partition size (default: ${DATA_PART_SIZE})
  --apppart=SIZE    App partition size (default: ${APP_PART_SIZE})
  --vmname=NAME     VirtualBox VM name (default: vmbox-hdr-processor-v<version>)
  --clean           Remove the output dir before building (fresh build)
  --dry-run         Print the plan and the checks, change nothing
  --no-ova          Register the VM but skip OVA export
  --replace-vm      Build even if a registered VM of this name or with its disk in --output exists (it is deleted)
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
        --allow-tmpfs) ALLOW_TMPFS=true ;;
        --packages=*)  PACKAGES_FILE="${arg#*=}" ;;
        --master=*)    MASTER="${arg#*=}"; MASTER_GIVEN=true ;;
        --master-name=*) MASTER_NAME="${arg#*=}" ;;
        --no-master)   MASTER="" ;;
        --ospart=*)    OS_PART_SIZE="${arg#*=}" ;;
        --datapart=*)  DATA_PART_SIZE="${arg#*=}" ;;
        --apppart=*)   APP_PART_SIZE="${arg#*=}" ;;
        --vmname=*)    VM_NAME="${arg#*=}" ;;
        --clean)       CLEAN=true ;;
        --dry-run)     DRY_RUN=true ;;
        --no-ova)      EXPORT_OVA=false ;;
        --replace-vm)  REPLACE_VM=true ;;
        --start)       START_VM=true ;;
        --skip-tag-check) SKIP_TAG_CHECK=true ;;
        --help|-h)     show_usage ;;
        *)             echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
    esac
done

[ -n "$VM_NAME" ] || VM_NAME="vmbox-hdr-processor-v${VERSION}"
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="${VMBOX_BUILD_ROOT:-/home/adav/extended-disk/vmbox-build}/hdr-processor-${VERSION}"
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

# A build re-creates the VM (04-convert-to-vbox.sh --force: unregister + delete its disk) and --clean deletes the
# output dir. A registered VM of this name, or one running from a disk in the output dir, would go with it: maybe
# the owner's, with the only copy of its data (the production converter 0.3.1 runs from its build dir). Refuse.
if command -v VBoxManage >/dev/null 2>&1 && [ "$REPLACE_VM" != true ]; then
    while IFS= read -r vm_line; do
        vm="${vm_line#\"}"; vm="${vm%\" \{*}"
        vm_disks="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null | sed -n 's/^"[^"]*-[0-9]*-[0-9]*"="\(\/[^"]*\)"$/\1/p')"
        if [ "$vm" = "$VM_NAME" ] || grep -qF "${OUTPUT_DIR%/}/" <<<"$vm_disks"; then
            fail "VM '${vm}' is registered (disk: ${vm_disks:-none}); this build would delete it. A test VM: VBoxManage unregistervm '${vm}' --delete, then build again. Another --vmname / --output, or --replace-vm to build over it anyway."
        fi
    done < <(VBoxManage list vms 2>/dev/null)
fi

[ "$(id -u)" -ne 0 ] || fail "run this as a normal user, not root (it calls sudo; VirtualBox VMs are per-user)."
for f in "$PACKAGES_FILE" "$SYSTEM_RUNTIME_PACKAGES_FILE" "$APP_SYSTEM_PACKAGES_FILE" \
         "${SCRIPT_DIR}/packages/hdr-processor-runtime-dependencies-hook.sh"; do
    [ -f "$f" ] || fail "missing: $f"
done

app_line="$(grep -v '^[[:space:]]*#' "$PACKAGES_FILE" | grep -m1 '^hdr-processor|' || true)"
[ -n "$app_line" ] || fail "no hdr-processor line in $PACKAGES_FILE"
APP_REPO="$(echo "$app_line" | cut -d'|' -f2)"
APP_TAG="$(echo "$app_line" | cut -d'|' -f3)"
PROJECT_ROOT="$SCRIPT_DIR"
APP_REPO="$(eval echo "$APP_REPO")"   # file://${PROJECT_ROOT}/apps/sdr-hdr-shootout-demo (git submodule)
if [[ "$APP_REPO" == file://* ]] && [ ! -e "${APP_REPO#file://}/.git" ]; then
    fail "${APP_REPO#file://} is empty: clone vmbox with --recursive, or run: git submodule update --init apps/sdr-hdr-shootout-demo"
fi
if [ -n "$MASTER" ]; then
    if [ ! -f "$MASTER" ]; then
        [ "${MASTER_GIVEN:-false}" = true ] && fail "--master ${MASTER} not found"
        echo "NOTE: no master at ${MASTER}: the VM starts with an empty Masters list (upload one there)" >&2
        MASTER=""
    fi
fi
if [ -n "$MASTER" ]; then
    MASTER="$(realpath "$MASTER")"
    [ -n "$MASTER_NAME" ] || MASTER_NAME="$(basename "$MASTER" | sed 's/+/plus/g')"
    case "$MASTER_NAME" in *[!A-Za-z0-9._-]*|.*|'') fail "--master-name ${MASTER_NAME}: use [A-Za-z0-9._-]";; esac
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
echo "  HDR processor OVA build$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
echo "  version : ${VERSION}"
echo "  app     : ${APP_REPO} @ ${APP_TAG}"
echo "  vm name : ${VM_NAME}"
echo "  output  : ${OUTPUT_DIR}"
echo "  parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} (dynamic VDI) app=${APP_PART_SIZE}"
echo "  vm      : ${VM_CPUS} vCPU, ${VM_MEMORY_MB} MB; forwards: dashboard ${HOST_DASHBOARD_PORT}->8000, web terminal ${HOST_WEBTERMINAL_PORT}->8003, ssh ${HOST_SSH_PORT}->22 (no app port)"
echo "  master  : ${MASTER:-none}${MASTER:+ -> /data/app-data/hdr-processor/masters/${MASTER_NAME} ($(du -h "$MASTER" | cut -f1))}"
echo "=================================================="

if [ "$DRY_RUN" = true ]; then
    echo "Checks:"
    check_tag || true
    command -v VBoxManage >/dev/null 2>&1 && echo "  VBoxManage found" || echo "  WARNING: VBoxManage not found"
    echo "Plan:"
    echo "  1 sudo build.sh --mode=base (hostname hdr-processor)"
    echo "  2 sudo scripts/02-build-packages.sh --packages=$(basename "$SYSTEM_RUNTIME_PACKAGES_FILE")"
    echo "  3 sudo scripts/build-app-partition.sh --packages=$(basename "$PACKAGES_FILE")"
    echo "  4 sudo scripts/03-create-image.sh${MASTER:+ --dataseed (the master)}"
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
[ "${avail_mb:-0}" -ge 12288 ] || fail "need >=12 GB free in ${OUTPUT_DIR} (raw image, VDI and OVA each carry the master; have ${avail_mb}MB)."

cd "$SCRIPT_DIR"

echo ">>> [1/6] Base root filesystem"
sudo "${SCRIPT_DIR}/build.sh" \
    --mode=base \
    --output="$OUTPUT_DIR" \
    --version="$VERSION" \
    --hostname=hdr-processor

echo ">>> [2/6] Runtime packages (python3, py3-numpy, py3-flask, ffmpeg, hdr10plus_tool)"
sudo "${SCRIPT_DIR}/scripts/02-build-packages.sh" \
    --rootfs="$ROOTFS_DIR" \
    --packages="$SYSTEM_RUNTIME_PACKAGES_FILE" \
    --version="$VERSION"

echo ">>> [3/6] App partition (hdr-processor @ ${APP_TAG})"
sudo "${SCRIPT_DIR}/scripts/build-app-partition.sh" \
    --rootfs="$ROOTFS_DIR" \
    --packages="$PACKAGES_FILE" \
    --system-packages="$APP_SYSTEM_PACKAGES_FILE" \
    --output="$APP_OUT_DIR" \
    --version="$VERSION"

echo ">>> [4/6] Disk image"
seed_args=()
if [ -n "$MASTER" ]; then
    # a symlink: 03-create-image.sh --dataseed follows it (the 1.4 GB file is copied once, into the image)
    SEED_DIR="${OUTPUT_DIR}/dataseed"
    rm -rf "$SEED_DIR"
    mkdir -p "${SEED_DIR}/app-data/hdr-processor/masters"
    ln -s "$MASTER" "${SEED_DIR}/app-data/hdr-processor/masters/${MASTER_NAME}"
    seed_args=(--dataseed="$SEED_DIR")
fi
sudo "${SCRIPT_DIR}/scripts/03-create-image.sh" \
    --rootfs="$ROOTFS_DIR" \
    --output="$OUTPUT_DIR" \
    --ospart="$OS_PART_SIZE" \
    --datapart="$DATA_PART_SIZE" \
    --apppart="$APP_PART_SIZE" \
    --appdir="$APP_CONTENT_DIR" \
    "${seed_args[@]}"

echo ">>> [5/6] Returning artifacts to $(id -un)"
sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"

echo ">>> [6/6] VirtualBox import$([ "$EXPORT_OVA" = true ] && echo ' + OVA')"
convert_args=(
    --input="$RAW_IMAGE"
    --vmname="$VM_NAME"
    --memory="$VM_MEMORY_MB"
    --cpus="$VM_CPUS"
    --force                                       # no --appdir: no direct port forward for 8011
    # Own host ports: coexists with the configurator (8000 / 8008 / 8003 / 2222) and the converter (8010 / 8013 /
    # 2223) on the same host. Guest ports stay 8000 / 8003 / 22.
    --sysmgmt-port="${HOST_DASHBOARD_PORT}"
    --webterminal-port="${HOST_WEBTERMINAL_PORT}"
    --ssh-port="${HOST_SSH_PORT}"
)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)
"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

if [ "$START_VM" = true ]; then
    echo ">>> Starting ${VM_NAME} (headless)"
    VBoxManage startvm "$VM_NAME" --type headless
fi

echo ""
echo "Done. VM '${VM_NAME}' registered."
echo "Open http://localhost:${HOST_DASHBOARD_PORT} -> Applications -> HDR processor (no direct port; through the dashboard only)."
if [ "$EXPORT_OVA" = true ]; then
    echo "OVA exported under ${OUTPUT_DIR} (see 04-convert-to-vbox.sh output above)."
fi
