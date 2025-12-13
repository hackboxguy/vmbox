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

### Avoid `http.server` Module in Alpine/BusyBox Environments

**Problem**: Python's built-in `http.server` module has compatibility issues with Alpine Linux and BusyBox networking tools.

**Symptoms**:
- Connections establish (TCP handshake completes)
- Server's `recv()` blocks forever
- No data is ever received by the server
- BusyBox `nc`, `wget`, and `curl` all exhibit the same behavior

**Solution**: Use Flask instead of `http.server`:

```python
# Instead of:
from http.server import HTTPServer, SimpleHTTPRequestHandler
httpd = HTTPServer(('0.0.0.0', 8002), MyHandler)
httpd.serve_forever()

# Use Flask:
from flask import Flask
app = Flask(__name__)
app.run(host='0.0.0.0', port=8002, threaded=True)
```

Flask's Werkzeug server handles socket operations more reliably across different environments.

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

## Summary of Key Fixes

| Issue | Root Cause | Solution |
|-------|------------|----------|
| localhost hangs inside VM | Missing `lo` interface | Enable `networking` service |
| http.server hangs | Incompatibility with BusyBox | Use Flask instead |
| 60s response delay | DNS reverse lookup | Override `address_string()` |
| Script silent exit | `((var++))` with `set -e` | Use `$((var + 1))` |
| Remote "Open" button fails | Hardcoded `localhost` | Use `window.location.hostname` |
