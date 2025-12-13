#!/usr/bin/env python3
"""
App Manager Service

Manages the lifecycle of applications deployed to the APP partition.
Provides:
- Ordered startup/shutdown of applications
- Health monitoring with configurable checks
- Unix socket API for control and status
- Process supervision and restart

Configuration:
- Reads global manifest from /app/manifest.json
- Per-app manifests from /app/<name>/manifest.json
- Creates data dirs in /data/app-data/<name>/
- Copies configs to /data/app-config/<name>/

Usage:
  python3 app-manager.py [--manifest /app/manifest.json]
"""

import argparse
import glob
import json
import logging
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler
from io import BytesIO
from pathlib import Path
from typing import Dict, List, Optional, Any

# Constants
DEFAULT_MANIFEST = "/app/manifest.json"
APP_DIR = "/app"
DATA_DIR = "/data"
RUN_DIR = "/run/app"
LOG_DIR = "/var/log/app"
SOCKET_PATH = "/run/app/app-manager.sock"
HEALTH_CHECK_INTERVAL = 10  # seconds

# Global state
apps: Dict[str, dict] = {}
running = True
health_thread: Optional[threading.Thread] = None

# Setup logging
def setup_logging():
    """Configure logging to file and console."""
    log_format = '%(asctime)s [%(levelname)s] %(name)s: %(message)s'

    os.makedirs(LOG_DIR, exist_ok=True)

    handlers = [
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(f"{LOG_DIR}/app-manager.log")
    ]

    logging.basicConfig(
        level=logging.INFO,
        format=log_format,
        handlers=handlers
    )

    return logging.getLogger("app-manager")

logger = setup_logging()


