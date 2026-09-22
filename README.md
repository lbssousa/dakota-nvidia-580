# dakota-nvidia-580

A customized [Bluefin Dakota](https://docs.projectbluefin.io/dakota/)
image with three components baked in via downstream OCI image layering
(not by forking the upstream BuildStream build — see ["Why downstream
instead of forking
BuildStream"](#why-downstream-instead-of-forking-buildstream) below):

- **Proprietary NVIDIA driver on the legacy 580.xxx branch** — needed
  because the target GPU is from a generation no longer supported by
  the official `dakota-nvidia`/`dakota-nvidia-gaming` variants, which
  track the newer branch (~610.x/615.x as of 2026).
- **[lbssousa/libfprint](https://github.com/lbssousa/libfprint) fork**
  (`goodix-538d-sigfm-gtls` branch), adding support for the Goodix
  538d fingerprint reader — the same fork used in
  [lbssousa/bluefin-initial-setup](https://github.com/lbssousa/bluefin-initial-setup)
  (`playbooks/dakota/libfprint.yml`), which installs it at **runtime**
  via distrobox for Dakota hosts not using this custom image. Here it
  is compiled during the image build and installed **directly into
  `/usr`, overwriting the stock libfprint** shipped in the Dakota base
  image at its original path — see ["How the libfprint overwrite
  works"](#how-the-libfprint-overwrite-works) below.
- **Epson's [`epson-printer-utility`](https://support.epson.net/linux/Printer/LSB_distribution_pages/en/utility.php)**
  (printer setup/maintenance GUI + `ecbd` network-discovery daemon),
  obtained and installed the same way as in
  [ublue-os/bluefin](https://github.com/ublue-os/bluefin)
  (`build_files/20-epson.sh`) — downloaded as a binary RPM and unpacked
  rather than installed via `rpm`/`dnf`, since Dakota has neither. This
  repo installs only the utility, not bluefin's
  `epson-inkjet-printer-escpr` driver package (which needs building
  from source against `cups-devel`/autotools, not present on Dakota).

Like the upstream project, this repo builds two variants from the same
`Containerfile`, both published:

- `ghcr.io/lbssousa/dakota-nvidia-580:stable` — standard Dakota base.
- `ghcr.io/lbssousa/dakota-nvidia-580-gaming:stable` — Dakota gaming
  base (Open Gaming Collective/OGC kernel, Steam, gamescope, etc.),
  mirroring the upstream `dakota-nvidia`/`dakota-nvidia-gaming` split.

## Status

Both variants build and publish successfully end-to-end in CI
(`.github/workflows/build.yml`) — see run
[`35787487801`](https://github.com/lbssousa/dakota-nvidia-580/actions/runs/35787487801).
The container image builds, all four NVIDIA kernel modules
(`nvidia.ko`, `nvidia-uvm.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`)
compile and link, and both images are signed with a valid SBOM
attestation (see ["Verification"](#verification)) — confirmed with
`cosign verify`/`cosign verify-attestation` against the published
images. **Nothing here has been booted on real Dakota hardware yet**
— see ["Known limitations"](#known-limitations)
below.

## Why `/usr/lib/modules/<kver>/build` is missing (and how this repo works around it)

`/usr/lib/modules/<kver>/build` is a dangling symlink on both
published images (`ghcr.io/projectbluefin/dakota:stable` and
`dakota-gaming:stable`). It points to `/usr/src/linux-<kver>`, which
is empty:

```
/usr/lib/modules/7.2.6/build -> ../../../src/linux-7.2.6
/usr/src/  →  (empty — only . and ..)
```

This isn't a packaging bug. Dakota's own BuildStream element that
compiles the NVIDIA driver
([`nvidia-drivers.bst`](https://github.com/projectbluefin/dakota/blob/testing/elements/bluefin-nvidia/nvidia-drivers.bst))
pulls in `freedesktop-sdk.bst:components/linux.bst` (or, for the
gaming variant,
[`elements/core/linux-ogc.bst`](https://github.com/projectbluefin/dakota/blob/testing/elements/core/linux-ogc.bst))
as an ordinary **build-time** dependency — BuildStream stages that
element's own package output (which genuinely contains
`/usr/src/linux-<kver>/` with a real `Makefile`, headers, `scripts/`,
and `Module.symvers`) into the sandbox for that one build step. But
`linux.bst` is deliberately **not** a runtime-dependency of the
composed OS (GNOME OS boots from a separately-staged kernel +
initramfs), so it's absent from what actually gets published. The
`build` symlink under `/usr/lib/modules/` survives because it's copied
from a sibling directory
([`unsigned-modules.bst`](https://github.com/projectbluefin/dakota/blob/testing/elements/bluefin/unsigned-modules.bst)
only stages `/usr/lib/modules`, never `/usr/src`) — hence a symlink
pointing at nothing.

**This repo's `kernel-src-builder` Containerfile stage reconstructs
that same tree itself**, from two things the *runtime* image genuinely
does ship:

- `/usr/lib/modules/<kver>/config` — the exact `.config` the running
  kernel was built with (present on both variants; this is the ground
  truth, no guessing).
- `<kver>` itself, which tells us which source to fetch: a plain
  version (e.g. `7.2.6`) means the standard variant's kernel, and
  matches
  [freedesktop-sdk's own source pin](https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/blob/master/elements/include/linux.yml)
  — vanilla `kernel.org` at tag `v<kver>` (its two patches only touch
  riscv/powerpc code, irrelevant on x86_64). A `-ogc<N>` suffix (e.g.
  `7.2.6-ogc1`) means the gaming variant's [Open Gaming Collective
  kernel](https://github.com/OpenGamingCollective/linux) fork, at the
  matching tag — `linux-ogc.bst` pins it explicitly
  (`ogc-localversion: '-ogc1'`, not autodetected).

`scripts/build-kernel-src.sh` fetches that source, drops in the
shipped `.config`, runs `make olddefconfig` + `make modules_prepare`,
builds `vmlinux` (needed for a real `Module.symvers` — NVIDIA's own
`conftest.sh` greps it to pick which kernel-version-specific code path
to compile, so an empty one silently steers it toward APIs long
removed from modern kernels) plus `drivers/gpu/drm/ttm/ttm.ko` and
`drivers/gpu/drm/drm_ttm_helper.ko` (the DRM subsystem pieces that are
loadable modules rather than built into `vmlinux` on Dakota's shipped
`.config`, and that `nvidia-drm.ko` needs symbols from), and assembles
`/usr/src/linux-<kver>/` with the same file list
`linux.bst`/`linux-ogc.bst` themselves copy — reproducing their exact
artifact shape.

Run this to confirm a given image still ships the `.config` this
approach depends on (a much weaker requirement than the old
`build/Makefile` check, and both variants pass it today):

```bash
./scripts/check-kernel-headers.sh stable dakota
./scripts/check-kernel-headers.sh stable dakota-gaming
```

## Architecture

The same `Containerfile` builds both variants — `dakota-base` resolves
to whichever image `BASE_IMAGE` points at (standard Dakota by
default; the gaming base when CI overrides it for the `-gaming` leg —
see ["CI and automatic updates"](#ci-and-automatic-updates) below).
Everything downstream (kernel headers, kmod build, libfprint, Epson
utility) is derived from that image at build time, so it needs no
per-variant changes.

```
dakota-base (FROM ${BASE_IMAGE}, e.g. ghcr.io/projectbluefin/dakota:stable@sha256:...
             or ghcr.io/projectbluefin/dakota-gaming:stable@sha256:... for the gaming variant)
  │
  ├─→ kernel-headers            extracts kernel version + its shipped .config
  │     │                       (NOT /usr/lib/modules/<kver>/build — see above)
  │     │
  │     └─→ kernel-src-builder  (Fedora, build environment only)
  │           fetches matching upstream kernel source (kernel.org or
  │           OpenGamingCollective/linux.git, auto-detected from the
  │           kernel version string), configures it with the shipped
  │           .config, builds vmlinux + the DRM modules nvidia-drm.ko
  │           needs, assembles a real /src/linux-<kver>/ +
  │           /lib/modules/<kver>/build
  │           (scripts/build-kernel-src.sh)
  │           │
  │           └─→ nvidia-builder    (Fedora, build environment only)
  │                 builds the out-of-tree kmod against the reconstructed
  │                 tree above, runs nvidia-installer --no-kernel-module,
  │                 and packages the result via a filesystem diff
  │                 (scripts/build-nvidia.sh)
  │
  ├─→ libfprint-probe         locates libfprint-2.so's exact libdir
  │     │                     in the Dakota base image
  │     │
  │     └─→ libfprint-builder (Fedora, build environment only)
  │           builds the fork against Fedora's opencv-devel, with
  │           --prefix=/usr --libdir=<probed dir>, DESTDIR=/out
  │
  ├─→ epson-builder           (Fedora, build environment only)
  │         downloads Epson's binary epson-printer-utility RPM and
  │         unpacks it (no rpm/dnf install) into /out
  │         (scripts/install-epson-utility.sh)
  │
  └─→ final (FROM dakota-base again)
        COPY of all three /out trees (libfprint's overwrites the
        stock library in place), nouveau blacklist, depmod +
        ldconfig -r, Epson post-install steps (symlink, systemd
        enable, /etc/services entry), signing policy
        (scripts/configure-signing-policy.sh — see "Verification"),
        bootc container lint
```

The `kernel-src-builder`, `nvidia-builder`, `libfprint-builder` and
`epson-builder` stages use Fedora **only as a build environment** (it
has `dnf`, `gcc`, `meson`, `rpm2cpio`...) — nothing from them ends up
in the final image except what the scripts explicitly package into
`/out`. The final image is still plain Dakota (GNOME OS, no RPMs) with
these payloads layered on top.

## How the libfprint overwrite works

Fedora's meson defaults to `lib64` as the libdir on x86_64, but Dakota
is a freedesktop-sdk/GNOME OS build and may not follow that same
convention (a single `lib`, no multilib split, is common in that
world). Building libfprint with a plain `--prefix=/usr` and Fedora's
own libdir guess could easily land the new `.so` in a directory that
doesn't match where Dakota's stock libfprint actually lives — you'd
end up with two parallel installations instead of overwriting one,
and which one `fprintd` picks up would depend on the dynamic linker's
search order, not on anything this repo controls.

The `libfprint-probe` stage avoids that by inspecting the *actual*
Dakota base image, finding `libfprint-2.so*` with `find`, and writing
out its containing directory. `libfprint-builder` then passes that
exact path as `--libdir` to `meson setup`, so the build lands at
precisely the same path the stock library occupies. The final stage's
`COPY --from=libfprint-builder /out/usr/ /usr/` then genuinely
replaces the original files in place — no `LD_LIBRARY_PATH` override,
no parallel `/usr/local` tree, nothing for `fprintd` to be pointed at
specially; it just finds the new library where it always expected the
old one.

This assumes the fork stays ABI-compatible with the stock libfprint
(same soname/version scheme) — it's a fork for a new device driver,
not a fork that changes the library's public API, so this should
hold, but hasn't been verified against Dakota's exact stock version.

## Why downstream instead of forking BuildStream

Dakota has no `dnf`/`rpm`/`akmods` — you can't `rpm-ostree install
akmod-nvidia` like on classic Bluefin/Aurora. The "native" way to
change what ships by default in the image is to edit the `.bst`
elements in the `dakota` repo itself and build everything through
BuildStream. That path is more correct (the module is built in the
very same kernel source tree), but it means maintaining a full fork of
the distro's build, with the entire BuildStream + freedesktop-sdk
toolchain, and continuously rebasing on top of upstream to not miss
security/GNOME updates.

This repo takes the cheaper path to maintain for a single-user setup:
a `Containerfile` that starts `FROM` the already-published image and
only compiles what actually needs compiling (the out-of-tree kmod +
the libfprint fork) against a kernel tree it reconstructs itself from
upstream source + the image's own shipped `.config` (see above) — plus
unpacking Epson's binary `epson-printer-utility` RPM, which needs no
compilation at all.

## Known limitations

- **`make vmlinux`'s final link needs several GB of RAM** in a single
  non-parallel step. GitHub Actions' hosted runners (16 GB) handle it
  in well under a minute; a memory-constrained machine may need swap
  or closed applications first, or just let CI do the build.
- **`kernel-src-builder` covers `vmlinux` + `ttm.ko` +
  `drm_ttm_helper.ko`'s exports, not literally every loadable module's.**
  If a future NVIDIA driver version (or a kernel bump) needs a symbol
  from some *other* loadable module, find the owning module from the
  undefined-symbol name and the kernel's own subsystem `Makefile`, then
  add a scoped `make path/to/that.ko` target — not a blanket `make
  modules`, which is prohibitively slow and memory-hungry against this
  `.config`.
- **NVIDIA's legacy 580.xxx driver needs patches for kernel 7.x, and
  the current fixes are pinned to driver 580.173.02** — re-derive them
  if you bump `NVIDIA_VERSION`. `580.65.06` (the original pin) doesn't
  compile against kernel 7.x at all. `build-nvidia.sh` applies:
  - `KCFLAGS="-Wno-implicit-function-declaration -Wno-int-conversion
    -Wno-incompatible-pointer-types"` — GCC 14+ (Fedora 42, the build
    stage) promotes these to hard errors unconditionally, not just via
    `-Werror`; delivered via `KCFLAGS` since kernel 7.2.6's top-level
    `Makefile` no longer reads `EXTRA_CFLAGS`.
  - A small `strncpy()` → `sized_strscpy()` compatibility shim,
    `#include`-injected into the exact source files that call it
    (`nvidia/os-interface.c`, `nvidia/linux_nvswitch.c`,
    `nvidia-uvm/uvm_pmm_gpu.c`, `nvidia-modeset/nvidia-modeset-linux.c`
    — re-grep this list, `grep -rln '\bstrncpy(' kernel/nvidia*`, if
    the version changes). `strncpy()` was fully removed from the
    kernel's public string API on 7.x.
- **`CONFIG_RUST` is force-disabled** in the reconstructed tree
  (`scripts/config --disable RUST` before `olddefconfig`). Both
  variants ship `CONFIG_RUST=y` for unrelated in-tree Rust drivers;
  with it on, `make modules_prepare` requires a matching
  `rustc`/`bindgen` toolchain that Fedora's `kernel-src-builder`
  doesn't provide and NVIDIA's C-only module doesn't need. This
  doesn't change any C struct layout, calling convention, or the
  kernel release string (vermagic).
- **Compiler version mismatch** — Dakota's kernels are built with GCC
  16.2.0 (per `CONFIG_CC_VERSION_TEXT` in the shipped `.config`);
  `kernel-src-builder` uses whatever GCC Fedora 42 ships. `RANDSTRUCT`
  and `LTO` are both off in the shipped config (the two options most
  likely to make a cross-compiler build genuinely ABI-incompatible),
  which meaningfully de-risks this, but isn't a byte-for-byte
  guarantee. `build-nvidia.sh` builds with `IGNORE_CC_MISMATCH=1` for
  the same reason — a real incompatibility would show up as a module
  load failure, not a build failure. Test `modprobe nvidia` before
  trusting a build.
- **Gaming variant: Dakota's own fixup patches to the OGC kernel are
  not applied.** `linux-ogc.bst` applies three small patches from
  `patches/linux-ogc/` in the Dakota repo (an `ayn-ec` HID fix, an
  `aw87xxx` DSP-only fix, an `asus` backlight fix) on top of the OGC
  tree before configuring it; `build-kernel-src.sh` clones the OGC
  tree as-is. All three are narrow, unrelated hardware-driver fixups —
  unlikely to affect the reconstructed headers/scripts/objtool this
  repo actually needs — but this is a deliberate fidelity gap, not a
  verified equivalence.
- **Gaming variant: `CONFIG_MODULE_SIG_ALL=y`** (standard variant has
  `CONFIG_MODULE_SIG` unset). If the real machine has Secure Boot
  enabled and kernel lockdown active, this makes it *more* likely an
  unsigned out-of-tree module gets rejected at load time on `-gaming`
  specifically, on top of the general Secure Boot risk below.
- **Secure Boot / module signing** — Dakota uses a UKI
  (`systemd-boot` + unified kernel image). An unsigned out-of-tree
  module can be rejected at boot under kernel lockdown with Secure
  Boot enabled. If `modprobe nvidia` fails silently on first boot,
  start here (disable Secure Boot, or set up MOK enrollment + module
  signing in the build). Not tested in this repo yet.
- **nouveau blacklist may not be enough** — if Dakota bakes nouveau
  statically into the UKI instead of as an on-demand module,
  `files/nvidia-blacklist-nouveau.conf` alone won't fix it. See the
  comment in that file.
- **`nvidia-installer` flags** — checked against `--help`/
  `--advanced-options` of recent versions, but they change between
  branches. Re-validate before changing `NVIDIA_VERSION`.
- **libfprint overwrite ABI assumption** — see the section above.
- **`epson-printer-utility` post-install steps run against Dakota
  itself, not just verified via Fedora tooling** — `systemctl enable`,
  the `/etc/services` edit, and the (guarded) `update-desktop-database`
  call all run in the `final` stage, straight against the Dakota base
  image. The file layout the RPM unpacks into was verified against a
  real download in a Fedora build stage, but whether the daemon starts
  cleanly, the launcher shows up in GNOME Shell, and printing actually
  works has not been checked on real Dakota hardware.
- **Nothing here has been validated on real Dakota hardware.** Treat
  it as a tested starting point, not a guarantee — the same caveat
  `bluefin-initial-setup` makes about Dakota in general (still alpha).

## Local build

**Memory:** `kernel-src-builder`'s `make vmlinux` step needs several
GB of free RAM for its final link. Close memory-heavy applications
first, or build on a machine with more headroom — GitHub Actions'
hosted runners (16 GB) clear this comfortably, which is one more
reason to let CI do the definitive build rather than fighting it on a
laptop.

```bash
# 1. Confirm the current digests and paste them into the Containerfile
#    (the `ARG BASE_IMAGE=...` / `ARG BASE_IMAGE_GAMING=...` lines):
skopeo inspect docker://ghcr.io/projectbluefin/dakota:stable | jq -r .Digest
skopeo inspect docker://ghcr.io/projectbluefin/dakota-gaming:stable | jq -r .Digest

# 2. Confirm the image still ships the .config kernel-src-builder
#    needs (see the section above) — for whichever variant(s) you're
#    about to build:
./scripts/check-kernel-headers.sh stable dakota
./scripts/check-kernel-headers.sh stable dakota-gaming

# 3. Build the standard variant (uses the Containerfile's BASE_IMAGE
#    default, no override needed):
podman build --file Containerfile --tag localhost/dakota-nvidia-580:dev .

#    ...or the gaming variant (override BASE_IMAGE with the pinned
#    BASE_IMAGE_GAMING value from the Containerfile):
podman build --file Containerfile \
  --build-arg BASE_IMAGE=ghcr.io/projectbluefin/dakota-gaming:stable@sha256:<digest> \
  --tag localhost/dakota-nvidia-580-gaming:dev .

# 4. Basic smoke test before installing on any real machine:
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia-drm
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia-uvm
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia-modeset
podman run --rm localhost/dakota-nvidia-580:dev bootc container lint
podman run --rm localhost/dakota-nvidia-580:dev sh -c \
  'readlink -f /usr/bin/epson-printer-utility && test -x /usr/bin/epson-printer-utility'
podman run --rm localhost/dakota-nvidia-580:dev systemctl is-enabled ecbd.service
```

To change the driver version: `--build-arg NVIDIA_VERSION=580.xx.xx`
(confirm the right version for your GPU at
[nvidia.com/en-us/drivers/unix](https://www.nvidia.com/en-us/drivers/unix/)
before pinning it).

## Using it on a real Dakota host

```bash
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580:stable
# or the gaming variant:
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580-gaming:stable
# or, if the official image already has the ujust recipe:
ujust rebase-helper
```

A reboot is required afterwards. Validate `modprobe nvidia`,
`nvidia-smi`, the fingerprint reader (`fprintd-list $USER`,
`fprintd-verify`), and the Epson utility (`systemctl status
ecbd.service`, launching "Epson Printer Utility" from the app grid, or
`epson-printer-utility` on the command line) before considering the
migration done — and keep a way back (`bootc switch` to the original
`dakota:stable`/`dakota-gaming:stable` image) until you've validated
it on real hardware.

## Verification

Images are signed with [cosign](https://github.com/sigstore/cosign),
the same as [lbssousa/bluefin](https://github.com/lbssousa/bluefin):
CI signs every image it pushes (key-pair signing, not keyless/Fulcio),
and generates + attests an SPDX SBOM via
[syft](https://github.com/anchore/syft), also signed with the same
key. The public key is committed at `cosign.pub` in this repository,
and baked into the image itself at
`/usr/lib/pki/containers/lbssousa.pub` with a matching
`/etc/containers/policy.json` entry for `ghcr.io/lbssousa`
(`scripts/configure-signing-policy.sh`) — so `bootc upgrade` verifies
the signature automatically, reporting `ostree-image-signed:` instead
of `ostree-unverified-registry:`, and refuses an unsigned image.

To verify manually (`--insecure-ignore-tlog` is required: signing runs
with `--tlog-upload=false`, so there's no Rekor transparency-log entry
to check against — the name is misleading here, verification against
`cosign.pub` still happens and still fails on a bad signature):

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  ghcr.io/lbssousa/dakota-nvidia-580:stable
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  ghcr.io/lbssousa/dakota-nvidia-580-gaming:stable

# SBOM attestation:
cosign verify-attestation --key cosign.pub --type spdxjson --insecure-ignore-tlog=true \
  ghcr.io/lbssousa/dakota-nvidia-580:stable
```

The signing key itself is never committed — CI holds it as the
`SIGNING_SECRET` (private key) and `COSIGN_PASSWORD` (its passphrase)
repository secrets, set once with `cosign generate-key-pair` +
`gh secret set`.

## CI and automatic updates

- `.github/workflows/build.yml` runs a two-way matrix (`standard`,
  `gaming`) from the same `Containerfile`, building and publishing
  both `ghcr.io/lbssousa/dakota-nvidia-580:stable` and
  `ghcr.io/lbssousa/dakota-nvidia-580-gaming:stable` on push to
  `main`, on a daily schedule (covers the case where a Renovate PR was
  already merged without a manual rebuild), and via
  `workflow_dispatch`. Each matrix leg resolves its base image by
  reading the `BASE_IMAGE`/`BASE_IMAGE_GAMING` `ARG` default straight
  out of the `Containerfile` and passing it as
  `--build-arg BASE_IMAGE=...` — the digest lives in one place. `fail-
  fast: false` means one variant failing (e.g. the gaming kernel
  breaking the kmod build) doesn't cancel the other's build/publish.
- `renovate.json5` tracks both digests — `BASE_IMAGE`
  (`ghcr.io/projectbluefin/dakota:stable`) and `BASE_IMAGE_GAMING`
  (`ghcr.io/projectbluefin/dakota-gaming:stable`) — pinned in the
  `Containerfile`, and opens a **separate** PR per variant when either
  changes upstream — **every bump is a reviewable PR**, not a silent
  rebuild, because a new base image can ship a new kernel and break
  the kmod until you confirm the build still passes. The two are kept
  separate because the gaming (OGC) kernel stream updates
  independently of, and sometimes lags, the standard one.
