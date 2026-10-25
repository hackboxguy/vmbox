"""scripts/02-build-packages.sh purge_build_deps: the build package set is removed after the hooks, except packages a
hook lists in /etc/vmbox/runtime-packages (the partkb converter needs git at runtime: found by the 0.1.0 boot test)."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from unittest import TestCase, main

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/02-build-packages.sh"


def purge(keep: str | None) -> str:
    rootfs = Path(tempfile.mkdtemp())
    if keep is not None:
        (rootfs / "etc/vmbox").mkdir(parents=True)
        (rootfs / "etc/vmbox/runtime-packages").write_text(keep)
    fn = subprocess.run(["sed", "-n", "/^purge_build_deps()/,/^}/p", str(SCRIPT)],
                        capture_output=True, text=True, check=True).stdout
    prog = f"""
log() {{ :; }}; info() {{ :; }}; warn() {{ :; }}
chroot_apk_del() {{ shift; echo "DEL $*"; }}
run_in_chroot() {{ :; }}
ALPINE_BUILD_PACKAGES=(build-base cmake g++ gcc git linux-headers make wget)
KEEP_BUILD_DEPS=false
{fn}
purge_build_deps
"""
    r = subprocess.run(["bash", "-c", prog], env={"PATH": os.environ["PATH"], "ROOTFS_DIR": str(rootfs)},
                       capture_output=True, text=True, check=True)
    return next(line[4:] for line in r.stdout.splitlines() if line.startswith("DEL "))


class PurgeBuildDepsTests(TestCase):
    def test_runtime_packages_of_a_hook_stay(self):
        removed = purge("git\nsqlite\npy3-pillow\n").split()
        self.assertNotIn("git", removed)
        self.assertEqual(removed, ["build-base", "cmake", "g++", "gcc", "linux-headers", "make", "wget"])

    def test_without_a_list_the_whole_build_set_goes(self):
        self.assertEqual(purge(None).split(), ["build-base", "cmake", "g++", "gcc", "git", "linux-headers", "make", "wget"])

    def test_the_partkb_hook_lists_its_runtime_packages(self):
        hook = (ROOT / "packages/partkb-runtime-dependencies-hook.sh").read_text()
        for pkg in ("git", "sqlite", "py3-pillow"):
            self.assertIn(pkg, hook.split("for p in ", 1)[1].split(";", 1)[0], pkg)


if __name__ == "__main__":
    main()
