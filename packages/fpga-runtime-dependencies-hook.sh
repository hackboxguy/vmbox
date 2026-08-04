#!/bin/sh
# Install runtime libraries shared by the future FPGA programming backends.
#
# Backend-specific compiler headers remain in the individual package hook so
# they are removed after the build. Do not install OpenFPGALoader from Alpine
# edge here: the FPGA backend installs a pinned, reviewed source revision.
set -eu

apk add --no-cache \
    libusb-compat \
    libftdi1 \
    libgpiod \
    libstdc++
