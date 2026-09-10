#!/usr/bin/env bash
# ==============================================================================
# apply-devbox-identity.sh
# Configures termux-packages tree with DevBox (com.devbox.terminal) identity
# and validates derived path properties.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    DEVBOX_APP_NAME="DevBox"
    DEVBOX_APP_PACKAGE="com.devbox.terminal"
    DEVBOX_APP_NAMESPACE="com.devbox.terminal"
    DEVBOX_PREFIX="/data/data/com.devbox.terminal/files/usr"
fi

TARGET_DIR="${1:-.}"
TARGET_DIR="$(realpath "${TARGET_DIR}")"
PROPERTIES_FILE="${TARGET_DIR}/scripts/properties.sh"

echo "[*] Applying DevBox identity to: ${TARGET_DIR}"

if [[ ! -f "${PROPERTIES_FILE}" ]]; then
    echo "[-] ERROR: properties.sh not found at ${PROPERTIES_FILE}" >&2
    exit 1
fi

# Create backup of original properties.sh
if [[ ! -f "${PROPERTIES_FILE}.orig" ]]; then
    cp -p "${PROPERTIES_FILE}" "${PROPERTIES_FILE}.orig"
fi

# Replace default Termux branding and package identity
python3 - <<PY
import sys

props_path = "${PROPERTIES_FILE}"
with open(props_path, "r", encoding="utf-8") as f:
    content = f.read()

replacements = [
    ('TERMUX__NAME="Termux"', 'TERMUX__NAME="${DEVBOX_APP_NAME}"'),
    ('TERMUX_APP__PACKAGE_NAME="com.termux"', 'TERMUX_APP__PACKAGE_NAME="${DEVBOX_APP_PACKAGE}"'),
    ('TERMUX_APP__NAMESPACE="com.termux"', 'TERMUX_APP__NAMESPACE="${DEVBOX_APP_NAMESPACE}"'),
    ('TERMUX_REPO_APP__PACKAGE_NAME="com.termux"', 'TERMUX_REPO_APP__PACKAGE_NAME="${DEVBOX_APP_PACKAGE}"'),
    ('TERMUX_REPO_APP__DATA_DIR="/data/data/com.termux"', 'TERMUX_REPO_APP__DATA_DIR="/data/data/${DEVBOX_APP_PACKAGE}"'),
    ('TERMUX_REPO__CORE_DIR="/data/data/com.termux/termux/core"', 'TERMUX_REPO__CORE_DIR="/data/data/${DEVBOX_APP_PACKAGE}/termux/core"'),
    ('TERMUX_REPO__APPS_DIR="/data/data/com.termux/termux/app"', 'TERMUX_REPO__APPS_DIR="/data/data/${DEVBOX_APP_PACKAGE}/termux/app"'),
    ('TERMUX_REPO__ROOTFS="/data/data/com.termux/files"', 'TERMUX_REPO__ROOTFS="/data/data/${DEVBOX_APP_PACKAGE}/files"'),
    ('TERMUX_REPO__HOME="/data/data/com.termux/files/home"', 'TERMUX_REPO__HOME="/data/data/${DEVBOX_APP_PACKAGE}/files/home"'),
    ('TERMUX_REPO__PREFIX="/data/data/com.termux/files/usr"', 'TERMUX_REPO__PREFIX="/data/data/${DEVBOX_APP_PACKAGE}/files/usr"'),
    ('CGCT_DEFAULT_PREFIX="/data/data/com.termux/files/usr/glibc"', 'CGCT_DEFAULT_PREFIX="/data/data/${DEVBOX_APP_PACKAGE}/files/usr/glibc"'),
    ('export CGCT_DIR="/data/data/com.termux/cgct"', 'export CGCT_DIR="/data/data/${DEVBOX_APP_PACKAGE}/cgct"'),
]

for old, new in replacements:
    if old in content:
        content = content.replace(old, new)
        print(f"  [+] Replaced: {old} -> {new}")
    else:
        print(f"  [!] Warning: pattern not found: {old}")

with open(props_path, "w", encoding="utf-8") as f:
    f.write(content)

print("[*] Successfully updated properties.sh")
PY

# Safe-guard build-bootstraps.sh against empty/unset variable deletion in container
# and replace subshell memory-leaking variable capture with a temporary log file
BOOTSTRAPS_SCRIPT="${TARGET_DIR}/scripts/build-bootstraps.sh"
if [[ -f "${BOOTSTRAPS_SCRIPT}" ]]; then
    python3 - "${BOOTSTRAPS_SCRIPT}" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# Replace unconditional variable expansion rm -f with safe non-empty directory checks
text = text.replace(
    'rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH"/*',
    'if [[ -n "${TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH:-}" && -d "${TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH}" ]]; then rm -f "${TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH}"/*; fi'
)
text = text.replace(
    'rm -f "$TERMUX_BUILT_DEBS_DIRECTORY"/*',
    'if [[ -n "${TERMUX_BUILT_DEBS_DIRECTORY:-}" && -d "${TERMUX_BUILT_DEBS_DIRECTORY}" ]]; then rm -f "${TERMUX_BUILT_DEBS_DIRECTORY}"/*; fi'
)

