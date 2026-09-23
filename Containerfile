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
# BuildStream fork, and the risks that haven't been validated on real
# hardware yet).
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

ARG NVIDIA_VERSION=580.173.02
ARG LIBFPRINT_REPO=https://github.com/lbssousa/libfprint.git
ARG LIBFPRINT_REF=goodix-538d-sigfm-gtls
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
# kernel-headers — extracts this specific image's kernel version and
# its shipped .config (the ground truth kernel-src-builder reconstructs
# a build tree from). Fails loudly and early if the image doesn't even
# ship the .config — that would mean Dakota's kernel packaging changed
# more deeply than the missing-build-tree issue this repo works around.
# ---------------------------------------------------------------------
FROM dakota-base AS kernel-headers
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
    cp "/usr/lib/modules/$kver/config" /kernel-config

# ---------------------------------------------------------------------
# kernel-src-builder — Fedora used only as a build environment;
# reconstructs a real /lib/modules/<kver>/build tree (Makefile,
# headers, scripts, objtool) from upstream kernel source + the exact
# .config extracted above, via scripts/build-kernel-src.sh. See that
# script and README.md for the full rationale.
# ---------------------------------------------------------------------
FROM fedora:42 AS kernel-src-builder
# openssl (the CLI, not just openssl-devel's headers/libs) is needed by
# certs/Makefile's gen_key rule: the gaming variant's shipped .config
# has CONFIG_MODULE_SIG_ALL=y (unset on standard), which makes `make
# vmlinux` generate a self-signed certs/signing_key.pem via `openssl req`.
RUN dnf install -y gcc make bison flex bc elfutils-libelf-devel \
        openssl openssl-devel perl findutils diffutils ncurses-devel \
        git curl tar xz which hostname && \
    dnf clean all
COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=kernel-headers /kernel-config /kernel-config
COPY scripts/build-kernel-src.sh /build-kernel-src.sh
RUN chmod +x /build-kernel-src.sh && \
    /build-kernel-src.sh "$(cat /kernel-version)" /kernel-config /out

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
# nvidia-builder — Fedora used only as a build environment (dnf/gcc/
# make); nothing here ends up in the final image except what
# build-nvidia.sh explicitly packages into /out.
# ---------------------------------------------------------------------
FROM fedora:42 AS nvidia-builder
ARG NVIDIA_VERSION
RUN dnf install -y gcc make kmod elfutils-libelf-devel perl-interpreter \
        tar xz curl which && \
    dnf clean all
COPY --from=kernel-src-builder /out/ /kernel-src/
COPY --from=kernel-headers /kernel-version /kernel-version
COPY scripts/build-nvidia.sh /build-nvidia.sh
RUN chmod +x /build-nvidia.sh && /build-nvidia.sh "${NVIDIA_VERSION}" /kernel-src /out

# ---------------------------------------------------------------------
# libfprint-builder — same fork/ref used in
# lbssousa/bluefin-initial-setup (playbooks/dakota/libfprint.yml,
# dakota_libfprint_repo/_ref vars in group_vars/all/dakota.yml), which
# installs the same fork at runtime via distrobox for Dakota hosts not
# using this custom image. Here it's built against Fedora's
# opencv-devel instead of the host's Homebrew — there's no host, this
# is an image build.
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
        libgudev-devel libgusb-devel systemd-devel nss-devel \
        pixman-devel gtk-doc python3-cairo python3-gobject cairo-devel \
        umockdev git cmake opencv-devel && \
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
# binary epson-printer-utility RPM (printer setup/maintenance GUI +
# ecbd network-discovery daemon), via
# scripts/install-epson-utility.sh — adapted from lbssousa/bluefin's
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

COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=nvidia-builder /out/ /
COPY --from=libfprint-builder /out/usr/ /usr/
COPY --from=pam-u2f-builder /out/usr/ /usr/
COPY --from=epson-builder /out/ /
COPY files/nvidia-blacklist-nouveau.conf /usr/lib/modprobe.d/nvidia-blacklist-nouveau.conf

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
# this):
#
# - /opt -> /var/opt compatibility symlink: bootc's /opt is a symlink
#   to /var/opt (mutable, not part of the image layer), but the
#   binary's resource paths are hardcoded to /opt/epson-printer-utility/.
#   /usr/lib is replaced wholesale on 'bootc upgrade'; this symlink
#   persists across that and always points at the current version.
# - systemctl enable: registers the ecbd daemon (network printer
#   discovery) to start at boot.
# - /etc/services entry: registers the ecbd port (cbtd 35587/tcp);
#   /etc is mutable in bootc and 3-way merged on upgrade, safe to edit.
# - update-desktop-database: rebuilds the desktop file cache so the
#   utility's launcher shows up immediately; guarded since Dakota
#   (GNOME OS) may not ship desktop-file-utils.
RUN mkdir -p /var/opt && \
    ln -sfn /usr/lib/epson-printer-utility /var/opt/epson-printer-utility && \
    systemctl enable ecbd.service && \
    if ! grep -q 'cbtd' /etc/services 2>/dev/null; then \
        printf '\ncbtd\t35587/tcp\t# Epson printer backend\n' >> /etc/services; \
    fi && \
    if command -v update-desktop-database >/dev/null 2>&1; then \
        update-desktop-database /usr/share/applications; \
    fi

# Device nodes (e.g. /dev/ecblp0) created by the epson-printer-utility
# RPM's post-install scriptlet on a real install cannot be stored in
# OCI image layers; none should exist here since we never ran the
# scriptlet, but clean up defensively to avoid rechunking failures.
RUN find / -xdev \( -type c -o -type b -o -type p -o -type s \) -name 'ecblp*' -delete 2>/dev/null || true

RUN bootc container lint
