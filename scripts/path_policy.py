#!/usr/bin/env python3
"""Shared foreign path policy for DevBox bootstrap verification.

Only rejects paths unless explicitly reviewed as non-runtime comments,
docs, examples, or scoped fixtures. Reviewed findings carry full context
and only apply to an exact path + exact SHA-256 pair. Any newer content
returns to hard rejection.
"""

from __future__ import annotations

import re

PACKAGE = "com.devbox.terminal"
SELF_CANDIDATE_PREFIX = b"/data/data/" + PACKAGE.encode()

# /data/data/X, /data/user/N/X and /data/user_de/N/X.
PATH_RE = re.compile(rb"/data/(?:data/|user(?:_de)?/[0-9]+/)([A-Za-z0-9_.-]+)")


class PolicyError(ValueError):
    pass


# Path and package scoped rules: only exact matching hashes may whitelist
# the specific foreign package for that member name.
REVIEWED_PACKAGES = {
    "bin/termux-exec-ld-preload-lib": (
        "ed7237f9fcf2126341da65e3237a14ab1f6ff35334b4e97d0506cf26bcb2b045",
        {b"com.termux"},
        "Example CANNOT LINK EXECUTABLE comment retains historical Termux path; shell operations do not use foreign path.",
    ),
    "include/termux-exec/termux/termux_exec__nos__c/v1/termux/api/termux_exec/service/ld_preload/direct/exec/ExecIntercept.h": (
        "1d22ff61481babbd865eb74270966b3d040637f799d5bdb8a170c11bc0dd81bf",
        {b"com.termux"},
        "Doxygen comments of historical linker truncation behavior; not compiled path constants.",
    ),
    "include/termux-exec/termux/termux_exec__nos__c/v1/termux/api/termux_exec/service/ld_preload/TermuxExecLDPreload.h": (
        "f60f346b051183c50ff39caa1ea94a0cca07e8088bf28b5c7f176c55fc103ce8",
        {b"com.android.shell"},
        "Commentary for system com.android.shell examples; not bundled runtime path.",
    ),
    "lib/perl5/5.42.2/pod/perlandroid.pod": (
        "78b29f75200e65f585ed2184101d9aa471132ab49a81691b748c20d8eda906ba",
        {b"com.pdaxrom.cctools"},
        "Third-party toolchain documentation example.",
    ),
    "libexec/installed-tests/termux-core/lib/termux-core_nos_c/tre/bin/libtermux-core_nos_c_tre_unit-binary-tests-fsanitize": (
        "ead3b9201d248c7af1bf30ef0256f6769d59e997c2fc1b31eda4fd5db37f7fa4",
        {b"com.foo"},
        "Unit-test fixture uses intentionally bogus com.foo identity.",
    ),
    "libexec/installed-tests/termux-core/lib/termux-core_nos_c/tre/bin/libtermux-core_nos_c_tre_unit-binary-tests-nofsanitize": (
        "7f8319cee25ad650868eaeb31f69be66484801d1d34e7af242596a8cc5766b40",
        {b"com.foo"},
        "Unit-test fixture uses intentionally bogus com.foo identity.",
    ),
    "libexec/installed-tests/termux-core/app/main/scripts/termux/shell/command/environment/termux-shell-command-environment_runtime-script-tests": (
        "79fcb9bd68963cacce5aea4c78a86f2a5b2d78b8c3af9733dfcae991997166ba",
        {b"com.foo"},
        "Unit-test fixture uses intentionally bogus com.foo identity.",
    ),
    "share/examples/termux/termux.properties": (
        "89094537f49531dc9b380a0dec3a441b2fb92577e0a4f1db505790eb8b7025b0",
        {b"com.termux"},
        "Commented default in example properties file.",
    ),
}


def process(data: bytes, name: str, sha256: str) -> list[str]:
    """Inspect all foreign path matches; only exact hash+package exceptions pass."""
    labels = []
    name = name or ""
    allowed_packages = set()
    rule = REVIEWED_PACKAGES.get(name)
    if rule is not None and rule[0] == sha256:
        allowed_packages = rule[1]
        labels.append(f"REVIEWED NON-RUNTIME ALLOWLIST APPLIED to {name}: {rule[2]}")

    for match in PATH_RE.finditer(data):
        package = match.group(1)
        if package == PACKAGE.encode():
            continue
        if package in allowed_packages:
            continue
        raise PolicyError(f"Foreign application data path in {name}: {match.group(0)!r}")
    return labels


def inspect_paths(data: bytes, name: str = "") -> list[str]:
    """Compute member hash and return reviewed labels; otherwise raises."""
    import hashlib as _hashlib

    return process(data, name, _hashlib.sha256(data).hexdigest())
