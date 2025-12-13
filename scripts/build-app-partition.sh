#!/bin/bash
#
# build-app-partition.sh - Build APP partition content from packages.txt
#
# This script reads the new-format packages.txt and builds each application
# using CMake, outputting a staging directory ready for SquashFS conversion.
#
# This is separate from 02-build-packages.sh which handles hook-based
# packages that install directly into the rootfs.
#
# Usage:
#   sudo ./build-app-partition.sh --rootfs=/path/to/rootfs --packages=packages.txt
#
# Output:
#   Creates app-staging/app/ directory with:
#   - manifest.json (global app registry)
#   - startup.d/*.sh (startup scripts)
#   - shutdown.d/*.sh (shutdown scripts)
#   - <appname>/ (per-app directories with binaries, assets, configs)
#
set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source configuration and library
source "${PROJECT_ROOT}/config.sh"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/chroot-helper.sh"

# Command line arguments
ROOTFS_DIR=""
PACKAGES_FILE=""
APP_STAGING=""
VERSION=""
DEBUG_MODE=false

# Build directory (inside chroot)
BUILD_DIR="/tmp/app-build"

show_usage() {
    cat <<EOF
Build APP Partition Content

This script builds applications from packages.txt for the APP partition.
Output is a staging directory ready for SquashFS conversion.

Usage:
  sudo $0 --rootfs=DIR --packages=FILE [OPTIONS]

Required Arguments:
  --rootfs=DIR         Path to the Alpine rootfs directory (for chroot building)
  --packages=FILE      Path to packages.txt file (new format)

Optional Arguments:
  --output=DIR         Output staging directory (default: \$ROOTFS/../app-staging)
  --version=VERSION    Version string for global manifest (default: 1.0.0)
  --debug              Keep build artifacts on failure
  --help, -h           Show this help

Package File Format (packages.txt):
  # NAME|GIT_REPO|VERSION|CMAKE_OPTIONS|BUILD_DEPS|PORT|PRIORITY|TYPE|DESCRIPTION
  hello-world|file://\${PROJECT_ROOT}/apps/hello-world|HEAD||cmake|8002|20|webapp|Hello World Demo

Output Structure:
  app-staging/app/
  ├── manifest.json           # Global app registry
  ├── startup.d/
  │   └── 20-hello-world.sh   # Startup scripts (ordered by priority)
  ├── shutdown.d/
  │   └── 80-hello-world.sh   # Shutdown scripts (reverse priority)
  └── hello-world/
      ├── manifest.json       # Per-app manifest
      ├── bin/                # Executables
      ├── share/              # Static assets
      └── etc/                # Default configs

EOF
    exit 0
}

parse_arguments() {
    [ $# -eq 0 ] && show_usage

    for arg in "$@"; do
        case "$arg" in
            --rootfs=*)     ROOTFS_DIR="${arg#*=}" ;;
            --packages=*)   PACKAGES_FILE="${arg#*=}" ;;
            --output=*)     APP_STAGING="${arg#*=}" ;;
            --version=*)    VERSION="${arg#*=}" ;;
            --debug)        DEBUG_MODE=true ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg" ;;
        esac
    done

    # Validate required arguments
    [ -z "$ROOTFS_DIR" ] && error "Missing required argument: --rootfs"
    [ -z "$PACKAGES_FILE" ] && error "Missing required argument: --packages"

    # Convert to absolute paths
    ROOTFS_DIR="$(to_absolute_path "$ROOTFS_DIR")"
    PACKAGES_FILE="$(to_absolute_path "$PACKAGES_FILE")"

    # Set defaults
    if [ -z "$APP_STAGING" ]; then
        APP_STAGING="$(dirname "$ROOTFS_DIR")/app-staging"
    fi
    APP_STAGING="$(to_absolute_path "$APP_STAGING")"

    [ -z "$VERSION" ] && VERSION="1.0.0"

    # Validate inputs
    validate_dir "$ROOTFS_DIR" "Rootfs directory"
    validate_file "$PACKAGES_FILE" "Packages file"

    # Export for sub-processes
    export ROOTFS_DIR PACKAGES_FILE APP_STAGING VERSION DEBUG_MODE
    export PROJECT_ROOT SCRIPT_DIR
}

