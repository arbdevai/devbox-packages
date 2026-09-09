#!/usr/bin/env bash
# ==============================================================================
# verify-bootstrap-prefix.sh
# Validates DevBox (com.devbox.terminal) bootstrap archive integrity,
# verifies prefix path separation from com.termux, and generates checksums.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    DEVBOX_APP_PACKAGE="com.devbox.terminal"
    DEVBOX_PREFIX="/data/data/com.devbox.terminal/files/usr"
    DEVBOX_ARCH="aarch64"
fi

ZIP_FILE="${1:-}"

if [[ -z "${ZIP_FILE}" || ! -f "${ZIP_FILE}" ]]; then
    echo "[-] ERROR: Bootstrap archive file not specified or not found: '${ZIP_FILE}'" >&2
    echo "Usage: $0 <path-to-bootstrap-arch.zip>" >&2
    exit 1
fi

ZIP_FILE="$(realpath "${ZIP_FILE}")"
ZIP_DIR="$(dirname "${ZIP_FILE}")"
ZIP_NAME="$(basename "${ZIP_FILE}")"

echo "[*] Inspecting bootstrap archive: ${ZIP_NAME}"

TMP_VERIFY_DIR="$(mktemp -d "/tmp/devbox-verify-XXXXXX")"
trap 'rm -rf "${TMP_VERIFY_DIR}"' EXIT

unzip -q "${ZIP_FILE}" -d "${TMP_VERIFY_DIR}"

# 1. Verify SYMLINKS.txt
echo "[*] Checking SYMLINKS.txt..."
if [[ ! -f "${TMP_VERIFY_DIR}/SYMLINKS.txt" ]]; then
    echo "[-] ERROR: SYMLINKS.txt missing from bootstrap archive!" >&2
    exit 1
fi

SYMLINK_COUNT="$(wc -l < "${TMP_VERIFY_DIR}/SYMLINKS.txt")"
echo "    Found ${SYMLINK_COUNT} symlink mappings."
if [[ "${SYMLINK_COUNT}" -eq 0 ]]; then
    echo "[-] ERROR: SYMLINKS.txt is empty!" >&2
    exit 1
fi

# 2. Verify critical executables
echo "[*] Checking essential binaries..."
CRITICAL_FILES=(
    "bin/bash"
    "bin/dash"
    "bin/dpkg"
    "bin/apt"
    "etc/apt/sources.list"
    "var/lib/dpkg/status"
)

MISSING_COUNT=0
for cf in "${CRITICAL_FILES[@]}"; do
    if [[ ! -f "${TMP_VERIFY_DIR}/${cf}" ]]; then
        echo "    [!] Warning: ${cf} not found as regular file (may be symlink)."
    else
        echo "    [+] Found ${cf}"
    fi
done

# 3. Check for forbidden com.termux strings in text files and ELF binaries
echo "[*] Checking for forbidden 'com.termux' contamination..."
CONTAMINATION_FOUND=0

# Check dpkg status and conffiles
if [[ -f "${TMP_VERIFY_DIR}/var/lib/dpkg/status" ]]; then
    if grep -q "com.termux" "${TMP_VERIFY_DIR}/var/lib/dpkg/status" 2>/dev/null; then
        echo "[-] ERROR: Found 'com.termux' references in var/lib/dpkg/status!" >&2
        grep -n "com.termux" "${TMP_VERIFY_DIR}/var/lib/dpkg/status" | head -n 10 >&2
        CONTAMINATION_FOUND=1
    fi
fi

# Check binaries if strings utility is available
if command -v strings >/dev/null 2>&1; then
    for bin_file in "${TMP_VERIFY_DIR}/bin/bash" "${TMP_VERIFY_DIR}/bin/dpkg" "${TMP_VERIFY_DIR}/bin/apt"; do
        if [[ -f "${bin_file}" ]]; then
            if strings "${bin_file}" | grep -q "/data/data/com.termux"; then
                echo "[-] ERROR: Hardcoded '/data/data/com.termux' found in binary $(basename "${bin_file}")!" >&2
                CONTAMINATION_FOUND=1
            fi
            if strings "${bin_file}" | grep -q "${DEVBOX_PREFIX}"; then
                echo "    [+] Confirmed ${DEVBOX_PREFIX} in $(basename "${bin_file}")"
            fi
        fi
    done
fi

if [[ "${CONTAMINATION_FOUND}" -ne 0 ]]; then
    echo "[-] ERROR: Bootstrap archive contains contaminated 'com.termux' paths!" >&2
    exit 1
fi

# 4. Extract package summary from dpkg/status
PACKAGES_INSTALLED=()
if [[ -f "${TMP_VERIFY_DIR}/var/lib/dpkg/status" ]]; then
    while IFS= read -r pkg; do
        PACKAGES_INSTALLED+=("${pkg}")
    done < <(grep "^Package: " "${TMP_VERIFY_DIR}/var/lib/dpkg/status" | cut -d' ' -f2 | sort -u)
fi

TOTAL_FILES="$(find "${TMP_VERIFY_DIR}" -type f | wc -l)"
ZIP_SIZE="$(stat -c %s "${ZIP_FILE}" 2>/dev/null || stat -f %z "${ZIP_FILE}")"
SHA256_HASH="$(sha256sum "${ZIP_FILE}" | cut -d' ' -f1)"

# 5. Write SHA256 file
echo "${SHA256_HASH}  ${ZIP_NAME}" > "${ZIP_FILE}.sha256"
echo "[+] Wrote checksum to: ${ZIP_FILE}.sha256 (${SHA256_HASH})"

# 6. Write JSON manifest
MANIFEST_FILE="${ZIP_DIR}/manifest.json"
python3 - <<PY
import json
from datetime import datetime, timezone

manifest = {
    "application_name": "${DEVBOX_APP_NAME:-DevBox}",
    "package_name": "${DEVBOX_APP_PACKAGE}",
    "prefix": "${DEVBOX_PREFIX}",
    "architecture": "${DEVBOX_ARCH}",
    "archive_file": "${ZIP_NAME}",
    "sha256": "${SHA256_HASH}",
    "size_bytes": ${ZIP_SIZE},
    "file_count": ${TOTAL_FILES},
    "symlink_count": ${SYMLINK_COUNT},
    "built_at": datetime.now(timezone.utc).isoformat(),
    "installed_packages": """${PACKAGES_INSTALLED[*]:-}""".split()
}

with open("${MANIFEST_FILE}", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)

print("[+] Wrote manifest to: ${MANIFEST_FILE}")
PY

echo "[+] Bootstrap archive verification PASSED."
