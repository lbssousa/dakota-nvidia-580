# syntax=docker/dockerfile:1.7
#
# Custom Dakota image: proprietary NVIDIA driver on the legacy 580.xxx
# branch (for a GPU generation no longer supported by the official
# dakota-nvidia / dakota-nvidia-gaming variants, which track the newer
# branch, ~610.x/615.x as of 2026) + the lbssousa/libfprint fork
# (Goodix 538d) + Yubico's pam-u2f (YubiKey FIDO2/U2F PAM module +
# pamu2fcfg) + Epson's epson-printer-utility, baked in via downstream
# OCI image layering — not via forking the upstream BuildStream build.
# See README.md for the full reasoning (why downstream instead of a
# BuildStream fork) and known limitations.
#
# The published Dakota images do NOT expose a usable kernel build tree
# at /usr/lib/modules/<kver>/build — the symlink is there, but its
# target (/usr/src/linux-<kver>) is empty (see README.md, "Why
# /usr/lib/modules/<kver>/build is missing"). Upstream's own
# nvidia-drivers.bst never hits this because it builds inside
# BuildStream, where freedesktop-sdk.bst:components/linux.bst (or, for
# -gaming, elements/core/linux-ogc.bst) is staged as an ordinary
# build-dependency.
#
# The kernel-src-builder stage below reconstructs that same tree
# ourselves outside BuildStream: it fetches the matching upstream
# kernel source (vanilla kernel.org for the standard variant,
# OpenGamingCollective/linux.git for -gaming — auto-detected from the
# kernel version string) and configures it with the exact .config the
# running kernel was built with, which the runtime image DOES ship at
# /usr/lib/modules/<kver>/config. See scripts/build-kernel-src.sh and
# README.md for the full derivation and its residual risks.

# Latest release of the 580 branch, which is what this repo is named
# for and builds. Bumping WITHIN the branch is routine — the
# .github/workflows/nvidia-driver-update.yml watcher opens a PR for it.
# Changing the branch (590/595/610/615 are all published too, and still
# list this repo's target Pascal GPUs as current) is not: it would make
# the "580" in the repo and image names wrong, and the kernel-7.x
# workarounds in scripts/build-nvidia.sh would need re-deriving. The
# watcher therefore reports a newer branch without ever proposing it.
ARG NVIDIA_VERSION=580.178.04
ARG LIBFPRINT_REPO=https://github.com/lbssousa/libfprint.git
# Pinned to a tag, not a branch: a tag is an immutable, reviewed
# release point, so bumping this value is a deliberate, visible change.
# Check https://github.com/lbssousa/libfprint/tags for newer releases
# before bumping.
ARG LIBFPRINT_REF=v1.94.10-goodix538d.2
# pam-u2f (upstream Yubico, not a fork): provides pam_u2f.so + pamu2fcfg,
# the PAM module and enrollment CLI needed to use a YubiKey for FIDO2/U2F
# PAM authentication — neither can come from Homebrew, since PAM modules
# must live in the system's PAM module directory to be loadable by
# gdm/sudo/su at all (a module under /home/linuxbrew is not on that
# path). Its own runtime dependency, libfido2, IS left to `brew install
# libfido2`, matching what lbssousa/bluefin-initial-setup
# (playbooks/yubikey.yml) already documents/assumes for Fedora Dakota
# hosts — not independently verified here that ldconfig actually
# resolves the Homebrew-provided libfido2.so for a module living in
# /usr on THIS image; this repo's base image ships no linuxbrew
# ld.so.conf.d entry out of the box (checked directly), so that must
# come from whatever installs Homebrew on the running host. Re-verify
# before relying on this at login/sudo time.
ARG PAM_U2F_REPO=https://github.com/Yubico/pam-u2f.git
ARG PAM_U2F_REF=pam_u2f-1.4.0

# On by default: revert three of Bluefin's default GNOME customizations
# back to stock GNOME behavior (set to "false" to keep Bluefin's own
# desktop defaults instead). Bluefin bakes its desktop defaults into
# /usr/share/glib-2.0/schemas/zz0-bluefin-modifications.gschema.override
# (a GSettings *default-value* override, compiled into
# gschemas.compiled — a per-user dconf still wins over it, this only
# changes what a fresh account starts with). When set to "true", the
# final stage below adds a same-mechanism override file that sorts
# after Bluefin's own (zz0 and zz3) so it wins on any key both define,
# and re-runs glib-compile-schemas:
#   - window titlebar buttons: Bluefin's button-layout is
#     ":minimize,maximize,close"; this reverts to ":close".
#   - hot corners: Bluefin sets enable-hot-corners=false; this reverts
#     to true.
#   - Blur my Shell (blur-my-shell@aunetx) and Dash to Dock
#     (dash-to-dock@micxgx.gmail.com) are force-disabled via the
#     `disabled-extensions` gsettings key, which
#     org.gnome.shell.gschema.xml documents as taking precedence over
#     `enabled-extensions` — more robust than trying to strip them out
#     of Bluefin's own enabled-extensions list, which is set in two
#     separate override files.
ARG DISABLE_BLUEFIN_GNOME_TWEAKS=true

