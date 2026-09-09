#!/usr/bin/env bash
# ==============================================================================
# build-devbox-bootstrap.sh
# Builds DevBox (com.devbox.terminal) ARM64 bootstrap archive from source.
# Ensures all bootstrap dependencies are compiled for com.devbox.terminal
# rather than downloaded from official Termux deb repositories.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    DEVBOX_APP_PACKAGE="com.devbox.terminal"
    DEVBOX_ARCH="aarch64"
    FORCE_REBUILD=1
fi

REPOROOT="${1:-.}"
REPOROOT="$(realpath "${REPOROOT}")"
OUTPUT_DIR="${REPOROOT}/output"
BOOTSTRAP_ZIP="${REPOROOT}/bootstrap-${DEVBOX_ARCH}.zip"

echo "============================================================"
echo " DevBox Bootstrap Archive Source Builder"
echo " Target Package:  ${DEVBOX_APP_PACKAGE}"
echo " Target Arch:     ${DEVBOX_ARCH} (ARM64)"
echo " Build Directory: ${REPOROOT}"
echo "============================================================"

# Ensure DevBox identity is applied before build
"${SCRIPT_DIR}/apply-devbox-identity.sh" "${REPOROOT}"

# Explicitly ensure dependency downloading is disabled
unset TERMUX_INSTALL_DEPS || true
export TERMUX_INSTALL_DEPS="false"

# Build arguments for build-bootstraps.sh
# -f forces build of packages even if previously built
# --architectures restricts build to ARM64 (aarch64)
# Note: NEVER pass -i or -I to ensure source compilation of all dependencies
BUILD_BOOTSTRAP_ARGS=("--architectures" "${DEVBOX_ARCH}")
if [[ "${FORCE_REBUILD}" == "1" ]]; then
    BUILD_BOOTSTRAP_ARGS+=("-f")
fi

echo "[*] Invoking scripts/build-bootstraps.sh ${BUILD_BOOTSTRAP_ARGS[*]}..."
cd "${REPOROOT}"

# Execute build-bootstraps.sh
./scripts/build-bootstraps.sh "${BUILD_BOOTSTRAP_ARGS[@]}"

# Verify bootstrap zip generation
if [[ ! -f "${BOOTSTRAP_ZIP}" ]]; then
    echo "[-] ERROR: Expected bootstrap archive not found at ${BOOTSTRAP_ZIP}" >&2
    exit 1
fi

echo "[+] Successfully created: ${BOOTSTRAP_ZIP} ($(du -h "${BOOTSTRAP_ZIP}" | cut -f1))"

# Run verification and generate checksums
echo "[*] Verifying prefix and symbols in bootstrap archive..."
"${SCRIPT_DIR}/verify-bootstrap-prefix.sh" "${BOOTSTRAP_ZIP}"

echo "============================================================"
echo " DevBox Bootstrap Build Completed Successfully"
echo " Archive:  ${BOOTSTRAP_ZIP}"
echo " Checksum: $(cat "${BOOTSTRAP_ZIP}.sha256" 2>/dev/null || sha256sum "${BOOTSTRAP_ZIP}")"
echo "============================================================"
