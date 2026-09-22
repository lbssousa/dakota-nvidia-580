#!/usr/bin/env bash
# Checks, BEFORE investing any more time in this repo, whether the
# given Dakota image exposes a kernel build tree complete enough to
# compile an out-of-tree module (the NVIDIA kmod).
#
# This is the biggest unresolved risk of the "downstream Containerfile"
# approach described in README.md: Dakota is built from scratch via
# BuildStream, not from RPM kernel-devel packages, and is a
# space-optimized image (dedup via chunkah) — there's no guarantee the
# full kernel build tree survives in the runtime image instead of only
# existing in BuildStream's own build artifacts. If this script fails,
# the Containerfile will fail too (the kernel-headers stage does the
# same check) — but running this first avoids setting up everything
# else (GHCR secrets, Renovate, etc.) only to find this out afterwards.
#
# Usage: scripts/check-kernel-headers.sh [ref]
#   ref: tag or tag@sha256:... of the Dakota image (default: stable)
set -euo pipefail

ref="${1:-stable}"
image="ghcr.io/projectbluefin/dakota:${ref}"

echo "==> Inspecting ${image}..." >&2
podman run --rm "${image}" bash -c '
    set -euo pipefail
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"
    echo "Kernel: $kver"
    if [ -f "/usr/lib/modules/$kver/build/Makefile" ]; then
        echo "OK: /usr/lib/modules/$kver/build exists and has a Makefile."
        exit 0
    fi
    echo "MISSING: /usr/lib/modules/$kver/build (or its Makefile)."
    echo "Contents of /usr/lib/modules/$kver:"
    ls -la "/usr/lib/modules/$kver" || true
    exit 1
'