# Identity this downstream image reports as, in place of the upstream
# Dakota base it's layered on. Rewritten in the final stage below into
# both /etc/os-release's IMAGE_NAME/IMAGE_VENDOR/IMAGE_TAG/IMAGE_REF
# fields AND /usr/share/ublue-os/image-info.json. The latter is what
# actually matters for `uwelcome` (Dakota's login banner,
# github.com/projectbluefin/uwelcome, internal/system/system.go
# GetImageInfo()): it reads ONLY that JSON file for the "<oci-symbol>
# `<ref>:<tag>`" banner line, never the os-release fields — the
# os-release rewrite is kept as a Universal Blue convention other
# tooling may read, but image-info.json is the one that drives the
# banner. CI overrides IMAGE_NAME per matrix leg (standard vs
# "-gaming") — see .github/workflows/build.yml. IMAGE_TAG default
# matches what CI actually publishes on every build ("latest" — see
# README.md, "CI and automatic updates"): :stable is a later,
# unrelated registry retag of a past :latest digest, promoted weekly
# with no rebuild, so the image never gets built with IMAGE_TAG=stable
# — its self-reported identity correctly says "latest" even once
# viewed through the :stable tag, the same way upstream Dakota's own
# build always embeds "latest" as its OCI_IMAGE_VERSION regardless of
# which stream tag (:testing/:next/:stable) ends up pointing at it.
ARG IMAGE_NAME=dakota-nvidia-580
ARG IMAGE_VENDOR=lbssousa
ARG IMAGE_TAG=latest

# ---------------------------------------------------------------------
# dakota-base — ALWAYS pinned by digest, never a floating tag ("stable"
# changes content over time). The NVIDIA module below is compiled
# against this exact image's kernel; if the digest changes without a
# rebuild, the result is a new kernel paired with a stale .ko (it won't
# load, or worse, it loads and is unstable). Renovate (renovate.json5)
# opens a PR when either digest below changes; CI builds both variants
# from that PR.
#
# BASE_IMAGE is what FROM actually resolves below — the "standard"
# Dakota variant, built by default. BASE_IMAGE_GAMING isn't consumed
# by any FROM in this file: CI's build matrix
# (.github/workflows/build.yml) reads it straight out of this file and
# passes it as `--build-arg BASE_IMAGE=...` for the "-gaming" leg, so
# the gaming variant's kernel (the Open Gaming Collective/OGC kernel —
# see docs.projectbluefin.io/dakota) gets picked up with no
# Containerfile changes needed. Keeping both pins here, not only in
# the workflow, gives Renovate a single place to bump digests in.
# ---------------------------------------------------------------------
ARG BASE_IMAGE=ghcr.io/projectbluefin/dakota:stable@sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8
ARG BASE_IMAGE_GAMING=ghcr.io/projectbluefin/dakota-gaming:stable@sha256:e0670ab927e6762e175a73a1ed47b54215163170a5efe407472640c1ac9951ea
# ^ resolved via (re-run before every build — these drift):
#   skopeo inspect docker://ghcr.io/projectbluefin/dakota:stable | jq -r .Digest
#   skopeo inspect docker://ghcr.io/projectbluefin/dakota-gaming:stable | jq -r .Digest

FROM ${BASE_IMAGE} AS dakota-base

