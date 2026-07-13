#!/bin/sh
#
# jetson-flash.sh - flash an AGX Xavier (CTI Rogue) from inside the VMBOX appliance.
#
# Runs on the Alpine host side. Alpine is musl; NVIDIA's flash chain (tegrarcm, tegraflash,
# mkbootimg) is prebuilt glibc x86_64 and will not run on it. So we chroot into a minimal
# Ubuntu sandbox that ships on the APP partition, and run flash.sh in there.
#
# The payload on /app is a read-only SquashFS, but flash.sh writes into Linux_for_Tegra/
# (signed bootloader blobs, generated cfgs). Rather than copy several GB to /data, we
# overlay a writable upper from /data over the read-only tree: the big system.img stays
# compressed at rest in the SquashFS and is never copied, while flash.sh gets a tree it can
# write to. Keeps both the OVA and the running VM disk small.
#
set -e

APP=/app/dms-deploy
DATA=/data/jetson-flash
TARGET="${FLASH_TARGET:-cti/xavier/rogue/base}"
DEVICE="${FLASH_DEVICE:-mmcblk0p1}"

log() { echo "[jetson-flash] $*"; }
die() { echo "[jetson-flash] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$APP/Linux_for_Tegra" ] || die "$APP/Linux_for_Tegra missing (bad APP partition?)"
[ -d "$APP/ubuntu-chroot" ]   || die "$APP/ubuntu-chroot missing (bad APP partition?)"

# --- 1. Is the board actually in recovery mode? -------------------------------------
#
# ⚠ DETECT WITH lsusb ONLY. Never run tegrarcm/tegraflash as a "harmless" pre-flight check.
# The Tegra bootrom's RCM handshake is ONE-SHOT: the first RCM conversation after entering
# recovery consumes the session, and every later one fails ("Failed to read UID" /
# "Error: probing the target board failed") until the board is physically reset back into
# recovery. Even `tegrarcm_v2 --uid`, which merely reads an ID, burns it. lsusb only reads
# the USB descriptor and does not touch RCM, so it is safe.
#
# VID 0955 = NVIDIA APX. If this is empty the usual causes are: board not in recovery,
# the VirtualBox USB filter did not capture it, or the Extension Pack is missing on the host.
if ! lsusb | grep -qi '0955:'; then
    die "no Jetson in recovery mode (no USB VID 0955).
       - Put the board in recovery: hold FORCE_RECOVERY, tap RESET, release.
       - Check the VM captured it: the VirtualBox USB filter must match VID 0955.
       - USB 2/3 passthrough needs the VirtualBox Extension Pack on the HOST."
fi
log "Jetson detected in recovery mode:"
lsusb | grep -i '0955:' | sed 's/^/    /'

# --- 2. Writable overlays over the read-only payload --------------------------------
cleanup() {
    umount -l "$C/dev"  2>/dev/null || true
    umount -l "$C/sys"  2>/dev/null || true
    umount -l "$C/proc" 2>/dev/null || true
    umount -l "$C/mnt/lft" 2>/dev/null || true
    umount -l "$DATA/chroot/merged" 2>/dev/null || true
    umount -l "$DATA/lft/merged"    2>/dev/null || true
}
C="$DATA/chroot/merged"
trap cleanup EXIT

# A previous run may have left the upper dirs dirty; flash.sh must start from the pristine
# tree or it can reuse a half-written bootloader blob.
rm -rf "$DATA/lft/upper" "$DATA/lft/work" "$DATA/chroot/upper" "$DATA/chroot/work"
mkdir -p "$DATA/lft/upper" "$DATA/lft/work" "$DATA/lft/merged" \
         "$DATA/chroot/upper" "$DATA/chroot/work" "$DATA/chroot/merged"

log "Overlaying writable upper (on /data) over the read-only flash tree (on /app)"
mount -t overlay overlay \
    -o "lowerdir=$APP/Linux_for_Tegra,upperdir=$DATA/lft/upper,workdir=$DATA/lft/work" \
    "$DATA/lft/merged"
mount -t overlay overlay \
    -o "lowerdir=$APP/ubuntu-chroot,upperdir=$DATA/chroot/upper,workdir=$DATA/chroot/work" \
    "$C"

# --- 3. Enter the Ubuntu sandbox ----------------------------------------------------
mkdir -p "$C/mnt/lft"
mount --bind "$DATA/lft/merged" "$C/mnt/lft"
mount -t proc  proc "$C/proc"
mount -t sysfs sys  "$C/sys"
# --rbind (not --bind) so /dev/bus/usb comes along; tegrarcm talks to the board through it.
mount --rbind /dev  "$C/dev"

log "Flashing: ./flash.sh -r $TARGET $DEVICE   (expect ~10-30 min; the board reboots itself)"
log "-------------------------------------------------------------------------------"
# -r = reuse the prebuilt system.img instead of rebuilding it from a rootfs. The image is
# baked at build time, so nothing is generated on the customer's machine.
#
# USER=root: flash.sh gates on the $USER *environment variable* (flash.sh:1521), not on
# `id -u`. Inside a chroot that variable is unset, so without this it refuses to run with
# "flash.sh requires root privilege" even though we are uid 0.
#
# SKIP_REC_IMG=1: do not regenerate the recovery ramdisk. Regenerating it copies dozens of
# files OUT of Linux_for_Tegra/rootfs/ (wpa_supplicant scripts, wifi firmware, parted,
# diff...), and we ship no rootfs -- it is 6+ GB and the whole point of flashing with -r is
# that the image is prebuilt. So we bake recovery.img at BUILD time (where the full rootfs
# exists) and reuse it here, exactly as we do with system.img. Without this, flash.sh dies
# after the board probe with L4T's opaque "command is failed".
chroot "$C" /usr/bin/env USER=root HOME=/root SKIP_REC_IMG=1 /bin/bash -c \
    "cd /mnt/lft && ./flash.sh -r '$TARGET' '$DEVICE'"
rc=$?
log "-------------------------------------------------------------------------------"
[ $rc -eq 0 ] || die "flash.sh failed (exit $rc)"
log "FLASH OK"
