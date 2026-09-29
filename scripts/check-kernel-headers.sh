#!/usr/bin/env bash
# Checks, BEFORE investing any more time in this repo, whether the
# given Dakota image ships what the Containerfile needs:
#
#   - the kernel version and its exact .config at
#     /usr/lib/modules/<kver>/config, which the kernel-src-builder stage
#     reconstructs a kernel build tree from. This is the hard
#     requirement; a missing .config fails this check.
#   - /usr/lib/modules/<kver>/vmlinux, with a .BTF section — the
#     authoritative `struct module` layout that scripts/module-abi.py
#     reads to prove the modules it just built can actually be loaded
#     (see README.md, "struct module layout must match the running
#     kernel"). Reported but not fatal here: what it costs, if absent,
#     is that verification, which the build then refuses to skip unless
#     you set ALLOW_UNVERIFIED_MODULE_ABI=1.
#
# /usr/lib/modules/<kver>/build itself is a dangling symlink on
# published Dakota images — Dakota's own BuildStream pipeline never
# ships it at runtime, by design (linux.bst is a build-time-only
# dependency of nvidia-drivers.bst upstream; see README.md, "Why
# /usr/lib/modules/<kver>/build is missing"). This repo works around
# that by rebuilding the tree from upstream kernel source + the shipped
# .config (scripts/build-kernel-src.sh) instead of relying on /build
# being present. What actually needs to exist is the .config this check
# looks for — if THAT'S missing, Dakota's kernel packaging changed in a
# way this repo doesn't handle yet.
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

# NOTE: the script below is single-quoted, so it must contain no single
# quotes of its own (that includes apostrophes in prose).
podman run --rm "${image}" bash -c '
    set -euo pipefail
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"
    echo "Kernel: $kver"

    status=0

    if [ -f "/usr/lib/modules/$kver/config" ]; then
        echo "OK: /usr/lib/modules/$kver/config exists — kernel-src-builder"
        echo "can reconstruct a build tree from it."
    else
        echo "MISSING: /usr/lib/modules/$kver/config."
        echo "Contents of /usr/lib/modules/$kver:"
        ls -la "/usr/lib/modules/$kver" || true
        status=1
    fi

    vmlinux="/usr/lib/modules/$kver/vmlinux"
    if [ ! -f "$vmlinux" ]; then
        echo "NOTE: $vmlinux is absent, so scripts/module-abi.py has no ground"
        echo "truth for the struct module layout of this image."
    else
        if command -v readelf >/dev/null 2>&1; then
            has_btf=$(readelf -SW "$vmlinux" 2>/dev/null | grep -c "\.BTF " || true)
        else
            # No binutils in the image: fall back to looking for the
            # section name anywhere in the file (it lives in .shstrtab).
            has_btf=$(grep -c "\.BTF" "$vmlinux" 2>/dev/null || true)
        fi
        if [ "${has_btf:-0}" -gt 0 ]; then
            echo "OK: $vmlinux has a .BTF section — scripts/module-abi.py can"
            echo "verify every built module against it."
        else
            echo "NOTE: $vmlinux has no .BTF section (CONFIG_DEBUG_INFO_BTF may"
            echo "be unset in the kernel of this image), so scripts/module-abi.py"
            echo "has no ground truth to verify against."
        fi
    fi

    exit "$status"
'
