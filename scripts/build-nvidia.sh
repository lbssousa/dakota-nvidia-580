#!/usr/bin/env bash
# Compiles the proprietary NVIDIA kmod (out-of-tree) against the
# kernel extracted by the Containerfile's kernel-headers stage, and
# packages the official installer's userspace components via a
# filesystem diff — instead of manually listing the files the
# nvidia-installer installs. The installer's file manifest changes
# between driver versions and isn't documented stably enough to
# hardcode here; capturing the real diff is more reliable.
#
# Usage: build-nvidia.sh <version> <kernel-src-root> <output> <libdir>
#   <version>          e.g. 580.178.04 (legacy branch — confirm at
#                      https://www.nvidia.com/en-us/drivers/unix/
#                      that it's the right version for your GPU before
#                      pinning it; also confirm it's new enough to build
#                      against the target kernel — 580.65.06 predates
#                      kernel 7.x-era API changes this script works
#                      around and doesn't build against it at all)
#   <kernel-src-root>  root containing lib/modules/<kver>/build
#   <output>           directory to populate with the final tree
#                      (usr/lib/modules/..., usr/lib/x86_64-linux-gnu/...,
#                      etc.)
#   <libdir>           absolute path of the real 64-bit library
#                      directory in the target runtime image (e.g.
#                      /usr/lib/x86_64-linux-gnu on Dakota — see
#                      nvidia-libdir-probe in the Containerfile). This
#                      builder stage is plain fedora:44, where
#                      nvidia-installer would otherwise auto-detect
#                      Fedora's own /usr/lib64 convention — wrong for
#                      Dakota's Debian-style multiarch layout, and
#                      invisible to Dakota's ldconfig (see README.md,
#                      "How the NVIDIA userspace libraries are
#                      installed").
set -euo pipefail

version="$1"
kernel_src_root="$2"
out_dir="$3"
libdir="$4"
# nvidia-installer's --opengl-libdir/--utility-libdir/--gbm-backend-dir
# are relative to their own install prefix (--opengl-prefix,
# --utility-prefix — both default to /usr, per --advanced-options), so
# strip that leading /usr/ back off the absolute path the probe found.
relative_libdir="${libdir#/usr/}"

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
# No IGNORE_CC_MISMATCH, but do not read much into that passing. It was
# described here as enforcing a match with the compiler that built
# Dakota's kernel; it does not, and never did. NVIDIA's cc_sanity_check
# (kernel/conftest.sh) parses only major.minor out of
# include/generated/compile.h's LINUX_COMPILER and compares it to
# __GNUC__/__GNUC_MINOR__ of $(CC). Dakota's kernel GCC is 16.2.0 and
# Fedora 44's is 16.2.1 — both "16.2" — so the check passes either way
# and is blind to exactly the micro-version drift it was credited with
# catching. It is left unset because it costs nothing and would still
# catch a major/minor jump.
#
# $(CC) itself: NVIDIA's kernel/Makefile takes the first word of the
# tree's CONFIG_CC_VERSION_TEXT when CC is unset, which is plain "gcc",
# resolved from PATH.
#
# IGNORE_MISSING_MODULE_SYMVERS: belt-and-suspenders only. The tree
# scripts/build-kernel-src.sh assembles ships a real Module.symvers
# (derived from the image's own binaries — see that script), so this
# sanity check should pass on its own; this flag just avoids a hard
# Containerfile failure
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
#
# The --opengl-libdir/--utility-libdir/--x-library-path/--x-module-path/
# --gbm-backend-dir overrides below all steer the installer at
# "${libdir}" (found by nvidia-libdir-probe) instead of letting it
# auto-detect a libdir — without them it guesses Fedora's own
# convention (/usr/lib64), since that's what's actually true of this
# fedora:44 builder stage, not of the Dakota image these files end up
# in. See README.md, "How the NVIDIA userspace libraries are
# installed".
#
# --no-install-compat32-libs: this builder stage has Fedora's own
# 32-bit multilib packages available, which makes nvidia-installer
# auto-install a full parallel set of 32-bit compatibility libraries —
# but Dakota ships no 32-bit multiarch directory at all
# (/usr/lib/i386-linux-gnu doesn't exist), so those libraries are dead
# weight nothing on the target image could ever load. See README.md,
# "Known limitations" for the gaming-variant caveat (32-bit Wine/Proton
# titles needing 32-bit OpenGL would need this revisited).
#
# The three list files must live on a filesystem that `find / -xdev`
# never descends into — hence the literal /tmp paths rather than the
# relative names: the redirect creates each list file *before* find
# runs, so a list file on the scanned filesystem would appear in its own
# output. before.list would then contain itself (fine, it is on both
# sides of the comm) but after.list would not exist during the first
# find and does exist during the second, so `comm -13` would classify
# it as newly installed and copy the installer's /dev node inventory
# into the image. -xdev is what keeps that from happening: /tmp is a
# tmpfs, so it is a separate mount and out of reach. Do not move these
# into $workdir — `mktemp -d` honours TMPDIR, so that is only safe for
# as long as nobody points TMPDIR at the root filesystem.
find / -xdev \( -type f -o -type l \) 2>/dev/null | sort > /tmp/before.list