# ---------------------------------------------------------------------
# kernel-headers — extracts the three pieces of ground truth every
# stage below works from, straight out of this specific image:
#
#   /kernel-version        this image's kernel release string.
#   /kernel-config         the exact .config it was built with — what
#                          kernel-src-builder reconstructs a build tree
#                          from.
#   /kernel-module-abi.json  the authoritative layout of `struct module`,
#                          read out of the image's own
#                          /usr/lib/modules/<kver>/vmlinux .BTF section.
#                          nvidia-builder checks the modules it built
#                          against this, so a build tree that diverged
#                          from this kernel fails the build instead of
#                          the boot. See scripts/module-abi.py.
#   /kernel-module-symvers   a real Module.symvers, read out of that same
#                          vmlinux's __ksymtab/__kflagstab sections plus
#                          every module under /usr/lib/modules/<kver>/
#                          kernel/. This replaces the `make vmlinux` that
#                          kernel-src-builder used to run purely to
#                          produce one — a full kernel compile, for
#                          information the image already contains. See
#                          scripts/gen-module-symvers.py.
#
# Fails loudly and early if the image doesn't even ship the .config —
# that would mean Dakota's kernel packaging changed more deeply than the
# missing-build-tree issue this repo works around.
#
# Everything here runs with the base image's own tooling (python3 only —
# both scripts deliberately share a small ELF reader of their own,
# kernel_elf.py, rather than depending on bpftool, pahole or binutils
# being present in a runtime image).
# ---------------------------------------------------------------------
FROM dakota-base AS kernel-headers
COPY scripts/kernel_elf.py /kernel_elf.py
COPY scripts/module-abi.py /module-abi.py
COPY scripts/gen-module-symvers.py /gen-module-symvers.py
RUN set -eux; \
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"; \
    echo "$kver" > /kernel-version; \
    if [ ! -f "/usr/lib/modules/$kver/config" ]; then \
        echo "ERROR: /usr/lib/modules/$kver/config is missing from this" >&2; \
        echo "Dakota image — can't reconstruct a matching kernel build" >&2; \
        echo "tree without the exact .config the running kernel used." >&2; \
        echo "See README.md, section 'Why /usr/lib/modules/<kver>/build" >&2; \
        echo "is missing'." >&2; \
        exit 1; \
    fi; \
    cp "/usr/lib/modules/$kver/config" /kernel-config; \
    python3 /module-abi.py extract "$kver" \
        "/usr/lib/modules/$kver/vmlinux" /kernel-module-abi.json; \
    python3 /gen-module-symvers.py "/usr/lib/modules/$kver" /kernel-module-symvers

# ---------------------------------------------------------------------
# kernel-src-builder — Fedora used only as a build environment;
# reconstructs a real /lib/modules/<kver>/build tree (Makefile,
# headers, scripts, objtool) from upstream kernel source + the exact
# .config extracted above, via scripts/build-kernel-src.sh. See that
# script and README.md for the full rationale.
#
# Uses Fedora 44's own gcc/binutils, as nvidia-builder below does too
# (see that stage's comment on why): this stage compiles
# no kernel code at all any more. `modules_prepare` generates headers and
# builds host tools (scripts/, objtool) that never ship and never run on
# the target, so which compiler produced them doesn't matter.
#
# The .config this stage reconciles is a different matter entirely: it
# decides the layout of `struct module`, which every module compiled
# against the resulting tree bakes into its own
# .gnu.linkonce.this_module relocations. Get it wrong and the modules
# compile, link, and pass vermagic, then fail to load. That's why
# build-kernel-src.sh aborts on any option `make olddefconfig` silently
# changes, and why the package list below is ABI-relevant rather than
# merely sufficient to compile.
# ---------------------------------------------------------------------
FROM fedora:44 AS kernel-src-builder
# dwarves (i.e. pahole) is not a nicety here — leaving it out silently
# changes the module ABI. CONFIG_DEBUG_INFO_BTF `depends on
# PAHOLE_VERSION >= 122`, and scripts/pahole-version.sh reports 0 when
# pahole isn't on PATH, so `make olddefconfig` quietly drops Dakota's
# shipped CONFIG_DEBUG_INFO_BTF=y along with CONFIG_DEBUG_INFO_BTF_MODULES=y.
# The latter contributes 24 bytes to `struct module` (btf_data_size,
# btf_base_data_size, btf_data, btf_base_data) between its `init` and
# `exit` members, so without pahole every NVIDIA module builds cleanly
# and then refuses to load at boot with "x86/modules: Invalid relocation
# target, existing value is nonzero" / -ENOEXEC — its `exit` relocation
# pointing 24 bytes early, at source_list.prev. See README.md, "struct
# module layout must match the running kernel".
#
# Note that pahole is needed only so Kconfig keeps the option: nothing
# here runs `pahole -J`. This stage no longer builds vmlinux at all (see
# build-kernel-src.sh), which is why zlib/zstd/pkgconf — needed only to
# build tools/bpf/resolve_btfids during that link — are gone.
#
# openssl (the CLI) stays, for a different reason than it was originally
# added. It is no longer needed for certs/Makefile's gen_key rule, since
# nothing links a vmlinux to sign, but certs/Kconfig probes the binary
# directly:
#
#   config OPENSSL_SUPPORTS_ML_DSA
#           def_bool $(success, openssl list -key-managers | grep -q ML-DSA-87)
#
# Without the CLI that comes out different from Dakota's own .config, and
# build-kernel-src.sh's guard rightly refuses to build against a tree whose
# configuration silently drifted. (Found by actually running the stage, not
# by reading it.)
RUN dnf install -y gcc make bison flex bc elfutils-libelf-devel \
        openssl openssl-devel perl findutils diffutils ncurses-devel \
        dwarves git curl tar xz which hostname && \
    dnf clean all
COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=kernel-headers /kernel-config /kernel-config
COPY --from=kernel-headers /kernel-module-symvers /kernel-module-symvers
COPY scripts/build-kernel-src.sh /build-kernel-src.sh
RUN chmod +x /build-kernel-src.sh && \
    /build-kernel-src.sh "$(cat /kernel-version)" /kernel-config /out \
        /kernel-module-symvers

# ---------------------------------------------------------------------
# libfprint-probe — locates the exact path of the libfprint shared
# library already shipped in the Dakota base image, so the build below
# can install to that same libdir and genuinely overwrite it instead
# of landing in a different, distro-conventional path (Fedora defaults
# to lib64; a freedesktop-sdk/GNOME OS build like Dakota may not).
# ---------------------------------------------------------------------
FROM dakota-base AS libfprint-probe
RUN set -eux; \
    so="$(find /usr/lib* -name 'libfprint-2.so*' 2>/dev/null | head -n1)"; \
    if [ -z "$so" ]; then \
        echo "ERROR: libfprint-2.so not found in this Dakota base image." >&2; \
        echo "Can't determine the libdir to overwrite it in-place." >&2; \
        exit 1; \
    fi; \
    dirname "$so" > /libfprint-libdir; \
    echo "Found libfprint at: $so (libdir: $(cat /libfprint-libdir))" >&2

# ---------------------------------------------------------------------
# pam-u2f-probe — same idea as libfprint-probe above, but for the PAM
# module directory: locates it by finding pam_unix.so (always present —
# it's what local password auth uses), rather than assuming a
# distro-conventional path. Confirmed on this base image to NOT be a
# plain lib64/security path: it's /usr/lib/x86_64-linux-gnu/security
# (Debian-style multiarch), while /usr/lib/security exists too but only
# holds an unrelated pam_apparmor.so — installing pam_u2f.so into the
# wrong one of the two would make it silently unloadable by PAM.
# ---------------------------------------------------------------------
FROM dakota-base AS pam-u2f-probe
RUN set -eux; \
    so="$(find /usr/lib* -name 'pam_unix.so' 2>/dev/null | head -n1)"; \
    if [ -z "$so" ]; then \
        echo "ERROR: pam_unix.so not found in this Dakota base image." >&2; \
        echo "Can't determine where PAM security modules live." >&2; \
        exit 1; \
    fi; \
    dirname "$so" > /pam-u2f-libdir; \
    echo "Found PAM modules at: $so (dir: $(cat /pam-u2f-libdir))" >&2

# ---------------------------------------------------------------------
# nvidia-libdir-probe — same idea as libfprint-probe/pam-u2f-probe
# above, applied to NVIDIA's userspace libraries: locates the real
# 64-bit library directory already used in the Dakota base image by
# finding libGL.so.1 (Mesa's, present in every variant), rather than
# assuming a distro-conventional path. `nvidia-installer` runs inside
# the plain fedora:44 nvidia-builder stage below, where the RHEL/Fedora
# convention (64-bit libs under /usr/lib64) holds — but Dakota/GNOME OS
# uses a Debian-style multiarch layout instead
# (/usr/lib/x86_64-linux-gnu, confirmed here the same way
# pam-u2f-probe confirmed /usr/lib/x86_64-linux-gnu/security below).
# Left uncorrected, the installer's own directory auto-detection (and
# its 32-bit-compat auto-detection, which sees Fedora's own multilib
# packages, not Dakota's — Dakota has no 32-bit multiarch directory at
# all) puts every NVIDIA .so under /usr/lib64 and /usr/lib, neither of
# which Dakota's ldconfig ever scans by default: the kernel module
# still loads fine, but nvidia-smi/nvidia-settings/anything else that
# dlopens libnvidia-ml.so.1 or libnvidia-cfg.so.1 fails outright. See
# README.md, "How the NVIDIA userspace libraries are installed".
# ---------------------------------------------------------------------
FROM dakota-base AS nvidia-libdir-probe
RUN set -eux; \
    so="$(find /usr/lib* -name 'libGL.so.1*' 2>/dev/null | head -n1)"; \
    if [ -z "$so" ]; then \
        echo "ERROR: libGL.so.1 not found in this Dakota base image." >&2; \
        echo "Can't determine the libdir NVIDIA's userspace libraries need to install into." >&2; \
        exit 1; \
    fi; \
    dirname "$so" > /nvidia-libdir; \
    echo "Found the runtime library dir at: $so (libdir: $(cat /nvidia-libdir))" >&2

