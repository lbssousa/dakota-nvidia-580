#!/usr/bin/env bash
# Reconstructs a real, compilable kernel "build" tree for whatever
# kernel version this specific Dakota base image ships — because the
# published runtime image does NOT contain one (see README.md, "Why
# /usr/lib/modules/<kver>/build is missing").
#
# Upstream Dakota gets this tree for free during its own BuildStream
# build: nvidia-drivers.bst declares freedesktop-sdk.bst:components/
# linux.bst (or, for the gaming variant, elements/core/linux-ogc.bst)
# as a build-dependency, and BuildStream stages that element's own
# package output — which contains /usr/src/linux-<kver>/ with exactly
# the Makefile, .config, arch/<arch>/include, arch/<arch>/Makefile,
# scripts/, include/, and (if enabled) tools/objtool/objtool that an
# out-of-tree module build needs — into the sandbox. That tree is
# real, not a hack: it's the same shape a kernel-devel RPM ships,
# assembled by linux.bst's own install-commands. It's just never
# included in the final runtime OCI image, because linux.bst is
# deliberately NOT a runtime-dependency of the composed OS (gnomeos
# boots from a separately-staged kernel+initramfs).
#
# This script reproduces that same linux.bst/linux-ogc.bst artifact
# shape ourselves, from the two pieces of ground truth the *runtime*
# image DOES ship:
#   - /usr/lib/modules/<kver>/config — the exact .config the running
#     kernel was built with.
#   - <kver> itself, which tells us which upstream tree to fetch:
#       - a plain version (e.g. "7.2.6")      -> vanilla kernel.org
#         source at tag v<kver> (freedesktop-sdk's own linux.bst
#         source pin, per elements/include/linux.yml — its only two
#         patches touch riscv/powerpc-only code, irrelevant on x86_64,
#         so vanilla upstream is faithful here).
#       - a "-ogc<N>" suffix (e.g. "7.2.6-ogc1") -> the Open Gaming
#         Collective kernel fork at the matching tag, from
#         elements/core/linux-ogc.bst's own source pin.
#
# Usage: build-kernel-src.sh <kver> <config-file> <output-dir>
set -euo pipefail

kver="$1"
config_file="$2"
out_dir="$3"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
cd "${workdir}"

if [[ "${kver}" == *-ogc* ]]; then
    echo "==> ${kver} looks like an Open Gaming Collective (OGC) kernel; cloning github.com/OpenGamingCollective/linux.git"
    git clone --branch "v${kver}" --depth 1 https://github.com/OpenGamingCollective/linux.git src
    # scripts/setlocalversion appends a '+' to kernelrelease whenever a
    # .git directory is present and the tree doesn't look like a clean
    # checkout of an exact tag, even for a --depth 1 clone of that tag.
    # Removing .git makes this identical to the tarball path below,
    # which has no git metadata to inspect.
    rm -rf src/.git
else
    series="${kver%%.*}"
    echo "==> ${kver} looks like a plain upstream release; downloading vanilla kernel.org source (series ${series}.x)"
    curl -fL --retry 3 --retry-delay 5 -o linux.tar.xz \
        "https://cdn.kernel.org/pub/linux/kernel/v${series}.x/linux-${kver}.tar.xz"
    mkdir src
    tar -xf linux.tar.xz -C src --strip-components=1
fi

cd src
cp "${config_file}" .config

# NVIDIA's legacy 580.xxx module source is plain C; it needs none of
# the in-tree Rust support Dakota's shipped .config enables (CONFIG_RUST=y,
# for unrelated in-tree Rust drivers). With CONFIG_RUST=y, `make prepare`
# hard-requires scripts/rust_is_available.sh to pass against a matching
# rustc/bindgen — a real toolchain-version dependency we don't otherwise
# need at all. Disabling it here changes no C struct layout, calling
# convention, or the kernel release string (vermagic) — see README.md.
scripts/config --disable RUST 2>/dev/null || true

echo "==> Reconciling shipped .config against this exact source tree (olddefconfig)..."
make -j1 olddefconfig

release="$(make -s kernelrelease)"
if [ "${release}" != "${kver}" ]; then
    echo "ERROR: rebuilt kernelrelease ('${release}') does not match the" >&2
    echo "running kernel's version ('${kver}'). An out-of-tree module built" >&2
    echo "against this tree would fail the kernel's vermagic check at" >&2
    echo "'insmod' time even if it compiles cleanly. Aborting rather than" >&2
    echo "produce a module that silently fails to load." >&2
    exit 1
fi

echo "==> Preparing the tree for external module builds (modules_prepare)..."
make -j"$(nproc)" modules_prepare

have_objtool=false
if [ "$(scripts/config -s OBJTOOL 2>/dev/null || true)" = "y" ]; then
    echo "==> CONFIG_OBJTOOL=y; building tools/objtool/objtool..."
    make -j"$(nproc)" tools/objtool/objtool
    have_objtool=true
fi