./nvidia-installer \
    --silent \
    --accept-license \
    --no-questions \
    --ui=none \
    --no-kernel-module \
    --no-nouveau-check \
    --no-rpms \
    --no-backup \
    --no-check-for-alternate-installs \
    --skip-depmod \
    --skip-module-load \
    --no-install-libglvnd \
    --no-install-compat32-libs \
    --opengl-libdir="${relative_libdir}" \
    --utility-libdir="${relative_libdir}" \
    --x-library-path="${libdir}" \
    --x-module-path="${libdir}/xorg/modules" \
    --gbm-backend-dir="${relative_libdir}/gbm"

find / -xdev \( -type f -o -type l \) 2>/dev/null | sort > /tmp/after.list
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

# nvidia-modprobe is deliberately NOT suppressed (--no-nvidia-modprobe
# used to be passed here; see below). Its mode in the .run payload is
# 0755, not setuid, which is exactly what this image wants: nothing
# unprivileged needs to call it, because files/nvidia-device-nodes.service
# calls it as root, Before=display-manager.service, and files/60-nvidia.rules
# calls it from udev (also root) to cover unprivileged containers.
# projectbluefin/dakota makes the same choice for the same reason
# ("nvidia-modprobe stays 0755 (not NVIDIA's 4755):
# nvidia-device-nodes.service invokes it as root, so no unprivileged
# process needs it").
echo "==> Verifying nvidia-modprobe is present and not setuid..."
if [ ! -x "${out_dir}/usr/bin/nvidia-modprobe" ]; then
    echo "ERROR: ${out_dir}/usr/bin/nvidia-modprobe missing from the installer's payload." >&2
    echo "Without it neither files/nvidia-device-nodes.service nor" >&2
    echo "files/60-nvidia.rules can create /dev/nvidia*, and every" >&2
    echo "non-root client (gnome-shell, CUDA, nvidia-smi) loses it too." >&2
    exit 1
fi
if [ -u "${out_dir}/usr/bin/nvidia-modprobe" ]; then
    echo "WARNING: nvidia-modprobe is setuid in the payload. Nothing needs" >&2
    echo "it to be — files/nvidia-device-nodes.service runs it as root —" >&2
    echo "and a setuid root helper is a needless escalation surface." >&2
    echo "Stripping it; NVIDIA's own docs treat it as optional for this reason." >&2
    chmod 0755 "${out_dir}/usr/bin/nvidia-modprobe"
fi