# Parse a line from packages.txt (new format with 9 fields)
# Sets PKG_* variables
parse_package_line() {
    local line="$1"

    # Reset variables
    PKG_NAME=""
    PKG_REPO=""
    PKG_VERSION=""
    PKG_CMAKE_OPTIONS=""
    PKG_BUILD_DEPS=""
    PKG_PORT=""
    PKG_PRIORITY=""
    PKG_TYPE=""
    PKG_DESCRIPTION=""

    # Parse pipe-separated fields
    IFS='|' read -r PKG_NAME PKG_REPO PKG_VERSION PKG_CMAKE_OPTIONS \
                   PKG_BUILD_DEPS PKG_PORT PKG_PRIORITY PKG_TYPE \
                   PKG_DESCRIPTION <<< "$line"

    # Expand variables in PKG_REPO (like ${SCRIPT_DIR})
    PKG_REPO=$(eval echo "$PKG_REPO")

    # Validate required fields
    [ -z "$PKG_NAME" ] && return 1
    [ -z "$PKG_REPO" ] && return 1

    # Set defaults
    [ -z "$PKG_VERSION" ] && PKG_VERSION="HEAD"
    [ -z "$PKG_PORT" ] && PKG_PORT="0"
    [ -z "$PKG_PRIORITY" ] && PKG_PRIORITY="50"
    [ -z "$PKG_TYPE" ] && PKG_TYPE="service"
    [ -z "$PKG_DESCRIPTION" ] && PKG_DESCRIPTION="$PKG_NAME"

    return 0
}