# ---------------------------------------------------------------------
# nvidia-builder — Fedora used only as a build environment (dnf/gcc/
# make/kmod/...); nothing here ends up in the final image except what
# build-nvidia.sh explicitly packages into /out.
#
# The compiler and linker used to come from a toolchain-builder stage that
# built GCC 16.2.0 + binutils 2.47 from upstream source, at the pins
# freedesktop-sdk uses for Dakota's own kernel, because Fedora's own
# gcc/binutils were believed not to be good enough — the claim being that
# a micro-version of GCC drift made nvidia.ko fail at insmod with
# "Invalid relocation target, existing value is nonzero" in
# .gnu.linkonce.this_module.
#
# That diagnosis was wrong. The real cause was a `struct module` layout
# mismatch from a silently dropped .config option (see README.md,
# "`struct module` layout must match the running kernel"), now fixed and
# guarded structurally by scripts/module-abi.py. The from-source toolchain
# was the slowest step in every CI run and rested on that superseded
# explanation, so it was removed; `git log -- scripts/build-toolchain.sh`
# has it if it is ever needed back.
#
# What is verifiably true about the compiler check either way: nothing in
# this build distinguishes the two compilers.
#   - NVIDIA's own cc_sanity_check (kernel/conftest.sh) parses only
#     major.minor out of include/generated/compile.h's LINUX_COMPILER and
#     compares it to __GNUC__/__GNUC_MINOR__. Dakota's kernel GCC is
#     16.2.0 and Fedora 44's is 16.2.1: both are "16.2", so the check
#     passes with or without this stage, and cannot see a micro-version
#     drift at all.
#   - The tree's own CONFIG_CC_VERSION_TEXT is Fedora's, not Dakota's,
#     because `make olddefconfig` in kernel-src-builder recomputes it
#     from the compiler actually present there. Using Fedora's gcc here
#     therefore makes the module and the tree it is built against
#     self-consistent for the first time.
#
# What no check can settle is whether a module built by 16.2.1 against a
# kernel built by 16.2.0 loads and behaves. A local build compared the
# five resulting modules against the from-source-toolchain reference and
# found identical section sets, identical undefined-symbol sets and no
# unresolved externals — but codegen stays unobserved, and only real
# hardware answers it. See README.md, "Known limitations".
# ---------------------------------------------------------------------
FROM fedora:44 AS nvidia-builder
ARG NVIDIA_VERSION
# gcc/binutils now come from Fedora (the experiment above). python3 runs
# scripts/module-abi.py, which build-nvidia.sh invokes on the freshly
# built .ko files before packaging them.
RUN dnf install -y gcc binutils make kmod elfutils-libelf-devel \
        perl-interpreter python3 tar xz curl which && \
    dnf clean all
COPY --from=kernel-src-builder /out/ /kernel-src/
COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=kernel-headers /kernel-module-abi.json /kernel-module-abi.json
COPY --from=nvidia-libdir-probe /nvidia-libdir /nvidia-libdir
COPY scripts/kernel_elf.py /kernel_elf.py
COPY scripts/module-abi.py /module-abi.py
COPY scripts/build-nvidia.sh /build-nvidia.sh
RUN chmod +x /build-nvidia.sh && /build-nvidia.sh "${NVIDIA_VERSION}" /kernel-src /out "$(cat /nvidia-libdir)"

# ---------------------------------------------------------------------
# libfprint-builder — same fork/ref used in
# lbssousa/bluefin-initial-setup (playbooks/dakota/libfprint.yml,
# dakota_libfprint_repo/_ref vars in group_vars/all/dakota.yml), which
# installs the same fork at runtime via distrobox for Dakota hosts not
# using this custom image.
#
# The goodixtls53xd driver's SIGFM matcher is a self-contained
# implementation with no OpenCV dependency at all — no opencv-devel,
# and nothing to vendor or statically link. systemd-udev provides
# udev.pc, needed for the driver's udev-rules install path.
#
# Installed straight into the libdir found by libfprint-probe, under
# --prefix=/usr: this overwrites the stock libfprint shipped in the
# Dakota base image in place, rather than adding a parallel copy under
# /usr/local that would need an LD_LIBRARY_PATH override to be picked
# up by fprintd.
# ---------------------------------------------------------------------
FROM fedora:44 AS libfprint-builder
ARG LIBFPRINT_REPO
ARG LIBFPRINT_REF
RUN dnf install -y meson gcc gcc-c++ ninja-build pkgconf-pkg-config \
        openssl-devel glib2-devel gobject-introspection-devel \
        libgudev-devel libgusb-devel systemd-devel systemd-udev nss-devel \
        pixman-devel gtk-doc python3-cairo python3-gobject cairo-devel \
        umockdev git && \
    dnf clean all
