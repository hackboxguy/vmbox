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
USB_MODE_EXPLICIT=false
VM_NAME=""
CLEAN=false
EXPORT_OVA=true
START_VM=false
DRY_RUN=false
FPGA_QUALIFICATION=false

PACKAGES_FILE="${SCRIPT_DIR}/packages-generic-flasher.txt"
SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-generic-flasher-system.txt"
APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-generic-flasher.txt"
FPGA_USB_FILTER_FILE="${SOURCE_ROOT}/sp6bins/firmware/fpga/usb-filters.txt"
FPGA_WEBAPP_REVISION="3f1ee46c6dd97592e09d0a0c09ae497f4db09ab3"
SP6BINS_REVISION="de53575eace17d8ce0b300fbd8771130eb5ee5f6"
XC3SPROG_REVISION="1392bc420db9c5d9506ee93c2fca802cadb69b9f"
FXLOAD_REVISION="af574c391c70b3445fb141503a7c54db99508069"
OPENFPGALOADER_REVISION="1fc75395385ae7f3d31bfdd6cba0467e0afb4d25"

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
  --dry-run          Print dependency/bootstrap and build plan without making changes
  --fpga-qualification
                     Build the pinned FPGA-only Gate-3a VM; excludes unrelated
                     RH850 and Web Terminal sources and applications.
  --no-ova           Register the VM but do not export an OVA
  --start            Start the registered VM headlessly after the build
  --help, -h         Show this help

Private source layout beside vmbox/:
  fpga-flasher-webapp/  rh850-flash-tools/  sp6bins/  xc3sprog/  web-terminal/

Missing sibling repositories are cloned from their configured private GitHub
origins before the build. The RH850 webapp submodule is initialized as needed.
Run with --dry-run first to inspect these actions without changing the checkout.

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
        --usb=*) USB_MODE="${arg#*=}"; USB_MODE_EXPLICIT=true ;;
        --clean) CLEAN=true ;;
        --dry-run) DRY_RUN=true ;;
        --fpga-qualification) FPGA_QUALIFICATION=true ;;
        --no-ova) EXPORT_OVA=false ;;
        --start) START_VM=true ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# FPGA JTAG adapters such as the Arty Z7's FT2232 are high-speed devices.
# Qualification images default to EHCI, but an explicit caller choice is kept.
if [ "$FPGA_QUALIFICATION" = true ] && [ "$USB_MODE_EXPLICIT" = false ]; then
    USB_MODE="2"
fi

case "$USB_MODE" in 1|2|3) ;; *) echo "ERROR: --usb must be 1, 2, or 3" >&2; exit 2 ;; esac
[ -n "$VM_NAME" ] || VM_NAME="generic-flasher-v${VERSION}"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

# These are intentionally explicit: the flasher appliance is private and must
# only fetch its reviewed source repositories from the organisation's origins.
declare -A PRIVATE_SOURCE_URLS=(
    [rh850-flash-tools]="https://github.com/hackboxguy/rh850-flash-tools.git"
    [sp6bins]="https://github.com/hackboxguy/sp6bins.git"
    [xc3sprog]="https://github.com/hackboxguy/xc3sprog.git"
    [web-terminal]="https://github.com/hackboxguy/web-terminal.git"
)
PRIVATE_SOURCE_DIRS=(rh850-flash-tools sp6bins xc3sprog web-terminal)
RH850_WEBAPP_SUBMODULE="apps/rh850-flasher-webapp"

if [ "$FPGA_QUALIFICATION" = true ]; then
    PACKAGES_FILE="${SCRIPT_DIR}/packages-fpga-qualification.txt"
    SYSTEM_RUNTIME_PACKAGES_FILE="${SCRIPT_DIR}/packages-fpga-qualification-system.txt"
    APP_SYSTEM_PACKAGES_FILE="${SCRIPT_DIR}/system-packages-fpga-qualification.txt"
    PRIVATE_SOURCE_DIRS=(sp6bins xc3sprog)
fi

