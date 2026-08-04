"""Loopback contract tests for the system-management application proxy."""

from __future__ import annotations

import importlib.util
import logging
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from unittest import TestCase, main, mock, skipUnless

try:
    import flask  # noqa: F401
except ImportError:
    flask = None


ROOT = Path(__file__).resolve().parents[1]
APP_PATH = ROOT / "rootfs/opt/system-mgmt/app.py"


class _Backend(BaseHTTPRequestHandler):
    received = {}

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        parts = []
        while sum(map(len, parts)) < length:
            parts.append(self.rfile.read(min(1024, length - sum(map(len, parts)))))
        type(self).received = {
            "body": b"".join(parts),
            "actor": self.headers.get("X-VMBOX-Actor"),
            "proxy": self.headers.get("X-VMBOX-System-Proxy"),
        }
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"streamed":')
        self.wfile.write(b"true}")

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/css; charset=utf-8")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(b":root { --fixture: 1; }")


@skipUnless(flask is not None, "Flask is available in the VMBOX rootfs, not this host checkout")
class SystemManagementProxyTests(TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("system_mgmt_test_app", APP_PATH)
        cls.module = importlib.util.module_from_spec(spec)
        with mock.patch("logging.handlers.RotatingFileHandler", lambda *_args, **_kwargs: logging.NullHandler()):
            spec.loader.exec_module(cls.module)
        cls.module.app.config.update(TESTING=True, SECRET_KEY="test-secret")
        cls.backend = ThreadingHTTPServer(("127.0.0.1", 0), _Backend)
        cls.module.get_app_ports = lambda: {"fpga-flasher-webapp": cls.backend.server_port}
        cls.thread = Thread(target=cls.backend.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.backend.shutdown()
        cls.thread.join()
        cls.backend.server_close()

    def authenticated_client(self):
        client = self.module.app.test_client()
        with client.session_transaction() as session:
            session["username"] = "operator@example.invalid"
            session["login_time"] = datetime.now().isoformat()
        return client

    def test_fpga_upload_streams_and_injects_proxy_identity(self):
        response = self.authenticated_client().post(
            "/app/fpga-flasher-webapp/api/v1/artifacts",
            data=b"x" * 8192,
            headers={
                "Content-Type": "application/octet-stream",
                "Origin": "http://localhost",
                "X-CSRF-Token": "test-token",
                "X-Requested-With": "XMLHttpRequest",
            },
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data, b'{"streamed":true}')
        self.assertEqual(_Backend.received["body"], b"x" * 8192)
        self.assertEqual(_Backend.received["actor"], "operator@example.invalid")
        self.assertEqual(_Backend.received["proxy"], "1")

    def test_fpga_write_rejects_missing_browser_contract_headers(self):
        response = self.authenticated_client().post(
            "/app/fpga-flasher-webapp/api/v1/artifacts", data=b"x"
        )
        self.assertEqual(response.status_code, 403)

    def test_proxy_preserves_a_single_backend_content_type_for_stylesheets(self):
        response = self.authenticated_client().get("/app/fpga-flasher-webapp/styles.css")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, b":root { --fixture: 1; }")
        self.assertEqual(response.headers.getlist("Content-Type"), ["text/css; charset=utf-8"])
        self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")


if __name__ == "__main__":
    main()
