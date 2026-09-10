#!/usr/bin/env bash
# Image preparation only, before the restricted package-build container starts.
set -euo pipefail
sdk_root="${ANDROID_HOME:-/home/builder/lib/android-sdk-9123335}"
[[ "$sdk_root" == /home/builder/lib/android-sdk-* && -d "$sdk_root" ]] || {
    printf 'Unexpected/missing SDK root: %s\n' "$sdk_root" >&2; exit 1;
}
manager="$(find "$sdk_root" -type f -name sdkmanager -print -quit)"
[[ -n "$manager" && -x "$manager" ]] || { printf 'sdkmanager not found\n' >&2; exit 1; }
# Avoid an unbounded yes pipeline masking sdkmanager failures under pipefail.
licenses="$(mktemp)"
trap 'rm -f "$licenses"' EXIT
printf 'y\n%.0s' {1..100} > "$licenses"
"$manager" --sdk_root="$sdk_root" --licenses < "$licenses"
"$manager" --sdk_root="$sdk_root" 'platforms;android-33' 'build-tools;30.0.3'
test -s "$sdk_root/platforms/android-33/android.jar"
test -x "$sdk_root/build-tools/30.0.3/aapt2"
test -s "$sdk_root/build-tools/30.0.3/source.properties"
printf 'SDK preflight passed: Platform 33 and Build-Tools 30.0.3\n'
