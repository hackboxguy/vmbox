#!/usr/bin/env python3
"""
Hello World Demo Application

A minimal application demonstrating the VirtualBox Alpine VM app framework.
Uses only Python standard library - no external dependencies.

This serves as a reference implementation for building lightweight apps
that integrate with the VM's app-manager service.

Features:
- Serves static HTML page following the UI Design System
- Provides /health endpoint for health checks
- Handles graceful shutdown via SIGTERM
- Loads configuration from /data/app-config/hello-world/config.json
"""

import json
import os
import signal
import sys
import logging
from datetime import datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.parse

# Configuration defaults
DEFAULT_PORT = 8002
DEFAULT_HOST = '0.0.0.0'

# Environment variables
APP_NAME = 'hello-world'
APP_VERSION = '1.0.0'
APP_DATA_DIR = os.environ.get('APP_DATA_DIR', f'/data/app-data/{APP_NAME}')
APP_CONFIG_DIR = os.environ.get('APP_CONFIG_DIR', f'/data/app-config/{APP_NAME}')
APP_LOG_FILE = os.environ.get('APP_LOG_FILE', f'/var/log/app/{APP_NAME}.log')
STATIC_DIR = os.environ.get('APP_STATIC_DIR', f'/app/{APP_NAME}/share/www')

# Start time for uptime calculation
START_TIME = datetime.now()

# Global config
config = {
    'greeting': 'Hello, World!',
    'version': APP_VERSION
}


def setup_logging():
    """Configure logging to file and console."""
    log_format = '%(asctime)s [%(levelname)s] %(name)s: %(message)s'

    # Create log directory if needed
    log_dir = os.path.dirname(APP_LOG_FILE)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
        except Exception:
            pass

    handlers = [logging.StreamHandler(sys.stdout)]

    try:
        handlers.append(logging.FileHandler(APP_LOG_FILE))
    except Exception:
        pass

    logging.basicConfig(
        level=logging.INFO,
        format=log_format,
        handlers=handlers
    )

    return logging.getLogger(APP_NAME)


logger = setup_logging()


def load_config(config_path):
    """Load configuration from JSON file."""
    global config

    if os.path.exists(config_path):
        try:
            with open(config_path, 'r') as f:
                user_config = json.load(f)
                config.update(user_config)
                logger.info(f"Loaded configuration from {config_path}")
        except Exception as e:
            logger.warning(f"Failed to load config from {config_path}: {e}")
    else:
        logger.info(f"No config file at {config_path}, using defaults")


class HelloWorldHandler(SimpleHTTPRequestHandler):
    """HTTP request handler for the Hello World app."""

    # Use HTTP/1.1 for better compatibility
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        # Set the directory for serving static files
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def end_headers(self):
        """Add Connection: close header to ensure proper response termination."""
        self.send_header('Connection', 'close')
        super().end_headers()

    def address_string(self):
        """Return client IP without DNS lookup (prevents timeout delays)."""
        return self.client_address[0]

    def log_message(self, format, *args):
        """Override to use our logger."""
        logger.info("%s - %s", self.address_string(), format % args)

    def do_GET(self):
        """Handle GET requests."""
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == '/health':
            self.handle_health()
        elif path == '/api/greeting':
            self.handle_greeting()
        elif path == '/api/info':
            self.handle_info()
        elif path == '/' or path == '/index.html':
            self.handle_index()
        else:
            # Serve static files
            super().do_GET()

    def handle_health(self):
        """Health check endpoint."""
        response = {
            'status': 'healthy',
            'timestamp': datetime.now().isoformat(),
            'uptime_seconds': (datetime.now() - START_TIME).total_seconds()
        }
        self.send_json_response(response)

    def handle_greeting(self):
        """API endpoint for greeting message."""
        response = {
            'greeting': config.get('greeting', 'Hello, World!'),
            'timestamp': datetime.now().isoformat()
        }
        self.send_json_response(response)

    def handle_info(self):
        """API endpoint for app information."""
        uptime = datetime.now() - START_TIME
        hours, remainder = divmod(int(uptime.total_seconds()), 3600)
        minutes, seconds = divmod(remainder, 60)

        response = {
            'name': APP_NAME,
            'version': APP_VERSION,
            'uptime': f"{hours}h {minutes}m {seconds}s",
            'uptime_seconds': uptime.total_seconds(),
            'config': config,
            'environment': {
                'data_dir': APP_DATA_DIR,
                'config_dir': APP_CONFIG_DIR,
                'log_file': APP_LOG_FILE
            }
        }
        self.send_json_response(response)

    def handle_index(self):
        """Serve the main index page."""
        index_path = os.path.join(STATIC_DIR, 'index.html')
        if os.path.exists(index_path):
            self.path = '/index.html'
            super().do_GET()
        else:
            # Fallback: generate a simple response
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            html = f"""<!DOCTYPE html>
<html>
<head><title>Hello World</title></head>
<body>
<h1>{config.get('greeting', 'Hello, World!')}</h1>
<p>Version: {APP_VERSION}</p>
<p><a href="/health">Health Check</a></p>
</body>
</html>"""
            self.wfile.write(html.encode())

    def send_json_response(self, data, status=200):
        """Send a JSON response."""
        response_body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(response_body))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(response_body)


class ReusableHTTPServer(HTTPServer):
    """HTTP Server that allows address reuse."""
    allow_reuse_address = True


def shutdown_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    signal_name = signal.Signals(signum).name
    logger.info(f"Received {signal_name}, shutting down gracefully...")
    sys.exit(0)


def parse_args():
    """Parse command line arguments."""
    import argparse
    parser = argparse.ArgumentParser(description='Hello World Demo Application')
    parser.add_argument('--config', type=str,
                       default=os.path.join(APP_CONFIG_DIR, 'config.json'),
                       help='Path to configuration file')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT,
                       help=f'Port to listen on (default: {DEFAULT_PORT})')
    parser.add_argument('--host', type=str, default=DEFAULT_HOST,
                       help=f'Host to bind to (default: {DEFAULT_HOST})')
    return parser.parse_args()


def main():
    """Main entry point."""
    args = parse_args()

    # Setup signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    # Load configuration
    load_config(args.config)

    # Create data directories if they don't exist
    for dir_path in [APP_DATA_DIR, APP_CONFIG_DIR]:
        if not os.path.exists(dir_path):
            try:
                os.makedirs(dir_path, exist_ok=True)
                logger.info(f"Created directory: {dir_path}")
            except Exception as e:
                logger.warning(f"Could not create directory {dir_path}: {e}")

    # Start HTTP server
    server_address = (args.host, args.port)

    try:
        httpd = ReusableHTTPServer(server_address, HelloWorldHandler)
        logger.info(f"Hello World server starting on http://{args.host}:{args.port}")
        logger.info(f"Static files: {STATIC_DIR}")
        logger.info(f"Health check: http://{args.host}:{args.port}/health")
        httpd.serve_forever()
    except OSError as e:
        logger.error(f"Failed to start server: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
        sys.exit(0)


if __name__ == '__main__':
    main()