def load_global_manifest(manifest_path: str) -> dict:
    """Load the global manifest from APP partition."""
    if not os.path.exists(manifest_path):
        logger.warning(f"Global manifest not found: {manifest_path}")
        return {"apps": [], "startup_order": []}

    try:
        with open(manifest_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load manifest: {e}")
        return {"apps": [], "startup_order": []}


def load_app_manifest(app_name: str) -> dict:
    """Load per-app manifest."""
    manifest_path = f"{APP_DIR}/{app_name}/manifest.json"

    if not os.path.exists(manifest_path):
        logger.warning(f"App manifest not found: {manifest_path}")
        return {}

    try:
        with open(manifest_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load app manifest for {app_name}: {e}")
        return {}


def init_app_directories(app_name: str, manifest: dict):
    """Create data and config directories for an app."""
    data_dir = f"{DATA_DIR}/app-data/{app_name}"
    config_dir = f"{DATA_DIR}/app-config/{app_name}"

    # Create base directories
    os.makedirs(data_dir, exist_ok=True)
    os.makedirs(config_dir, exist_ok=True)

    # Create data subdirectories from manifest
    for subdir in manifest.get("data_dirs", []):
        os.makedirs(f"{data_dir}/{subdir}", exist_ok=True)

    # Copy default configs if they don't exist
    for config in manifest.get("config_files", []):
        source = f"{APP_DIR}/{app_name}/{config.get('source', '')}"
        dest = f"{config_dir}/{config.get('dest', '')}"

        if os.path.exists(source) and not os.path.exists(dest):
            shutil.copy2(source, dest)
            logger.info(f"Copied default config: {dest}")


def get_pid(app_name: str) -> Optional[int]:
    """Get PID of a running app from its PID file."""
    pid_file = f"{RUN_DIR}/{app_name}.pid"

    if not os.path.exists(pid_file):
        return None

    try:
        with open(pid_file, 'r') as f:
            pid = int(f.read().strip())

        # Check if process is running
        os.kill(pid, 0)
        return pid
    except (ValueError, ProcessLookupError, FileNotFoundError):
        return None


def is_running(app_name: str) -> bool:
    """Check if an app is running."""
    return get_pid(app_name) is not None


def run_startup_scripts():
    """Execute all startup scripts in order."""
    startup_dir = f"{APP_DIR}/startup.d"

    if not os.path.exists(startup_dir):
        logger.warning(f"Startup directory not found: {startup_dir}")
        return

    scripts = sorted(glob.glob(f"{startup_dir}/*.sh"))

    for script in scripts:
        script_name = os.path.basename(script)
        logger.info(f"Running startup script: {script_name}")

        try:
            result = subprocess.run(
                ["/bin/sh", script],
                capture_output=True,
                text=True,
                timeout=60
            )
            if result.returncode != 0:
                logger.error(f"Startup script failed: {script_name}")
                logger.error(f"stderr: {result.stderr}")
            else:
                logger.info(f"Startup script completed: {script_name}")
        except subprocess.TimeoutExpired:
            logger.error(f"Startup script timed out: {script_name}")
        except Exception as e:
            logger.error(f"Failed to run startup script {script_name}: {e}")


def run_shutdown_scripts():
    """Execute all shutdown scripts in order."""
    shutdown_dir = f"{APP_DIR}/shutdown.d"

    if not os.path.exists(shutdown_dir):
        return

    scripts = sorted(glob.glob(f"{shutdown_dir}/*.sh"))

    for script in scripts:
        script_name = os.path.basename(script)
        logger.info(f"Running shutdown script: {script_name}")

        try:
            result = subprocess.run(
                ["/bin/sh", script],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                logger.warning(f"Shutdown script returned non-zero: {script_name}")
        except subprocess.TimeoutExpired:
            logger.warning(f"Shutdown script timed out: {script_name}")
        except Exception as e:
            logger.error(f"Failed to run shutdown script {script_name}: {e}")


def start_app(app_name: str) -> bool:
    """Start a specific application."""
    if is_running(app_name):
        logger.info(f"{app_name} is already running")
        return True

    startup_script = None
    for script in glob.glob(f"{APP_DIR}/startup.d/*-{app_name}.sh"):
        startup_script = script
        break

    if not startup_script:
        logger.error(f"No startup script found for {app_name}")
        return False

    try:
        result = subprocess.run(
            ["/bin/sh", startup_script],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode == 0:
            logger.info(f"Started {app_name}")
            return True
        else:
            logger.error(f"Failed to start {app_name}: {result.stderr}")
            return False
    except Exception as e:
        logger.error(f"Failed to start {app_name}: {e}")
        return False


def stop_app(app_name: str) -> bool:
    """Stop a specific application."""
    if not is_running(app_name):
        logger.info(f"{app_name} is not running")
        return True

    shutdown_script = None
    for script in glob.glob(f"{APP_DIR}/shutdown.d/*-{app_name}.sh"):
        shutdown_script = script
        break

    if shutdown_script:
        try:
            subprocess.run(["/bin/sh", shutdown_script], timeout=30)
            return True
        except Exception as e:
            logger.warning(f"Shutdown script failed for {app_name}: {e}")

    # Fallback: kill by PID
    pid = get_pid(app_name)
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(2)
            if is_running(app_name):
                os.kill(pid, signal.SIGKILL)
            logger.info(f"Stopped {app_name}")
            return True
        except Exception as e:
            logger.error(f"Failed to stop {app_name}: {e}")
            return False

    return True


def restart_app(app_name: str) -> bool:
    """Restart a specific application."""
    stop_app(app_name)
    time.sleep(1)
    return start_app(app_name)


def check_health_http(app_name: str, config: dict) -> dict:
    """Perform HTTP health check."""
    import urllib.request
    import urllib.error

    port = config.get("port", 8000)
    endpoint = config.get("endpoint", "/health")
    timeout = config.get("timeout", 5)
    expected = config.get("expected_status", 200)

    url = f"http://localhost:{port}{endpoint}"
    start_time = time.time()

    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status_code = response.status
            elapsed = (time.time() - start_time) * 1000

            if status_code == expected:
                return {
                    "status": "healthy",
                    "response_time_ms": round(elapsed, 2),
                    "status_code": status_code
                }
            else:
                return {
                    "status": "unhealthy",
                    "response_time_ms": round(elapsed, 2),
                    "status_code": status_code,
                    "error": f"Expected {expected}, got {status_code}"
                }
    except urllib.error.URLError as e:
        return {"status": "unhealthy", "error": str(e.reason)}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}


def check_health_tcp(app_name: str, config: dict) -> dict:
    """Perform TCP port health check."""
    port = config.get("port", 8000)
    timeout = config.get("timeout", 5)

    start_time = time.time()

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex(('localhost', port))
        sock.close()

        elapsed = (time.time() - start_time) * 1000

        if result == 0:
            return {
                "status": "healthy",
                "response_time_ms": round(elapsed, 2)
            }
        else:
            return {"status": "unhealthy", "error": "Connection refused"}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}


def check_health_process(app_name: str, config: dict) -> dict:
    """Check if process is running."""
    if is_running(app_name):
        return {"status": "healthy"}
    else:
        return {"status": "unhealthy", "error": "Process not running"}


def check_app_health(app_name: str) -> dict:
    """Perform health check for an app."""
    if app_name not in apps:
        return {"status": "unknown", "error": "App not found"}

    app = apps[app_name]

    if not is_running(app_name):
        return {"status": "stopped"}

    health_config = app.get("manifest", {}).get("health", {})
    health_type = health_config.get("type", "process")

    if health_type == "http":
        return check_health_http(app_name, health_config)
    elif health_type == "tcp":
        return check_health_tcp(app_name, health_config)
    else:
        return check_health_process(app_name, health_config)


def get_app_status(app_name: str) -> dict:
    """Get full status for an app."""
    if app_name not in apps:
        return {"error": "App not found"}

    app = apps[app_name]
    manifest = app.get("manifest", {})

    pid = get_pid(app_name)
    running = pid is not None

    # Calculate uptime if running
    uptime_seconds = 0
    uptime_human = "N/A"
    if running and app.get("start_time"):
        uptime_seconds = int(time.time() - app["start_time"])
        hours, rem = divmod(uptime_seconds, 3600)
        mins, secs = divmod(rem, 60)
        if hours > 0:
            uptime_human = f"{hours}h {mins}m"
        elif mins > 0:
            uptime_human = f"{mins}m {secs}s"
        else:
            uptime_human = f"{secs}s"

    health = app.get("last_health", {"status": "unknown"})

    return {
        "name": app_name,
        "version": manifest.get("version", "unknown"),
        "description": manifest.get("description", ""),
        "type": manifest.get("type", "service"),
        "port": manifest.get("port", 0),
        "status": "running" if running else "stopped",
        "pid": pid,
        "health": health,
        "uptime_seconds": uptime_seconds,
        "uptime_human": uptime_human
    }


def health_monitor_loop():
    """Background thread for health monitoring."""
    global running, apps

    while running:
        for app_name in apps:
            if not running:
                break

            health = check_app_health(app_name)
            health["last_check"] = datetime.now().isoformat()
            apps[app_name]["last_health"] = health

            # Track start time when app becomes running
            if is_running(app_name) and not apps[app_name].get("start_time"):
                apps[app_name]["start_time"] = time.time()
            elif not is_running(app_name):
                apps[app_name]["start_time"] = None

        # Wait for next check
        for _ in range(HEALTH_CHECK_INTERVAL):
            if not running:
                break
            time.sleep(1)


class UnixSocketHandler(BaseHTTPRequestHandler):
    """HTTP request handler for Unix socket API."""

    def log_message(self, format, *args):
        logger.debug(f"API: {format % args}")

    def send_json(self, data: Any, status: int = 200):
        response = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(response))
        self.end_headers()
        self.wfile.write(response)

    def do_GET(self):
        path = self.path.split('?')[0]

        if path == '/apps':
            # List all apps
            result = {"apps": [get_app_status(name) for name in apps]}
            self.send_json(result)

        elif path.startswith('/apps/') and '/health' in path:
            app_name = path.split('/')[2]
            health = check_app_health(app_name)
            self.send_json(health)

        elif path.startswith('/apps/'):
            app_name = path.split('/')[2]
            status = get_app_status(app_name)
            self.send_json(status)

        else:
            self.send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = self.path

        if '/start' in path:
            app_name = path.split('/')[2]
            success = start_app(app_name)
            self.send_json({"success": success, "status": get_app_status(app_name)})

        elif '/stop' in path:
            app_name = path.split('/')[2]
            success = stop_app(app_name)
            self.send_json({"success": success, "status": get_app_status(app_name)})

        elif '/restart' in path:
            app_name = path.split('/')[2]
            success = restart_app(app_name)
            self.send_json({"success": success, "status": get_app_status(app_name)})

        else:
            self.send_json({"error": "Not found"}, 404)


class UnixSocketHTTPServer:
    """HTTP server on Unix socket."""

    def __init__(self, socket_path: str, handler_class):
        self.socket_path = socket_path
        self.handler_class = handler_class
        self.server_socket = None
        self.running = False

    def start(self):
        # Remove existing socket
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)

        self.server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind(self.socket_path)
        os.chmod(self.socket_path, 0o660)
        self.server_socket.listen(5)
        self.running = True

        logger.info(f"API listening on: {self.socket_path}")

        while self.running:
            try:
                self.server_socket.settimeout(1.0)
                conn, _ = self.server_socket.accept()
                self._handle_connection(conn)
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    logger.error(f"API error: {e}")

    def _handle_connection(self, conn):
        """Handle a single connection."""
        try:
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\r\n\r\n" in data:
                    break

            if data:
                # Parse HTTP request
                rfile = BytesIO(data)
                wfile = BytesIO()

                # Create handler instance without calling __init__
                # (BaseHTTPRequestHandler.__init__ expects a socket with makefile())
                handler = object.__new__(self.handler_class)
                handler.rfile = rfile
                handler.wfile = wfile
                handler.client_address = ('socket', 0)
                handler.server = self
                handler.requestline = ''
                handler.request_version = 'HTTP/1.1'
                handler.close_connection = True

                # Parse request line
                request_line = data.split(b'\r\n')[0].decode()
                parts = request_line.split(' ')
                if len(parts) >= 2:
                    handler.command = parts[0]
                    handler.path = parts[1]
                    handler.requestline = request_line

                    # Handle request
                    if handler.command == 'GET':
                        handler.do_GET()
                    elif handler.command == 'POST':
                        handler.do_POST()

                # Send response
                conn.sendall(wfile.getvalue())
        except Exception as e:
            logger.error(f"Connection error: {e}")
        finally:
            conn.close()

    def stop(self):
        self.running = False
        if self.server_socket:
            self.server_socket.close()
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)