# Replace memory-exhausting subshell build_output=$(...) with log-file tee
old_build_block = """\texec 99>&1
\tbuild_output="$("$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" -a "$TERMUX_ARCH" "$package_name" 2>&1 | tee >(cat - >&99); exit ${PIPESTATUS[0]})";
\treturn_value=$?
\techo "[*] Building \'$package_name\' exited with exit code $return_value"
\texec 99>&-
\tif [ $return_value -ne 0 ]; then
\t\techo "Failed to build package \'$package_name\' for arch \'$TERMUX_ARCH\'" 1>&2

\t\t# Dependency packages may not have a build.sh, so we ignore the error.
\t\t# A better way should be implemented to validate if its actually a dependency
\t\t# and not a required package itself, by removing dependencies from PACKAGES array.
\t\tif [[ $IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR == "1" ]] && [[ "$build_output" == *"No build.sh script at package dir"* ]]; then"""

new_build_block = """\tlocal _build_log="/tmp/termux_pkg_build.log"
\tset +e
\t"$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" -a "$TERMUX_ARCH" "$package_name" 2>&1 | tee "$_build_log"
\treturn_value=${PIPESTATUS[0]}
\tset -e
\techo "[*] Building \'$package_name\' exited with exit code $return_value"
\tif [ $return_value -ne 0 ]; then
\t\techo "Failed to build package \'$package_name\' for arch \'$TERMUX_ARCH\'" 1>&2

\t\tif [[ $IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR == "1" ]] && grep -q "No build.sh script at package dir" "$_build_log" 2>/dev/null; then"""

if old_build_block in text:
    text = text.replace(old_build_block, new_build_block)
    print("[*] Successfully patched build_package subshell memory leak")
else:
    print("[!] Warning: old_build_block not found in build-bootstraps.sh")

# Fix typo in upstream build-bootstraps.sh: bzip2 package is named libbz2 in termux-packages
text = text.replace(
    'PACKAGES+=("bzip2")',
    'PACKAGES+=("libbz2")'
)
print("[*] Replaced PACKAGES+=(\"bzip2\") with PACKAGES+=(\"libbz2\")")

# The restricted builder permits writes only under output/, not the checkout root.
# Explicitly propagate failures: callers using `function || return` disable errexit
# inside the function, even when the script has set -e.
old_archive = '''\t\tzip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./*
\t)

\tmv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "$TERMUX_PACKAGES_DIRECTORY/"'''
new_archive = '''\t\tzip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./* || return $?
\t) || return $?

\tlocal destination="$TERMUX_PACKAGES_DIRECTORY/output/bootstrap-${1}.zip"
\tmkdir -p "$TERMUX_PACKAGES_DIRECTORY/output" || return $?
\tmv -- "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "$destination" || return $?
\ttest -s "$destination" || return 1'''
if text.count(old_archive) == 1:
    text = text.replace(old_archive, new_archive)
elif new_archive not in text:
    raise SystemExit("Bootstrap archive output patch did not match pinned source; refusing build")

with open(path, "w", encoding="utf-8") as f:
    f.write(text)

print("[*] Successfully safeguarded scripts/build-bootstraps.sh")
PY
fi

# Validate updated properties.sh by executing in subshell
echo "[*] Validating updated properties.sh derivation rules..."
(
    cd "${TARGET_DIR}"
    export TERMUX_SCRIPTDIR="${TARGET_DIR}"
    # shellcheck source=/dev/null
    source "${PROPERTIES_FILE}"

    echo "    TERMUX__NAME:           ${TERMUX__NAME}"
    echo "    TERMUX_APP__PACKAGE_NAME: ${TERMUX_APP__PACKAGE_NAME}"
    echo "    TERMUX_APP__DATA_DIR:   ${TERMUX_APP__DATA_DIR}"
    echo "    TERMUX__ROOTFS:         ${TERMUX__ROOTFS}"
    echo "    TERMUX__PREFIX:         ${TERMUX__PREFIX}"
    echo "    TERMUX_PREFIX:          ${TERMUX_PREFIX}"
    echo "    TERMUX_ANDROID_HOME:    ${TERMUX_ANDROID_HOME}"

    if [[ "${TERMUX_APP__PACKAGE_NAME}" != "${DEVBOX_APP_PACKAGE}" ]]; then
        echo "[-] ERROR: Package name mismatch! Expected '${DEVBOX_APP_PACKAGE}', got '${TERMUX_APP__PACKAGE_NAME}'" >&2
        exit 1
    fi

    if [[ "${TERMUX__PREFIX}" != "${DEVBOX_PREFIX}" ]]; then
        echo "[-] ERROR: Prefix mismatch! Expected '${DEVBOX_PREFIX}', got '${TERMUX__PREFIX}'" >&2
        exit 1
    fi

    if [[ "${TERMUX_PREFIX}" != "${DEVBOX_PREFIX}" ]]; then
        echo "[-] ERROR: Deprecated TERMUX_PREFIX mismatch! Expected '${DEVBOX_PREFIX}', got '${TERMUX_PREFIX}'" >&2
        exit 1
    fi

    if [[ "${TERMUX_APP__DATA_DIR}" != "${DEVBOX_DATA_DIR}" ]]; then
        echo "[-] ERROR: Data dir mismatch! Expected '${DEVBOX_DATA_DIR}', got '${TERMUX_APP__DATA_DIR}'" >&2
        exit 1
    fi
)

echo "[+] DevBox identity applied and verified successfully."