# NVIDIA's own conftest.sh (nv-timer.h's del_timer_sync/timer_delete_sync
# switch, and many other feature checks) doesn't gate on kernel version
# macros alone -- it greps Module.symvers for the *exact* export line of
# each symbol it cares about, and silently assumes "not present" (falling
# back to APIs long removed from modern kernels) whenever that file is
# missing or incomplete. modules_prepare alone never produces a real one.
# `make vmlinux` builds the kernel image and runs modpost over it,
# populating Module.symvers with every symbol exported directly from the
# kernel (built-in, not from a loadable module) -- covers this class of
# core-subsystem symbol NVIDIA's conftest checks for, without paying for
# a full `make modules` across every driver in this everything-enabled
# .config. See README.md for what this still doesn't cover.
echo "==> Building vmlinux to populate a real Module.symvers..."
make -j"$(nproc)" vmlinux

# drivers/gpu/drm/ is built as a set of loadable modules in Dakota's
# shipped .config (not built into vmlinux), so `make vmlinux` alone
# leaves DRM's own exports out of Module.symvers. nvidia-drm.ko (the
# DRM/KMS integration module, needed for accelerated Wayland/GNOME
# Shell output) needs drm_fbdev_ttm_driver_fbdev_probe
# (drivers/gpu/drm/drm_fbdev_ttm.c), which belongs to
# drivers/gpu/drm/drm_ttm_helper.ko -- CONFIG_DRM=y and
# CONFIG_DRM_KMS_HELPER=y are both built into vmlinux already on this
# .config, but CONFIG_DRM_TTM_HELPER=m is a real loadable module (per
# `drm_ttm_helper-$(CONFIG_DRM_FBDEV_EMULATION) += drm_fbdev_ttm.o` in
# drivers/gpu/drm/Makefile). drm_ttm_helper.ko itself then needs
# drivers/gpu/drm/ttm/ttm.ko (CONFIG_DRM_TTM=m too, providing
# ttm_bo_vunmap/ttm_bo_mmap_obj/ttm_bo_vmap).
#
# `make drivers/gpu/drm/` (the whole directory) is NOT the right scope
# for this: it builds every vendor GPU driver enabled in this
# everything-enabled .config too (amdgpu alone is one of the largest
# drivers in the kernel tree), which is prohibitively slow and
# memory-hungry. Building the two specific .ko targets instead keeps
# this to just what nvidia-drm.ko actually needs; if a future NVIDIA
# version or kernel bump needs a symbol from some other loadable
# module, find its owning module the same way (grep the kernel's own
# subsystem Makefile for the file that exports it) and add one more
# scoped target here.
echo "==> Building ttm.ko + drm_ttm_helper.ko so nvidia-drm.ko's DRM-core dependencies land in Module.symvers..."
make -j"$(nproc)" drivers/gpu/drm/ttm/ttm.ko drivers/gpu/drm/drm_ttm_helper.ko

# Modern kbuild names `make vmlinux`'s modpost output vmlinux.symvers,
# not Module.symvers -- the latter is only materialized by the full
# `modules` target (merging vmlinux.symvers with every built module's
# own exports). Since we built the two DRM modules above via scoped
# per-target invocations (not the full `modules` target), check for
# Module.symvers first -- kbuild's per-target module build does
# produce/update it -- and only fall back to vmlinux.symvers if that
# somehow didn't happen. External-module tooling (nvidia-installer's
# Kbuild, conftest.sh) only ever looks for the file named
# Module.symvers, so install it under that name -- its content is
# genuinely real (vmlinux + the two DRM modules') exports, just missing
# anything exported solely by some *other* loadable module we didn't
# also build here.
if [ -f Module.symvers ]; then
    symvers_src="Module.symvers"
elif [ -f vmlinux.symvers ]; then
    symvers_src="vmlinux.symvers"
else
    echo "ERROR: neither Module.symvers nor vmlinux.symvers exists after" >&2
    echo "'make vmlinux' -- kbuild's output naming may have changed again." >&2
    exit 1
fi

echo "==> Assembling the linux.bst-shaped output tree in ${out_dir}..."

targetdir="${out_dir}/src/linux-${release}"
mkdir -p "${targetdir}"

# Mirrors freedesktop-sdk's own linux.bst / linux-ogc.bst install-commands
# 'to_copy' list exactly — this is the artifact shape nvidia-drivers.bst
# itself compiles against upstream. Module.symvers here comes from `make
# vmlinux` + ttm.ko + drm_ttm_helper.ko above (vmlinux's built-in
# exports plus those two modules' — not every loadable module — see
# README.md for what that still doesn't cover).
to_copy=(
    Makefile
    .config
    "arch/x86/include"
    "arch/x86/Makefile"
    scripts
    include
)
if [ "${have_objtool}" = true ]; then
    to_copy+=(tools/objtool/objtool)
fi
for f in "${to_copy[@]}"; do
    dest="${targetdir}/${f}"
    mkdir -p "$(dirname "${dest}")"
    cp -aT "${f}" "${dest}"
done
cp -aT "${symvers_src}" "${targetdir}/Module.symvers"

mkdir -p "${out_dir}/lib/modules/${release}"
ln -sr "${targetdir}" "${out_dir}/lib/modules/${release}/build"

echo "==> build-kernel-src.sh done: ${targetdir}"
