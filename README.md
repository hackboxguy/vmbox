# VirtualBox Alpine Demo Image Builder

A build system for generating minimal Alpine Linux-based VirtualBox images with a read-only root filesystem and persistent data partition.

## Features

- **Immutable Root Filesystem**: SquashFS-based read-only rootfs with OverlayFS for runtime changes
- **Persistent Data**: Separate ext4 partition for user data, configurations, and overlay changes
- **Factory Reset**: One-click reset to restore the system to its original state
- **System Management WebUI**: Real-time dashboard showing CPU, memory, disk, and network stats
- **Cross-Platform**: Export as OVA for use on Windows, macOS, or Linux
- **Minimal Footprint**: Based on Alpine Linux (~150MB compressed)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     VirtualBox VM                               │
├─────────────────────────────────────────────────────────────────┤
│  Disk Layout (MBR/BIOS)                                         │
│  ┌──────────┬────────────────────┬─────────────────────────┐    │
│  │ BOOT     │ ROOTFS             │ DATA                    │    │
│  │ (FAT32)  │ (SquashFS, ro)     │ (ext4, rw)              │    │
│  │ 64MB     │ 500MB              │ 1024MB                  │    │
│  │ syslinux │ Alpine + packages  │ overlay, /var, /home    │    │
│  │ kernel   │                    │                         │    │
│  │ initramfs│                    │                         │    │
│  └──────────┴────────────────────┴─────────────────────────┘    │
│                                                                 │
│  Runtime Filesystem (OverlayFS):                                │
│  /           → merged (squashfs lower + data/overlay upper)     │
│  /data       → DATA partition (direct mount)                    │
│  /mnt/shared → VirtualBox shared folder                         │
│                                                                 │
│  Services:                                                      │
│  ├── SSH (port 22)           → localhost:2222                   │
│  ├── System Mgmt (port 8000) → localhost:8000                   │
│  └── Business App (port 8001)→ localhost:8001                   │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Host System (Linux)

```bash
# Arch Linux
sudo pacman -S parted dosfstools e2fsprogs squashfs-tools syslinux virtualbox wget mtools socat

# Ubuntu/Debian
sudo apt install parted dosfstools e2fsprogs squashfs-tools syslinux virtualbox wget mtools socat
```

## Quick Start

### Build the Image

```bash
# Clone the repository
git clone https://github.com/hackboxguy/virtualbox-demo.git
cd virtualbox-demo

# Build the image (requires root for loop devices)
sudo ./build.sh --mode=base --output=/tmp/alpine-build --version=1.0.0

# Create Image partitions
sudo ./scripts/03-create-image.sh \
  --rootfs=/tmp/alpine-build/rootfs \
  --output=/tmp/alpine-build \
  --ospart=500M \
  --datapart=200M

# change owner of /tmp/alpine-build to the user
sudo chown -R $(id -u):$(id -g) /tmp/alpine-build

# Convert to VirtualBox VM
./scripts/04-convert-to-vbox.sh \
    --input=/tmp/alpine-build/alpine-vbox.raw \
    --vmname=alpine-demo \
    --export-ova --force
```

### Start the VM

```bash
# Headless mode
VBoxManage startvm alpine-demo --type headless

# Or with GUI
VBoxManage startvm alpine-demo --type gui
```

### Access the VM

| Service | URL/Command |
|---------|-------------|
| SSH | `ssh -p 2222 admin@localhost` |
| System Management | http://localhost:8000 |
| Business App | http://localhost:8001 |

### Default Credentials

- **Username**: `admin`
- **Password**: `brb0x`

These credentials are used for:
- SSH access
- Serial console terminal
- System Management WebUI

### Changing Password

You can change the password in two ways:

1. **Via Web UI**: Click the "Change Password" button in the Actions section of the dashboard
2. **Via SSH or serial console**:
   ```bash
   passwd admin
   ```

The new password will be used for all access methods (SSH, terminal, and WebUI).

### Password Recovery

If you forget your password, you have two options:

1. **Factory Reset** (if you can access the WebUI): Click the Factory Reset button
2. **Reimport OVA**: Delete the VM and reimport the original OVA file to restore default credentials

## Build Options

### build.sh

```bash
sudo ./build.sh \
    --mode=base \           # Build mode: base or incremental
    --output=/path/to/dir \ # Output directory
    --version=1.0.0 \       # Image version string
    [--ospart=500M] \       # Root partition size (default: 500M)
    [--datapart=1024M] \    # Data partition size (default: 1024M)
    [--hostname=alpine-vm] \# VM hostname
    [--dev-mode] \          # Create writable rootfs (no squashfs)
    [--debug]               # Enable debug output
```

### 04-convert-to-vbox.sh

```bash
./scripts/04-convert-to-vbox.sh \
    --input=image.raw \     # Path to raw disk image
    --vmname=alpine-demo \  # VM name
    [--memory=1024] \       # RAM in MB (default: 1024)
    [--cpus=2] \            # CPU count (default: 2)
    [--serial] \            # Enable serial console (Linux only)
    [--export-ova] \        # Export portable OVA file
    [--force]               # Overwrite existing VM
```

## Cross-Platform Deployment

### Export for Windows/macOS

The `--export-ova` flag creates a portable OVA file that can be imported on any platform:

```bash
./scripts/04-convert-to-vbox.sh \
    --input=/tmp/alpine-build/alpine-vbox.raw \
    --vmname=alpine-demo \
    --export-ova
```

