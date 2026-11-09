#!/bin/sh
# Install disp-report-card (display_report_card.py): MCU-Tools' Display Measurements tab
# draws its gamut and white-point chart with it, from the same result layout the Pi's
# display tests write. Basic rendering only: Alpine's NumPy and Matplotlib with the Agg
# backend (colour-science, for the optional advanced chart, is not installed).
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}

[ -f "$SOURCE_DIR/src/display_report_card.py" ] && [ -f "$SOURCE_DIR/Makefile" ] || {
    echo "ERROR: disp-report-card source is incomplete: $SOURCE_DIR" >&2
    exit 1
}

# Runtime libraries stay in the image, unlike the hook's build dependencies.
apk add --no-cache py3-numpy py3-matplotlib
make -C "$SOURCE_DIR" install PREFIX=/usr PYTHON=/usr/bin/python3

# Render the bundled fixture once: proves the libraries load, and builds Matplotlib's
# font cache now instead of on the first measurement.
MPLCONFIGDIR=/var/cache/matplotlib /usr/bin/display-report-card \
    --input "$SOURCE_DIR/test-data/15-6-0od" --output /tmp/drc-smoke.png \
    --panels gamut,zoom_gamut --resolution 1920x800 >/dev/null
[ -s /tmp/drc-smoke.png ] || {
    echo "ERROR: display-report-card did not render its fixture" >&2
    exit 1
}
rm -f /tmp/drc-smoke.png
echo "disp-report-card installed: /usr/bin/display-report-card"
