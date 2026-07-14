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

# --- 3b. Make flash.sh wait for the board to come back after it reboots it -------------
#
# flash.sh talks to the board TWICE: it reads the board EEPROM first (Board ID/FAB/SKU), and
# that probe ends with `tegrarcm_v2 --reboot recovery` -- the board resets, drops off USB, and
# re-enumerates. flash.sh then spends ~17 s generating blobs and starts the real flash pass,
# assuming the board is back.
#
# It usually is, on a Linux host. On a WINDOWS host VirtualBox takes longer to re-capture the
# device, so the flash pass finds no bootrom, and tegrarcm_v2 blocks forever on a dead USB
# handle ("BootRom is not running"). The device DOES come back -- the UI's board detector goes
# green again afterwards -- so this is a race, not a detection failure. 17 s is simply not
# enough of a margin on Windows.
#
# So: patch the vendor script, in the writable overlay (never the shipped read-only tree), to
# block until the board is actually back on USB before the flash pass runs. flash.sh:3427
# `eval "${flashcmd}"` is that pass.
# Anchor on the banner line that immediately precedes the REAL flash pass (flash.sh:3436-3437).
# There are two `eval "${flashcmd}"` sites -- the other is the --to-sign branch, which we never
# take -- so anchoring on the eval itself would patch both.
ANCHOR='echo "\*\*\* Flashing target device started\. \*\*\*"'
F="$DATA/lft/merged/flash.sh"
grep -qE "^${ANCHOR}$" "$F" || die "flash.sh: cannot find the flash-start banner -- L4T version changed?"
cat > "$DATA/lft/merged/wait-for-rcm.sh" <<'WAIT'
# Wait for the Jetson to re-appear on USB after flash.sh's probe rebooted it into recovery.
# sysfs, not lsusb: the Ubuntu sandbox is a debootstrap minbase and has no usbutils. (And it
# must never be tegrarcm -- the RCM handshake is one-shot; probing it would burn the session.)
_wait_for_rcm() {
    local i=0
    while [ "$i" -lt 180 ]; do
        if grep -qs '0955' /sys/bus/usb/devices/*/idVendor 2>/dev/null; then
            [ "$i" -gt 0 ] && echo "[jetson-flash] board is back on USB after ${i}s"
            sleep 3          # let enumeration settle before tegrarcm opens it
            return 0
        fi
        [ "$i" = 0 ] && echo "[jetson-flash] waiting for the board to re-appear on USB after its reboot..."
        sleep 1
        i=$((i + 1))
    done
    echo "[jetson-flash] the board never came back on USB after its reboot (waited 180s)." >&2
    echo "[jetson-flash] VirtualBox did not re-capture it. Power-cycle the board back into" >&2
    echo "[jetson-flash] recovery mode, and connect it directly rather than through a hub." >&2
    return 1
}
_wait_for_rcm || exit 1
WAIT
# Source by ABSOLUTE path: by this point flash.sh has cd'd into bootloader/, and /mnt/lft is
# where the tree is bind-mounted inside the sandbox.
sed -i "s|^${ANCHOR}$|&\n. /mnt/lft/wait-for-rcm.sh|" "$F"
grep -q 'wait-for-rcm.sh' "$F" || die "failed to patch flash.sh with the USB re-attach wait"
log "flash.sh patched: it will wait for the board to re-appear on USB before the flash pass"

log "Flashing: ./flash.sh -r $TARGET $DEVICE   (expect ~10-50 min; the board reboots itself)"
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
