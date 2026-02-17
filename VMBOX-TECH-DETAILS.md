# VirtualBox Alpine VM - Technical Details

This document captures important technical findings, gotchas, and solutions discovered during development and debugging of the VirtualBox Alpine VM framework.

## Table of Contents

1. [Network Configuration](#network-configuration)
2. [Python HTTP Servers](#python-http-servers)
3. [Bash Scripting Gotchas](#bash-scripting-gotchas)
4. [VirtualBox NAT Port Forwarding](#virtualbox-nat-port-forwarding)
5. [WebUI Considerations](#webui-considerations)
6. [OpenRC Service Management](#openrc-service-management)
7. [WebSocket and JSON Parsing](#websocket-and-json-parsing)
8. [Log Management](#log-management)
9. [USB Passthrough and CAN Bus](#usb-passthrough-and-can-bus)

---

## Network Configuration

### Loopback Interface (`lo`) Must Be Explicitly Enabled

**Problem**: Connections to `localhost` or `127.0.0.1` inside the VM hang indefinitely.

**Root Cause**: The `networking` service was not enabled. Without it, `/etc/network/interfaces` is never processed and the loopback interface (`lo`) is never brought up.

**Symptoms**:
- `ifconfig` shows only `eth0`, no `lo` interface
- `curl http://localhost:8000/` hangs inside the VM
- External connections via VirtualBox NAT work fine (they use `eth0`)

**Solution**: Enable the `networking` service in `config.sh`:

```bash
ENABLED_SERVICES=(
    "devfs"
    "hostname"
    "networking"    # <-- Required for loopback interface
    "sshd"
    "dhcpcd"
    ...
)
```

**Key Insight**: `dhcpcd` only handles DHCP for network interfaces - it does NOT process `/etc/network/interfaces`. The `networking` service is responsible for bringing up interfaces defined there, including the loopback.

**Configuration file** (`/etc/network/interfaces`):
```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
```

---

## Python HTTP Servers

### Using `http.server` Module Correctly

**Problem**: Connections to `http.server` hang or timeout.

**Root Cause**: Usually caused by missing loopback interface (see [Network Configuration](#network-configuration)). Once `lo` is properly configured, `http.server` works fine.

**Important**: The `http.server` module works correctly in Alpine/BusyBox when:
1. The loopback interface is enabled (via `networking` service)
2. Proper HTTP headers are set (see fixes below)

**Recommended for**: Lightweight demo apps with zero external dependencies.

**For production apps**: Consider Flask for more features and better error handling.

### DNS Reverse Lookup Delays in BaseHTTPRequestHandler

**Problem**: HTTP responses take 60+ seconds to return.

**Root Cause**: Python's `BaseHTTPRequestHandler.address_string()` method calls `socket.getfqdn()` which performs a reverse DNS lookup on every request.

**Solution**: Override `address_string()` to return the raw IP:

```python
class MyHandler(SimpleHTTPRequestHandler):
    def address_string(self):
        """Return client IP without DNS lookup."""
        return self.client_address[0]
```

### HTTP/1.1 Connection Handling

**Problem**: Clients hang waiting for response even after server sends data.

**Root Cause**: HTTP/1.1 uses persistent connections by default. Without proper `Connection: close` headers, clients wait for more data.

**Solution**: Explicitly close connections:

```python
class MyHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        self.send_header('Connection', 'close')
        super().end_headers()
```

---

## Bash Scripting Gotchas

### Arithmetic Increment with `set -e`

**Problem**: Script silently exits when using `((var++))` with `set -e`.

**Root Cause**: In Bash, `((expression))` returns exit code based on the expression result. When `var=0`, `((var++))` evaluates to 0 (the pre-increment value), which is falsy, causing exit code 1.

```bash
set -e
count=0
((count++))  # Returns exit code 1, script exits!
```

**Solution**: Use arithmetic expansion instead:

```bash
count=$((count + 1))  # Always returns exit code 0
```

### Sed Replacement and Variable Names

**Problem**: `sed` replacing variable references when only placeholders should be replaced.

**Example**: `sed -i "s/APP_NAME/${name}/g"` also replaces `$APP_NAME` and `${APP_NAME}` in the file.

**Solution**: Use unique placeholder names that won't conflict:

```bash
# Use specific placeholders
cat > script.sh <<'EOF'
APP_NAME="APP_NAME_PLACEHOLDER"
echo "Running ${APP_NAME}"
EOF

# Replace only the placeholder
sed -i "s/APP_NAME_PLACEHOLDER/${name}/g" script.sh
```

---

## VirtualBox NAT Port Forwarding

### Port Forwarding Configuration

VirtualBox NAT mode requires explicit port forwarding rules. The VM's internal services are not directly accessible from the host.

**Adding port forwarding rules**:

```bash
VBoxManage modifyvm "vm-name" \
    --natpf1 "ssh,tcp,,2222,,22" \
    --natpf1 "webapp,tcp,,8000,,8000"
```

Format: `name,protocol,host_ip,host_port,guest_ip,guest_port`

### Viewing Current Rules

```bash
VBoxManage showvminfo "vm-name" | grep -i "rule\|natpf"
```

### Dynamic Port Forwarding from App Manifest

The `04-convert-to-vbox.sh` script reads `manifest.json` to automatically configure port forwarding for all apps:

```bash
# Reads app ports from manifest and creates forwarding rules
VBoxManage modifyvm "$VM_NAME" \
    --natpf1 "app-${app_name},tcp,,${app_port},,${app_port}"
```

---

## WebUI Considerations

### Dynamic Hostname for External Access

**Problem**: Hardcoded `localhost` URLs don't work when accessing WebUI from remote browsers.

**Example**: User accesses `http://192.168.1.80:8000/` but "Open App" button links to `http://localhost:8002/`.

**Solution**: Use `window.location.hostname` in JavaScript:

```javascript
// Instead of:
href="http://localhost:${app.port}/"

// Use:
href="http://${window.location.hostname}:${app.port}/"
```

This ensures the link uses whatever hostname the user is currently using to access the page.

---

## OpenRC Service Management

### Service Dependencies

Services can declare dependencies using the `depend()` function:

```bash
depend() {
    need net              # Must have networking
    after firewall        # Start after firewall
    before shutdown       # Stop before shutdown
}
```

### Service Enable Order

Services are enabled in the order listed in `ENABLED_SERVICES`. For proper boot sequence:

1. `devfs` - Device filesystem
2. `hostname` - Set hostname
3. `networking` - Bring up network interfaces (including loopback)
4. `sshd` - SSH daemon
5. `dhcpcd` - DHCP client
6. Custom services...

### conf.d Variables Not Reaching Daemon Processes

**Problem**: Environment variables defined in `/etc/conf.d/<svcname>` are available inside the init script shell but the daemon launched by `start-stop-daemon --background` doesn't see them.

**Root Cause**: OpenRC's `openrc-run` automatically sources `/etc/conf.d/$RC_SVCNAME`, so the variables exist in the init script's process. However, `start-stop-daemon --background` forks a new process and does **not** inherit the parent shell's exported variables. Alpine's `start-stop-daemon` also lacks a `--env` flag (unlike some other implementations).

**Solution**: Export the variables in `start_pre()` with defaults. Because `start-stop-daemon` on Alpine **does** inherit the environment of the calling shell when not using `--chuid`/`--user` with login, exporting them before the `start()` call ensures the child process receives them:

```bash
start_pre() {
    # Export conf.d variables so start-stop-daemon child inherits them
    export SYSTEM_MGMT_PORT="${SYSTEM_MGMT_PORT:-8000}"
    export SYSTEM_MGMT_HOST="${SYSTEM_MGMT_HOST:-0.0.0.0}"
}
```

The Python app then reads these with `os.environ.get()`:

```python
app.run(host=os.environ.get('SYSTEM_MGMT_HOST', '0.0.0.0'),
        port=int(os.environ.get('SYSTEM_MGMT_PORT', 8000)))
```

**Key Insight**: Always provide defaults on both sides (shell and Python) so the app works even without a conf.d file. The conf.d file only needs to be created when overriding the defaults.

### Checking Service Status

```bash
rc-service service-name status
rc-status                        # Show all services
```

---

## Debugging Tips

### Network Connectivity Inside VM

```bash
# Check interfaces
ifconfig -a
ip addr

# Check listening ports
ss -tlnp
netstat -tlnp

# Test local connectivity
curl -v http://127.0.0.1:8000/health
curl -v http://$(hostname -I | awk '{print $1}'):8000/health
```

### Service Logs

```bash
# System services
cat /var/log/messages
dmesg | tail -50

# App manager logs
cat /var/log/app/app-manager.log
cat /var/log/app/hello-world.log
```

### VirtualBox VM Debugging

```bash
# From host - check VM info
VBoxManage showvminfo "vm-name"

# Serial console (if enabled)
socat - UNIX-CONNECT:/tmp/vm-name-serial.sock

# SSH access
ssh -p 2222 admin@localhost
```

---

## Serial Console Configuration

### Boot Delays When Serial Console Not Connected

**Problem**: VM services don't start until someone connects to the serial console.

**Root Cause**: When `console=ttyS0` is in the kernel command line (especially as the last/primary console), init and OpenRC write output to the serial port. If nothing is connected to read from it, writes can block, delaying boot.

**Solution**: Remove `console=ttyS0` from the kernel command line:

```bash
# Instead of (ttyS0 as primary console - BLOCKS):
APPEND root=/dev/sda2 console=tty0 console=ttyS0,115200n8 quiet

# Use (tty0 only - serial is optional):
APPEND root=/dev/sda2 console=tty0 quiet
```

**Additionally**, use `askfirst` for serial getty in `/etc/inittab`:

```bash
ttyS0::askfirst:/sbin/getty -L 115200 ttyS0 vt100
```

**Key Points**:
- The **last** `console=` parameter is the primary console
- With `console=ttyS0` as primary, init blocks if serial not connected
- Removing `console=ttyS0` makes serial truly optional
- Serial login still works via getty when someone connects

---

## WebSocket and JSON Parsing

### Single-Digit Characters Causing WebSocket Disconnection

**Problem**: Typing the character "2" (or any single digit 0-9) in the web-terminal causes WebSocket disconnection.

**Root Cause**: In the WebSocket message handler, `json.loads("2")` succeeds and returns the integer `2`. The code then tried to call `msg.get('type')` on an integer, causing an `AttributeError` that crashed the handler.

**Why single digits?**: Single digits are valid JSON literals. `json.loads("2")` → `2`, `json.loads("true")` → `True`. Most other raw terminal input like "abc" or "hello" fails JSON parsing and is correctly treated as terminal data.

**Solution (Python backend)**:

```python
try:
    msg = json.loads(message)
    # Must be a dict with 'type' field to be a control message
    if not isinstance(msg, dict):
        raise ValueError("Not a control message")
    msg_type = msg.get('type')
    # ... handle control messages
except (json.JSONDecodeError, ValueError):
    # Raw terminal input - send to serial port
    serial_connection.write(message.encode('utf-8'))
```

**Solution (JavaScript frontend)**:

```javascript
ws.onmessage = (event) => {
    try {
        const msg = JSON.parse(event.data);
        // Must be an object with 'type' to be a control message
        if (msg && typeof msg === 'object' && msg.type) {
            handleControlMessage(msg);
        } else {
            // Valid JSON but not a control message - treat as terminal data
            terminal.write(event.data);
        }
    } catch (e) {
        // Raw terminal data
        terminal.write(event.data);
    }
};
```

**Key Insight**: When mixing JSON control messages with raw data on the same WebSocket, always verify the parsed result is the expected type (object/dict) before accessing properties.

### WebSocket Token Reuse

**Problem**: WebSocket reconnection fails with "Invalid token" after the first connection.

**Root Cause**: Tokens were deleted immediately after first validation, making them one-time use only. When the WebSocket reconnected (e.g., after network hiccup), the same token was rejected.

**Solution**: Allow token reuse within the validity period (60 seconds):

```python
# Token validation endpoint
if token in app._ws_tokens:
    token_info = app._ws_tokens[token]
    if datetime.now() < token_info['expires']:
        # Token is valid - allow reuse until expiry
        # DO NOT delete the token here
        return jsonify({'valid': True, 'username': token_info['username']})
```

**Key Insight**: Short-lived tokens should remain valid for their entire lifetime, not just the first use. Deletion should happen via expiry cleanup, not on validation.

---

## Log Management

### Clearing Kernel Messages (dmesg)

**Problem**: "Clear Log" button doesn't work when Kernel Messages is selected.

**Root Cause**: Kernel messages come from the kernel ring buffer, not a regular file. You can't truncate `/dev/kmsg` or a non-existent file path.

**Solution**: Use `dmesg --clear` command (requires root):

```python
@app.route('/api/logs/<source_id>/clear', methods=['POST'])
def api_clear_log(source_id):
    # Special handling for dmesg (kernel ring buffer)
    if source_id == 'dmesg':
        result = subprocess.run(['dmesg', '--clear'],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            return jsonify({'status': 'ok', 'message': 'Kernel messages cleared'})
        else:
            return jsonify({'status': 'error', 'message': result.stderr}), 500

    # Regular file truncation for other logs
    if os.path.exists(path):
        open(path, 'w').close()  # Truncate file
```

### Log Truncation vs Deletion

**Problem**: Should log clearing delete the file or truncate it?

**Answer**: Truncate. Running applications may hold open file handles. If you delete and recreate the file, the app continues writing to the old (now deleted) file descriptor.

```python
# Truncate (keeps file handle valid):
open(path, 'w').close()

# Delete (breaks running apps):
os.remove(path)  # DON'T DO THIS
```

### Duplicate Log Messages

**Problem**: Log messages appear twice in the log file.

**Root Cause**: Both a file handler and stdout handler were configured. OpenRC captures stdout and writes it to the same log file, resulting in duplicates.

**Solution**: Use file-only logging with `RotatingFileHandler` (no stdout handler):

```python
from logging.handlers import RotatingFileHandler

def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    handlers = [
        RotatingFileHandler(
            f"{LOG_DIR}/app-manager.log",
            maxBytes=5*1024*1024,   # 5 MB per file
            backupCount=3           # Keep 3 rotated files
        )
    ]
    logging.basicConfig(level=logging.INFO, handlers=handlers)
```

OpenRC's `output_log`/`error_log` still captures any uncaught stdout/stderr as a safety net.

### Log Rotation for Embedded Systems

**Problem**: Log files grow unbounded on a system with limited disk space (SquashFS rootfs + small ext4 data partition). A long-running VM can eventually fill the data partition with logs.

**Solution**: Use Python's `RotatingFileHandler` instead of plain `FileHandler`:

```python
from logging.handlers import RotatingFileHandler

handler = RotatingFileHandler(
    '/var/log/app/app-manager.log',
    maxBytes=5*1024*1024,   # Rotate at 5 MB
    backupCount=3           # Keep app-manager.log.1, .2, .3
)
```

**Sizing guidelines**:
- Main services (app-manager): `maxBytes=5MB`, `backupCount=3` → max 20 MB total
- Auxiliary logs (auth log): `maxBytes=2MB`, `backupCount=3` → max 8 MB total
- Adjust based on available space on the DATA partition

**Key Insight**: `RotatingFileHandler` handles rotation atomically — the current file is renamed and a new empty file is created. Existing file handles continue working. No external tool like `logrotate` is needed, keeping the Alpine image minimal.

### Download Logs as ZIP

For collecting all logs for support/debugging, provide a ZIP download endpoint:

```python
@app.route('/api/logs/download')
def api_download_logs():
    memory_file = io.BytesIO()
    with zipfile.ZipFile(memory_file, 'w', zipfile.ZIP_DEFLATED) as zf:
        # Add app logs
        for log_file in glob.glob('/var/log/app/*.log'):
            zf.write(log_file, f'app/{os.path.basename(log_file)}')

        # Add dmesg output
        result = subprocess.run(['dmesg'], capture_output=True, text=True)
        if result.returncode == 0:
            zf.writestr('system/dmesg.log', result.stdout)

    memory_file.seek(0)
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    return send_file(memory_file, mimetype='application/zip',
                     as_attachment=True, download_name=f'logs-{timestamp}.zip')
```

---

## USB Passthrough and CAN Bus

### VirtualBox USB Controller Requirements

**Problem**: VM fails to start with error about USB 2.0/3.0 controller.

**Root Cause**: USB 2.0 (EHCI) and USB 3.0 (xHCI) controllers require the VirtualBox Extension Pack to be installed.

**Solution**: The framework defaults to USB 1.1 (OHCI) which works without Extension Pack, with automatic fallback if higher modes are requested but Extension Pack is not installed:

```bash
# In 04-convert-to-vbox.sh
local extpack_installed=false
if VBoxManage list extpacks 2>/dev/null | grep -q "Oracle VM VirtualBox Extension Pack"; then
    extpack_installed=true
fi

if [ "$USB_MODE" = "2" ] || [ "$USB_MODE" = "3" ]; then
    if [ "$extpack_installed" = "false" ]; then
        warn "USB $USB_MODE.0 requires VirtualBox Extension Pack (not installed)"
        warn "Falling back to USB 1.1 (OHCI)"
        USB_MODE="1"
    fi
fi
```

**Key Insight**: USB 1.1 (OHCI) is sufficient for most USB-serial adapters including CAN interfaces. Only use USB 2.0/3.0 if you need higher throughput devices.

### USB Device Filters for Passthrough

USB devices must be explicitly passed through to the VM using VID/PID filters:

```bash
# Android ADB devices (Google/AOSP VID)
VBoxManage usbfilter add 5 --target "$VM_NAME" \
    --name "Android ADB" --vendorid 18d1 --active yes

# CANable USB-CAN adapter (gs_usb driver)
VBoxManage usbfilter add 6 --target "$VM_NAME" \
    --name "CANable" --vendorid 1d50 --active yes

# PCAN-USB adapter (peak_usb driver) - opt-in via --pcan flag
# Filter index is assigned dynamically after other filters
VBoxManage usbfilter add $next_filter --target "$VM_NAME" \
    --name "PCAN-USB" --vendorid 0c72 --active yes
```

**Note**: The PCAN-USB filter is **not** added by default. Pass `--pcan` to `04-convert-to-vbox.sh` to enable it. The filter index is assigned dynamically to avoid gaps.

**Finding VIDs**: Use `lsusb` on the host when the device is plugged in to find vendor ID.

### CAN Interface Auto-Configuration

**Problem**: CAN interfaces require manual configuration (`ip link set can0 type can bitrate 500000 && ip link set can0 up`) every time.

**Challenge**: Two scenarios need to be handled:
1. **Boot-time**: Adapter is plugged in when VM starts
2. **Hotplug**: Adapter is plugged in after VM is running

**Solution**: Dual-coverage approach using both OpenRC service and udev rule.

#### Why Dual Coverage is Needed

When a USB device is plugged in **before** VM boot, VirtualBox USB passthrough has a race condition:
- The udev rule fires when the CAN interface appears
- But USB passthrough may not be fully complete
- Result: Interface is UP but no packets received

A boot-time service with a delay gives USB passthrough time to complete.

When a USB device is **hotplugged** after boot, the udev rule handles it immediately.

#### udev Rule for Hotplug (`/etc/udev/rules.d/99-can.rules`)

```bash
SUBSYSTEM=="net", ACTION=="add", KERNEL=="can[0-9]*", RUN+="/usr/local/bin/setup-can.sh $kernel"
```

**Key Points**:
- Use `KERNEL=="can[0-9]*"` not `ATTR{type}=="280"` - ATTR may not be available at add time
- Use `$kernel` (udev syntax) not `'%k'` (old syntax) for interface name
- Runs `/usr/local/bin/setup-can.sh` with interface name as argument

#### Setup Script (`/usr/local/bin/setup-can.sh`)

```bash
#!/bin/sh
[ -f /etc/conf.d/can ] && . /etc/conf.d/can

INTERFACE="$1"
BITRATE="${CAN_BITRATE:-500000}"

# Validate interface
[ -z "$INTERFACE" ] && exit 1
[ ! -d "/sys/class/net/$INTERFACE" ] && exit 1

# Small delay for hardware initialization
sleep 1

# Load can_raw module (needed for candump/cansend)
modprobe can_raw 2>/dev/null || true

# Configure and bring up interface
ip link set "$INTERFACE" type can bitrate "$BITRATE"
ip link set "$INTERFACE" up

logger -t "setup-can" "$INTERFACE configured (bitrate=$BITRATE)"
```

#### OpenRC Service for Boot-time (`/etc/init.d/can-setup`)

```bash
#!/sbin/openrc-run
description="CAN bus interface configuration"

depend() {
    need udev
    after udev-trigger
}

start() {
    ebegin "Configuring CAN interfaces"

    [ -f /etc/conf.d/can ] && . /etc/conf.d/can
    BITRATE="${CAN_BITRATE:-500000}"

    # Wait for USB passthrough to complete
    sleep 2

    modprobe can_raw 2>/dev/null || true

    # Configure any unconfigured CAN interfaces
    for iface in /sys/class/net/can*; do
        [ -d "$iface" ] || continue
        name=$(basename "$iface")

        if ip link show "$name" 2>/dev/null | grep -q "state DOWN"; then
            ip link set "$name" type can bitrate "$BITRATE" 2>/dev/null && \
            ip link set "$name" up 2>/dev/null
        fi
    done

    eend 0
}
```

**Key Points**:
- Depends on `udev` and runs `after udev-trigger` to ensure devices are enumerated
- 2-second delay allows USB passthrough to fully complete
- Only configures interfaces that are DOWN (unconfigured)
- Won't interfere with udev-configured interfaces

#### Configuration File (`/etc/conf.d/can`)

```bash
# Default bitrate for all CAN interfaces (in bps)
# Common values: 125000, 250000, 500000, 1000000
CAN_BITRATE=500000
```

### CAN Kernel Modules

Required modules in `/etc/modules`:

```
# CAN bus support
can
can_raw
vcan
gs_usb      # CANable, canable.io adapters
peak_usb    # PCAN-USB adapters
slcan       # Serial line CAN adapters
```

### Debugging CAN Issues

```bash
# Check interface status
ip -details link show can0

# Verify CAN type (should be 280)
cat /sys/class/net/can0/type

# Check for traffic
candump can0

# Send test frame
cansend can0 123#DEADBEEF

# Check module loaded
lsmod | grep can

# Check USB device passed through
lsusb

# View setup logs
dmesg | grep -i can
cat /var/log/messages | grep setup-can
```

### Common CAN Problems

| Symptom | Cause | Solution |
|---------|-------|----------|
| Interface UP but 0 RX packets | `can_raw` module not loaded | Add `modprobe can_raw` to setup |
| Interface doesn't appear | USB not passed through | Check VBoxManage usbfilter |
| `RTNETLINK Operation not supported` | CAN modules not loaded | Check `/etc/modules` includes `can` |
| Interface DOWN after boot | USB passthrough race | Increase delay in can-setup service |
| "No such device" error | Wrong interface name | Use `ip link show` to find actual name |

---

## Summary of Key Fixes

| Issue | Root Cause | Solution |
|-------|------------|----------|
| localhost hangs inside VM | Missing `lo` interface | Enable `networking` service |
| http.server hangs | Missing `lo` interface | Enable `networking` service (http.server works fine with proper network config) |
| 60s response delay | DNS reverse lookup | Override `address_string()` |
| Script silent exit | `((var++))` with `set -e` | Use `$((var + 1))` |
| Remote "Open" button fails | Hardcoded `localhost` | Use `window.location.hostname` |
| Boot waits for serial console | `console=ttyS0` in kernel cmdline | Remove `console=ttyS0`, use only `console=tty0` |
| Typing "2" disconnects WebSocket | `json.loads("2")` returns int, not dict | Check `isinstance(msg, dict)` before accessing `.get()` |
| WebSocket reconnection fails | Token deleted after first validation | Allow token reuse within validity period |
| Duplicate log messages | Both stdout and file handlers active | Use file-only `RotatingFileHandler` (no stdout handler) |
| Unbounded log growth | Plain `FileHandler` never rotates | Use `RotatingFileHandler` with size limits |
| conf.d vars missing in daemon | `start-stop-daemon` doesn't inherit shell env | Export vars in `start_pre()` with defaults |
| Kernel messages won't clear | dmesg is ring buffer, not file | Use `dmesg --clear` command |
| VM won't start (USB 2.0 error) | Extension Pack not installed | Default to USB 1.1 with auto-fallback |
| CAN interface UP but no RX | `can_raw` module not loaded | Add `modprobe can_raw` to setup script |
| CAN works hotplug but not at boot | USB passthrough race condition | Use OpenRC service with 2-second delay |
| udev rule doesn't match CAN | `ATTR{type}` not available at add time | Use `KERNEL=="can[0-9]*"` instead |