COPY --from=libfprint-probe /libfprint-libdir /libfprint-libdir
RUN git clone --branch "${LIBFPRINT_REF}" --depth 1 "${LIBFPRINT_REPO}" /src
RUN libdir="$(cat /libfprint-libdir)" && \
    meson setup /src/builddir /src --prefix=/usr --libdir="${libdir}" -Ddrivers=all && \
    ninja -C /src/builddir && \
    DESTDIR=/out ninja -C /src/builddir install

# ---------------------------------------------------------------------
# pam-u2f-builder — builds Yubico's own pam-u2f (upstream, not a fork)
# from source: pam_u2f.so (the PAM module) + pamu2fcfg (the CLI used to
# enroll a YubiKey and generate ~/.config/Yubico/u2f_keys — see
# lbssousa/bluefin-initial-setup playbooks/yubikey.yml for the intended
# usage). Man pages are skipped (-DBUILD_MANPAGES=OFF) since building
# them needs asciidoc/a2x, an extra dependency for something outside
# this task's scope (libraries + executables only).
#
# libfido2-devel is a BUILD-time only dependency here (needed to link
# pam_u2f.so/pamu2fcfg against libfido2's headers/.so) — the runtime
# libfido2.so itself is deliberately not copied into the final image;
# see the PAM_U2F_REPO/REF comment near the top of this file for why.
#
# pam_u2f.so is installed into the exact directory pam-u2f-probe found
# (-DPAM_DIR), same reasoning as libfprint-builder's --libdir above.
# pamu2fcfg has no such ambiguity — CMake's default GNUInstallDirs
# always resolves its bin dir to /usr/bin here.
# ---------------------------------------------------------------------
FROM fedora:44 AS pam-u2f-builder
ARG PAM_U2F_REPO
ARG PAM_U2F_REF
RUN dnf install -y cmake gcc make pkgconf-pkg-config pam-devel \
        openssl-devel libfido2-devel git && \
    dnf clean all
COPY --from=pam-u2f-probe /pam-u2f-libdir /pam-u2f-libdir
RUN git clone --branch "${PAM_U2F_REF}" --depth 1 "${PAM_U2F_REPO}" /src
RUN pamdir="$(cat /pam-u2f-libdir)" && \
    cmake -S /src -B /src/build \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DPAM_DIR="${pamdir}" \
        -DBUILD_MANPAGES=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build /src/build --parallel && \
    DESTDIR=/out cmake --install /src/build

# ---------------------------------------------------------------------
# epson-builder — Fedora used only to download and unpack Epson's
# binary epson-printer-utility RPM, keeping just the CUPS backend
# (rastertoepson filter) and the ecbd network-discovery daemon — not
# the Qt5 setup/maintenance GUI, which Dakota can't run (see
# scripts/install-epson-utility.sh) — via
# scripts/install-epson-utility.sh, adapted from lbssousa/bluefin's
# build_files/20-epson.sh. Only rpm2cpio/cpio/curl are needed; nothing
# here is compiled, and no dnf/rpm database ends up in the final
# image, since Dakota (GNOME OS) has neither.
# ---------------------------------------------------------------------
FROM fedora:42 AS epson-builder
RUN dnf install -y curl cpio rpm && \
    dnf clean all
COPY scripts/install-epson-utility.sh /install-epson-utility.sh
RUN chmod +x /install-epson-utility.sh && /install-epson-utility.sh /out

# ---------------------------------------------------------------------
# final — Dakota + all payloads, baked into the image. /usr is
# writable during the build (it only becomes read-only at runtime via
# composefs), so writing straight into it — including overwriting the
# stock libfprint files at their original path — works, unlike the
# /var/usrlocal workaround the runtime install (bluefin-initial-setup)
# needs.
# ---------------------------------------------------------------------
FROM dakota-base

ARG IMAGE_NAME
ARG IMAGE_VENDOR
ARG IMAGE_TAG
ARG DISABLE_BLUEFIN_GNOME_TWEAKS

COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=nvidia-builder /out/ /
# COPY --from=libfprint-builder /out/usr/ /usr/
COPY --from=pam-u2f-builder /out/usr/ /usr/
# COPY --from=epson-builder /out/ /
COPY files/nvidia-blacklist-nouveau.conf /usr/lib/modprobe.d/nvidia-blacklist-nouveau.conf

