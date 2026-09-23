#!/usr/bin/env bash
# Builds the exact GCC + binutils that built Dakota's own kernel, from
# official upstream source — not whatever Fedora happens to package.
#
# Dakota's kernel is built by freedesktop-sdk
# (elements/bootstrap/gcc.bst, elements/bootstrap/binutils.bst in the
# dakota/freedesktop-sdk repo), which pins exact upstream versions of
# its own, not synced with any Fedora release. The out-of-tree NVIDIA
# kmod needs a real relocation (init_module/cleanup_module in the
# kbuild-generated .gnu.linkonce.this_module section) resolved at
# insmod time by the running kernel's module loader — even a small
# toolchain gap there is enough to make that fail. See README.md,
# "Compiler version mismatch".
#
# Usage: build-toolchain.sh <install-prefix>
#
# Re-derive GCC_VERSION/BINUTILS_TAG whenever a base-image bump changes
# the kernel's own toolchain — check the new image's
# /usr/lib/modules/<kver>/config for CONFIG_CC_VERSION_TEXT (GCC) and
# boot it to read /proc/version (binutils; not present in the shipped
# .config). Cross-check both against freedesktop-sdk's own pins:
#   https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/raw/master/elements/include/gcc-source.yml
#   https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/raw/master/elements/bootstrap/include/binutils-source.yml
set -euo pipefail

prefix="$1"

# Official GCC release matching Dakota's CONFIG_CC_VERSION_TEXT
# ("gcc (GCC) 16.2.0"). freedesktop-sdk's gcc-source.yml pins the same
# tag byte-for-byte (releases/gcc-16.2.0-0-g78d4ac73dd391005b895a6148...).
gcc_version="16.2.0"

# freedesktop-sdk's binutils-source.yml pins commit
# 6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32, which its own ref string
# ("binutils-2_47-0-g6ce87bbc...") identifies as exactly the
# binutils-2_47 tag (the "-0-g" means zero commits past that tag).
binutils_tag="binutils-2_47"

nproc_val="$(nproc)"
workdir="$(mktemp -d)"
cd "$workdir"

echo "==> Building binutils (${binutils_tag}) into ${prefix}..."
git clone --branch "${binutils_tag}" --depth 1 \
    https://sourceware.org/git/binutils-gdb.git binutils-src
# freedesktop-sdk's own binutils.bst removes gdb outright
# (sourceware.org/bugzilla/29933) and disables the debugger pieces —
# mirrored here since we only need the assembler/linker/binutils, not
# a debugger, and it cuts build time.
rm -rf binutils-src/gdb binutils-src/gdbserver binutils-src/gdbsupport
mkdir binutils-build
(
    cd binutils-build
    ../binutils-src/configure \
        --prefix="${prefix}" \
        --disable-gdb \
        --disable-gdbserver \
        --disable-libdecnumber \
        --disable-readline \
        --disable-sim \
        --disable-nls
    make -j"${nproc_val}"
    make install-strip
)
rm -rf binutils-src binutils-build

echo "==> Building GCC ${gcc_version} into ${prefix}..."
curl -fsSL -o gcc.tar.xz \
    "https://ftp.gnu.org/gnu/gcc/gcc-${gcc_version}/gcc-${gcc_version}.tar.xz"
tar xf gcc.tar.xz
rm -f gcc.tar.xz
(
    cd "gcc-${gcc_version}"
    # Pulls gmp/mpfr/mpc/isl into the source tree so configure builds
    # them in-tree — the same approach freedesktop-sdk's gcc.bst takes
    # (bundling those instead of relying on a system copy), and the
    # simplest way to get a version set GCC itself has already vetted
    # for this release.
    ./contrib/download_prerequisites
)
mkdir gcc-build
(
    cd gcc-build
    # Only the pieces that can plausibly affect kernel-module codegen:
    # --disable-bootstrap (freedesktop-sdk's gcc.bst does too — a
    # single-stage build, not gcc's default 3-stage self-compare;
    # fine here since we're not shipping this compiler as a system
    # toolchain, just using it once to build kernel objects) and the
    # same --enable-default-pie/--enable-default-ssp/--enable-cet used
    # upstream. Kbuild itself overrides PIE/stack-protector/CET
    # defaults explicitly per its own .config either way (see
    # README.md) — matched here for completeness, not because it's
    # expected to matter.
    # PATH prepended so this build picks up the binutils just built
    # above (as/ld) instead of Fedora's.
    PATH="${prefix}/bin:${PATH}" \
    ../gcc-${gcc_version}/configure \
        --prefix="${prefix}" \
        --disable-multilib \
        --enable-languages=c \
        --disable-bootstrap \
        --enable-default-pie \
        --enable-default-ssp \
        --enable-cet \
        --disable-nls \
        --disable-libssp
    PATH="${prefix}/bin:${PATH}" make -j"${nproc_val}"
    PATH="${prefix}/bin:${PATH}" make install-strip
)
rm -rf "gcc-${gcc_version}" gcc-build

cd /
rm -rf "${workdir}"

echo "==> Toolchain built: $("${prefix}/bin/gcc" --version | head -n1)"
echo "==> $("${prefix}/bin/ld" --version | head -n1)"
