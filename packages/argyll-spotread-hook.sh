#!/bin/sh
# Build ArgyllCMS spotread for the X-Rite i1 Display Pro (and the other instruments
# Argyll drives). Alpine has no ArgyllCMS package, so the pinned source is built
# here with FT-Jam, which Alpine lacks as well. Only spotread is installed.
#
# GCC 14 rejects the old C in jam and in Argyll's bundled zlib (implicit function
# declarations), so both are built with -fpermissive through a wrapper that is
# only on the PATH during this build. spotread links libX11 even for a reading.
set -eu

ARGYLL_VERSION=3.5.0
ARGYLL_URL="https://www.argyllcms.com/Argyll_V${ARGYLL_VERSION}_src.zip"
ARGYLL_SHA256=f8576ce5589fd15620abb73ff049ea31f55ddbd1bba6d1ffa87452658e7bc85f
FTJAM_URL="https://deb.debian.org/debian/pool/main/f/ftjam/ftjam_2.5.2.orig.tar.gz"
FTJAM_SHA256=a5d456f65477d77936e1726f5f803a2e6def18a6c6fccf5ea8528926c136abc8

BUILD_DIR=/tmp/argyll-build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/bin"
cd "$BUILD_DIR"

fetch() {
    wget -q -O "$2" "$1"
    echo "$3  $2" | sha256sum -c -
}
fetch "$ARGYLL_URL" argyll.zip "$ARGYLL_SHA256"
fetch "$FTJAM_URL" ftjam.tar.gz "$FTJAM_SHA256"

# Runtime library stays; the headers go with the build.
apk add --no-cache libx11
apk add --no-cache --virtual .argyll-build build-base linux-headers \
    libx11-dev libxext-dev libxxf86vm-dev libxinerama-dev libxrandr-dev \
    libxscrnsaver-dev libxau-dev libxdmcp-dev

printf '#!/bin/sh\nexec /usr/bin/gcc -fpermissive "$@"\n' > "$BUILD_DIR/bin/cc"
chmod +x "$BUILD_DIR/bin/cc"
export PATH="$BUILD_DIR/bin:$PATH"

# jam0 is FT-Jam's complete bootstrap build; its second stage ignores CFLAGS.
tar xzf ftjam.tar.gz
(cd ftjam-2.5.2 && ./configure >/dev/null && make jam0 CFLAGS="-O2 -fpermissive") > "$BUILD_DIR/jam.log" 2>&1 || {
    tail -40 "$BUILD_DIR/jam.log" >&2
    exit 1
}
install -m 0755 ftjam-2.5.2/jam0 "$BUILD_DIR/bin/jam"

unzip -q argyll.zip
cd "Argyll_V${ARGYLL_VERSION}"
# On Linux Argyll resets the i1 Display Pro when it closes it (i1d3.c: the HID driver
# otherwise keeps it from re-opening). The VM's emulated OHCI controller does not take
# that reset: the meter drops off the bus after one reading, and repeated resets have
# taken the whole controller down. ARGYLL_I1D3_NO_RESET=1 skips it; MCU-Tools sets it,
# and the meter re-opens without it (tested on the rig, 2026-11-09).
sed -i 's#^\tusbflags |= icomuf_reset_before_close;#\tif (getenv("ARGYLL_I1D3_NO_RESET") == NULL)\n\t\tusbflags |= icomuf_reset_before_close;#' \
    spectro/i1d3.c
grep -q 'ARGYLL_I1D3_NO_RESET' spectro/i1d3.c || {
    echo "ERROR: could not patch the i1d3 reset in spectro/i1d3.c" >&2
    exit 1
}
NUMBER_OF_PROCESSORS="$(nproc)" sh makeall.sh > "$BUILD_DIR/argyll.log" 2>&1 || {
    tail -40 "$BUILD_DIR/argyll.log" >&2
    exit 1
}
install -m 0755 -s spectro/spotread /usr/bin/spotread

# Argyll talks to the instrument through usbfs, so the device node needs the
# group the web apps run in, as the Bluebox rule does.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-argyll-colorimeter.rules <<'EOF'
# X-Rite i1 Display Pro / ColorMunki Display (i1d3): read with ArgyllCMS spotread.
SUBSYSTEM=="usb", ATTR{idVendor}=="0765", ATTR{idProduct}=="5020", MODE="0660", GROUP="plugdev"
EOF

cd /
apk del --no-cache .argyll-build
rm -rf "$BUILD_DIR"
# Not spotread -?: it scans for instruments first, which can wait without a device.
if ldd /usr/bin/spotread 2>&1 | grep -q -i -e "not found" -e "error"; then
    ldd /usr/bin/spotread >&2
    echo "ERROR: spotread is missing a shared library" >&2
    exit 1
fi
echo "spotread: ArgyllCMS ${ARGYLL_VERSION} installed"
