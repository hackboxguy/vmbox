#!/bin/sh
# Runtime of the partkb converter (partkb VM plan §7.1): Python with PyMuPDF (PDF text, ds requirement >= 1.24),
# httpx (Azure OpenAI client), PyYAML, jsonschema, Pillow (page images), git (data/ is a local git repository, D7)
# and sqlite (index).
#
# PyMuPDF: Alpine 3.21 has no py3-pymupdf (only edge/testing, masked here, and it needs edge's libmupdf), so the
# pinned PyMuPDF musllinux wheel is installed with pip, binary only. PyMuPDF 2.0 ships no musllinux wheel (sdist
# only, and the source build fails in this chroot); 1.28.2 is the newest with one (abi3, ~26 MB download,
# installed 65 MB).
# Verified 2026-10-25 in the converter build chroot (Python 3.12.15).
set -eu

# git is also one of the image's build packages, which scripts/02-build-packages.sh removes after the hooks: list it
# as a runtime package so it stays (the converter's data/ is a git repository).
mkdir -p /etc/vmbox
for p in git sqlite py3-pillow; do
    grep -qx "$p" /etc/vmbox/runtime-packages 2>/dev/null || echo "$p" >> /etc/vmbox/runtime-packages
done

apk add --no-cache \
    python3 \
    py3-pip \
    py3-yaml \
    py3-httpx \
    py3-jsonschema \
    py3-pillow \
    git \
    sqlite

# pymupdf==1.28.2 pinned by the wheel's SHA-256 in partkb-runtime-dependencies-hook-requirements.txt (copied next to
# this hook into the chroot by scripts/02-build-packages.sh)
pip3 install --no-cache-dir --break-system-packages --only-binary=:all: --require-hashes \
    -r /tmp/partkb-runtime-dependencies-hook-requirements.txt

python3 - <<'PY'
import httpx, jsonschema, pymupdf, sqlite3, yaml, PIL
print("partkb runtime imports ok: pymupdf", pymupdf.VersionBind, "pillow", PIL.__version__, "httpx", httpx.__version__, "jsonschema",
      jsonschema.__version__ if hasattr(jsonschema, "__version__") else "?", "yaml", yaml.__version__,
      "sqlite", sqlite3.sqlite_version)
assert tuple(int(x) for x in pymupdf.VersionBind.split(".")[:2]) >= (1, 24), "PyMuPDF < 1.24"
PY
