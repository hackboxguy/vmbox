#!/bin/sh
# setup-slcan.sh - Attach a serial-line CAN adapter (CANable 2.0 with its stock slcan
# firmware, 16d0:117e) as a SocketCAN interface when its ttyACM appears.
# Called by udev (99-can.rules): setup-slcan.sh ttyACM0
#
# slcand turns the tty into canN and leaves when the adapter is unplugged (hangup).
# The bit rate is one of the firmware's fixed rates (-s6 = 500 kbit/s); the sample
# point is the firmware's own, and there is no automatic bus-off restart.

[ -f /etc/conf.d/can ] && . /etc/conf.d/can

TTY="$1"
BITRATE="${CAN_BITRATE:-500000}"
TXQUEUELEN="${CAN_TXQUEUELEN-128}"
LOG_TAG="setup-slcan"

case "$BITRATE" in
    10000) SPEED=0 ;; 20000) SPEED=1 ;; 50000) SPEED=2 ;; 100000) SPEED=3 ;;
    125000) SPEED=4 ;; 250000) SPEED=5 ;; 500000) SPEED=6 ;; 800000) SPEED=7 ;;
    1000000) SPEED=8 ;;
    *) logger -t "$LOG_TAG" "Error: $BITRATE is not an slcan rate"; exit 1 ;;
esac

if [ -z "$TTY" ] || [ ! -c "/dev/$TTY" ]; then
    logger -t "$LOG_TAG" "Error: no tty /dev/$TTY"
    exit 1
fi

# The first free canN, so a second adapter does not take can0 from the first.
n=0
while [ -e "/sys/class/net/can$n" ]; do n=$((n + 1)); done
IFACE="can$n"

modprobe slcan 2>/dev/null || true
modprobe can_raw 2>/dev/null || true

# Daemonised, outside udev's event, which would otherwise end it.
if ! setsid slcand -o -c -s"$SPEED" "/dev/$TTY" "$IFACE" </dev/null >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "Error: slcand failed on /dev/$TTY"
    exit 1
fi

i=0
while [ ! -e "/sys/class/net/$IFACE" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "/sys/class/net/$IFACE" ]; then
    logger -t "$LOG_TAG" "Error: $IFACE did not appear for /dev/$TTY"
    exit 1
fi

# The kernel only learns the rate (and reports it) when it is set through ip, which
# needs the link down.
ip link set "$IFACE" down 2>/dev/null
ip link set "$IFACE" type can bitrate "$BITRATE" 2>&1 || logger -t "$LOG_TAG" "Warning: could not set $BITRATE on $IFACE"
[ -n "$TXQUEUELEN" ] && ip link set "$IFACE" txqueuelen "$TXQUEUELEN" 2>/dev/null
if ! ip link set "$IFACE" up 2>&1; then
    logger -t "$LOG_TAG" "Error: Failed to bring up $IFACE"
    exit 1
fi
logger -t "$LOG_TAG" "$IFACE configured on /dev/$TTY (slcan, $BITRATE bit/s)"