# Keeps fprintd resident (--no-timeout) instead of idle-exiting and
# having to cold-reopen the Goodix 538d sensor on every fingerprint
# verification — confirmed on real hardware to otherwise race GNOME
# Shell's own verification timeout on a clockwork ~15-minute cadence
# (every fingerprint-auth re-arm while the screen is locked). See
# files/fprintd-no-timeout.conf and README.md, "Known limitations",
# for the full chain from that timeout to the lock screen occasionally
# showing no password/fingerprint prompt at all.
# COPY files/fprintd-no-timeout.conf /usr/lib/systemd/system/fprintd.service.d/10-no-timeout.conf

# Makes a YubiKey that was already plugged in at boot visible to GnuPG
# (`gpg --card-status`) without hand-restarting pcscd first. Replaces
# the stock p11-kit module file registering OpenSC globally, whose own
# FIXME-documented blacklist of desktop daemons is stale on current
# Dakota, with a whitelist of command-line tools — no desktop daemon
# can grab the card ahead of scdaemon's exclusive connect any more.
# See files/opensc-p11-kit.module for the full diagnosis and README.md,
# "Making the YubiKey visible to GnuPG at boot".
# COPY files/opensc-p11-kit.module /usr/share/p11-kit/modules/opensc.module

# Guard for the COPY above: it only helps as long as the base image
# still ships OpenSC and registers it nowhere else. If OpenSC ever
# disappears from the base, the card contention disappears with it and
# the override becomes dead weight to drop; if a second module file
# starts registering opensc-pkcs11.so, the override is silently
# bypassed through that one. Either way the build should say so rather
# than ship something that quietly stopped doing its job.
# RUN set -eux; \
#     test -n "$(find /usr/lib /usr/lib64 -name 'opensc-pkcs11.so' -print -quit 2>/dev/null)"; \
#     others="$(grep -rlF 'opensc-pkcs11.so' /usr/share/p11-kit/modules \
#         | grep -vx '/usr/share/p11-kit/modules/opensc.module' || true)"; \
#     if [ -n "${others}" ]; then \
#         echo "OpenSC still registered by other p11-kit module file(s): ${others}" >&2; \
#         exit 1; \
#     fi

# Kernel command-line args baked in via bootc's kargs.d mechanism
# (/usr/lib/bootc/kargs.d/*.toml — applied to the BLS entry bootc
# writes on every deployment, e.g. after `bootc switch`/`upgrade`).
# This is the actual fix for nouveau grabbing the GPU before nvidia.ko
# ever gets a chance to: the modprobe.d blacklist above only takes
# effect once /usr is mounted, but nouveau binds the PCI device
# earlier, inside the initramfs (dracut honors rd.driver.blacklist=
# from the kernel command line at that stage; `rhgb quiet` triggers
# early KMS, which is what races nvidia.ko). See files/nvidia-kargs.toml
# and README.md. Kargs only take effect on deployments created after
# this file lands in the image — a fresh `bootc switch`/`upgrade` is
# required, not just a reboot.
COPY files/nvidia-kargs.toml /usr/lib/bootc/kargs.d/30-nvidia-blacklist-nouveau.toml

# Rewrite this downstream image's identity into /etc/os-release,
# overwriting the upstream Dakota base's own IMAGE_NAME/IMAGE_VENDOR/
# IMAGE_TAG/IMAGE_REF fields (a Universal Blue os-release convention;
# kept in sync, though see below for what actually drives uwelcome's
# banner).
RUN set -eux; \
    sed -i \
        -e "s|^IMAGE_NAME=.*|IMAGE_NAME=\"${IMAGE_NAME}\"|" \
        -e "s|^IMAGE_VENDOR=.*|IMAGE_VENDOR=\"${IMAGE_VENDOR}\"|" \
        -e "s|^IMAGE_TAG=.*|IMAGE_TAG=\"${IMAGE_TAG}\"|" \
        -e "s|^IMAGE_REF=.*|IMAGE_REF=\"ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}\"|" \
        /etc/os-release