# ---------------------------------------------------------------------
# Dakota / freedesktop-sdk integration fixes.
#
# These are all about where the driver's own files have to land for the
# freedesktop-sdk graphics stack to find them. Reference implementation:
# projectbluefin/dakota's elements/bluefin-nvidia/nvidia-drivers.bst,
# which solves the same problem against the same stack (and is where
# this repo's 10_nvidia.json placement came from originally).
#
# 1. EGL vendor ICD. libglvnd only scans /etc/glvnd/egl_vendor.d and
#    ${libdir}/GL/glvnd/egl_vendor.d — never /usr/share/glvnd/egl_vendor.d,
#    where nvidia-installer puts it. Verified against the base image's
#    own libEGL.so.1.1.0 rather than trusted:
#      $ strings libEGL.so.1.1.0 | grep egl_vendor.d
#      /etc/glvnd/egl_vendor.d:/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d
#    So the load-bearing copy goes to /etc. /usr/share is kept too, as
#    convention (and because nvidia-installer wrote it there anyway).
#    The GL/ copy is deliberately NOT created: that path is a symlink
#    into the Mesa extension tree, and a real directory there shadows
#    Mesa's own 50_mesa.json at the OCI merge.
#    Upstream-Status: not-submitted (fdsdk libglvnd sets
#      datadir=${libdir}/GL, so it will never search /usr/share)
#
# 2. GBM backend. Mesa's libgbm has its backend directory compiled in —
#    also verified against the base image's binary:
#      $ strings libgbm.so.1 | grep GL/
#      /usr/lib/x86_64-linux-gnu/GL/lib/gbm
#    which is a symlink to ../default/lib/gbm. The installer's own
#    --gbm-backend-dir output lands in ${libdir}/gbm/, a directory
#    nothing ever looks in, so the symlink is placed where libgbm
#    actually probes. Note that ldconfig will not help here: it only
#    caches files whose name starts with "lib", so dri_gbm.so and
#    nvidia-drm_gbm.so never appear in /etc/ld.so.cache no matter which
#    directories are configured. (Verified with a no-DT_SONAME .so.)
# ---------------------------------------------------------------------
echo "==> Configuring Dakota-compatible paths for EGL and GBM..."

mkdir -p "${out_dir}/etc/glvnd/egl_vendor.d"
if [ ! -f "10_nvidia.json" ]; then
    echo "ERROR: 10_nvidia.json missing from the driver payload." >&2
    echo "libglvnd would then find only Mesa's 50_mesa.json and never" >&2
    echo "load libEGL_nvidia.so.0 at all." >&2
    exit 1
fi
install -Dm644 "10_nvidia.json" "${out_dir}/etc/glvnd/egl_vendor.d/10_nvidia.json"

# GBM: manifest-driven rather than hardcoded, so a new release that
# splits out another allocator/driver library keeps working. Row shape
# (from the payload's .manifest):
#   nvidia-drm_gbm.so 0000 GBM_BACKEND_LIB_SYMLINK NATIVE libnvidia-allocator.so.1 MODULE:nvalloc
mapfile -t gbm_symlinks < <(awk '$3 == "GBM_BACKEND_LIB_SYMLINK" && $4 == "NATIVE" { print $1, $5 }' .manifest)
if [ "${#gbm_symlinks[@]}" -eq 0 ]; then
    echo "ERROR: .manifest declares no NATIVE GBM_BACKEND_LIB_SYMLINK rows." >&2
    echo "libgbm would fall back to dri_gbm.so only, and any GBM surface" >&2
    echo "that needs the NVIDIA backend (PRIME render-node buffers) fails." >&2
    exit 1
fi
gbm_dir="${out_dir}${libdir}/GL/default/lib/gbm"
mkdir -p "$gbm_dir"
for row in "${gbm_symlinks[@]}"; do
    name="${row%% *}"
    target="${row##* }"
    resolved="${out_dir}${libdir}/${target}"
    if [ ! -e "$resolved" ]; then
        echo "ERROR: .manifest wants GL/default/lib/gbm/${name} -> ${target}," >&2
        echo "but ${libdir}/${target} is not in the installer's output." >&2
        echo "That symlink would dangle and libgbm would silently skip the" >&2
        echo "NVIDIA GBM backend." >&2
        exit 1
    fi
    # ln -sfn with an absolute final path, NOT `ln -srf`: -r is
    # --relative, not "recursive", so it silently rewrites the target
    # into a chain of ../ that happens to resolve to the same file here
    # and breaks the moment anything moves. Absolute, because the
    # resulting link ships into a different tree than it was built in.
    ln -sfn "${libdir}/${target}" "${gbm_dir}/${name}"
    echo "    GL/default/lib/gbm/${name} -> ${libdir}/${target}"
done

