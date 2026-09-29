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

# ---------------------------------------------------------------------
# Guard: olddefconfig must not have silently changed anything else.
#
# `olddefconfig`'s entire job is to resolve, without asking and without
# saying so, every shipped option whose dependencies this tree can't
# satisfy. Crucially, some Kconfig dependencies are on a build *tool*
# being installed rather than on another option:
#
#   config DEBUG_INFO_BTF
#           ...
#           depends on PAHOLE_VERSION >= 122
#
# and scripts/pahole-version.sh reports 0 when pahole isn't on PATH. A
# missing package in the Containerfile's kernel-src-builder stage
# therefore flips a shipped "=y" to unset with no diagnostic at all.
#
# That is not cosmetic when the option is one of the `#ifdef CONFIG_*`
# blocks inside `struct module` (include/linux/module.h):
# CONFIG_DEBUG_INFO_BTF_MODULES contributes 24 bytes of btf_data_size/
# btf_base_data_size/btf_data/btf_base_data, sitting between `init` and
# `exit`. Lose it and every module built against this tree puts its
# `exit` pointer 24 bytes early — at 0x498 instead of 0x4b0, i.e. on
# top of source_list.prev. vermagic encodes none of this, so such a
# module compiles clean, passes the version check, and then fails to
# load: load_module() populates source_list (module_unload_init()'s
# INIT_LIST_HEAD) *before* apply_relocations(), and x86's
# __write_relocate_add() rejects any relocation whose target isn't
# still zero — "Invalid relocation target, existing value is nonzero",
# -ENOEXEC. This repo shipped exactly that once.
#
# So: treat any silent divergence as a build failure, and run the check
# here rather than after the expensive modules_prepare/vmlinux builds
# below. scripts/module-abi.py is the second, structural half of the
# same defence — it checks the resulting .ko against the running
# kernel's own BTF, catching a layout mismatch whatever its cause.
# ---------------------------------------------------------------------
normalize_config() {
    # "CONFIG_X=v" -> "CONFIG_X v", "# CONFIG_X is not set" -> "CONFIG_X n".
    # Comparing normalized name/value pairs rather than raw lines is what
    # makes a shipped "=y" turning into "is not set" register as a changed
    # option instead of an unrelated deleted line and added comment.
    sed -nE -e 's/^(CONFIG_[A-Za-z0-9_]+)=(.*)$/\1 \2/p' \
            -e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1 n/p' "$1" \
        | LC_ALL=C sort
}

normalize_config "${config_file}" > ../config.shipped.norm
normalize_config .config          > ../config.reconciled.norm

# Symbol names allowed to differ, as anchored extended regexes. Add to
# this list only alongside a comment explaining why that divergence
# can't affect the module ABI.
#
# The sole entry covers the deliberate `scripts/config --disable RUST`
# above — and, equally, the fact that Kconfig would have dropped RUST by
# itself here regardless (CONFIG_RUST depends on RUST_IS_AVAILABLE,
# another tool probe: scripts/rust_is_available.sh, and this stage
# installs no rustc). Every option Dakota's shipped .config enables that
# depends on Rust carries RUST in its own symbol name — CONFIG_RUST,
# CONFIG_HAVE_RUST, CONFIG_RUST_IS_AVAILABLE, the CONFIG_RUSTC_* probe
# results, CONFIG_RUST_OVERFLOW_CHECKS, CONFIG_ANDROID_BINDER_IPC_RUST —
# and the Rust-only drivers that don't (CONFIG_DRM_NOVA,
# CONFIG_NOVA_CORE) are already unset there. None of them appears in an
# `#ifdef` inside struct module.
allowed_deltas=(
    'CONFIG_[A-Z0-9_]*RUST[A-Z0-9_]*'
)

delta_value() {
    # $1: normalized file, $2: symbol. Prints the whole value, which may
    # itself contain spaces (CONFIG_RUSTC_VERSION_TEXT, CONFIG_CC_VERSION_TEXT).
    LC_ALL=C awk -v k="$2" '$1 == k { sub(/^[^ ]+ /, ""); print; found = 1 }
                            END { if (!found) print "(absent)" }' "$1"
}

describe_delta() {
    printf '      %-48s %s -> %s\n' "$1" \
        "$(delta_value ../config.shipped.norm "$1")" \
        "$(delta_value ../config.reconciled.norm "$1")"
}

changed="$(LC_ALL=C comm -3 ../config.shipped.norm ../config.reconciled.norm \
    | awk '{ print $1 }' | LC_ALL=C sort -u)"

expected_changes=()
unexpected_changes=()
while IFS= read -r opt; do
    [ -n "${opt}" ] || continue
    allowed=false
    for pat in "${allowed_deltas[@]}"; do
        if [[ "${opt}" =~ ^${pat}$ ]]; then
            allowed=true
            break
        fi
    done
    if [ "${allowed}" = true ]; then
        expected_changes+=("${opt}")
    else
        unexpected_changes+=("${opt}")
    fi
done <<< "${changed}"

if [ "${#expected_changes[@]}" -gt 0 ]; then
    echo "==> olddefconfig resolved ${#expected_changes[@]} expected option(s) (the Rust disable above):"
    for opt in "${expected_changes[@]}"; do
        describe_delta "${opt}"
    done
fi

if [ "${#unexpected_changes[@]}" -gt 0 ]; then
    {
        echo "ERROR: 'make olddefconfig' silently changed ${#unexpected_changes[@]} option(s) this"
        echo "script did not ask it to:"
        echo
        for opt in "${unexpected_changes[@]}"; do
            describe_delta "${opt}"
        done
        echo
        echo "A build tree whose .config differs from the running kernel's is not the"
        echo "tree this repo needs: differences in struct module's #ifdef CONFIG_*"
        echo "blocks silently produce modules that compile, pass vermagic, and then"
        echo "fail to load with '-ENOEXEC / Invalid relocation target'."
        echo
        echo "Almost always this means a build tool some Kconfig symbol probes for is"
        echo "not installed in the Containerfile's kernel-src-builder stage, so"
        echo "Kconfig concluded the option is unavailable. Check the affected symbols'"
        echo "'depends on' lines for a *_VERSION or \$(success,...) probe — pahole"
        echo "(package: dwarves) for CONFIG_DEBUG_INFO_BTF is the known example — and"
        echo "install the missing package rather than accepting the changed option."
        echo
        echo "If a divergence really is harmless, add its symbol to allowed_deltas"
        echo "above WITH a comment saying why it can't affect the module ABI."
    } >&2
    exit 1
fi

echo "==> Guard OK: the reconciled .config matches Dakota's shipped one on every"
echo "    option except the expected Rust ones."

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
