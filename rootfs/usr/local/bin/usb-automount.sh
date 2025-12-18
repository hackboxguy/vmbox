#!/bin/sh
#
# usb-automount.sh - Auto-mount/unmount USB storage devices
#
# Called by udev rules when USB storage devices are added/removed.
# Mount point: /mnt/usb/<device> (e.g., /mnt/usb/sdb1)
#
# Supported filesystems: NTFS, FAT32/FAT16 (vfat), exFAT, ext2/3/4
#

MOUNT_BASE="/mnt/usb"
LOG_TAG="usb-automount"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> /var/log/usb-automount.log
}

do_mount() {
    local device="$1"
    local devpath="/dev/$device"
    local mountpoint="$MOUNT_BASE/$device"

    # Skip if not a partition (no number suffix)
    case "$device" in
        sd[a-z]) return 0 ;;  # Skip whole disk devices like sdb
    esac

    # Skip if already mounted
    if mount | grep -q "^$devpath "; then
        log "Device $devpath already mounted"
        return 0
    fi

    # Detect filesystem type
    local fstype=$(blkid -o value -s TYPE "$devpath" 2>/dev/null)
    if [ -z "$fstype" ]; then
        log "Cannot detect filesystem type for $devpath"
        return 1
    fi

    # Create mount point
    mkdir -p "$mountpoint"

    # Mount based on filesystem type
    local mount_opts=""
    case "$fstype" in
        ntfs)
            # Use ntfs-3g for NTFS (read-write support)
            if command -v ntfs-3g >/dev/null 2>&1; then
                log "Mounting $devpath ($fstype) at $mountpoint using ntfs-3g"
                ntfs-3g "$devpath" "$mountpoint" -o rw,uid=1000,gid=1000,umask=002
            else
                log "ntfs-3g not installed, mounting read-only"
                mount -t ntfs -o ro "$devpath" "$mountpoint"
            fi
            ;;
        vfat|fat16|fat32|msdos)
            # FAT filesystems
            log "Mounting $devpath ($fstype) at $mountpoint"
            mount -t vfat -o rw,uid=1000,gid=1000,umask=002 "$devpath" "$mountpoint"
            ;;
        exfat)
            # exFAT filesystem
            log "Mounting $devpath ($fstype) at $mountpoint"
            mount -t exfat -o rw,uid=1000,gid=1000,umask=002 "$devpath" "$mountpoint"
            ;;
        ext2|ext3|ext4)
            # Linux native filesystems
            log "Mounting $devpath ($fstype) at $mountpoint"
            mount -t "$fstype" "$devpath" "$mountpoint"
            ;;
        *)
            log "Unsupported filesystem type: $fstype for $devpath"
            rmdir "$mountpoint" 2>/dev/null
            return 1
            ;;
    esac

    local result=$?
    if [ $result -eq 0 ]; then
        log "Successfully mounted $devpath at $mountpoint"
    else
        log "Failed to mount $devpath (exit code: $result)"
        rmdir "$mountpoint" 2>/dev/null
    fi

    return $result
}

do_unmount() {
    local device="$1"
    local devpath="/dev/$device"
    local mountpoint="$MOUNT_BASE/$device"

    # Skip if not a partition
    case "$device" in
        sd[a-z]) return 0 ;;
    esac

    # Check if mounted
    if ! mount | grep -q "^$devpath \|$mountpoint"; then
        log "Device $devpath not mounted, skipping unmount"
        return 0
    fi

    log "Unmounting $mountpoint"

    # Unmount
    umount "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null

    # Remove mount point directory
    rmdir "$mountpoint" 2>/dev/null

    log "Successfully unmounted $devpath"
    return 0
}

# Main
ACTION="$1"
DEVICE="$2"

# Ensure mount base directory exists
mkdir -p "$MOUNT_BASE"

case "$ACTION" in
    add)
        do_mount "$DEVICE"
        ;;
    remove)
        do_unmount "$DEVICE"
        ;;
    *)
        echo "Usage: $0 {add|remove} <device>"
        exit 1
        ;;
esac
