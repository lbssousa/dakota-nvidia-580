# syntax=docker/dockerfile:1.7
#
# Custom Dakota image: proprietary NVIDIA driver on the legacy 580.xxx
# branch (for a GPU generation no longer supported by the official
# dakota-nvidia / dakota-nvidia-gaming variants, which track the newer
# branch, ~610.x/615.x as of 2026) + the lbssousa/libfprint fork
# (Goodix 538d) + Yubico's pam-u2f (YubiKey FIDO2/U2F PAM module +
# pamu2fcfg) + OpenSSH and GCR's ssh-agent patched for security key
# (FIDO) PIN/touch prompts, baked in via downstream
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

# OpenSSH, rebuilt with files/openssh-askpass-notify.patch. The base
# image's ssh is plain upstream 10.5p1; the patch makes notify_start()
# (the "Confirm user presence for key ..." request for FIDO keys) honour
# SSH_ASKPASS_REQUIRE the way read_passphrase() already does, so with
# SSH_ASKPASS_REQUIRE=prefer the touch request goes to the askpass dialog
# instead of a terminal nobody is looking at (proposed upstream; drop
# this stage once a release carries it). The version MUST equal the
# base image's: openssh-probe fails the build when it doesn't, so a base
# bump that moves to a new OpenSSH needs this pin (and the checksum)
# bumped with it rather than silently downgrading ssh.
ARG OPENSSH_VERSION=10.5p1
ARG OPENSSH_SHA256=d44d28a839ea9daf969cc69150fde59910b2b39361dad81a3bd6cbd19218db11

# GCR's ssh-agent wrapper (gcr-ssh-agent) and askpass (gcr4-ssh-askpass),
# rebuilt with files/gcr-ssh-agent-fido-prompts.patch so FIDO ("sk") keys
# work through it: as shipped, the ssh-agent it spawns has no askpass, so
# the security key PIN prompt fails and the touch request is never shown
# (see the patch header; based on gcr!173, which is still open). Only
# the two executables are replaced; they link the base's own libgcr-4,
# so GCR_REF MUST be the base's gcr version: gcr-probe fails the build
# otherwise. Drop this once a release carries the fix.
ARG GCR_REPO=https://gitlab.gnome.org/GNOME/gcr.git
ARG GCR_REF=4.4.1

# libcupsfilters, rebuilt with the two printing fixes in
# files/libcupsfilters-*.patch so PDF jobs and the CUPS test page print
# (OpenPrinting/libcupsfilters#167 and #249; see projectbluefin/dakota#1707).
# The version MUST equal the base's: libcupsfilters-probe fails the build
# otherwise. Drop the stage once the base's release carries both fixes.
ARG LIBCUPSFILTERS_VERSION=2.2.1
ARG LIBCUPSFILTERS_SHA256=0a22b849d5068c4c86b20fbb4192d3faa3dabcc9ee844c8fd73710ed821d4860

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
# matches what CI actually publishes on every build ("testing" on
# main; see README.md, "CI and automatic updates"): :stable is a
# later, unrelated registry retag of a past :testing digest, promoted
# weekly with no rebuild, so the image never gets built with
# IMAGE_TAG=stable — its self-reported identity correctly says
# "testing" even once viewed through the :stable tag, the same way
# upstream Dakota's own build always embeds "latest" as its
# OCI_IMAGE_VERSION regardless of which stream tag
# (:testing/:next/:stable) ends up pointing at it.
#
# The `next` branch overrides this to "next" and repins the two base
# digests below to the upstream :next images, so the two streams
# differ by nothing but these three ARG values.
ARG IMAGE_NAME=dakota-nvidia-580
ARG IMAGE_VENDOR=lbssousa
ARG IMAGE_TAG=testing

