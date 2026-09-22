#!/usr/bin/env bash
# Compiles the proprietary NVIDIA kmod (out-of-tree) against the
# kernel extracted by the Containerfile's kernel-headers stage, and
# packages the official installer's userspace components via a
# filesystem diff — instead of manually listing the files the
# nvidia-installer installs. The installer's file manifest changes
# between driver versions and isn't documented stably enough to
# hardcode here; capturing the real diff is more reliable.
#
# Usage: build-nvidia.sh <version> <kernel-src-root> <output>
#   <version>          e.g. 580.65.06 (legacy branch — confirm at
#                      https://www.nvidia.com/en-us/drivers/unix/
#                      that it's the right version for your GPU before
#                      pinning it)
#   <kernel-src-root>  root containing lib/modules/<kver>/build
#   <output>           directory to populate with the final tree
#                      (usr/lib/modules/..., usr/lib64/..., etc.)
set -euo pipefail

version="$1"
kernel_src_root="$2"
out_dir="$3"

kver="$(cat /kernel-version)"
build_dir="${kernel_src_root}/lib/modules/${kver}/build"

if [ ! -f "${build_dir}/Makefile" ]; then
    echo "ERROR: ${build_dir}/Makefile not found." >&2
    echo "The Containerfile's kernel-headers stage should have caught this earlier." >&2
    exit 1
fi

workdir="$(mktemp -d)"
cd "$workdir"

url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
echo "==> Downloading NVIDIA driver ${version}..."
curl -fsSLO "$url"
chmod +x "NVIDIA-Linux-x86_64-${version}.run"

echo "==> Extracting installer..."
"./NVIDIA-Linux-x86_64-${version}.run" -x
cd "NVIDIA-Linux-x86_64-${version}"

echo "==> Building the kmod against ${build_dir}..."
# IGNORE_CC_MISMATCH: this stage's Fedora compiler is almost certainly
# not bit-for-bit the one used to build Dakota's kernel
# (freedesktop-sdk). That's tolerable for an out-of-tree module; real
# ABI incompatibilities would show up as a link/load failure, not a
# compile failure — test `modprobe nvidia` on the final image before
# considering this validated.
make -C kernel SYSSRC="${build_dir}" IGNORE_CC_MISMATCH=1 modules

mkdir -p "${out_dir}/usr/lib/modules/${kver}/extra"
find kernel -maxdepth 1 -name '*.ko' -exec cp {} "${out_dir}/usr/lib/modules/${kver}/extra/" \;

echo "==> Installing userspace components (--no-kernel-module, the kmod was already handled above)..."
# WARNING: the flag names below were checked against
# --advanced-options of recent installer versions, but nvidia-installer
# changes flags between branches — run `./nvidia-installer --help` and
# `--advanced-options` the first time you switch versions and adjust
# this list before trusting the build.
find / -xdev -type f 2>/dev/null | sort > /tmp/before.list

./nvidia-installer \
    --silent \
    --accept-license \
    --no-questions \
    --ui=none \
    --no-kernel-module \
    --no-nouveau-check \
    --no-nvidia-modprobe \
    --no-rpms \
    --no-backup \
    --no-check-for-alternate-installs \
    --skip-depmod \
    --skip-module-load \
    --install-libglvnd

find / -xdev -type f 2>/dev/null | sort > /tmp/after.list
comm -13 /tmp/before.list /tmp/after.list > /tmp/new-files.list

n="$(wc -l < /tmp/new-files.list)"
echo "==> ${n} new files detected; packaging into ${out_dir}"
if [ "$n" -eq 0 ]; then
    echo "ERROR: no new files — nvidia-installer probably failed silently" >&2
    echo "or exited before installing anything. Re-run without --silent" >&2
    echo "to see the full output." >&2
    exit 1
fi

while IFS= read -r f; do
    mkdir -p "${out_dir}$(dirname "$f")"
    cp -a "$f" "${out_dir}${f}"
done < /tmp/new-files.list

echo "==> build-nvidia.sh done."