source_revision() {
    local source_path="$1"
    git -C "$source_path" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

expected_webapp_revision() {
    git -C "$SCRIPT_DIR" ls-tree HEAD -- "$RH850_WEBAPP_SUBMODULE" 2>/dev/null | awk '{print $3}'
}

print_build_plan() {
    local source_dir source_path parent_dir available_mb expected_revision current_revision fpga_catalogue enabled_profiles

    echo "=================================================="
    echo " Generic Flasher VMBOX dry run"
    echo " version : ${VERSION}"
    echo " vm name : ${VM_NAME}"
    echo " output  : ${OUTPUT_DIR}"
    echo " parts   : os=${OS_PART_SIZE} data=${DATA_PART_SIZE} app=${APP_PART_SIZE}"
    echo " usb     : ${USB_MODE}.0"
    echo "=================================================="
    echo "Dependency bootstrap:"
    for source_dir in "${PRIVATE_SOURCE_DIRS[@]}"; do
        source_path="${SOURCE_ROOT}/${source_dir}"
        if [ -d "$source_path" ]; then
            echo "  present: ${source_path} ($(source_revision "$source_path"))"
        elif [ -e "$source_path" ]; then
            echo "  ERROR: ${source_path} exists but is not a directory"
        else
            echo "  would clone: ${PRIVATE_SOURCE_URLS[$source_dir]} -> ${source_path}"
        fi
    done

    if [ "$FPGA_QUALIFICATION" = false ]; then
        source_path="${SCRIPT_DIR}/${RH850_WEBAPP_SUBMODULE}"
        expected_revision="$(expected_webapp_revision)"
        current_revision="$(git -C "$source_path" rev-parse HEAD 2>/dev/null || true)"
        if [ -f "${source_path}/CMakeLists.txt" ] && [ -n "$expected_revision" ] && [ "$current_revision" = "$expected_revision" ]; then
            echo "  present: ${source_path} ($(source_revision "$source_path"))"
        elif [ -f "${source_path}/CMakeLists.txt" ] && [ -n "$expected_revision" ]; then
            echo "  would update submodule: ${RH850_WEBAPP_SUBMODULE} (${current_revision:-unknown} -> ${expected_revision})"
        else
            echo "  would initialize submodule: ${RH850_WEBAPP_SUBMODULE}"
        fi
    else
        echo "  FPGA-only qualification mode: RH850 and Web Terminal sources are not required"
    fi

    source_path="${SOURCE_ROOT}/fpga-flasher-webapp"
    if [ -f "${source_path}/CMakeLists.txt" ]; then
        echo "  present: ${source_path} ($(source_revision "$source_path"), expected ${FPGA_WEBAPP_REVISION:0:7})"
    else
        echo "  ERROR: required FPGA webapp source is missing: ${source_path}"
    fi

    source_path="${SOURCE_ROOT}/openFPGALoader"
    if [ -f "${source_path}/CMakeLists.txt" ]; then
        echo "  present: ${source_path} ($(source_revision "$source_path"), expected ${OPENFPGALOADER_REVISION:0:7})"
    else
        echo "  ERROR: required pinned OpenFPGALoader source is missing: ${source_path}"
    fi
    source_path="${SOURCE_ROOT}/fxload"
    if [ -f "${source_path}/CMakeLists.txt" ] && [ -f "${source_path}/CLI11/LICENSE" ]; then
        echo "  present: ${source_path} ($(source_revision "$source_path"), expected ${FXLOAD_REVISION:0:7})"
    else
        echo "  ERROR: required pinned FXLoad source is missing or incomplete: ${source_path}"
    fi

    fpga_catalogue="${SOURCE_ROOT}/sp6bins/firmware/fpga/catalog.json"
    if [ -f "$fpga_catalogue" ]; then
        echo "FPGA profiles: private catalogue present (${fpga_catalogue})"
        if command -v jq >/dev/null 2>&1; then
            enabled_profiles="$(jq -r '.profiles[] | select(.enabled == true) | .id' "$fpga_catalogue" 2>/dev/null || true)"
            [ -n "$enabled_profiles" ] && echo "FPGA enabled profiles: ${enabled_profiles//$'\n'/, }" || echo "FPGA enabled profiles: none (hardware qualification pending)"
        fi
    else
        echo "FPGA profiles: Phase-1 fixture mode only (no private hardware catalogue)"
    fi
    if [ -f "$FPGA_USB_FILTER_FILE" ]; then
        echo "FPGA USB filters: exact profile-generated filters present (${FPGA_USB_FILTER_FILE})"
    else
        echo "FPGA USB filters: no hardware profiles enabled"
    fi

    if command -v VBoxManage >/dev/null 2>&1; then
        echo "VirtualBox: available ($(VBoxManage --version 2>/dev/null || printf unknown))"
    else
        echo "VirtualBox: MISSING (required for a real build)"
    fi

    parent_dir="$OUTPUT_DIR"
    while [ ! -d "$parent_dir" ] && [ "$parent_dir" != / ]; do
        parent_dir="$(dirname "$parent_dir")"
    done
    available_mb="$(df -BM "$parent_dir" | awk 'NR == 2 { sub(/M$/, "", $4); print $4 }')"
    echo "Disk: ${available_mb:-unknown} MB free below ${parent_dir} (6144 MB required)"
    [ "$CLEAN" = true ] && echo "Cleanup: would remove ${OUTPUT_DIR} before building"
    [ "$EXPORT_OVA" = true ] && echo "Export: would create an OVA" || echo "Export: VM registration only (--no-ova)"
    [ "$START_VM" = true ] && echo "Start: would start ${VM_NAME} headlessly"
    echo "No files, repositories, VM registrations, or VirtualBox settings were changed."
}

bootstrap_private_sources() {
    local source_dir source_path source_url

    command -v git >/dev/null 2>&1 || {
        echo "ERROR: git is required to fetch private build sources." >&2
        exit 1
    }

    for source_dir in "${PRIVATE_SOURCE_DIRS[@]}"; do
        source_path="${SOURCE_ROOT}/${source_dir}"
        source_url="${PRIVATE_SOURCE_URLS[$source_dir]}"
        if [ -d "$source_path" ]; then
            echo ">>> Using private source: ${source_path} ($(source_revision "$source_path"))"
            continue
        fi
        [ ! -e "$source_path" ] || {
            echo "ERROR: required source path exists but is not a directory: ${source_path}" >&2
            exit 1
        }

        echo ">>> Cloning private source: ${source_url}"
        git clone --recurse-submodules --branch main "$source_url" "$source_path" || {
            echo "ERROR: could not clone ${source_dir}. Ensure your GitHub credentials can access the private repository." >&2
            exit 1
        }
    done
}

bootstrap_rh850_webapp_submodule() {
    local source_path="${SCRIPT_DIR}/${RH850_WEBAPP_SUBMODULE}"
    local expected_revision current_revision

    command -v git >/dev/null 2>&1 || {
        echo "ERROR: git is required to initialize ${RH850_WEBAPP_SUBMODULE}." >&2
        exit 1
    }
    expected_revision="$(expected_webapp_revision)"
    [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || {
        echo "ERROR: ${RH850_WEBAPP_SUBMODULE} is not a valid pinned submodule in this VMBOX checkout." >&2
        exit 1
    }
    current_revision="$(git -C "$source_path" rev-parse HEAD 2>/dev/null || true)"
    if [ -f "${source_path}/CMakeLists.txt" ] && [ "$current_revision" = "$expected_revision" ]; then
        echo ">>> Using private webapp submodule: ${RH850_WEBAPP_SUBMODULE} ($(source_revision "$source_path"))"
        return 0
    fi

    echo ">>> Synchronizing private webapp submodule: ${RH850_WEBAPP_SUBMODULE} (${current_revision:-uninitialized} -> ${expected_revision})"
    git -C "$SCRIPT_DIR" submodule update --init --recursive -- "$RH850_WEBAPP_SUBMODULE" || {
        echo "ERROR: could not synchronize ${RH850_WEBAPP_SUBMODULE}. Ensure your GitHub credentials can access the private repository and the checkout has no conflicting local changes." >&2
        exit 1
    }
    current_revision="$(git -C "$source_path" rev-parse HEAD 2>/dev/null || true)"
    [ -f "${source_path}/CMakeLists.txt" ] && [ "$current_revision" = "$expected_revision" ] || {
        echo "ERROR: RH850 webapp submodule did not reach its pinned revision: ${expected_revision}" >&2
        exit 1
    }
}

validate_build_inputs() {
    local input
    local inputs=(
        "${PACKAGES_FILE}" \
        "${SYSTEM_RUNTIME_PACKAGES_FILE}" \
        "${APP_SYSTEM_PACKAGES_FILE}"
    )
    if [ "$FPGA_QUALIFICATION" = false ]; then
        inputs+=(
            "${SOURCE_ROOT}/sp6bins/firmware/catalog.json"
            "${SOURCE_ROOT}/sp6bins/tools/install_rh850_firmware_catalog.py"
            "${SCRIPT_DIR}/apps/rh850-flasher-webapp/CMakeLists.txt"
            "${SOURCE_ROOT}/web-terminal/CMakeLists.txt"
        )
    fi
    for input in "${inputs[@]}"; do
        [ -f "$input" ] || { echo "ERROR: required build input is missing: $input" >&2; exit 1; }
    done

    validate_fpga_build_inputs
}

validate_fpga_build_inputs() {
    local input
    for input in \
        "${SOURCE_ROOT}/sp6bins/tools/install_fpga_flasher_inputs.py" \
        "${SOURCE_ROOT}/sp6bins/firmware/fpga/catalog.json" \
        "${SOURCE_ROOT}/sp6bins/firmware/fpga/approved-artifacts.json" \
        "${SOURCE_ROOT}/sp6bins/firmware/fpga/runtime-config.json" \
        "${SOURCE_ROOT}/sp6bins/firmware/fpga/usb-filters.txt" \
        "${SOURCE_ROOT}/xc3sprog/CMakeLists.txt" \
        "${SOURCE_ROOT}/openFPGALoader/CMakeLists.txt" \
        "${SOURCE_ROOT}/fxload/CMakeLists.txt" \
        "${SOURCE_ROOT}/fxload/CLI11/LICENSE" \
        "${SOURCE_ROOT}/sp6bins/src/scripts/fpga-openfpgaloader-artyz7-backend.sh" \
        "${SOURCE_ROOT}/fpga-flasher-webapp/CMakeLists.txt"; do
        [ -f "$input" ] || { echo "ERROR: required FPGA build input is missing: $input" >&2; exit 1; }
    done

    validate_pinned_source "${SOURCE_ROOT}/fpga-flasher-webapp" "$FPGA_WEBAPP_REVISION"
    validate_pinned_source "${SOURCE_ROOT}/sp6bins" "$SP6BINS_REVISION"
    validate_pinned_source "${SOURCE_ROOT}/xc3sprog" "$XC3SPROG_REVISION"
    validate_pinned_source "${SOURCE_ROOT}/openFPGALoader" "$OPENFPGALOADER_REVISION"
    validate_pinned_source "${SOURCE_ROOT}/fxload" "$FXLOAD_REVISION"
}

validate_pinned_source() {
    local source_path="$1" expected_revision="$2" actual_revision
    actual_revision="$(git -C "$source_path" rev-parse HEAD 2>/dev/null || true)"
    [ "$actual_revision" = "$expected_revision" ] || {
        echo "ERROR: source is not at the reviewed revision: ${source_path} (have ${actual_revision:-unknown}, expected ${expected_revision})" >&2
        exit 1
    }
    [ -z "$(git -C "$source_path" status --porcelain)" ] || {
        echo "ERROR: source has uncommitted changes: ${source_path}" >&2
        exit 1
    }
}

if [ "$DRY_RUN" = true ]; then
    print_build_plan
    validate_fpga_build_inputs
    exit 0
fi

[ "$(id -u)" -ne 0 ] || {
    echo "ERROR: run this builder as a normal user, not root." >&2
    exit 1
}

bootstrap_private_sources
[ "$FPGA_QUALIFICATION" = true ] || bootstrap_rh850_webapp_submodule
validate_build_inputs
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
    --force
)
[ "$FPGA_QUALIFICATION" = true ] || convert_args+=(--rh850-bluebox)
[ -f "$FPGA_USB_FILTER_FILE" ] && convert_args+=(--usb-filter-file="$FPGA_USB_FILTER_FILE")
[ "$FPGA_QUALIFICATION" = true ] && convert_args+=(--exact-usb-filters-only)
[ "$EXPORT_OVA" = true ] && convert_args+=(--export-ova)
"${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh" "${convert_args[@]}"

if [ "$START_VM" = true ]; then
    echo ">>> Starting ${VM_NAME}"
    VBoxManage startvm "$VM_NAME" --type headless
fi

if [ "$FPGA_QUALIFICATION" = true ]; then
    echo "Done. Open http://localhost:8000 and launch FPGA Configuration Flasher from Applications."
else
    echo "Done. Open http://localhost:8000 and launch RH850 Flasher from Applications."
fi