# ---------------------------------------------------------------------
# dakota-base — ALWAYS pinned by digest, never a floating tag ("stable"
# and "next" both change content over time). The NVIDIA module below is
# compiled against this exact image's kernel; if the digest changes
# without a rebuild, the result is a new kernel paired with a stale .ko
# (it won't load, or worse, it loads and is unstable). Renovate
# (renovate.json5) opens a PR when either digest below changes; CI builds
# both variants from that PR.
#
# On `main` both pins track the upstream :testing images. On the `next`
# branch they track :next instead (GNOME rolling master), which is what
# makes that branch worth having: a new upstream base arrives there days
# before it reaches :testing, so the kmod gets exercised against a new
# kernel on the bleeding-edge stream instead of on the one machines
# track. Both branches keep the same ARG names, so build.yml's matrix
# needs no per-branch override — it reads whatever this file says.
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
ARG BASE_IMAGE=ghcr.io/projectbluefin/dakota:testing@sha256:110fdf396bd1a11d5665616c86e5b86a1513c389d617a423eb0f4a446b6b87df
ARG BASE_IMAGE_GAMING=ghcr.io/projectbluefin/dakota-gaming:testing@sha256:c3f06bbb395d46bf97c500b4d4a5ea7a8c634e235541012f5741e429cfd74f10
# ^ resolved via (re-run before every build — these drift):
#   skopeo inspect docker://ghcr.io/projectbluefin/dakota:testing | jq -r .Digest
#   skopeo inspect docker://ghcr.io/projectbluefin/dakota-gaming:testing | jq -r .Digest

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
# openssh-probe — records the OpenSSH version the base image ships, for
# openssh-builder to compare against OPENSSH_VERSION.
# ---------------------------------------------------------------------
FROM dakota-base AS openssh-probe
RUN set -eux; \
    ssh -V 2>&1 | sed -E 's/^OpenSSH_([0-9]+\.[0-9]+p[0-9]+).*/\1/' > /openssh-version; \
    echo "Base image ships OpenSSH $(cat /openssh-version)" >&2

# ---------------------------------------------------------------------
# gcr-probe — records the gcr version the base image ships, for
# gcr-builder to compare against GCR_REF. Read from libgcr-4's file name:
# gcr 4.x builds it as libgcr-4.so.4.<minor>.<micro>, i.e. the first
# three components of the release version (4.4.0.1 ships 4.4.0).
# ---------------------------------------------------------------------
FROM dakota-base AS gcr-probe
RUN set -eux; \
    so="$(find /usr/lib* -name 'libgcr-4.so.4.*' 2>/dev/null | head -n1)"; \
    if [ -z "$so" ]; then \
        echo "ERROR: libgcr-4.so.4.* not found in this Dakota base image." >&2; \
        exit 1; \
    fi; \
    basename "$so" | sed -E 's/^libgcr-4\.so\.//' > /gcr-version; \
    echo "Base image ships gcr $(cat /gcr-version) ($so)" >&2

# ---------------------------------------------------------------------
# libcupsfilters-probe — records the libcupsfilters release the base
# image ships, for libcupsfilters-builder to compare against
# LIBCUPSFILTERS_VERSION. Read from the CHANGES.md header the package
# installs ("# CHANGES - OpenPrinting libcupsfilters v2.2.1 - ...").
# ---------------------------------------------------------------------
FROM dakota-base AS libcupsfilters-probe
RUN set -eux; \
    sed -nE '1s/^.* v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' /usr/share/doc/libcupsfilters/CHANGES.md > /libcupsfilters-version; \
    test -s /libcupsfilters-version; \
    test -f /usr/lib/x86_64-linux-gnu/libcupsfilters.so.2.0.0; \
    echo "Base image ships libcupsfilters $(cat /libcupsfilters-version)" >&2

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
# openssh-builder — builds ssh, ssh-agent and ssh-keygen (the three
# programs that call notify_start(); see files/openssh-askpass-notify.patch)
# from the upstream tarball plus that patch. Only those three are
# replaced in the final image: they link nothing but libcrypto, libz and
# glibc, all present in the base at an equal or newer version than this
# Fedora's. --with-security-key-builtin only makes "internal" (the base's
# ssh-sk-helper) the default SK provider, as in the base's own build;
# without it `ssh-keygen -K` fails with "Cannot download keys without
# provider". libfido2-devel is needed by configure, nothing links it.
# ssh-sk-helper, which needs the base's own libfido2/libcbor,
# and sshd, which is built against PAM/audit, are deliberately left
# alone — neither calls notify_start().
#
# Paths match the base's build (/usr/libexec helpers, /etc/ssh config).
# The tarball is pinned by checksum rather than PGP signature.
# ---------------------------------------------------------------------
FROM fedora:44 AS openssh-builder
ARG OPENSSH_VERSION
ARG OPENSSH_SHA256
RUN dnf install -y gcc make openssl-devel zlib-devel libfido2-devel patch curl && \
    dnf clean all