# The actual fix for uwelcome's banner (the os-release rewrite above
# does NOT do it — see the ARG IMAGE_NAME comment near the top of this
# file): overwrite /usr/share/ublue-os/image-info.json, the file
# uwelcome's GetImageInfo() reads verbatim for the "<ref>:<tag>" line.
# Format mirrors what ublue-os/bluefin's build_files/base/00-image-info.sh
# generates (same field names/shape, confirmed by pulling the upstream
# Dakota base and cat'ing its own copy of this file).
RUN set -eux; \
    image_flavor="nvidia-580"; \
    case "${IMAGE_NAME}" in *-gaming) image_flavor="nvidia-580-gaming" ;; esac; \
    mkdir -p /usr/share/ublue-os; \
    printf '{\n  "image-name": "%s",\n  "image-flavor": "%s",\n  "image-vendor": "%s",\n  "image-ref": "ostree-image-signed:docker://ghcr.io/%s/%s",\n  "image-tag": "%s"\n}\n' \
        "${IMAGE_NAME}" "${image_flavor}" "${IMAGE_VENDOR}" "${IMAGE_VENDOR}" "${IMAGE_NAME}" "${IMAGE_TAG}" \
        > /usr/share/ublue-os/image-info.json

# Reverts the three Bluefin GNOME defaults described at the
# DISABLE_BLUEFIN_GNOME_TWEAKS ARG comment near the top of this file.
# "zz9" sorts after both of Bluefin's own override files (zz0 and zz3
# at the time of writing), which is what makes it win on button-layout
# and enable-hot-corners; disabled-extensions doesn't need that,
# since Bluefin's files never set that key. glib-compile-schemas is
# already shipped in the Dakota base image, so no extra tooling stage
# is needed to rerun it.
# RUN if [ "${DISABLE_BLUEFIN_GNOME_TWEAKS}" = "true" ]; then \
#         printf '%s\n' \
#             '[org.gnome.desktop.wm.preferences]' \
#             "button-layout=':close'" \
#             '' \
#             '[org.gnome.desktop.interface]' \
#             'enable-hot-corners=true' \
#             '' \
#             '[org.gnome.shell]' \
#             "disabled-extensions=['blur-my-shell@aunetx', 'dash-to-dock@micxgx.gmail.com']" \
#             > /usr/share/glib-2.0/schemas/zz9-dakota-nvidia-580-gnome-tweaks.gschema.override; \
#         glib-compile-schemas /usr/share/glib-2.0/schemas; \
#     fi

# Signing policy — mirrors lbssousa/bluefin's build_files/00-signing.sh
# and Dakota's own convention for verified registries (its shipped
# /usr/lib/pki/containers/ublue-os*.pub + registries.d/ublue-os.yaml).
# Requires images at ghcr.io/lbssousa to carry a valid cosign signature
# (CI signs every push — see .github/workflows/build.yml) before
# `bootc upgrade`/`podman pull` accepts them; without this, bootc
# reports "ostree-unverified-registry:" instead of
# "ostree-image-signed:" and applies unsigned images unchecked.
COPY cosign.pub /cosign.pub
COPY scripts/configure-signing-policy.sh /configure-signing-policy.sh
RUN chmod +x /configure-signing-policy.sh && \
    /configure-signing-policy.sh /cosign.pub && \
    rm -f /cosign.pub /configure-signing-policy.sh

# Post-install steps. depmod is our own addition (specific to having
# added an out-of-tree kernel module); ldconfig -r is the same step
# that Dakota's own docs/oci-assembly.md describes as "load-bearing —
# removing it breaks the image in ways that only show up after a
# bootc switch", needed here because we replaced libfprint-2.so and
# added new NVIDIA .so files.
RUN kver="$(cat /kernel-version)" && \
    depmod -a "$kver" && \
    ldconfig -r / && \
    rm -f /kernel-version

# Epson epson-printer-utility post-install steps (replicated from the
# RPM's post-install scriptlet, which cannot run in a container build;
# see scripts/install-epson-utility.sh for the file-layout half of
# this). Only the pieces printing actually needs — systemctl enable
# registers the ecbd daemon (network printer discovery) to start at
# boot; the /etc/services entry registers its port (cbtd 35587/tcp),
# safe to edit since /etc is mutable in bootc and 3-way merged on
# upgrade. (The GUI setup/maintenance utility itself is not shipped —
# see scripts/install-epson-utility.sh for why.)
# RUN systemctl enable ecbd.service && \
#     if ! grep -q 'cbtd' /etc/services 2>/dev/null; then \
#         printf '\ncbtd\t35587/tcp\t# Epson printer backend\n' >> /etc/services; \
#     fi

# Device nodes (e.g. /dev/ecblp0) created by the epson-printer-utility
# RPM's post-install scriptlet on a real install cannot be stored in
# OCI image layers; none should exist here since we never ran the
# scriptlet, but clean up defensively to avoid rechunking failures.
# RUN find / -xdev \( -type c -o -type b -o -type p -o -type s \) -name 'ecblp*' -delete 2>/dev/null || true

RUN bootc container lint
