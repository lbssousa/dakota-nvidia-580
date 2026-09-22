#!/usr/bin/env bash
# Checks, BEFORE investing any more time in this repo, whether the
# given Dakota image ships what the Containerfile's kernel-src-builder
# stage needs to reconstruct a kernel build tree: the kernel version
# and its exact .config at /usr/lib/modules/<kver>/config.
#
# CONFIRMED (see README.md, "Why /usr/lib/modules/<kver>/build is
# missing"): /usr/lib/modules/<kver>/build itself is a dangling
# symlink on published Dakota images — Dakota's own BuildStream
# pipeline never ships it at runtime, by design (linux.bst is a
# build-time-only dependency of nvidia-drivers.bst upstream). This
# repo works around that by rebuilding the tree from upstream kernel
# source + the shipped .config (scripts/build-kernel-src.sh) instead
# of relying on /build being present. What actually needs to exist is
# the .config this check looks for — if THAT'S missing, Dakota's
# kernel packaging changed in a way this repo doesn't handle yet.
#
# Usage: scripts/check-kernel-headers.sh [ref] [variant]
#   ref:     tag or tag@sha256:... of the Dakota image (default: stable)
#   variant: "dakota" (default) or "dakota-gaming" — check the gaming
#            variant (Open Gaming Collective/OGC kernel) separately,
#            since it's a different kernel build than the standard one
#            and either can regress independently.
set -euo pipefail

ref="${1:-stable}"
variant="${2:-dakota}"
image="ghcr.io/projectbluefin/${variant}:${ref}"

echo "==> Inspecting ${image}..." >&2
podman run --rm "${image}" bash -c '
    set -euo pipefail
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"
    echo "Kernel: $kver"
    if [ -f "/usr/lib/modules/$kver/config" ]; then
        echo "OK: /usr/lib/modules/$kver/config exists — kernel-src-builder"
        echo "can reconstruct a build tree from it."
        exit 0
    fi
    echo "MISSING: /usr/lib/modules/$kver/config."
    echo "Contents of /usr/lib/modules/$kver:"
    ls -la "/usr/lib/modules/$kver" || true
    exit 1
'
