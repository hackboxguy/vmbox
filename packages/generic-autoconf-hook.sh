#!/bin/sh
#
# generic-autoconf-hook.sh - Build autoconf-based packages from source
#
# This script builds packages that use the standard autoconf build system
# (configure/make/make install). It supports tarball and git sources.
#
# Environment variables (set by caller):
#   HOOK_NAME           - Package name (for logging)
#   HOOK_SOURCE         - Source URL (tarball or git)
#   HOOK_VERSION        - Version string
#   HOOK_BUILD_OPTIONS  - Configure options (space-separated)
#   HOOK_INSTALL_PREFIX - Installation prefix (default: /usr)
#
# The package is installed to the specified prefix (default /usr).
#
set -e

echo "======================================"
echo "  Generic Autoconf Build Hook"
echo "======================================"
echo ""

# Get parameters from environment
NAME="${HOOK_NAME:-unknown}"
SOURCE="${HOOK_SOURCE:-}"
VERSION="${HOOK_VERSION:-unknown}"
BUILD_OPTIONS="${HOOK_BUILD_OPTIONS:-}"
INSTALL_PREFIX="${HOOK_INSTALL_PREFIX:-/usr}"

# Validate required variables
if [ -z "$SOURCE" ]; then
    echo "ERROR: HOOK_SOURCE not set"
    exit 1
fi

echo "Package: $NAME"
echo "Source:  $SOURCE"
echo "Version: $VERSION"
echo "Options: $BUILD_OPTIONS"
echo "Prefix:  $INSTALL_PREFIX"
echo ""

# Step 1: Get source code
echo "[1/4] Obtaining source code..."
cd /tmp

# Detect source type and fetch accordingly
# Check file:// FIRST (before extension checks) since local files can have any extension
if echo "$SOURCE" | grep -q '^file://'; then
    # Local file or directory
    LOCAL_PATH="${SOURCE#file://}"
    echo "Using local source: $LOCAL_PATH"

    if [ ! -e "$LOCAL_PATH" ]; then
        echo "ERROR: Local source not found: $LOCAL_PATH"
        exit 1
    fi

    if [ -f "$LOCAL_PATH" ]; then
        # It's a file - determine compression from extension
        case "$LOCAL_PATH" in
            *.tar.gz)  DECOMPRESS="z" ;;
            *.tar.bz2) DECOMPRESS="j" ;;
            *.tar.xz)  DECOMPRESS="J" ;;
            *)         DECOMPRESS="a" ;;  # auto-detect
        esac
        mkdir -p "${NAME}-build"
        tar x${DECOMPRESS}f "$LOCAL_PATH" -C "${NAME}-build" --strip-components=1
    else
        # It's a directory - copy it
        cp -a "$LOCAL_PATH" "${NAME}-build"
    fi
    cd "${NAME}-build"

elif echo "$SOURCE" | grep -qE '\.tar\.(gz|bz2|xz)$'; then
    # Remote tarball source
    echo "Downloading tarball: $SOURCE"

    # Determine compression type
    case "$SOURCE" in
        *.tar.gz)  DECOMPRESS="z" ;;
        *.tar.bz2) DECOMPRESS="j" ;;
        *.tar.xz)  DECOMPRESS="J" ;;
        *)         DECOMPRESS="a" ;;  # auto-detect
    esac

    wget -q "$SOURCE" -O "${NAME}-source.tar"
    mkdir -p "${NAME}-build"
    tar x${DECOMPRESS}f "${NAME}-source.tar" -C "${NAME}-build" --strip-components=1
    rm -f "${NAME}-source.tar"
    cd "${NAME}-build"

elif echo "$SOURCE" | grep -qE '\.git$'; then
    # Git repository
    echo "Cloning git repository: $SOURCE"
    git clone --depth=1 "$SOURCE" "${NAME}-build"
    cd "${NAME}-build"
    if [ "$VERSION" != "HEAD" ] && [ -n "$VERSION" ]; then
        git checkout "$VERSION" 2>/dev/null || true
    fi

else
    echo "ERROR: Unknown source format: $SOURCE"
    echo "Supported: .tar.gz, .tar.bz2, .tar.xz, .git, file://"
    exit 1
fi

# Step 2: Configure
echo ""
echo "[2/4] Configuring..."

# Build configure command with options
CONFIGURE_CMD="./configure --prefix=${INSTALL_PREFIX}"
if [ -n "$BUILD_OPTIONS" ]; then
    CONFIGURE_CMD="$CONFIGURE_CMD $BUILD_OPTIONS"
fi

echo "Running: $CONFIGURE_CMD"
LOG_FILE="/tmp/${NAME}-configure.log"
if ! eval "$CONFIGURE_CMD" > "$LOG_FILE" 2>&1; then
    echo "Configure FAILED! Last 50 lines of output:"
    tail -50 "$LOG_FILE"
    rm -f "$LOG_FILE"
    exit 1
fi
echo "Configure completed. Summary:"
tail -10 "$LOG_FILE"
rm -f "$LOG_FILE"

# Step 3: Build
echo ""
echo "[3/4] Building..."
NPROC=$(nproc 2>/dev/null || echo 1)
LOG_FILE="/tmp/${NAME}-build.log"
if ! make -j"$NPROC" > "$LOG_FILE" 2>&1; then
    echo "Build FAILED! Last 50 lines of output:"
    tail -50 "$LOG_FILE"
    rm -f "$LOG_FILE"
    exit 1
fi
echo "Build completed."
rm -f "$LOG_FILE"

# Step 4: Install
echo ""
echo "[4/4] Installing to ${INSTALL_PREFIX}..."
LOG_FILE="/tmp/${NAME}-install.log"
if ! make install > "$LOG_FILE" 2>&1; then
    echo "Install FAILED! Last 50 lines of output:"
    tail -50 "$LOG_FILE"
    rm -f "$LOG_FILE"
    exit 1
fi
echo "Install completed."
rm -f "$LOG_FILE"

# Verify installation
echo ""
echo "Verifying installation..."
if [ -d "${INSTALL_PREFIX}/lib" ]; then
    echo "Libraries installed:"
    ls -la "${INSTALL_PREFIX}/lib/"lib${NAME}* 2>/dev/null | head -5 || echo "  (none found with name prefix)"
fi
if [ -d "${INSTALL_PREFIX}/include" ]; then
    HEADER_COUNT=$(find "${INSTALL_PREFIX}/include" -name "*.h" -newer /tmp/${NAME}-build 2>/dev/null | wc -l)
    echo "Headers: ${HEADER_COUNT} files installed"
fi

# Cleanup
echo ""
echo "Cleaning up..."
cd /
rm -rf "/tmp/${NAME}-build"

echo ""
echo "======================================"
echo "  ${NAME} ${VERSION} Build Complete"
echo "======================================"
echo "Installed to: ${INSTALL_PREFIX}"
echo ""
