# VirtualBox Alpine VM - Technical Details

This document captures important technical findings, gotchas, and solutions discovered during development and debugging of the VirtualBox Alpine VM framework.

## Table of Contents

1. [Network Configuration](#network-configuration)
2. [Python HTTP Servers](#python-http-servers)
3. [Bash Scripting Gotchas](#bash-scripting-gotchas)
4. [VirtualBox NAT Port Forwarding](#virtualbox-nat-port-forwarding)
5. [WebUI Considerations](#webui-considerations)
6. [OpenRC Service Management](#openrc-service-management)

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

## Summary of Key Fixes

| Issue | Root Cause | Solution |
|-------|------------|----------|
| localhost hangs inside VM | Missing `lo` interface | Enable `networking` service |
| http.server hangs | Missing `lo` interface | Enable `networking` service (http.server works fine with proper network config) |
| 60s response delay | DNS reverse lookup | Override `address_string()` |
| Script silent exit | `((var++))` with `set -e` | Use `$((var + 1))` |
| Remote "Open" button fails | Hardcoded `localhost` | Use `window.location.hostname` |
| Boot waits for serial console | `console=ttyS0` in kernel cmdline | Remove `console=ttyS0`, use only `console=tty0` |