COPY --from=openssh-probe /openssh-version /openssh-version
COPY files/openssh-askpass-notify.patch /openssh-askpass-notify.patch
RUN set -eux; \
    if [ "$(cat /openssh-version)" != "${OPENSSH_VERSION}" ]; then \
        echo "ERROR: the base image ships OpenSSH $(cat /openssh-version) but OPENSSH_VERSION is ${OPENSSH_VERSION}." >&2; \
        echo "Bump OPENSSH_VERSION and OPENSSH_SHA256 in the Containerfile." >&2; \
        exit 1; \
    fi; \
    curl -fsSL -o /openssh.tar.gz "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz"; \
    echo "${OPENSSH_SHA256}  /openssh.tar.gz" | sha256sum -c -; \
    tar -xzf /openssh.tar.gz -C /; \
    cd "/openssh-${OPENSSH_VERSION}"; \
    patch -Np1 -i /openssh-askpass-notify.patch; \
    ./configure --prefix=/usr --sysconfdir=/etc/ssh --libexecdir=/usr/libexec \
        --with-privsep-path=/var/empty --with-security-key-builtin; \
    make -j"$(nproc)" ssh ssh-agent ssh-keygen; \
    grep -q '^#define ENABLE_SK_INTERNAL' config.h || \
        { echo "ERROR: ENABLE_SK_INTERNAL is not set; ssh-keygen -K would have no default SK provider." >&2; exit 1; }; \
    install -D -m0755 ssh ssh-agent ssh-keygen -t /out/usr/bin/

# ---------------------------------------------------------------------
# gcr-builder — builds gcr at the base's version with
# files/gcr-ssh-agent-fido-prompts.patch, runs the ssh-agent/askpass
# tests, and keeps only /usr/libexec/gcr-ssh-agent and
# /usr/libexec/gcr4-ssh-askpass. The libraries built along the way are
# discarded: both executables use only libgcr-4/gck-2's public API and
# load the base's copies at runtime, next to a glib (2.90) no older than
# this Fedora's. GTK, introspection and docs are off (not needed for
# these two). find_program() resolves ssh-agent/ssh-add to /usr/bin,
# which is where the base has them too.
# ---------------------------------------------------------------------
FROM fedora:44 AS gcr-builder
ARG GCR_REPO
ARG GCR_REF
RUN dnf install -y meson ninja-build gcc git gettext pkgconf-pkg-config \
        glib2-devel libgcrypt-devel p11-kit-devel libsecret-devel \
        systemd-devel "pkgconfig(systemd)" openssh-clients gnupg2 patch && \
    dnf clean all
COPY --from=gcr-probe /gcr-version /gcr-version
COPY files/gcr-ssh-agent-fido-prompts.patch /gcr-ssh-agent-fido-prompts.patch
RUN set -eux; \
    if [ "$(cat /gcr-version)" != "$(echo "${GCR_REF}" | cut -d. -f1-3)" ]; then \
        echo "ERROR: the base image ships gcr $(cat /gcr-version) but GCR_REF is ${GCR_REF}." >&2; \
        echo "Bump GCR_REF in the Containerfile (and check the patch still applies)." >&2; \
        exit 1; \
    fi; \
    git clone --branch "${GCR_REF}" --depth 1 "${GCR_REPO}" /src; \
    cd /src; \
    patch -Np1 -i /gcr-ssh-agent-fido-prompts.patch; \
    meson setup build --prefix=/usr --libexecdir=/usr/libexec \
        -Dgtk4=false -Dintrospection=false -Dvapi=false -Dgtk_doc=false \
        -Dcrypto=libgcrypt -Dssh_agent=true -Dsystemd=enabled \
        -Dgpg_path=/usr/bin/gpg; \
    ninja -C build; \
    meson test -C build --print-errorlogs --suite gcr-ssh-agent; \
    meson test -C build --print-errorlogs ssh-askpass; \
    install -D -m0755 build/gcr/gcr-ssh-agent build/gcr/gcr4-ssh-askpass \
        -t /out/usr/libexec/

