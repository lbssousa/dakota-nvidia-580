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
# Usage: build-kernel-src.sh <kver> <config-file> <output-dir> <module-symvers>
#   <module-symvers>  a Module.symvers derived from the target image's own
#                     vmlinux and shipped modules by
#                     scripts/gen-module-symvers.py. This script used to
#                     produce one by running `make vmlinux` here; see the
#                     comment above where it's installed for why it no
#                     longer does.
set -euo pipefail

kver="$1"
config_file="$2"
out_dir="$3"
module_symvers="$4"

if [ ! -s "${module_symvers}" ]; then
    echo "ERROR: ${module_symvers} is missing or empty. It should have been" >&2
    echo "produced by scripts/gen-module-symvers.py in the kernel-headers" >&2
    echo "stage, from the Dakota image's own /usr/lib/modules/<kver>/vmlinux" >&2
    echo "and kernel/**/*.ko." >&2
    exit 1
fi

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
# here, before modules_prepare below spends any time on a tree that is
# already wrong. scripts/module-abi.py is the second, structural half of the
# same defence — it checks the resulting .ko against the running
# kernel's own BTF, catching a layout mismatch whatever its cause.
# ---------------------------------------------------------------------
normalize_config() {
    # "CONFIG_X=v" -> "CONFIG_X<TAB>v", "# CONFIG_X is not set" ->
    # "CONFIG_X<TAB>n". Comparing name/value pairs rather than raw lines is
    # what makes a shipped "=y" turning into "is not set" register as a
    # changed option instead of an unrelated deleted line and added comment.
    # The separator is a tab because values contain spaces
    # (CONFIG_CC_VERSION_TEXT, CONFIG_ANDROID_BINDER_DEVICES).
    sed -nE -e 's/^(CONFIG_[A-Za-z0-9_]+)=(.*)$/\1\t\2/p' \
            -e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1\tn/p' "$1" \
        | LC_ALL=C sort
}

normalize_config "${config_file}" > ../config.shipped.norm
normalize_config .config          > ../config.reconciled.norm