def signal_handler(signum, frame):
    """Handle shutdown signals."""
    global running
    signal_name = signal.Signals(signum).name
    logger.info(f"Received {signal_name}, shutting down...")
    running = False


def main():
    global running, apps, health_thread

    parser = argparse.ArgumentParser(description='App Manager Service')
    parser.add_argument('--manifest', type=str, default=DEFAULT_MANIFEST,
                       help=f'Path to global manifest (default: {DEFAULT_MANIFEST})')
    args = parser.parse_args()

    # Setup signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    logger.info("App Manager starting...")

    # Create runtime directories
    os.makedirs(RUN_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(f"{DATA_DIR}/app-data", exist_ok=True)
    os.makedirs(f"{DATA_DIR}/app-config", exist_ok=True)

    # Load global manifest
    manifest = load_global_manifest(args.manifest)
    logger.info(f"Loaded manifest: {len(manifest.get('apps', []))} app(s)")

    # Load per-app manifests and initialize directories
    for app_entry in manifest.get("apps", []):
        # Handle both string format (legacy) and object format (new)
        if isinstance(app_entry, dict):
            app_name = app_entry.get("name", "")
            global_port = app_entry.get("port", 0)
            global_type = app_entry.get("type", "service")
        else:
            app_name = app_entry
            global_port = 0
            global_type = "service"

        if not app_name:
            continue

        app_manifest = load_app_manifest(app_name)
        # Merge global manifest info with per-app manifest
        if global_port and not app_manifest.get("port"):
            app_manifest["port"] = global_port
        if global_type and not app_manifest.get("type"):
            app_manifest["type"] = global_type

        apps[app_name] = {
            "manifest": app_manifest,
            "last_health": {"status": "unknown"},
            "start_time": None
        }
        init_app_directories(app_name, app_manifest)
        logger.info(f"Initialized: {app_name}")

    # Run startup scripts
    logger.info("Running startup scripts...")
    run_startup_scripts()

    # Start health monitoring thread
    health_thread = threading.Thread(target=health_monitor_loop, daemon=True)
    health_thread.start()

    # Start API server
    api_server = UnixSocketHTTPServer(SOCKET_PATH, UnixSocketHandler)
    api_thread = threading.Thread(target=api_server.start, daemon=True)
    api_thread.start()

    logger.info("App Manager ready")

    # Main loop
    while running:
        time.sleep(1)

    # Shutdown
    logger.info("Shutting down...")

    # Stop API server
    api_server.stop()

    # Run shutdown scripts
    run_shutdown_scripts()

    logger.info("App Manager stopped")


if __name__ == '__main__':
    main()
