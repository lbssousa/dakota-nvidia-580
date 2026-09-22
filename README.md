# dakota-nvidia-580

A customized [Bluefin Dakota](https://docs.projectbluefin.io/dakota/)
image with two components baked in via downstream OCI image layering
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

## ⚠️ Before anything else: validate the kernel headers

The single biggest unresolved risk in this whole project is this:
**it is not confirmed that the published `dakota:stable` image exposes
a complete kernel build tree** at `/usr/lib/modules/<kver>/build`.
Dakota is assembled from scratch via Apache BuildStream (not from RPM
`kernel-devel` packages), as a space-optimized image with dedup via
Chunkah — there's no guarantee that tree survives in the runtime image
rather than only existing in BuildStream's own intermediate build
artifacts.

Run this **before** setting up GHCR secrets, Renovate, etc.:

```bash
./scripts/check-kernel-headers.sh stable
```

If it fails, this whole approach (downstream Containerfile) doesn't
work, and the only alternative is forking the BuildStream build of
[`projectbluefin/dakota`](https://github.com/projectbluefin/dakota)
itself and pinning the driver version there — much heavier (requires
the full BuildStream + freedesktop-sdk + gnome-build-meta toolchain),
but it's the "native" path the project itself uses. See
`docs/oci-assembly.md` and `docs/patches.md` in the Dakota repo.

## Architecture

```
dakota-base (FROM ghcr.io/projectbluefin/dakota:stable@sha256:...)
  │
  ├─→ kernel-headers          extracts kernel version + /usr/lib/modules/<kver>/build
  │     │
  │     └─→ nvidia-builder    (Fedora, build environment only)
  │           builds the out-of-tree kmod against the headers above,
  │           runs nvidia-installer --no-kernel-module, and packages
  │           the result via a filesystem diff (scripts/build-nvidia.sh)
  │
  ├─→ libfprint-probe         locates libfprint-2.so's exact libdir
  │     │                     in the Dakota base image
  │     │
  │     └─→ libfprint-builder (Fedora, build environment only)
  │           builds the fork against Fedora's opencv-devel, with
  │           --prefix=/usr --libdir=<probed dir>, DESTDIR=/out
  │
  └─→ final (FROM dakota-base again)
        COPY of both /out trees (the second one overwrites the stock
        libfprint in place), nouveau blacklist, depmod + ldconfig -r,
        bootc container lint
```

The `nvidia-builder` and `libfprint-builder` stages use Fedora **only
as a build environment** (it has `dnf`, `gcc`, `meson`...) — nothing
from them ends up in the final image except what the scripts
explicitly package into `/out`. The final image is still plain Dakota
(GNOME OS, no RPMs) with these two payloads layered on top.

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
the libfprint fork) against headers extracted from that specific
image.

## Known risks, not fully validated

- **Kernel headers missing from the published image** — see the
  section above. Blocking; check this first.
- **Kernel API drift vs. the legacy driver branch** — Dakota tracks
  the upstream kernel closely; NVIDIA's 580.xxx branch is legacy and
  may lack compatibility patches for very recent kernels (the kind of
  patch RPM Fusion carries for legacy NVIDIA drivers on Fedora). If
  the kmod build fails on kernel API mismatches, look for community
  compatibility patches before trying to hand-patch it yourself.
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
- **Nothing here has been validated on real Dakota hardware.** Treat
  it as a tested starting point, not a guarantee — the same caveat
  `bluefin-initial-setup` makes about Dakota in general (still alpha).

## Local build

```bash
# 1. Confirm the current digest of dakota:stable and paste it into the
#    Containerfile (the `FROM ... @sha256:...` line):
skopeo inspect docker://ghcr.io/projectbluefin/dakota:stable | jq -r .Digest

# 2. Validate the kernel headers BEFORE building (see the section
#    above):
./scripts/check-kernel-headers.sh stable

# 3. Build:
podman build --file Containerfile --tag localhost/dakota-nvidia-580:dev .

# 4. Basic smoke test before installing on any real machine:
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia
podman run --rm localhost/dakota-nvidia-580:dev bootc container lint
```

To change the driver version: `--build-arg NVIDIA_VERSION=580.xx.xx`
(confirm the right version for your GPU at
[nvidia.com/en-us/drivers/unix](https://www.nvidia.com/en-us/drivers/unix/)
before pinning it).

## Using it on a real Dakota host

```bash
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580:stable
# or, if the official image already has the ujust recipe:
ujust rebase-helper
```

A reboot is required afterwards. Validate `modprobe nvidia`,
`nvidia-smi`, and the fingerprint reader (`fprintd-list $USER`,
`fprintd-verify`) before considering the migration done — and keep a
way back (`bootc switch` to the original `dakota:stable` image) until
you've validated it on real hardware.

## CI and automatic updates

- `.github/workflows/build.yml` builds and publishes
  `ghcr.io/lbssousa/dakota-nvidia-580:stable` on push to `main`, on a
  daily schedule (covers the case where a Renovate PR was already
  merged without a manual rebuild), and via `workflow_dispatch`.
- `renovate.json5` tracks the digest of
  `ghcr.io/projectbluefin/dakota:stable` pinned in the `Containerfile`
  and opens a PR when it changes upstream — **every bump is a
  reviewable PR**, not a silent rebuild, because a new base image can
  ship a new kernel and break the kmod until you confirm the build
  still passes.
