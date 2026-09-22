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
#   <version>          e.g. 580.173.02 (legacy branch — confirm at
#                      https://www.nvidia.com/en-us/drivers/unix/
#                      that it's the right version for your GPU before
#                      pinning it; also confirm it's new enough to build
#                      against the target kernel — 580.65.06 predates
#                      kernel 7.x-era API changes this script works
#                      around and doesn't build against it at all)
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
#
# IGNORE_MISSING_MODULE_SYMVERS: belt-and-suspenders only. The tree
# scripts/build-kernel-src.sh reconstructs now ships a real Module.symvers
# (from `make vmlinux`, not just `modules_prepare` — see that script), so
# this sanity check should pass on its own; this flag just avoids a hard
# Containerfile failure in the edge case where a future Dakota .config
# somehow produces an empty one instead. NVIDIA's own conftest.sh actually
# *depends* on Module.symvers content, beyond what this flag's name
# suggests — it greps it to decide which kernel-version-specific code
# path to compile (e.g. del_timer_sync vs. timer_delete_sync in
# nv-timer.h); an empty/missing file silently steers it toward APIs long
# removed from modern kernels instead of just skipping a CRC check
# (confirmed by actually hitting this with an incomplete tree).
#
# KCFLAGS: GCC 14+ (this Fedora 42 stage) made a small group of
# diagnostics errors unconditionally, not just via -Werror (confirmed:
# appending `EXTRA_CFLAGS += -Wno-...` to kernel/Kbuild had no effect at
# all — kernel 7.2.6's top-level Makefile no longer reads EXTRA_CFLAGS,
# only `KBUILD_CFLAGS += $(KCFLAGS)`, confirmed straight in its source).
# These three all surface on the same underlying issue below (strncpy),
# just differently depending on how each call site uses it:
#   - implicit-function-declaration: the plain "used before declared"
#     case (nvidia/os-interface.c).
#   - int-conversion: same missing declaration, but where the call site
#     *does* use the return value — an implicit declaration defaults to
#     an int-returning prototype, so `return strncpy(...)` (real
#     signature: char *) trips this instead (nvidia/linux_nvswitch.c).
#   - incompatible-pointer-types: same GCC 14+ generation of default-
#     error promotions; nvidia-drivers.bst upstream already demotes this
#     one for the same reason ("NVIDIA's source still has benign
#     mismatches" — see elements/bluefin-nvidia/nvidia-drivers.bst).
# Same class of fix lbssousa/bluefin's build_files/20-epson.sh applies to
# Epson's escpr driver for the identical GCC 14+ change (that build uses
# autotools CFLAGS, not kbuild, so it doesn't hit the KCFLAGS-vs-
# EXTRA_CFLAGS wrinkle above).
#
# Silencing those diagnostics isn't enough by itself: modpost then
# reports "strncpy" undefined in nvidia.ko/nvidia-uvm.ko/nvidia-modeset.ko
# — confirmed by actually hitting it, including after force-including
# <linux/string.h> globally via KCFLAGS -include (which should have
# supplied a declaration, if one still existed). It doesn't: strncpy()
# was fully removed from Linux's public string API on kernel 7.x
# (checked straight in include/linux/string.h upstream — only mentioned
# in comments pointing at strscpy() as the replacement now; two of the
# four files below already #include <linux/string.h> directly and still
# fail the same way, confirming this). Forcing it globally also backfired
# a different way: it reordered header inclusion for every NVIDIA source
# file, not just the ones needing it, and reintroduced a 'conflicting
# types for vm_fault_t' error (nv-platform.c) that the same NVIDIA
# version otherwise builds clean without it — confirmed by hitting that
# regression, then removing the global -include and scoping the fix
# below to only the 4 files that actually call strncpy().
#
# sized_strscpy() (lib/string.c, EXPORT_SYMBOL, always built into
# vmlinux — never a loadable module, so this doesn't depend on
# scripts/build-kernel-src.sh covering module-only exports) is the real
# underlying primitive strscpy() itself wraps; the shim below
# reimplements strncpy()'s classic signature on top of it.
nv_strncpy_shim="$(mktemp --suffix=.h)"
cat > "${nv_strncpy_shim}" << 'EOF'
#ifndef __NV_STRNCPY_COMPAT_H__
#define __NV_STRNCPY_COMPAT_H__
#include <linux/string.h>
#ifndef strncpy
static inline char *strncpy(char *dest, const char *src, size_t n)
{
    sized_strscpy(dest, src, n);
    return dest;
}
#endif
#endif
EOF

# The exact set of files calling strncpy() in this driver version —
# found by grepping the extracted source, not guessed; re-check this
# list (`grep -rln '\bstrncpy(' kernel/nvidia*`) whenever NVIDIA_VERSION
# changes, since it can shift between driver releases.
nv_strncpy_callers=(
    kernel/nvidia/os-interface.c
    kernel/nvidia/linux_nvswitch.c
    kernel/nvidia-uvm/uvm_pmm_gpu.c
    kernel/nvidia-modeset/nvidia-modeset-linux.c
)
for f in "${nv_strncpy_callers[@]}"; do
    if [ -f "$f" ]; then
        sed -i "1i #include \"${nv_strncpy_shim}\"" "$f"
    fi
done

KCFLAGS="-Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types" \
make -C kernel SYSSRC="${build_dir}" IGNORE_CC_MISMATCH=1 \
    IGNORE_MISSING_MODULE_SYMVERS=1 modules

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