# ---------------------------------------------------------------------
# libcupsfilters-builder — builds libcupsfilters at the base's version
# with the two printing fixes below, and keeps only the shared library:
#   files/libcupsfilters-flush-pdf-before-page-count.patch
#       (OpenPrinting/libcupsfilters#167; PDF jobs failing with
#       "Missing Root object"; also in projectbluefin/dakota#1724)
#   files/libcupsfilters-banner-close-output.patch
#       (OpenPrinting/libcupsfilters#249; the CUPS test page,
#       application/vnd.cups-pdf-banner, failing with "universal filter
#       failed"; see projectbluefin/dakota#1707)
# The filters under /usr/lib/cups/filter and cupsd's helpers link the
# library dynamically, so replacing libcupsfilters.so.2.0.0 is enough.
# Its dependencies are soname-stable and already in the base, except
# libjxl: this Fedora has 0.11, the base 0.12, so the library would not
# load. It is therefore built --without-jpegxl (JPEG XL *input images*
# are no longer converted by the image filters; nothing else changes).
# Revisit if this Fedora catches up to the base's libjxl.
# LIBCUPSFILTERS_VERSION MUST be the base's: the probe fails the build
# otherwise, so a base bump with a newer libcupsfilters (which may carry
# these fixes) is looked at instead of silently downgraded.
# ---------------------------------------------------------------------
FROM fedora:44 AS libcupsfilters-builder
ARG LIBCUPSFILTERS_VERSION
ARG LIBCUPSFILTERS_SHA256
RUN dnf install -y gcc gcc-c++ make patch curl xz pkgconf-pkg-config \
        cups-devel pdfio-devel poppler-cpp-devel poppler-devel \
        ghostscript ghostscript-devel lcms2-devel libjpeg-turbo-devel libpng-devel \
        libtiff-devel libexif-devel fontconfig-devel \
        dbus-devel qpdf-devel mupdf poppler-utils cups-ipptool && \
    dnf clean all
COPY --from=libcupsfilters-probe /libcupsfilters-version /libcupsfilters-version
COPY files/libcupsfilters-flush-pdf-before-page-count.patch files/libcupsfilters-banner-close-output.patch /
RUN set -eux; \
    if [ "$(cat /libcupsfilters-version)" != "${LIBCUPSFILTERS_VERSION}" ]; then \
        echo "ERROR: the base image ships libcupsfilters $(cat /libcupsfilters-version) but LIBCUPSFILTERS_VERSION is ${LIBCUPSFILTERS_VERSION}." >&2; \
        echo "Bump LIBCUPSFILTERS_VERSION/SHA256 (or drop this stage if the base carries the fixes)." >&2; \
        exit 1; \
    fi; \
    curl -fsSL -o /src.tar.xz "https://github.com/OpenPrinting/libcupsfilters/releases/download/${LIBCUPSFILTERS_VERSION}/libcupsfilters-${LIBCUPSFILTERS_VERSION}.tar.xz"; \
    echo "${LIBCUPSFILTERS_SHA256}  /src.tar.xz" | sha256sum -c -; \
    tar -xJf /src.tar.xz -C /; \
    cd "/libcupsfilters-${LIBCUPSFILTERS_VERSION}"; \
    patch -Np1 -i /libcupsfilters-flush-pdf-before-page-count.patch; \
    patch -Np1 -i /libcupsfilters-banner-close-output.patch; \
    ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu \
        --sysconfdir=/etc --localstatedir=/var --disable-static \
        --without-jpegxl; \
    make -j"$(nproc)"; \
    install -D -m0755 .libs/libcupsfilters.so.2.0.0 -t /out/usr/lib/x86_64-linux-gnu/

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

COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=nvidia-builder /out/ /
# TEMPORARILY DISABLED: the libfprint fork is not baked into the image for
# now; it is installed at runtime via lbssousa/bluefin-initial-setup
# (`just libfprint-dakota`). Re-enable by uncommenting the line below.
# The libfprint-probe/libfprint-builder stages are kept: BuildKit skips
# stages that the final image doesn't reference.
# COPY --from=libfprint-builder /out/usr/ /usr/
COPY --from=pam-u2f-builder /out/usr/ /usr/
COPY --from=openssh-builder /out/usr/ /usr/
COPY --from=gcr-builder /out/usr/ /usr/
COPY --from=libcupsfilters-builder /out/usr/ /usr/
COPY files/nvidia-blacklist-nouveau.conf /usr/lib/modprobe.d/nvidia-blacklist-nouveau.conf

# Module options for nvidia.ko / nvidia-drm.ko, applied at load time.
# The PreserveVideoMemoryAllocations pair is what makes the suspend /
# hibernate units installed by build-nvidia.sh actually do something —
# without it /proc/driver/nvidia/suspend never exists, the driver vetoes
# kernel PM outright (nv_pmops_suspend returns -5) and the machine
# cannot sleep at all. Same content negativo17's nvidia-kmod-common RPM
# ships and projectbluefin/dakota ships, i.e. what Bazzite, Bluefin and
# BlueBuild all end up with via that RPM.
COPY files/nvidia-driver-params.conf /usr/lib/modprobe.d/nvidia.conf

# Explicit, ordered load of nvidia / nvidia-modeset / nvidia-drm /
# nvidia-uvm. Without this the modules only come in as a side effect of
# the `nvidia-drm.modeset=1` karg (the kernel's unknown_bootoption path
# calls request_module on it), which leaves the load order up to
# nvidia-drm.ko's depends= list and never loads nvidia-uvm at all.
COPY files/nvidia-modules-load.conf /usr/lib/modules-load.d/nvidia.conf

# Creates /dev/nvidia* before GDM. The load-bearing fix for the missing
# graphical environment: gnome-shell is unprivileged and cannot mknod,
# and nvidia-modprobe is deliberately not setuid here, so the nodes have
# to exist before the greeter's first EGL init. Same unit as projectbluefin/dakota's nvidia-device-nodes.bst.
COPY files/nvidia-device-nodes.service /usr/lib/systemd/system/nvidia-device-nodes.service

# udev equivalent, for the case the systemd unit can't cover: an
# unprivileged (rootless) container asking for the GPU has no privilege
# to mknod and nvidia.ko never creates the nodes. Ported from
# negativo17/nvidia-kmod-common's 60-nvidia.rules, the RPM that
# Bazzite, Bluefin and BlueBuild all install.
COPY files/60-nvidia.rules /usr/lib/udev/rules.d/60-nvidia.rules

# Enablement is baked as symlinks under /usr/lib/systemd/system, mirroring
# each unit's [Install] section — NOT shipped as a systemd preset. Presets
# are applied only by global-preset-all.service, gated on
# ConditionFirstBoot=yes, and per machine-id(5) a bootc/composefs boot is
# never a first boot (/etc/machine-id already holds a valid ID), so a
# preset leaves every unit disabled. Here that means no
# nvidia-device-nodes.service, hence no /dev/nvidiactl or /dev/nvidia0,
# hence gnome-shell SIGSEGV in cogl_renderer_is_hardware_accelerated and
# GDM giving up — while gdm.service stays active and `systemctl --failed`
# stays empty. Symlinks in the immutable /usr need no first-boot
# detection and survive `bootc switch`. See README.md, "Why the
# enablement is a symlink and not a preset".
#
# The sleep units are WantedBy the systemd-*.service they hook, not
# multi-user.target: linking them there would run nvidia-sleep.sh at boot.
RUN cd /usr/lib/systemd/system && \
    mkdir -p multi-user.target.wants \
             systemd-suspend.service.wants \
             systemd-hibernate.service.wants \
             systemd-suspend-then-hibernate.service.wants && \
    ln -s ../nvidia-device-nodes.service multi-user.target.wants/ && \
    ln -s ../nvidia-suspend.service systemd-suspend.service.wants/ && \
    ln -s ../nvidia-resume.service systemd-suspend.service.wants/ && \
    ln -s ../nvidia-hibernate.service systemd-hibernate.service.wants/ && \
    ln -s ../nvidia-resume.service systemd-hibernate.service.wants/ && \
    ln -s ../nvidia-suspend-then-hibernate.service systemd-suspend-then-hibernate.service.wants/ && \
    ln -s ../nvidia-resume.service systemd-suspend-then-hibernate.service.wants/

