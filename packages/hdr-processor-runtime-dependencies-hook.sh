#!/bin/sh
# Runtime of the HDR processor appliance (sdr-hdr-shootout-demo web-app, prompt v4 §5): Python with numpy and Flask,
# ffmpeg (zscale = libzimg, haldclut, libx264, libx265: the generator exits 3 without them) and hdr10plus_tool.
#
# The SDR modes (sdr-today, sdr-managed: the generator's libplacebo chain) need a Vulkan device; the VM has no GPU,
# so Mesa's lavapipe (mesa-vulkan-swrast) renders on the CPU. Alpine 3.21's ffmpeg 6.1 libplacebo filter finds "no
# suitable device" on its own and works on ffmpeg's Vulkan device (-init_hw_device vulkan; the generator's
# libplacebo_args() picks that). Measured 2026-10-26 in alpine:3.21 with 8 CPUs: ~1.8 fps at 1920x1080.
#
# hdr10plus_tool is not packaged in Alpine: the upstream release's x86_64-unknown-linux-musl build, pinned by version
# and SHA-256, installed to /usr/local/bin.
# Verified 2026-10-26 in alpine:3.21: ffmpeg 6.1.2 (libzimg 3), numpy 2.1.3, Flask 3.0.3, hdr10plus_tool 1.7.2; the
# generator renders a Peru excerpt there with the same per-scene decisions as on the PC (ffmpeg 9.0).
set -eu

HDR10PLUS_TOOL_VERSION=1.7.2
HDR10PLUS_TOOL_SHA256=06385f37a639d61ba21d4be3150c863846933bc3b58110e094d8fc8f1c2249f2
HDR10PLUS_TOOL_URL="https://github.com/quietvoid/hdr10plus_tool/releases/download/${HDR10PLUS_TOOL_VERSION}/hdr10plus_tool-${HDR10PLUS_TOOL_VERSION}-x86_64-unknown-linux-musl.tar.gz"

apk add --no-cache \
    python3 \
    py3-numpy \
    py3-flask \
    ffmpeg \
    mesa-vulkan-swrast

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wget -q -O "${tmp}/h10.tar.gz" "$HDR10PLUS_TOOL_URL"
echo "${HDR10PLUS_TOOL_SHA256}  ${tmp}/h10.tar.gz" | sha256sum -c -
tar xzf "${tmp}/h10.tar.gz" -C "$tmp"
install -m 0755 "${tmp}/hdr10plus_tool" /usr/local/bin/hdr10plus_tool
# the build chroot's PATH has no /usr/local/bin, and the generator finds the tool by PATH (shutil.which)
ln -sf /usr/local/bin/hdr10plus_tool /usr/bin/hdr10plus_tool

# Build-time assertions: everything the generator needs must be there and run under musl
fail() { echo "ERROR: $*" >&2; exit 1; }
filters="$(ffmpeg -hide_banner -filters 2>/dev/null)"
encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
for f in zscale haldclut; do
    echo "$filters" | grep -qE "^ [^ ]+ ${f} " || fail "Alpine's ffmpeg has no ${f} filter"
done
for e in libx264 libx265; do
    echo "$encoders" | grep -qE "^ [^ ]+ ${e} " || fail "Alpine's ffmpeg has no ${e} encoder"
done
ffv="$(ffmpeg -version | head -1 | sed -n 's/^ffmpeg version n\{0,1\}\([0-9]*\).*/\1/p')"
[ "${ffv:-0}" -ge 6 ] || fail "ffmpeg ${ffv} < 6 (zscale options as the generator uses them)"
echo "$filters" | grep -qE "^ [^ ]+ libplacebo " || fail "Alpine's ffmpeg has no libplacebo filter (the SDR modes)"
ffmpeg -v error -init_hw_device vulkan=vk -filter_hw_device vk -f lavfi -i testsrc2=s=64x64:d=0.1 \
    -vf libplacebo=format=yuv420p -frames:v 1 -f null - || fail "libplacebo does not render on lavapipe"
/usr/bin/hdr10plus_tool --version | grep -q "hdr10plus_tool ${HDR10PLUS_TOOL_VERSION}" || fail "hdr10plus_tool does not run"
python3 - <<'PY'
import flask, numpy
from importlib.metadata import version
print("hdr-processor runtime ok: numpy", numpy.__version__, "flask", version("flask"))
PY
echo "ffmpeg: $(ffmpeg -version | head -1)"
echo "hdr10plus_tool: $(/usr/bin/hdr10plus_tool --version)"