This creates `/tmp/alpine-build/alpine-demo.ova` which can be imported via:
- **GUI**: File → Import Appliance → Select .ova file
- **CLI**: `VBoxManage import alpine-demo.ova`

## System Management WebUI

![System Management Dashboard](images/system-ui.png)

The built-in dashboard at http://localhost:8000 provides a secure web interface for system monitoring and management.

### Authentication

The WebUI requires authentication using the same credentials as SSH/terminal access. Features:
- Shadow-based authentication (synced with system password)
- 30-minute session timeout
- Failed login attempts are logged to `/var/log/system-mgmt-auth.log`

### Features

The dashboard provides:

- **Real-time monitoring** via Server-Sent Events (1-second updates)
- **CPU usage** gauge with percentage and load averages
- **Memory usage** with visual progress bar
- **Disk usage** for all mounted partitions
- **Network stats** including RX/TX traffic
- **System uptime** and version information
- **Log Viewer** with multiple log sources, search, and auto-refresh
- **Change Password** to update system credentials
- **Factory Reset** button to restore original state
- **Reboot** button for system restart

### Log Viewer

The integrated log viewer allows you to view and search system logs directly from the dashboard.

**Available Log Sources:**
- **System Log** (`/var/log/messages`) - Main system log
- **Kernel Messages** (dmesg) - Kernel ring buffer
- **Authentication Log** (`/var/log/system-mgmt-auth.log`) - WebUI login attempts
- **Boot Log** (`/var/log/boot.log`) - System boot messages

**Features:**
- Select from multiple log sources
- Configurable line count (50-1000 lines)
- Real-time search/filter with highlighting
- Auto-refresh option (5-second interval)
- Scroll to latest entries

### API Endpoints

All API endpoints require authentication (except `/login`).

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/login` | GET/POST | Login page and authentication |
| `/logout` | GET | Log out and clear session |
| `/` | GET | Dashboard HTML page |
| `/api/stream` | GET | SSE stream for real-time updates |
| `/api/version` | GET | Image version information |
| `/api/system/info` | GET | All system information |
| `/api/system/cpu` | GET | CPU load averages |
| `/api/system/memory` | GET | Memory usage |
| `/api/system/disk` | GET | Disk usage |
| `/api/system/network` | GET | Network interface info |
| `/api/change-password` | POST | Change user password |
| `/api/logs/sources` | GET | List available log sources |
| `/api/logs/<source_id>` | GET | Get log content (params: `lines`, `search`) |
| `/api/factory-reset` | POST | Reset to factory defaults |
| `/api/reboot` | POST | Reboot the system |

## Directory Structure

```
virtualbox-demo/
├── build.sh                    # Main build orchestrator
├── config.sh                   # Default configuration values
├── README.md                   # This file
│
├── scripts/
│   ├── lib.sh                  # Shared utility functions
│   ├── chroot-helper.sh        # Alpine chroot setup/teardown
│   ├── 01-create-alpine-rootfs.sh  # Create base Alpine rootfs
│   ├── 02-build-packages.sh    # Build apps from packages.txt
│   ├── 03-create-image.sh      # Assemble disk image
│   └── 04-convert-to-vbox.sh   # Convert to VirtualBox VM
│
├── rootfs/                     # Files overlaid onto Alpine
│   ├── etc/
│   │   ├── init.d/             # OpenRC service scripts
│   │   └── conf.d/             # Service configurations
│   └── opt/
│       ├── system-mgmt/        # System management webapp
│       │   ├── app.py
│       │   └── templates/
│       │       └── index.html
│       └── business-app/       # Business logic placeholder
│           └── app.py
│
└── initramfs/
    └── init                    # Custom init for overlay boot
```

## How It Works

### Boot Process

1. **BIOS** → Syslinux bootloader
2. **Syslinux** → Loads kernel + initramfs
3. **Initramfs** → Custom init script:
   - Mounts SquashFS rootfs (read-only)
   - Mounts ext4 data partition (read-write)
   - Creates OverlayFS (merges rootfs + data/overlay)
   - `switch_root` to merged filesystem
4. **OpenRC** → Starts system services

### Factory Reset

Factory reset clears the overlay directories while preserving the base system:

```bash
# What happens during factory reset:
rm -rf /data/overlay/upper/*
rm -rf /data/overlay/work/*
reboot
```

After reboot, the system returns to its original state as defined in the SquashFS image.

## VM Management

```bash
# Start VM
VBoxManage startvm alpine-demo --type headless

# Stop VM (graceful)
VBoxManage controlvm alpine-demo acpipowerbutton

# Force stop
VBoxManage controlvm alpine-demo poweroff

# Delete VM
VBoxManage unregistervm alpine-demo --delete

# List running VMs
VBoxManage list runningvms
```

## Troubleshooting

### No network interface (only lo)

Ensure the VM is using the virtio network adapter:
```bash
VBoxManage modifyvm alpine-demo --nictype1 virtio
```

### SSH "PTY allocation request failed"

The `/dev/pts` filesystem may not be mounted. This is handled automatically on first boot, but you can manually fix it:
```bash
mount -t devpts devpts /dev/pts -o gid=5,mode=620
```

### Serial console on Windows

Serial console uses Unix sockets which don't work on Windows. Either:
- Disable serial port in VM settings, or
- Rebuild without `--serial` flag (default behavior)

### VM won't start after OVA import

If you get a serial port error on Windows, disable it:
1. VM Settings → Serial Ports → Port 1
2. Uncheck "Enable Serial Port"

## License

GPL v2 License - See LICENSE file for details.
