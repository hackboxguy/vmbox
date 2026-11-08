#!/bin/sh
# setup-can.sh - Auto-configure CAN interface when adapter is plugged in
# Called by udev rule when CAN interface is created
#
# Usage: setup-can.sh <interface>
# Example: setup-can.sh can0

# Source config file if it exists
[ -f /etc/conf.d/can ] && . /etc/conf.d/can

INTERFACE="$1"
BITRATE="${CAN_BITRATE:-500000}"  # Default 500kbps, override via config or environment
SAMPLE_POINT="${CAN_SAMPLE_POINT-0.8}"
RESTART_MS="${CAN_RESTART_MS-100}"
TXQUEUELEN="${CAN_TXQUEUELEN-128}"
LOG_TAG="setup-can"

# Validate interface name
if [ -z "$INTERFACE" ]; then
    logger -t "$LOG_TAG" "Error: No interface specified"
    exit 1
fi

# Check if interface exists
if [ ! -d "/sys/class/net/$INTERFACE" ]; then
    logger -t "$LOG_TAG" "Error: Interface $INTERFACE does not exist"
    exit 1
fi

# Check if it's actually a CAN interface
if [ ! -f "/sys/class/net/$INTERFACE/type" ]; then
    logger -t "$LOG_TAG" "Error: Cannot determine interface type for $INTERFACE"
    exit 1
fi

IFTYPE=$(cat "/sys/class/net/$INTERFACE/type")
if [ "$IFTYPE" != "280" ]; then
    logger -t "$LOG_TAG" "Error: $INTERFACE is not a CAN interface (type=$IFTYPE)"
    exit 1
fi

# Small delay to ensure hardware is fully initialized
sleep 1

# Ensure can_raw module is loaded (needed for candump/cansend)
modprobe can_raw 2>/dev/null || true

# Configure bitrate
TIMING="bitrate $BITRATE"
[ -n "$SAMPLE_POINT" ] && TIMING="$TIMING sample-point $SAMPLE_POINT"
logger -t "$LOG_TAG" "Configuring $INTERFACE: $TIMING${RESTART_MS:+ restart-ms $RESTART_MS}"

# shellcheck disable=SC2086
if ! ip link set "$INTERFACE" type can $TIMING 2>&1; then
    logger -t "$LOG_TAG" "Error: Failed to set bitrate on $INTERFACE"
    exit 1
fi

# Separate, since some adapters (gs_usb / candleLight) refuse it and one refused
# option fails the whole command.
if [ -n "$RESTART_MS" ] && ! ip link set "$INTERFACE" type can restart-ms "$RESTART_MS" 2>/dev/null; then
    logger -t "$LOG_TAG" "Note: $INTERFACE has no automatic bus-off restart; take it down and up after a bus-off"
fi

if [ -n "$TXQUEUELEN" ] && ! ip link set "$INTERFACE" txqueuelen "$TXQUEUELEN" 2>&1; then
    logger -t "$LOG_TAG" "Warning: could not set txqueuelen $TXQUEUELEN on $INTERFACE"
fi

# Bring interface up
if ! ip link set "$INTERFACE" up 2>&1; then
    logger -t "$LOG_TAG" "Error: Failed to bring up $INTERFACE"
    exit 1
fi

logger -t "$LOG_TAG" "$INTERFACE configured successfully ($TIMING)"
