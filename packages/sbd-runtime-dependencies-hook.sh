#!/bin/sh
# Runtime of the SBD configurator (text-to-block): Python imaging, the Liberation fonts the diagrams are laid out
# with, and resvg for PNG export.
#
# resvg is not in Alpine stable (edge/testing only), so the pinned upstream release binary is installed and checked
# against its SHA-256. It is linked against glibc (libc, libm, libgcc_s only): gcompat + libgcc run it. Verified in
# alpine:3.21. When the download or the checksum fails the image still builds: the app then serves SVG only and
# answers 503 for PNG (its /health reports backend "none").
set -eu

apk add --no-cache \
    python3 \
    py3-yaml \
    py3-pillow \
    font-liberation \
    gcompat \
    libgcc

RESVG_VERSION="0.48.1"
RESVG_SHA256="fa8c26495a187e592c501db15bf9e8a9fdc051d4b2b336b39703d5b59f912b9d"
RESVG_URL="https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz"

tmp="$(mktemp -d)"
if curl -fsSL --retry 3 -o "${tmp}/resvg.tar.gz" "$RESVG_URL" \
        && echo "${RESVG_SHA256}  ${tmp}/resvg.tar.gz" | sha256sum -c - >/dev/null \
        && tar -xzf "${tmp}/resvg.tar.gz" -C "$tmp" resvg; then
    install -m 0755 "${tmp}/resvg" /usr/local/bin/resvg
    /usr/local/bin/resvg --version
else
    echo "WARNING: resvg ${RESVG_VERSION} not installed (download or checksum failed); SBD configurator: SVG only" >&2
fi
rm -rf "$tmp"
