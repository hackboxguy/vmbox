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

# --- 3b. Stop flash.sh from rebooting the board mid-flash ------------------------------
#
# THE bug that made every flash from a Windows host fail.
#
# flash.sh talks to the board TWICE. First it reads the board EEPROM (Board ID/FAB/SKU/rev),
# and that probe ends with `tegrarcm_v2 --reboot recovery`: the board RESETS, drops off USB and
# re-enumerates. Then flash.sh builds its blobs and starts the real flash pass, assuming the
# board came back.
#
# On a Linux host VirtualBox re-captures the reset device and all is well. On WINDOWS it does
# not propagate the disconnect: the guest keeps a STALE handle on the old device. `lsusb` still
# lists VID 0955 -- so the board looks present, and even the UI's detector goes green -- but
# every USB transfer to it is dead. tegrarcm_v2 then blocks forever ("BootRom is not running").
# Waiting for the device does not help: it never "comes back", because as far as the guest is
# concerned it never left.
#
# So do not let the board reboot at all. flash.sh only probes because it does not know the
# board identity -- and it takes that identity from the environment if we supply it:
#   FUSELEVEL set  => skips get_fuse_level   (flash.sh:1615)
#   FAB      set  => skips get_board_version (flash.sh:1684)
# with no probe, there is no reset, no re-enumeration, and the whole flash runs in ONE
# continuous USB session -- which Windows handles fine (its probe pass did bootrom -> applet ->
# MB2 applet flawlessly before rebooting itself into oblivion).
#
# One thing is in the way: flash.sh hard-assigns `hwchipid=""` (line 1605) and then bails with
# "Error: probing the target board failed" (exit 14) if it is still empty. So patch that single
# line to honour HWCHIPID -- in the writable overlay, never the shipped read-only tree.
#
# VERIFIED, and this is the part that must not be taken on trust: with these values preset and
# NO board attached, flash.sh emits a flash command byte-identical (md5 d7e1b0e6...) to the one
# generated by a real probed flash. Same BCT, pinmux, PMIC, DTB. A wrong board spec here would
# feed the board someone else's pinmux, so "it booted" is not good enough -- it is diffed.
F="$DATA/lft/merged/flash.sh"
grep -q '^hwchipid="";$' "$F" || die "flash.sh: cannot find the hwchipid assignment -- L4T version changed?"
sed -i 's|^hwchipid="";$|hwchipid="${HWCHIPID:-}";|' "$F"
grep -q 'HWCHIPID' "$F" || die "failed to patch flash.sh to accept a preset chip id"

# The board's identity, as read by a real EEPROM probe on this hardware:
#   Board ID(2888) version(400) sku(0004) revision(M.0)
# The appliance targets one module (p2888 on a CTI Rogue carrier) and ships one image for
# AGX101 and AGX111 alike, so this is a constant of the product, not of a particular board.
BOARD_ENV="BOARDID=2888 FAB=400 BOARDSKU=0004 BOARDREV=M.0 \
FUSELEVEL=fuselevel_production CHIPREV=2 HWCHIPID=0x19"
log "flash.sh patched: board identity preset, so it will NOT reboot the board mid-flash"

log "Flashing: ./flash.sh -r $TARGET $DEVICE   (expect ~30-50 min; the log goes quiet during the write)"
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
# shellcheck disable=SC2086  # BOARD_ENV is a deliberate list of VAR=value words
chroot "$C" /usr/bin/env USER=root HOME=/root SKIP_REC_IMG=1 $BOARD_ENV /bin/bash -c \
    "cd /mnt/lft && ./flash.sh -r '$TARGET' '$DEVICE'"
rc=$?
log "-------------------------------------------------------------------------------"
[ $rc -eq 0 ] || die "flash.sh failed (exit $rc)"
log "FLASH OK"
