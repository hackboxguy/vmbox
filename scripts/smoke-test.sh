#!/bin/bash
#
# smoke-test.sh - Quick validation of build configuration files
#
# Checks that package files are parseable, scripts have valid syntax,
# and source URLs are well-formed. Does NOT require root or a full build.
#
# Usage:
#   ./scripts/smoke-test.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Smoke Test ==="
echo ""

# 1. config.sh sources without error
echo "[1] config.sh"
if bash -n "${PROJECT_ROOT}/config.sh" 2>/dev/null; then
    pass "config.sh syntax OK"
else
    fail "config.sh has syntax errors"
fi

# 2. Shell script syntax (bash -n) on core scripts
echo "[2] Shell script syntax"
for script in \
    "${PROJECT_ROOT}/build.sh" \
    "${PROJECT_ROOT}/config.sh" \
    "${SCRIPT_DIR}/lib.sh" \
    "${SCRIPT_DIR}/chroot-helper.sh" \
    "${SCRIPT_DIR}/01-create-alpine-rootfs.sh" \
    "${SCRIPT_DIR}/02-build-packages.sh" \
    "${SCRIPT_DIR}/03-create-image.sh" \
    "${SCRIPT_DIR}/04-convert-to-vbox.sh" \
    "${SCRIPT_DIR}/build-app-partition.sh"; do
    name="$(basename "$script")"
    if [ ! -f "$script" ]; then
        fail "$name not found"
        continue
    fi
    if bash -n "$script" 2>/dev/null; then
        pass "$name"
    else
        fail "$name has syntax errors"
    fi
done

# 3. Python syntax check
echo "[3] Python syntax"
for pyfile in \
    "${PROJECT_ROOT}/rootfs/opt/app-manager/app-manager.py" \
    "${PROJECT_ROOT}/rootfs/opt/system-mgmt/app.py" \
    "${PROJECT_ROOT}/rootfs/opt/business-app/app.py"; do
    name="$(basename "$(dirname "$pyfile")")/$(basename "$pyfile")"
    if [ ! -f "$pyfile" ]; then
        fail "$name not found"
        continue
    fi
    if python3 -m py_compile "$pyfile" 2>/dev/null; then
        pass "$name"
    else
        fail "$name has syntax errors"
    fi
done

# 4. packages.txt parsing
echo "[4] packages.txt format"
PACKAGES_FILE="${PROJECT_ROOT}/packages.txt"
if [ ! -f "$PACKAGES_FILE" ]; then
    fail "packages.txt not found"
else
    line_num=0
    pkg_count=0
    parse_errors=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Count fields (expect 9 pipe-separated)
        field_count=$(echo "$line" | awk -F'|' '{print NF}')
        if [ "$field_count" -lt 6 ]; then
            fail "packages.txt:${line_num} has $field_count fields (expected >= 6)"
            parse_errors=$((parse_errors + 1))
        else
            pkg_count=$((pkg_count + 1))
        fi

        # Validate source URL format
        source_url=$(echo "$line" | cut -d'|' -f2)
        if [ -n "$source_url" ]; then
            case "$source_url" in
                https://*|http://*|file://*) ;;
                *) fail "packages.txt:${line_num} invalid source URL: $source_url"
                   parse_errors=$((parse_errors + 1)) ;;
            esac
        fi
    done < "$PACKAGES_FILE"

    if [ "$parse_errors" -eq 0 ]; then
        pass "packages.txt ($pkg_count packages parsed)"
    fi
fi

# 5. system-packages.txt parsing
echo "[5] system-packages.txt format"
SYSPKG_FILE="${PROJECT_ROOT}/system-packages.txt"
if [ ! -f "$SYSPKG_FILE" ]; then
    fail "system-packages.txt not found"
else
    line_num=0
    pkg_count=0
    parse_errors=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        field_count=$(echo "$line" | awk -F'|' '{print NF}')
        if [ "$field_count" -lt 4 ]; then
            fail "system-packages.txt:${line_num} has $field_count fields (expected >= 4)"
            parse_errors=$((parse_errors + 1))
        else
            pkg_count=$((pkg_count + 1))
        fi

        source_url=$(echo "$line" | cut -d'|' -f2)
        if [ -n "$source_url" ]; then
            case "$source_url" in
                https://*|http://*|file://*) ;;
                *) fail "system-packages.txt:${line_num} invalid source URL: $source_url"
                   parse_errors=$((parse_errors + 1)) ;;
            esac
        fi
    done < "$SYSPKG_FILE"

    if [ "$parse_errors" -eq 0 ]; then
        pass "system-packages.txt ($pkg_count packages parsed)"
    fi
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