# Symbol names allowed to differ, as anchored extended regexes. Add to
# this list only alongside a comment explaining why that divergence
# can't affect the module ABI.
#
# The Rust entries cover the deliberate `scripts/config --disable RUST`
# above — and, equally, the fact that Kconfig would drop RUST here by itself
# regardless (CONFIG_RUST depends on RUST_IS_AVAILABLE, another tool probe:
# scripts/rust_is_available.sh, and this stage installs no rustc).
# CONFIG_BINDGEN_VERSION_TEXT belongs to that same probe result set despite
# not carrying RUST in its name.
allowed_deltas=(
    'CONFIG_[A-Z0-9_]*RUST[A-Z0-9_]*'
    'CONFIG_BINDGEN_VERSION(_TEXT)?'

    # The one place the Rust cascade reaches a symbol whose name gives no
    # hint of it. Dakota builds the Rust binder rather than the C one
    # (CONFIG_ANDROID_BINDER_IPC unset, CONFIG_ANDROID_BINDER_IPC_RUST=y),
    # and drivers/android/Kconfig declares the device-name string
    # `depends on ANDROID_BINDER_IPC || ANDROID_BINDER_IPC_RUST` — so
    # dropping Rust leaves it with no satisfied dependency and Kconfig stops
    # writing it at all. It is a string naming Android binder device nodes,
    # for a driver this tree does not build and that no header a module
    # compiles against ever reads.
    'CONFIG_ANDROID_BINDER_DEVICES'

    # --- Toolchain and build-environment probes ---
    #
    # Kconfig recomputes every symbol that has no prompt: its `default`
    # is evaluated fresh and the value in the .config is ignored. A large
    # family of those defaults probe the *installed* toolchain rather
    # than describing the kernel:
    #
    #   config CC_VERSION_TEXT  string  default "$(CC_VERSION_TEXT)"
    #   config GCC_VERSION      int     default $(cc-version) if CC_IS_GCC
    #   config PAHOLE_VERSION   int     default "$(PAHOLE_VERSION)"
    #
    # This stage runs on Fedora's gcc/binutils/pahole, not the ones
    # freedesktop-sdk built Dakota's kernel with, so all 62 of these in
    # Dakota's shipped .config are guaranteed to differ — e.g.
    # CC_VERSION_TEXT="gcc (GCC) 16.2.0" and PAHOLE_VERSION=131 there vs
    # Fedora 44's own. Failing on them would mean the guard could never
    # pass, so they are allowed.
    #
    # What makes that safe is that a probe only ever *describes* the
    # toolchain; anything it actually gates shows up in a separate,
    # non-probe symbol that this guard still checks. If Fedora's compiler
    # lacked something Dakota's had and a real feature got dropped as a
    # result, the failure would surface as that feature's own symbol —
    # CONFIG_STACKPROTECTOR, say — which is not in this list.
    #
    # Hence enumerated patterns rather than a family wildcard: a blanket
    # 'CONFIG_CC_.*' would also swallow CC_OPTIMIZE_FOR_PERFORMANCE (a
    # real codegen choice), and 'CONFIG_GCC_.*' would swallow the
    # GCC_PLUGIN_* family, which is where GCC_PLUGIN_RANDSTRUCT lives —
    # an option that genuinely reorders structs. Both stay checked.
    'CONFIG_(CC|AS|LD|GCC|CLANG|LLD|PAHOLE)_VERSION(_TEXT)?'
    'CONFIG_(CC|AS|LD)_IS_[A-Z0-9_]+'
    'CONFIG_(CC|AS|LD|PAHOLE)_HAS_[A-Z0-9_]+'
    'CONFIG_(CC|LD)_CAN_[A-Z0-9_]+'
    'CONFIG_TOOLS_SUPPORT_[A-Z0-9_]+'
    'CONFIG_AS_WRUSS'
    # Warning-flag strings and suppressions selected by compiler version.
    'CONFIG_CC_(IMPLICIT_FALLTHROUGH|MS_EXTENSIONS|NO_ARRAY_BOUNDS|NO_STRINGOP_OVERFLOW)'
    'CONFIG_GCC_NO_STRINGOP_OVERFLOW'
    'CONFIG_LD_ORPHAN_WARN(_LEVEL)?'
    # The bare plugin-infrastructure flag, gated on gcc-plugin-devel's
    # plugin-version.h being installed. Dakota ships CONFIG_GCC_PLUGINS=y
    # but selects no plugin at all (GCC_PLUGIN_LATENT_ENTROPY unset,
    # GCC_PLUGIN_RANDSTRUCT not even present), so on this .config it
    # enables nothing and gates nothing in the headers a module compiles
    # against. Every individual CONFIG_GCC_PLUGIN_* stays checked, so if
    # Dakota ever turns one on, this guard catches it. Installing
    # gcc-plugin-devel in the Containerfile would let this entry be
    # dropped, at the cost of another package in the stage.
    'CONFIG_GCC_PLUGINS'
)

delta_value() {
    # $1: normalized file, $2: symbol. A symbol with no line at all reports as
    # "n", because that is what it means: Kconfig writes nothing for a symbol
    # whose dependencies are unmet, and such a symbol is no more enabled than
    # one spelled out as "is not set".
    LC_ALL=C awk -F'\t' -v k="$2" '$1 == k { print $2; found = 1 }
                                   END { if (!found) print "n" }' "$1"
}

describe_delta() {
    printf '      %-48s %s -> %s\n' "$1" \
        "$(delta_value ../config.shipped.norm "$1")" \
        "$(delta_value ../config.reconciled.norm "$1")"
}

