"""Loopback contract tests for the system-management application proxy."""

from __future__ import annotations

import importlib.util
import json
import logging
import sys
import tempfile
import types
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
# the configurator's own manifest (submodule at the pinned tag) carries its proxy limits
SBD_MANIFEST = ROOT / "apps/text-to-block/manifest.template.json"


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

    def do_DELETE(self):
        self.send_response(204)
        self.end_headers()

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
        # crypt left the standard library in Python 3.13; the VM's Python still has it
        stub = {} if importlib.util.find_spec("crypt") else {"crypt": types.ModuleType("crypt")}
        with mock.patch("logging.handlers.RotatingFileHandler", lambda *_args, **_kwargs: logging.NullHandler()), \
                mock.patch.dict(sys.modules, stub):
            spec.loader.exec_module(cls.module)
        cls.module.app.config.update(TESTING=True, SECRET_KEY="test-secret")
        cls.backend = ThreadingHTTPServer(("127.0.0.1", 0), _Backend)
        cls.module.get_app_ports = lambda: {"fpga-flasher-webapp": cls.backend.server_port,
                                            "sbd-configurator": cls.backend.server_port,
                                            "zz-no-manifest": cls.backend.server_port}
        # /app/<name>/manifest.json as the image installs them
        cls.app_root = tempfile.TemporaryDirectory()
        cls.module.APP_DIR_ROOT = cls.app_root.name
        manifest = json.loads(SBD_MANIFEST.read_text().replace("@PROJECT_NAME@", "sbd-configurator")
                              .replace("@SBD_VERSION@", "test"))
        cls.write_manifest("sbd-configurator", manifest)
        cls.write_manifest("zz-huge", {"name": "zz-huge", "proxy": {"limits": [
            {"prefix": "/api/huge", "max_body_mb": 10 ** 7, "timeout_s": 86400},
            {"prefix": "/api/", "max_body_mb": 2, "timeout_s": 60}]}})
        cls.thread = Thread(target=cls.backend.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def write_manifest(cls, name, manifest):
        Path(cls.app_root.name, name).mkdir()
        Path(cls.app_root.name, name, "manifest.json").write_text(json.dumps(manifest))
        cls.module._app_proxy_cache.clear()

    @classmethod
    def tearDownClass(cls):
        cls.backend.shutdown()
        cls.thread.join()
        cls.backend.server_close()
        cls.app_root.cleanup()

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

    def test_sbd_photo_and_user_data_uploads_pass_above_the_default_limit(self):
        big = b"y" * (self.module.APP_PROXY_DEFAULT_MAX_BODY_BYTES + 4096)
        for path in ("/app/sbd-configurator/api/photos/board-x?subject=board&side=front",
                     "/app/sbd-configurator/api/user-data", "/app/sbd-configurator/api/user-data?overwrite=1"):
            response = self.authenticated_client().post(path, data=big, headers={"Content-Type": "application/zip"})
            self.assertEqual(response.status_code, 201, path)
            self.assertEqual(response.data, b'{"streamed":true}')
            self.assertEqual(_Backend.received["body"], big)

    def test_bodyless_delete_without_content_length_is_forwarded(self):
        client = self.authenticated_client()
        response = client.open("/app/sbd-configurator/api/profiles/x", method="DELETE",
                               environ_overrides={"CONTENT_LENGTH": ""})
        self.assertEqual(response.status_code, 204)
        response.close()

    def test_chunked_write_without_length_is_refused(self):
        response = self.authenticated_client().post(
            "/app/sbd-configurator/api/compose", data=b"x",
            headers={"Transfer-Encoding": "chunked"}, environ_overrides={"CONTENT_LENGTH": ""})
        self.assertEqual(response.status_code, 411)
        response.close()

    def test_sbd_other_writes_keep_the_default_limit(self):
        big = b"y" * (self.module.APP_PROXY_DEFAULT_MAX_BODY_BYTES + 1)
        for path in ("/app/sbd-configurator/api/compose", "/app/sbd-configurator/api/user-data-x",
                     "/app/sbd-configurator/api/photos"):
            response = self.authenticated_client().post(path, data=big, headers={"Content-Type": "application/json"})
            self.assertEqual(response.status_code, 413, path)
            response.close()

    def test_limits_default_without_a_matching_prefix(self):
        m = self.module
        default = (m.APP_PROXY_DEFAULT_MAX_BODY_BYTES, m.APP_PROXY_DEFAULT_TIMEOUT_SECONDS)
        self.assertEqual(m._proxy_limits("sbd-configurator", "/api/compose"), default)
        self.assertEqual(m._proxy_limits("sbd-configurator", "/api/user-data-x"), default)
        self.assertEqual(m._proxy_limits("sbd-configurator", "/api/photos"), default)

    def test_limits_from_the_manifest_first_match_wins(self):
        m = self.module
        mb = 1024 * 1024
        self.assertEqual(m._proxy_limits("sbd-configurator", "/api/photos/board-x?side=front"), (512 * mb, 300))
        self.assertEqual(m._proxy_limits("sbd-configurator", "/api/user-data?overwrite=1"), (512 * mb, 300))
        self.assertEqual(m._proxy_limits("zz-huge", "/api/other"), (2 * mb, 60))

    def test_limits_are_capped_by_the_ceiling(self):
        m = self.module
        self.assertEqual(m._proxy_limits("zz-huge", "/api/huge"),
                         (m.APP_PROXY_MAX_ALLOWED_BODY_BYTES, m.APP_PROXY_MAX_ALLOWED_TIMEOUT_SECONDS))
        self.assertEqual(m.APP_PROXY_MAX_ALLOWED_BODY_BYTES, 4 * 1024 ** 3)
        self.assertEqual(m.APP_PROXY_MAX_ALLOWED_TIMEOUT_SECONDS, 600)

    def test_missing_manifest_keeps_the_default_limit(self):
        m = self.module
        big = b"y" * (m.APP_PROXY_DEFAULT_MAX_BODY_BYTES + 1)
        self.assertEqual(m._proxy_limits("zz-no-manifest", "/api/photos/x"),
                         (m.APP_PROXY_DEFAULT_MAX_BODY_BYTES, m.APP_PROXY_DEFAULT_TIMEOUT_SECONDS))
        response = self.authenticated_client().post("/app/zz-no-manifest/api/photos/x", data=big,
                                                    headers={"Content-Type": "application/zip"})
        self.assertEqual(response.status_code, 413)
        response.close()
        # an app built elsewhere without a "proxy" entry keeps its built-in limits (FPGA flasher)
        self.assertEqual(m._proxy_limits("fpga-flasher-webapp", "/api/v1/artifacts"), (32 * 1024 * 1024, 300))

    def test_session_cookie_is_named_after_the_appliance(self):
        m = self.module
        with tempfile.NamedTemporaryFile("w", suffix="hostname") as f:
            f.write("sbd-configurator\n")
            f.flush()
            self.assertEqual(m._session_cookie_name(f.name), "session-sbd-configurator")
        self.assertEqual(m._session_cookie_name("/nonexistent/hostname"), "session")
        with mock.patch.dict(m.app.config, {"SESSION_COOKIE_NAME": "session-sbd-configurator"}), \
                mock.patch.object(m, "verify_shadow_password", lambda user, password: True):
            response = m.app.test_client().post("/login", data={"username": "admin", "password": "x"})
            self.assertEqual(response.status_code, 302)
            cookies = response.headers.getlist("Set-Cookie")
            self.assertTrue(any(c.startswith("session-sbd-configurator=") for c in cookies), cookies)

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
