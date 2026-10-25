"""The optional per-app env file /data/app-config/<app>/env (scripts/app-env-file.sh) and its place in the generated
startup script (scripts/build-app-partition.sh generate_startup_script): after the manifest env, never evaluated."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from unittest import TestCase, main

ROOT = Path(__file__).resolve().parents[1]
SNIPPET = ROOT / "scripts/app-env-file.sh"
BUILDER = ROOT / "scripts/build-app-partition.sh"


class AppEnvFileTests(TestCase):
    def run_snippet(self, text: str | None, extra_env: dict | None = None) -> tuple[dict, str, Path]:
        d = Path(tempfile.mkdtemp())
        if text is not None:
            (d / "env").write_text(text)
        env = {"PATH": os.environ["PATH"], "APP_CONFIG_DIR": str(d), **(extra_env or {})}
        r = subprocess.run(["sh", "-c", f". '{SNIPPET}'; env -0"], cwd=d, env=env, capture_output=True, check=True)
        out = dict(x.split("=", 1) for x in r.stdout.decode().split("\0") if "=" in x)
        return out, r.stderr.decode(), d

    def test_key_value_lines_are_exported_literally(self):
        env, err, d = self.run_snippet(
            "# overlay on\n\nSBD_LIBRARY_OVERLAY_DIR=/data/app-data/sbd-configurator/library-overlay\n"
            "WITH_SPACES=a b  c\nEQUALS=x=y\nDOLLAR=$HOME/$(touch pwned)`touch pwned2`\nQUOTED=\"kept\"\nNO_NEWLINE=end")
        self.assertEqual(env["SBD_LIBRARY_OVERLAY_DIR"], "/data/app-data/sbd-configurator/library-overlay")
        self.assertEqual(env["WITH_SPACES"], "a b  c")
        self.assertEqual(env["EQUALS"], "x=y")
        self.assertEqual(env["DOLLAR"], "$HOME/$(touch pwned)`touch pwned2`")
        self.assertEqual(env["QUOTED"], '"kept"')
        self.assertEqual(env["NO_NEWLINE"], "end")
        self.assertFalse((d / "pwned").exists() or (d / "pwned2").exists(), "the env file was evaluated")
        self.assertEqual(err, "")

    def test_invalid_lines_are_skipped_with_a_message(self):
        env, err, _ = self.run_snippet("BAD-KEY=1\n9LEADING=2\nno equals sign\n=empty\nGOOD=3\n")
        self.assertEqual(env.get("GOOD"), "3")
        self.assertNotIn("BAD-KEY", env)
        self.assertNotIn("9LEADING", env)
        self.assertEqual(err.count("skipping"), 4)

    def test_overrides_the_manifest_env_and_no_file_changes_nothing(self):
        env, _, _ = self.run_snippet("SBD_PORT=9999\n", {"SBD_PORT": "8008"})
        self.assertEqual(env["SBD_PORT"], "9999")
        env, err, _ = self.run_snippet(None, {"SBD_PORT": "8008"})
        self.assertEqual(env["SBD_PORT"], "8008")
        self.assertEqual(err, "")

    def test_generated_startup_script_applies_it_after_the_manifest_env(self):
        staging = Path(tempfile.mkdtemp())
        fn = subprocess.run(["sed", "-n", "/^generate_startup_script()/,/^}/p", str(BUILDER)],
                            capture_output=True, text=True, check=True).stdout
        subprocess.run(["bash", "-c", f"info() {{ :; }}; {fn}\ngenerate_startup_script demo-app 30 9000"],
                       env={"PATH": os.environ["PATH"], "APP_STAGING": str(staging), "SCRIPT_DIR": str(ROOT / "scripts")},
                       check=True)
        script = (staging / "app/startup.d/30-demo-app.sh").read_text()
        self.assertNotIn("@APP_ENV_FILE@", script)
        self.assertIn('APP_ENV_FILE="${APP_CONFIG_DIR}/env"', script)
        self.assertLess(script.index('eval "$MANIFEST_ENV"'), script.index('APP_ENV_FILE="${APP_CONFIG_DIR}/env"'))
        self.assertLess(script.index('APP_ENV_FILE="${APP_CONFIG_DIR}/env"'), script.index("# Start application"))
        subprocess.run(["sh", "-n", str(staging / "app/startup.d/30-demo-app.sh")], check=True)


if __name__ == "__main__":
    main()