# Compare over the union of both symbol sets, treating a symbol absent from
# a file as "n". Kconfig writes no line at all for a symbol whose
# dependencies are unmet, so "# CONFIG_X is not set" becoming "not mentioned
# anywhere" is not a change in the kernel's configuration -- it is the same
# disabled option, described differently. A line-wise diff reports six such
# non-events on this .config (DRM_NOVA, NOVA_CORE, KSTACK_ERASE,
# RANDSTRUCT_FULL, RANDSTRUCT_PERFORMANCE, GCC_PLUGIN_LATENT_ENTROPY), which
# would have made this guard unusable while telling us nothing.
changed="$(LC_ALL=C awk -F'\t' '
    NR == FNR { shipped[$1] = $2; next }
    { rebuilt[$1] = $2 }
    END {
        for (k in shipped) {
            if (k in rebuilt) {
                if (shipped[k] != rebuilt[k]) print k
            } else if (shipped[k] != "n") {
                print k
            }
        }
        for (k in rebuilt) {
            if (!(k in shipped) && rebuilt[k] != "n") print k
        }
    }' ../config.shipped.norm ../config.reconciled.norm | LC_ALL=C sort -u)"

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
    echo "==> olddefconfig resolved ${#expected_changes[@]} expected option(s) (the Rust"
    echo "    disable above, plus this stage's own toolchain-probe results):"
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
echo "    option that describes the kernel. Only Rust and toolchain-probe symbols"
echo "    differ, which is expected and explained in allowed_deltas above."

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

# Module.symvers is NOT produced here any more, and that is the single
# biggest simplification in this repo.
#
# An external module build needs it for two things: modpost resolves the
# module's undefined symbols against it (and derives the .ko's `depends=`
# from it), and NVIDIA's own conftest.sh greps it for the *exact* export
# line of each symbol it feature-tests -- silently assuming "not present",
# and falling back to APIs long removed from modern kernels, whenever the
# file is missing or incomplete. `modules_prepare` alone never produces
# one.
#
# This script used to get one by running `make vmlinux` (a full kernel
# compile, a final link needing several GB of RAM in one non-parallel
# step, and -- since CONFIG_DEBUG_INFO_BTF has to stay on for ABI reasons,
# see the guard above -- a `pahole -J` pass over a fully DWARF-annotated
# vmlinux), followed by two scoped module builds for the DRM exports
# `make vmlinux` leaves out.
#
# All of that reconstructed information the target image already contains,
# fully resolved: /usr/lib/modules/<kver>/vmlinux carries every built-in
# export in its __ksymtab/__kflagstab/__ksymtab_strings sections, and
# every loadable module under /usr/lib/modules/<kver>/kernel/ carries its
# own -- including ttm.ko and drm_ttm_helper.ko, the two this script used
# to compile by hand. scripts/gen-module-symvers.py reads them directly,
# in about two seconds, and the kernel-headers stage runs it. The result
# is also strictly more complete than what was built here before: every
# module in the image contributes, so a future NVIDIA release needing a
# symbol from some other module no longer requires anyone to find and add
# its build target.
#
# One consequence worth knowing: with no vmlinux in the assembled tree,
# kbuild skips BTF generation for the modules built against it --
# scripts/Makefile.modfinal's cmd_btf_ko tests for $(objtree)/vmlinux and
# prints "Skipping BTF generation ... due to unavailability of vmlinux"
# rather than failing. That was already the case before this change (the
# to_copy list below never included vmlinux either), it needs no pahole in
# the nvidia-builder stage, and module BTF is introspection metadata for
# BPF tooling -- nothing to do with whether the module loads.
echo "==> Using the Module.symvers derived from the image's own binaries:"
echo "      ${module_symvers} ($(wc -l < "${module_symvers}") exports)"

echo "==> Assembling the linux.bst-shaped output tree in ${out_dir}..."

targetdir="${out_dir}/src/linux-${release}"
mkdir -p "${targetdir}"

# Mirrors freedesktop-sdk's own linux.bst / linux-ogc.bst install-commands
# 'to_copy' list exactly — this is the artifact shape nvidia-drivers.bst
# itself compiles against upstream. Module.symvers is added separately
# below, from the file derived out of the image's own binaries (see the
# comment above), and vmlinux is deliberately not among these: kbuild
# then skips module BTF generation instead of needing pahole here.
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
cp -aT "${module_symvers}" "${targetdir}/Module.symvers"

mkdir -p "${out_dir}/lib/modules/${release}"
ln -sr "${targetdir}" "${out_dir}/lib/modules/${release}/build"

echo "==> build-kernel-src.sh done: ${targetdir}"