# Copy source to chroot build directory
fetch_source() {
    local name="$1"
    local repo="$2"
    local version="$3"
    local dest="${ROOTFS_DIR}${BUILD_DIR}/src-${name}"

    log "Fetching source for: $name"

    mkdir -p "$dest"

    if [[ "$repo" == file://* ]]; then
        # Local source - copy
        local src_path="${repo#file://}"
        if [ ! -d "$src_path" ]; then
            error "Local source not found: $src_path"
        fi
        cp -a "$src_path"/* "$dest/"
        info "Copied local source from: $src_path"
    else
        # Git repository - clone in chroot
        run_in_chroot "$ROOTFS_DIR" "
            apk add --quiet git 2>/dev/null || true
            git clone --depth 1 '$repo' '${BUILD_DIR}/src-${name}' 2>/dev/null || \
            git clone '$repo' '${BUILD_DIR}/src-${name}'
            if [ '$version' != 'HEAD' ]; then
                cd '${BUILD_DIR}/src-${name}'
                git checkout '$version' 2>/dev/null || true
            fi
        "
        info "Cloned from: $repo ($version)"
    fi
}

# Install build dependencies in chroot
install_build_deps() {
    local deps="$1"

    if [ -z "$deps" ]; then
        return 0
    fi

    log "Installing build dependencies: $deps"

    # Convert comma-separated to space-separated
    local dep_list="${deps//,/ }"

    # Install in chroot
    run_in_chroot "$ROOTFS_DIR" "apk add --virtual .app-build-deps $dep_list make gcc g++ musl-dev"
}

# Remove build dependencies from chroot
remove_build_deps() {
    log "Removing build dependencies..."
    run_in_chroot "$ROOTFS_DIR" "apk del .app-build-deps 2>/dev/null || true"
}

# Build a package using CMake in chroot
build_package() {
    local name="$1"
    local cmake_options="$2"
    local install_prefix="/app/${name}"

    log "Building package: $name"

    # Parse CMAKE_OPTIONS (comma to space)
    local cmake_opts=""
    if [ -n "$cmake_options" ]; then
        cmake_opts="${cmake_options//,/ }"
    fi

    # Build in chroot
    run_in_chroot "$ROOTFS_DIR" "
        cd '${BUILD_DIR}/src-${name}'
        mkdir -p _build
        cd _build
        cmake .. -DCMAKE_INSTALL_PREFIX='${install_prefix}' ${cmake_opts}
        make -j\$(nproc)
        make install DESTDIR='${BUILD_DIR}/install'
    "

    # Copy installed files to staging
    if [ -d "${ROOTFS_DIR}${BUILD_DIR}/install" ]; then
        cp -a "${ROOTFS_DIR}${BUILD_DIR}/install"/* "${APP_STAGING}/"
        rm -rf "${ROOTFS_DIR}${BUILD_DIR}/install"
    fi

    info "Built: $name -> ${APP_STAGING}/app/${name}"
}

# Generate startup script for an app
generate_startup_script() {
    local name="$1"
    local priority="$2"
    local port="$3"
    local script_path="${APP_STAGING}/app/startup.d/${priority}-${name}.sh"

    mkdir -p "$(dirname "$script_path")"

    cat > "$script_path" <<'STARTUP_EOF'
#!/bin/sh
# Startup script for APP_NAME_PLACEHOLDER
# Priority: APP_PRIORITY_PLACEHOLDER

APP_NAME="APP_NAME_PLACEHOLDER"
APP_DIR="/app/${APP_NAME}"
MANIFEST="${APP_DIR}/manifest.json"
PIDFILE="/run/app/${APP_NAME}.pid"
LOGFILE="/var/log/app/${APP_NAME}.log"

# Read command from manifest (if jq available) or use default
if command -v jq >/dev/null && [ -f "$MANIFEST" ]; then
    CMD=$(jq -r '.startup.command // empty' "$MANIFEST")
    ARGS=$(jq -r '.startup.args // [] | join(" ")' "$MANIFEST")
    WORKDIR=$(jq -r '.startup.working_dir // "/app/'"${APP_NAME}"'"' "$MANIFEST")
else
    # Try common executable names
    for bin in "${APP_DIR}/bin/${APP_NAME}-server" "${APP_DIR}/bin/${APP_NAME}" "${APP_DIR}/bin/app.py"; do
        if [ -x "$bin" ]; then
            CMD="$bin"
            break
        fi
    done
    ARGS=""
    WORKDIR="${APP_DIR}"
fi

if [ -z "$CMD" ]; then
    echo "No executable found for ${APP_NAME}" >&2
    exit 1
fi

# Setup environment
export APP_DATA_DIR="/data/app-data/${APP_NAME}"
export APP_CONFIG_DIR="/data/app-config/${APP_NAME}"
export APP_LOG_FILE="$LOGFILE"
export APP_STATIC_DIR="${APP_DIR}/share/www"

# Create directories
mkdir -p "$APP_DATA_DIR" "$APP_CONFIG_DIR" /run/app /var/log/app

# Copy default config if not exists
if [ -f "${APP_DIR}/etc/config.json.default" ] && [ ! -f "$APP_CONFIG_DIR/config.json" ]; then
    cp "${APP_DIR}/etc/config.json.default" "$APP_CONFIG_DIR/config.json"
    echo "Initialized default config for ${APP_NAME}"
fi

# Start application
cd "$WORKDIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting ${APP_NAME}..." >> "$LOGFILE"
$CMD $ARGS >> "$LOGFILE" 2>&1 &
PID=$!
echo $PID > "$PIDFILE"
echo "${APP_NAME} started (PID: $PID)"
STARTUP_EOF

    # Replace placeholders (only replace specific placeholder, not variable names)
    sed -i "s/APP_NAME_PLACEHOLDER/${name}/g" "$script_path"
    sed -i "s/APP_PRIORITY_PLACEHOLDER/${priority}/g" "$script_path"

    chmod +x "$script_path"
    info "Generated startup script: ${priority}-${name}.sh"
}

# Generate shutdown script for an app
generate_shutdown_script() {
    local name="$1"
    local priority="$2"
    # Shutdown scripts run in reverse order, so invert priority
    local shutdown_priority=$((100 - priority))
    local script_path="${APP_STAGING}/app/shutdown.d/${shutdown_priority}-${name}.sh"

    mkdir -p "$(dirname "$script_path")"

    cat > "$script_path" <<SHUTDOWN_EOF
#!/bin/sh
# Shutdown script for ${name}
# Priority: ${shutdown_priority} (inverted from startup priority ${priority})

APP_NAME="${name}"
PIDFILE="/run/app/\${APP_NAME}.pid"
LOGFILE="/var/log/app/\${APP_NAME}.log"
TIMEOUT=10

if [ ! -f "\$PIDFILE" ]; then
    echo "\${APP_NAME} not running (no PID file)"
    exit 0
fi

PID=\$(cat "\$PIDFILE")

if ! kill -0 "\$PID" 2>/dev/null; then
    echo "\${APP_NAME} not running (stale PID file)"
    rm -f "\$PIDFILE"
    exit 0
fi

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Stopping \${APP_NAME} (PID: \$PID)..." >> "\$LOGFILE"
echo "Stopping \${APP_NAME} (PID: \$PID)..."
kill -TERM "\$PID"

# Wait for graceful shutdown
count=0
while kill -0 "\$PID" 2>/dev/null && [ \$count -lt \$TIMEOUT ]; do
    sleep 1
    count=\$((count + 1))
done

# Force kill if still running
if kill -0 "\$PID" 2>/dev/null; then
    echo "\${APP_NAME} did not stop gracefully, sending SIGKILL..."
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Force killing \${APP_NAME}..." >> "\$LOGFILE"
    kill -KILL "\$PID" 2>/dev/null
    sleep 1
fi

rm -f "\$PIDFILE"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \${APP_NAME} stopped" >> "\$LOGFILE"
echo "\${APP_NAME} stopped"
SHUTDOWN_EOF

    chmod +x "$script_path"
    info "Generated shutdown script: ${shutdown_priority}-${name}.sh"
}

# Generate the global manifest.json
generate_global_manifest() {
    local manifest_path="${APP_STAGING}/app/manifest.json"

    log "Generating global manifest..."

    # Create apps array JSON with full info
    # Input format: app:port:type for each argument
    local apps_json="["
    local startup_json="["
    local first=true

    for app_info in "$@"; do
        # Parse app:port:type
        local app_name="${app_info%%:*}"
        local rest="${app_info#*:}"
        local app_port="${rest%%:*}"
        local app_type="${rest#*:}"

        if [ "$first" = true ]; then
            first=false
        else
            apps_json+=","
            startup_json+=","
        fi

        # Add app object with full details
        apps_json+="{\"name\":\"$app_name\",\"port\":$app_port,\"type\":\"$app_type\"}"
        startup_json+="\"$app_name\""
    done
    apps_json+="]"
    startup_json+="]"

    # Write manifest
    cat > "$manifest_path" <<EOF
{
  "version": "${VERSION}",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "build_host": "$(hostname)",
  "apps": ${apps_json},
  "startup_order": ${startup_json}
}
EOF

    info "Global manifest written: $manifest_path"
}

# Build all packages from packages.txt
build_all_packages() {
    log "Building packages from: $PACKAGES_FILE"

    # Create staging directories
    mkdir -p "${APP_STAGING}/app/startup.d"
    mkdir -p "${APP_STAGING}/app/shutdown.d"

    # Track built apps for manifest (sorted by priority)
    declare -A app_priorities
    declare -A app_ports
    declare -A app_types
    local app_list=()

    # Process each line in packages.txt
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse the line
        if ! parse_package_line "$line"; then
            warn "Skipping invalid line: $line"
            continue
        fi

        log "=========================================="
        log "Processing package: $PKG_NAME"
        log "  Repository: $PKG_REPO"
        log "  Version: $PKG_VERSION"
        log "  Port: $PKG_PORT"
        log "  Priority: $PKG_PRIORITY"
        log "  Type: $PKG_TYPE"
        log "=========================================="

        # Fetch source
        fetch_source "$PKG_NAME" "$PKG_REPO" "$PKG_VERSION"

        # Install build dependencies
        install_build_deps "$PKG_BUILD_DEPS"

        # Build the package
        build_package "$PKG_NAME" "$PKG_CMAKE_OPTIONS"

        # Remove build dependencies
        if [ -n "$PKG_BUILD_DEPS" ]; then
            remove_build_deps
        fi

        # Generate startup/shutdown scripts
        generate_startup_script "$PKG_NAME" "$PKG_PRIORITY" "$PKG_PORT"
        generate_shutdown_script "$PKG_NAME" "$PKG_PRIORITY"

        # Track for manifest
        app_list+=("$PKG_NAME")
        app_priorities["$PKG_NAME"]="$PKG_PRIORITY"
        app_ports["$PKG_NAME"]="$PKG_PORT"
        app_types["$PKG_NAME"]="$PKG_TYPE"

        # Cleanup source directory
        rm -rf "${ROOTFS_DIR}${BUILD_DIR}/src-${PKG_NAME}"

        log "Package $PKG_NAME built successfully"
        echo ""

    done < "$PACKAGES_FILE"

    # Sort app list by priority for startup order
    local sorted_apps=()
    for app in $(for k in "${!app_priorities[@]}"; do echo "${app_priorities[$k]}:$k"; done | sort -n | cut -d: -f2); do
        sorted_apps+=("$app")
    done

    # Generate global manifest with port and type info
    # Pass as: app:port:type for each app
    local app_info=()
    for app in "${sorted_apps[@]}"; do
        app_info+=("${app}:${app_ports[$app]}:${app_types[$app]}")
    done
    generate_global_manifest "${app_info[@]}"

    log "All packages built successfully"
    info "Staging directory: ${APP_STAGING}/app/"
}

# Cleanup function
cleanup() {
    if [ "${DEBUG_MODE}" != "true" ]; then
        log "Cleaning up..."
        rm -rf "${ROOTFS_DIR}${BUILD_DIR}" 2>/dev/null || true
    fi

    teardown_alpine_chroot "$ROOTFS_DIR" 2>/dev/null || true
}

# Main function
main() {
    parse_arguments "$@"

    # Check root
    check_root

    log "APP Partition Builder Starting..."

    show_config \
        "Rootfs" "$ROOTFS_DIR" \
        "Packages file" "$PACKAGES_FILE" \
        "Staging directory" "$APP_STAGING" \
        "Version" "$VERSION"

    # Check if packages file has any entries
    local entry_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        entry_count=$((entry_count + 1))
    done < "$PACKAGES_FILE"

    if [ "$entry_count" -eq 0 ]; then
        info "No packages to build in $PACKAGES_FILE"
        exit 0
    fi

    info "Found $entry_count package(s) to build"

    # Setup trap for cleanup
    trap cleanup EXIT

    # Prepare staging directory
    rm -rf "$APP_STAGING"
    mkdir -p "$APP_STAGING"

    # Create build directory in chroot
    mkdir -p "${ROOTFS_DIR}${BUILD_DIR}"

    # Setup chroot environment
    setup_alpine_chroot "$ROOTFS_DIR"

    # Build all packages
    build_all_packages

    log "=========================================="
    log "APP Partition Build Complete!"
    log "=========================================="
    info "Output: ${APP_STAGING}/app/"
    info ""
    info "To create SquashFS:"
    info "  mksquashfs ${APP_STAGING}/app app.squashfs -comp xz -b 256K"
    info ""
    info "Or use with 03-create-image.sh:"
    info "  sudo ./03-create-image.sh --appdir=${APP_STAGING}/app ..."
}

main "$@"