# ---------------------------------------------------------------------
# 3. Vulkan ICD. nvidia-installer installs this only if it finds a
#    Vulkan ICD loader on the build host, warning otherwise:
#      "This NVIDIA driver package includes Vulkan components, but no
#       Vulkan ICD loader was detected on this system."
#    This builder stage deliberately has none, so the installer skips
#    nvidia_icd.json (VULKAN_ICD_JSON in the .manifest) and every
#    published image so far shipped with no NVIDIA Vulkan driver at all
#    — the previous `if [ -f ... ]` here just fell through silently.
#    Verified by running the installer with exactly these flags: the
#    other EGL/Vulkan manifests are installed, nvidia_icd.json is not.
#    So place it from the payload ourselves.
#
#    /usr/share/vulkan/icd.d is the one correct location — the loader
#    scans /etc/vulkan/icd.d and /usr/share/vulkan/icd.d
#    independently, so a second copy under /etc registers the same
#    physical GPU twice. This script used to add that copy "to be
#    safe"; it isn't. (Bazzite's install-nvidia does the inverse
#    cleanup, dropping /usr/share/vulkan/icd.d/nouveau_icd.*.json so it
#    can't collide with NVIDIA's on a machine that has both.)
if [ ! -f "nvidia_icd.json" ]; then
    echo "ERROR: nvidia_icd.json missing from the driver payload." >&2
    echo "It is in the .manifest (VULKAN_ICD_JSON), so this is a payload" >&2
    echo "change, not an installer quirk — investigate before continuing." >&2
    exit 1
fi
install -Dm644 "nvidia_icd.json" "${out_dir}/usr/share/vulkan/icd.d/nvidia_icd.json"

# ---------------------------------------------------------------------
# 4. EGL external-platform JSONs (10_nvidia_wayland.json,
#    15_nvidia_gbm.json, ...): left exactly where nvidia-installer put
#    them, under /usr/share/egl/egl_external_platform.d, which is what
#    projectbluefin/dakota does too. This script used to mirror them
#    into /etc/egl/egl_external_platform.d and
#    ${libdir}/GL/default/egl/egl_external_platform.d on the theory
#    that libglvnd might look there. It doesn't: the base image's
#    libEGL.so.1.1.0 contains no external-platform search path at all
#    (see the strings output above), so both copies were inert weight.
#    They are still worth asserting on, though — if they ever vanish
#    from the payload, and a future libglvnd *does* read that dir, the
#    Wayland/GBM platform dispatch silently regresses.
for f in 10_nvidia_wayland.json 15_nvidia_gbm.json; do
    if [ ! -f "${out_dir}/usr/share/egl/egl_external_platform.d/$f" ]; then
        echo "ERROR: expected EGL external-platform JSON $f was not installed" >&2
        echo "by nvidia-installer (looked in /usr/share/egl/egl_external_platform.d)." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------
# 5. Suspend/hibernate/resume units. nvidia-installer ships these in the
#    payload's systemd/ tree but does not install them here — most
#    likely because it looks for a systemd install prefix and the
#    builder stage's answer doesn't match the target image's
#    /usr/lib/systemd. They are load-bearing, not cosmetic:
#    nvidia-sleep.sh exits immediately unless /proc/driver/nvidia/suspend
#    exists, which only happens with
#    NVreg_PreserveVideoMemoryAllocations=1 (files/nvidia-driver-params.conf).
#    Without these units a suspend loses GPU context and hard-locks the
#    machine; with them and the param, it round-trips cleanly.
# ---------------------------------------------------------------------
echo "==> Installing NVIDIA power-management units..."
systemd_dir="${out_dir}/usr/lib/systemd"
for svc in nvidia-suspend nvidia-resume nvidia-hibernate nvidia-suspend-then-hibernate; do
    if [ ! -f "systemd/system/${svc}.service" ]; then
        echo "ERROR: systemd/system/${svc}.service missing from driver payload." >&2
        exit 1
    fi
    install -Dm644 "systemd/system/${svc}.service" "${systemd_dir}/system/${svc}.service"
done

for f in systemd/nvidia-sleep.sh systemd/system-sleep/nvidia; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f missing from driver payload." >&2
        echo "The units above ExecStart it; without it they fail on every" >&2
        echo "suspend." >&2
        exit 1
    fi
done
install -Dm755 systemd/nvidia-sleep.sh "${out_dir}/usr/bin/nvidia-sleep.sh"
install -Dm755 systemd/system-sleep/nvidia "${systemd_dir}/system-sleep/nvidia"

