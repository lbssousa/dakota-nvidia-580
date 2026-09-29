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
#   <version>          e.g. 580.178.04 (legacy branch — confirm at
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
# No IGNORE_CC_MISMATCH: PATH is set up (see the nvidia-builder
# Containerfile stage) so $(CC) resolves to the toolchain-builder
# stage's from-source GCC, matching Dakota's own kernel exactly
# (CONFIG_CC_VERSION_TEXT) — kbuild's own mismatch check should just
# pass. Leaving it enforced means a future toolchain drift (see
# README.md, "Compiler/linker version mismatch") fails the build
# loudly instead of silently producing another unloadable .ko.
#
# IGNORE_MISSING_MODULE_SYMVERS: belt-and-suspenders only. The tree
# scripts/build-kernel-src.sh reconstructs ships a real Module.symvers
# (from `make vmlinux` — see that script), so this sanity check should
# pass on its own; this flag just avoids a hard Containerfile failure
# in the edge case where a future Dakota .config somehow produces an
# empty one instead. NVIDIA's own conftest.sh actually *depends* on
# Module.symvers content, beyond what this flag's name suggests — it
# greps it to decide which kernel-version-specific code path to
# compile (e.g. del_timer_sync vs. timer_delete_sync in nv-timer.h); an
# empty/missing file silently steers it toward APIs long removed from
# modern kernels instead of just skipping a CRC check.
#
# KCFLAGS: GCC 14+ (this stage's compiler) made a small group of
# diagnostics errors unconditionally, not just via -Werror. These three
# all trace back to the same root cause in NVIDIA's source: several
# files call strncpy() without including <string.h>/<linux/string.h>,
# relying on some other kernel header to pull it in transitively, which
# no longer holds on kernel 7.x:
#   - implicit-function-declaration: the plain "strncpy() used before
#     declared" case (nvidia/os-interface.c).
#   - int-conversion: same missing declaration, but where the call site
#     *does* use the return value — an implicit declaration defaults to
#     an int-returning prototype, so `return strncpy(...)` (real
#     signature: char *) trips this instead (nvidia/linux_nvswitch.c).
#   - incompatible-pointer-types: same GCC 14+ generation of default-
#     error promotions; nvidia-drivers.bst upstream already demotes this
#     one for the same reason ("NVIDIA's source still has benign
#     mismatches" — see elements/bluefin-nvidia/nvidia-drivers.bst).
# None of this is a real ABI/behavior risk: every case is GCC correctly
# assuming the wrong prototype for a function that unambiguously exists
# and behaves exactly as declared in <string.h> once actually visible.
# Same class of fix lbssousa/bluefin's build_files/20-epson.sh applies to
# Epson's escpr driver for the identical GCC 14+ change (that build uses
# autotools CFLAGS, not kbuild).
#
# Kept even though 580.178.04 no longer calls strncpy() at all (so the
# first two of those three no longer have a trigger in this version):
# they only demote diagnostics, `-Wno-incompatible-pointer-types` is
# demoted by nvidia-drivers.bst upstream for its own reasons, and a
# future 580.x can reintroduce the pattern. If NVIDIA's source ever
# depends on one of these being an error, that's a compile failure, not
# a silent miscompile.
#
# Delivered via KCFLAGS, not EXTRA_CFLAGS appended to kernel/Kbuild:
# kernel 7.2.6's top-level Makefile only reads `KBUILD_CFLAGS +=
# $(KCFLAGS)`, not EXTRA_CFLAGS.
#
# Silencing those diagnostics isn't enough by itself to make strncpy()
# work, though: modpost then reports it `undefined` in
# nvidia.ko/nvidia-uvm.ko/nvidia-modeset.ko. Without a visible
# declaration, GCC compiles the call as a real external symbol
# reference instead of inlining it (strncpy is a kernel builtin/inline,
# never an EXPORT_SYMBOL) — silencing the warning doesn't change that
# generated code. strncpy() was in fact fully removed from Linux's
# public string API on kernel 7.x (include/linux/string.h upstream only
# mentions it in comments pointing at strscpy() as the replacement);
# force-including <linux/string.h> globally via a compiler flag doesn't
# help either, and reorders header inclusion for every NVIDIA source
# file in a way that reintroduces an unrelated 'conflicting types for
# vm_fault_t' error on files that otherwise build clean. sized_strscpy()
# (lib/string.c, EXPORT_SYMBOL, always built into vmlinux — never a
# loadable module) is the real underlying primitive strscpy() wraps;
# the shim below reimplements strncpy()'s classic signature on top of
# it, and is injected only into the specific files that call the old
# name.
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

# Which files call strncpy() is derived here, not hardcoded, because it
# shifts between driver releases: 580.173.02 had four (nvidia/os-interface.c,
# nvidia/linux_nvswitch.c, nvidia-uvm/uvm_pmm_gpu.c,
# nvidia-modeset/nvidia-modeset-linux.c) and 580.178.04 has none at all —
# NVIDIA moved them off the old name upstream. A hardcoded list rots
# silently into either a pointless injection or a missed file, and
# re-deriving it by hand was a documented chore on every version bump;
# grepping for it makes the bump routine instead.
mapfile -t nv_strncpy_callers < <(grep -rl '\bstrncpy(' kernel/nvidia* 2>/dev/null | sort)
if [ "${#nv_strncpy_callers[@]}" -eq 0 ]; then
    echo "==> No strncpy() callers in this driver version; skipping the compat shim."
else
    echo "==> Injecting the strncpy() -> sized_strscpy() shim into ${#nv_strncpy_callers[@]} file(s):"
    printf '      %s\n' "${nv_strncpy_callers[@]}"
    for f in "${nv_strncpy_callers[@]}"; do
        sed -i "1i #include \"${nv_strncpy_shim}\"" "$f"
    done
fi

KCFLAGS="-Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types" \
make -C kernel SYSSRC="${build_dir}" IGNORE_MISSING_MODULE_SYMVERS=1 modules

# A clean compile proves nothing about loadability. The modules just
# built carry a `struct module` whose field offsets came from
# ${build_dir}'s reconstructed .config, and nothing checked yet that
# those offsets match the kernel they'll actually be inserted into —
# vermagic doesn't cover struct module's layout, and CONFIG_MODVERSIONS
# is unset on Dakota. A mismatch here is not a subtle degradation: the
# load fails outright with x86's "Invalid relocation target, existing
# value is nonzero" / -ENOEXEC. So compare against the layout read from
# the Dakota base image's own vmlinux .BTF before packaging anything.
# See scripts/module-abi.py for the full mechanism.
mapfile -t built_kos < <(find kernel -maxdepth 1 -name '*.ko' | sort)
if [ "${#built_kos[@]}" -eq 0 ]; then
    echo "ERROR: 'make modules' produced no .ko files." >&2
    exit 1
fi
echo "==> Verifying the ${#built_kos[@]} built module(s) against the kernel's own struct module layout..."
python3 /module-abi.py verify /kernel-module-abi.json "${built_kos[@]}"

mkdir -p "${out_dir}/usr/lib/modules/${kver}/extra"
cp "${built_kos[@]}" "${out_dir}/usr/lib/modules/${kver}/extra/"

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