# Keeps fprintd resident (--no-timeout) instead of idle-exiting and
# having to cold-reopen the Goodix 538d sensor on every fingerprint
# verification — confirmed on real hardware to otherwise race GNOME
# Shell's own verification timeout on a clockwork ~15-minute cadence
# (every fingerprint-auth re-arm while the screen is locked). See
# files/fprintd-no-timeout.conf and README.md, "Known limitations",
# for the full chain from that timeout to the lock screen occasionally
# showing no password/fingerprint prompt at all.
COPY files/fprintd-no-timeout.conf /usr/lib/systemd/system/fprintd.service.d/10-no-timeout.conf

# Makes a YubiKey that was already plugged in at boot visible to GnuPG
# (`gpg --card-status`) without hand-restarting pcscd first. Replaces
# the stock p11-kit module file registering OpenSC globally, whose own
# FIXME-documented blacklist of desktop daemons is stale on current
# Dakota, with a whitelist of command-line tools — no desktop daemon
# can grab the card ahead of scdaemon's exclusive connect any more.
# See files/opensc-p11-kit.module for the full diagnosis and README.md,
# "Making the YubiKey visible to GnuPG at boot".
COPY files/opensc-p11-kit.module /usr/share/p11-kit/modules/opensc.module

# Guard for the COPY above: it only helps as long as the base image
# still ships OpenSC and registers it nowhere else. If OpenSC ever
# disappears from the base, the card contention disappears with it and
# the override becomes dead weight to drop; if a second module file
# starts registering opensc-pkcs11.so, the override is silently
# bypassed through that one. Either way the build should say so rather
# than ship something that quietly stopped doing its job.
RUN set -eux; \
    test -n "$(find /usr/lib /usr/lib64 -name 'opensc-pkcs11.so' -print -quit 2>/dev/null)"; \
    others="$(grep -rlF 'opensc-pkcs11.so' /usr/share/p11-kit/modules \
        | grep -vx '/usr/share/p11-kit/modules/opensc.module' || true)"; \
    if [ -n "${others}" ]; then \
        echo "OpenSC still registered by other p11-kit module file(s): ${others}" >&2; \
        exit 1; \
    fi

# Kernel command-line args baked in via bootc's kargs.d mechanism
# (/usr/lib/bootc/kargs.d/*.toml — applied to the BLS entry bootc
# writes on every deployment, e.g. after `bootc switch`/`upgrade`).
#
# Two separate things, both only fixable from here:
#
# 1. nouveau grabbing the GPU before nvidia.ko ever gets a chance to:
#    the modprobe.d blacklist only takes effect once /usr is mounted,
#    but nouveau binds the PCI device earlier, inside the initramfs
#    (dracut honors rd.driver.blacklist= from the kernel command line
#    at that stage; `rhgb quiet` triggers early KMS, which is what
#    races nvidia.ko).
#
# 2. simpledrm claiming the framebuffer inside the initramfs, before
#    pivot_root, after which nvidia-drm cannot attach at all — symptom
#    is a black screen. initcall_blacklist= is the only lever, because
#    the GNOME OS initramfs is built upstream without knowledge of
#    NVIDIA and never consults our /usr/lib/modprobe.d. All three
#    reference implementations carry this argument for exactly that
#    reason: projectbluefin/dakota's nvidia-kargs.bst,
#    negativo17's nvidia-boot-update (CMDLINE_ARGS_ALWAYS_REMOVE), and
#    BlueBuild's setdrmvariables.sh.
#
# See files/nvidia-kargs.toml and README.md. Kargs only take effect on
# deployments created after this file lands in the image — a fresh
# `bootc switch`/`upgrade` is required, not just a reboot.
COPY files/nvidia-kargs.toml /usr/lib/bootc/kargs.d/30-nvidia.toml

# `ujust gnome-pure-toggle`: per-user switch between stock GNOME and
# Bluefin's desktop defaults (see the recipe for details).
COPY files/60-custom.just /usr/share/ublue-os/just/60-custom.just

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

RUN bootc container lint