# NVIDIA's no-freeze drop-ins. systemd freezes user sessions before
# sleep, which deadlocks against the VT switch nvidia-sleep.sh performs;
# these units unset Conflicts=shutdown.target on the relevant targets.
# These ship with 615.x and later but are NOT present in 580.178.04's
# payload — warn rather than fail, since that's a property of this
# branch, not a broken build.
shopt -s nullglob
nofreeze=(systemd/system/systemd-*.service.d)
shopt -u nullglob
if [ "${#nofreeze[@]}" -eq 0 ]; then
    echo "    NOTE: no nvidia-suspend-nofreeze drop-ins in this driver version's payload." >&2
    echo "    Suspend with an active X session may still deadlock. Harmless on a" >&2
    echo "    Wayland-only session (nothing is frozen that nvidia-sleep.sh" >&2
    echo "    conflicts with). Track it on the next version bump." >&2
else
    for d in "${nofreeze[@]}"; do
        install -Dm644 "${d}/nvidia-suspend-nofreeze.conf" \
            "${systemd_dir}/system/$(basename "$d")/nvidia-suspend-nofreeze.conf"
    done
    echo "    installed ${#nofreeze[@]} nvidia-suspend-nofreeze drop-in(s)"
fi

# nvidia-powerd (Dynamic Boost). The unit and its D-Bus policy are
# installed, but it is deliberately NOT enabled: Dynamic Boost is an
# RTX 50 laptop feature, and this branch's payload ships neither
# dlsnetparams.csv (its data table) nor anything else that would make it
# do anything. projectbluefin/dakota hard-fails on the missing table
# because 615.x has it; failing here would just mean the 580 branch can
# never build. Same call as Dakota's on the unit itself: absent the
# hardware it exits 0, so leaving it disabled loses nothing.
for f in systemd/system/nvidia-powerd.service nvidia-dbus.conf; do
    if [ -f "$f" ]; then
        case "$f" in
            systemd/*) install -Dm644 "$f" "${systemd_dir}/system/$(basename "$f")" ;;
            *)         install -Dm644 "$f" "${out_dir}/usr/share/dbus-1/system.d/$(basename "$f")" ;;
        esac
    fi
done
if [ ! -f dlsnetparams.csv ]; then
    echo "    NOTE: dlsnetparams.csv absent (580 branch has no Dynamic Boost)." >&2
    echo "    nvidia-powerd.service installed but not enabled." >&2
fi

# ---------------------------------------------------------------------
# 6. DT_NEEDED closure. Every libnvidia-* is dlopen'd by bare soname, so
#    a library that a newly-split-out module needs (libnvidia-gpucomp,
#    libnvidia-api, ...) but that the installer's own manifest selection
#    didn't put on disk fails only at run time, inside a compositor, as
#    an unexplained EGL init failure. Catch it in the build instead.
#    Same check projectbluefin/dakota runs; it is the one guard that
#    would have caught the regression this file's kargs section
#    documents.
# ---------------------------------------------------------------------
echo "==> Checking DT_NEEDED closure of the installed NVIDIA libraries..."
closure_status=0
for obj in "${out_dir}${libdir}"/lib*.so.* "${out_dir}${libdir}"/vdpau/lib*.so.* "${out_dir}/usr/bin"/*; do
    [ -f "$obj" ] && [ ! -L "$obj" ] || continue
    for dep in $(objdump -p "$obj" 2>/dev/null | awk '/NEEDED/{print $2}'); do
        case "$dep" in
            libnvidia-*|libcuda.so*|libnvcuvid.so*|libnvoptix.so*)
                if [ ! -e "${out_dir}${libdir}/${dep}" ]; then
                    echo "ERROR: $(basename "$obj") needs ${dep}, which is not installed" >&2
                    closure_status=1
                fi
                ;;
        esac
    done
done
if [ "$closure_status" -ne 0 ]; then
    echo "ERROR: NVIDIA userspace library closure is incomplete — the image" >&2
    echo "would ship libraries that dlopen a soname that isn't present." >&2
    exit 1
fi

echo "==> build-nvidia.sh done."
