# dakota-nvidia-580

A customized [Bluefin Dakota](https://docs.projectbluefin.io/dakota/)
image with four components baked in via downstream OCI image layering
(not by forking the upstream BuildStream build — see ["Why downstream
instead of forking
BuildStream"](#why-downstream-instead-of-forking-buildstream) below):

- **Proprietary NVIDIA driver on the legacy 580.xxx branch** — needed
  because the target GPU is from a generation no longer supported by
  the official `dakota-nvidia`/`dakota-nvidia-gaming` variants, which
  track the newer branch (~610.x/615.x as of 2026).
- **[lbssousa/libfprint](https://github.com/lbssousa/libfprint) fork**
  (pinned to tag `v1.94.10-goodix538d.2`), adding support for the
  Goodix 538d fingerprint reader — the same fork used in
  [lbssousa/bluefin-initial-setup](https://github.com/lbssousa/bluefin-initial-setup)
  (`playbooks/dakota/libfprint.yml`), which installs it at **runtime**
  via distrobox for Dakota hosts not using this custom image. Here it
  is compiled during the image build and installed **directly into
  `/usr`, overwriting the stock libfprint** shipped in the Dakota base
  image at its original path — see ["How the libfprint overwrite
  works"](#how-the-libfprint-overwrite-works) below. The
  goodixtls53xd driver's SIGFM matcher is a self-contained
  implementation with no OpenCV dependency, so `libfprint-builder`
  needs no `opencv-devel` and nothing OpenCV-related ends up in the
  final image.
- **[Yubico/pam-u2f](https://github.com/Yubico/pam-u2f)** (upstream,
  not a fork) — `pam_u2f.so` (the PAM module) and `pamu2fcfg` (the CLI
  used to enroll a YubiKey and generate `~/.config/Yubico/u2f_keys`),
  needed to authenticate with a YubiKey over FIDO2/U2F. Neither can
  come from Homebrew: PAM modules must live in the system's PAM module
  directory (found by `pam-u2f-probe`, same trick as `libfprint-probe`
  below) to be loadable by `gdm`/`sudo`/`su` at all. Its own runtime
  dependency, `libfido2`, is deliberately **not** baked in here — it's
  left to `brew install libfido2`, matching what
  [lbssousa/bluefin-initial-setup](https://github.com/lbssousa/bluefin-initial-setup)
  (`playbooks/yubikey.yml`) already documents for Fedora Dakota hosts.
  Actually wiring `pam_u2f.so` into `/etc/pam.d` (enabling YubiKey PAM
  auth) is **out of scope for this image** — this repo only ensures
  the library and executable exist; see
  [`playbooks/dakota/yubikey.yml`](https://github.com/lbssousa/bluefin-initial-setup/blob/main/playbooks/dakota/yubikey.yml)
  in bluefin-initial-setup for the current state of that (as of this
  writing, deliberately left out there too, since Dakota has no
  `authselect`) — though `/etc/pam.d/system-auth` on this image's base
  turns out to be a plain, directly-editable file (confirmed by
  inspecting the published image), not `authselect`-templated, so that
  gap may be easier to close than documented there.
- **Epson printer support** (CUPS `rastertoepson` filter + `ecbd`
  network-discovery daemon), extracted from Epson's binary
  `epson-printer-utility` RPM the same way as in
  [ublue-os/bluefin](https://github.com/ublue-os/bluefin)
  (`build_files/20-epson.sh`) — downloaded and unpacked rather than
  installed via `rpm`/`dnf`, since Dakota has neither. This repo does
  **not** ship the RPM's Qt5 setup/maintenance GUI (Dakota/GNOME OS has
  no Qt5 runtime, and bundling one just for an optional utility isn't
  worth the image-size cost; printing itself doesn't need it — see
  ["Known limitations"](#known-limitations)). Nor does it install bluefin's `epson-inkjet-printer-escpr`
  driver package, which needs building from source against
  `cups-devel`/autotools, not present on Dakota.

Like the upstream project, this repo builds two variants from the same
`Containerfile`, both published under two tags each — mirroring
upstream Dakota's own rolling-vs-promoted tag split (`:testing`
promoted to `:stable` on a fixed cadence), simplified to a single
rolling tag since this repo has no `:next`/`:testing` split of its own:

- `:latest` — rebuilt on every push to `main`, on the daily schedule
  that catches a merged Renovate base-image bump, and on manual
  dispatch. This is the rolling tag; see ["CI and automatic
  updates"](#ci-and-automatic-updates).
- `:stable` — a straight registry retag of whatever `:latest` digest
  is current at promotion time (no rebuild), promoted weekly. This is
  the tag a real machine should track.

  - `ghcr.io/lbssousa/dakota-nvidia-580` — standard Dakota base.
  - `ghcr.io/lbssousa/dakota-nvidia-580-gaming` — Dakota gaming base
    (Open Gaming Collective/OGC kernel, Steam, gamescope, etc.),
    mirroring the upstream `dakota-nvidia`/`dakota-nvidia-gaming` split.

## Status

Both variants build and publish successfully end-to-end in CI
(`.github/workflows/build.yml`). The container image builds, all four
NVIDIA kernel modules (`nvidia.ko`, `nvidia-uvm.ko`,
`nvidia-modeset.ko`, `nvidia-drm.ko`) compile and link, and both images
are signed with a valid SBOM attestation — see
["Verification"](#verification) for how to check that yourself with
`cosign verify`/`cosign verify-attestation`.

Open items on real hardware, tracked in detail in ["Known
limitations"](#known-limitations) below:

- Fingerprint enrollment/verification issues (`enroll-duplicate` on a
  second finger, cross-finger false negatives) are a
  [`lbssousa/libfprint`](https://github.com/lbssousa/libfprint) fork
  matter (the `goodixtls53xd` SIGFM matcher), not something this
  image-build repo's `Containerfile` controls — it only bundles that
  fork's build output.
- Secure Boot / module signing for the out-of-tree NVIDIA kmod hasn't
  been exercised.

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

## `struct module` layout must match the running kernel

Reconstructing the build tree buys a compilable kernel tree, but it
also creates a trap worth understanding, because it produced a real bug
in this repo: **a module can compile cleanly, pass every check the
kernel makes at `insmod` time, and still be impossible to load.**

Every `.ko` carries its own `struct module` instance — `__this_module`,
generated by `modpost` into `<mod>.mod.c` and linked into a
`.gnu.linkonce.this_module` section. Its `init`/`exit` function
pointers are left empty at compile time; the module ships two
`R_X86_64_64` relocations against `init_module`/`cleanup_module` in
`.rela.gnu.linkonce.this_module`, and the loader writes the resolved
addresses into those two slots.

The *offsets* of those slots come from whatever `struct module` looked
like in the build tree's `include/linux/module.h` — which is full of
`#ifdef CONFIG_*` blocks. Build against a tree whose `.config` differs
from the running kernel's in any one of them and the relocations name
the wrong fields. Nothing in a normal build notices:

- **vermagic** encodes only version, SMP, preempt, module-unload and
  modversions — not `struct module`'s layout.
- **CRCs** (`CONFIG_MODVERSIONS`) are unset on Dakota, and wouldn't
  cover this anyway.
- **the compiler and linker** see nothing wrong: the module is
  perfectly self-consistent, just consistent with the wrong kernel.

What you get instead is a boot-time failure, because `load_module()`
calls `module_unload_init()` — `INIT_LIST_HEAD(&mod->source_list)` —
*before* `apply_relocations()`, while x86's `__write_relocate_add()`
(`arch/x86/kernel/module.c`) requires every relocation target to still
be zero:

```
nvidia: loading out-of-tree module taints kernel.
module: x86/modules: Invalid relocation target, existing value is nonzero
        for sec 69, idx 1, type 1, loc ffffffffc2b6a258, val ffffffffc26a0b20
```

and the load returns `-ENOEXEC`.

### The bug this repo shipped

The `kernel-src-builder` stage had no `pahole` installed. In Kconfig:

```
config DEBUG_INFO_BTF
        ...
        depends on PAHOLE_VERSION >= 122
```

and `scripts/pahole-version.sh` reports `0` when `pahole` isn't on
`PATH`. So `make olddefconfig` — whose whole job is to resolve
unsatisfiable dependencies *silently* — dropped Dakota's shipped
`CONFIG_DEBUG_INFO_BTF=y`, and with it `CONFIG_DEBUG_INFO_BTF_MODULES=y`.
That option contributes 24 bytes to `struct module`
(`btf_data_size`, `btf_base_data_size`, `btf_data`, `btf_base_data`),
sitting between `init` and `exit`:

| field | Dakota's kernel | as built without `pahole` |
| --- | --- | --- |
| `init` | `0x130` | `0x130` (unaffected — the BTF block is after it) |
| `source_list` | `0x490`–`0x49f` | — |
| `exit` | `0x4b0` | **`0x498`** |

`0x498` is `source_list.prev`, which `INIT_LIST_HEAD` has already
pointed at itself by relocation time. Hence the error above — for all
five modules, though only `nvidia.ko` reaches `dmesg`, since it fails
first and the rest are never tried.

A missing build *tool*, in other words, silently changed the module
ABI. Note that `modprobe nvidia` run as an unprivileged user reports
only `Operation not permitted` (that's `EPERM` for lacking
`CAP_SYS_MODULE`), which hides this completely — always check `dmesg`.

### The two guards

Both halves are deliberate: one catches the cause, the other the
effect, so a future divergence from any other cause is still caught.

1. **`scripts/build-kernel-src.sh` fails on any silent `.config`
   change.** It diffs the reconciled `.config` against the shipped one
   immediately after `make olddefconfig` — before the expensive
   `modules_prepare`/`vmlinux` builds — and aborts unless every changed
   symbol matches its `allowed_deltas` list. That list holds exactly one
   entry today, the deliberate Rust disable (see ["Known
   limitations"](#known-limitations)). Adding to it requires a comment
   explaining why the divergence can't affect the module ABI.
2. **`scripts/module-abi.py` verifies the built modules structurally.**
   The Dakota base image ships `/usr/lib/modules/<kver>/vmlinux` with a
   `.BTF` section, i.e. the running kernel's own `struct module` layout
   as ground truth. `kernel-headers` extracts it to
   `/kernel-module-abi.json`; `build-nvidia.sh` then asserts, for every
   `.ko` it just built and before packaging any of them, that
   `sizeof(struct module)` and both relocation offsets agree with it.
   The script is stdlib-only, with its own small ELF and BTF readers —
   gating a correctness check on `bpftool` or `pahole` being installed
   would repeat the original mistake. It runs in about a tenth of a
   second.

   It can be run by hand against an installed system too, which is how
   to confirm a suspect `.ko` on real hardware:

   ```bash
   python3 scripts/module-abi.py extract "$(uname -r)" \
       "/usr/lib/modules/$(uname -r)/vmlinux" /tmp/abi.json
   python3 scripts/module-abi.py verify /tmp/abi.json \
       /usr/lib/modules/"$(uname -r)"/extra/*.ko
   ```

Keeping `CONFIG_DEBUG_INFO_BTF=y` has a cost: `make vmlinux` in
`kernel-src-builder` now also runs `pahole -J` over a `vmlinux` built
with full DWARF, and builds `tools/bpf/resolve_btfids` (hence the
`zlib-devel`/`libzstd-devel`/`pkgconf-pkg-config` packages). That is
the price of a tree that genuinely matches Dakota's kernel.

## Architecture

The same `Containerfile` builds both variants — `dakota-base` resolves
to whichever image `BASE_IMAGE` points at (standard Dakota by
default; the gaming base when CI overrides it for the `-gaming` leg —
see ["CI and automatic updates"](#ci-and-automatic-updates) below).
Everything downstream (kernel headers, kmod build, libfprint, pam-u2f,
Epson utility) is derived from that image at build time, so it needs
no per-variant changes.

```
dakota-base (FROM ${BASE_IMAGE}, e.g. ghcr.io/projectbluefin/dakota:stable@sha256:...
             or ghcr.io/projectbluefin/dakota-gaming:stable@sha256:... for the gaming variant)
  │
  ├─→ kernel-headers            extracts kernel version, its shipped .config,
  │     │                       and the authoritative struct module layout from
  │     │                       the image's own vmlinux .BTF section
  │     │                       (NOT /usr/lib/modules/<kver>/build — see above)
  │     │                       (scripts/module-abi.py extract)
  │     │
  │     └─→ kernel-src-builder  (Fedora, build environment only)
  │           fetches matching upstream kernel source (kernel.org or
  │           OpenGamingCollective/linux.git, auto-detected from the
  │           kernel version string), configures it with the shipped
  │           .config, ABORTS if olddefconfig silently changed any
  │           option (see "struct module layout must match the running
  │           kernel" above), builds vmlinux + the DRM modules
  │           nvidia-drm.ko needs, assembles a real /src/linux-<kver>/ +
  │           /lib/modules/<kver>/build
  │           (scripts/build-kernel-src.sh)
  │           │
  │           └─→ nvidia-builder    (Fedora, build environment only)
  │                 builds the out-of-tree kmod against the reconstructed
  │                 tree above, using GCC/binutils from toolchain-builder
  │                 (not Fedora's own — see "Compiler/linker version
  │                 mismatch" below), VERIFIES every built .ko against
  │                 the kernel's own struct module layout before
  │                 packaging (scripts/module-abi.py verify), runs
  │                 nvidia-installer --no-kernel-module, and packages the
  │                 result via a filesystem diff (scripts/build-nvidia.sh)
  │                 ↑
  │                 toolchain-builder (Fedora, build environment only)
  │                 builds GCC 16.2.0 + binutils from upstream source, at
  │                 the exact pins freedesktop-sdk itself uses to build
  │                 Dakota's kernel (scripts/build-toolchain.sh)
  │
  ├─→ libfprint-probe         locates libfprint-2.so's exact libdir
  │     │                     in the Dakota base image
  │     │
  │     └─→ libfprint-builder (Fedora, build environment only)
  │           builds the fork with meson, with
  │           --prefix=/usr --libdir=<probed dir>, DESTDIR=/out
  │
  ├─→ pam-u2f-probe           locates the PAM module directory
  │     │                     (e.g. /usr/lib/x86_64-linux-gnu/security)
  │     │                     in the Dakota base image
  │     │
  │     └─→ pam-u2f-builder   (Fedora, build environment only)
  │           builds Yubico's upstream pam-u2f (CMake) against Fedora's
  │           libfido2-devel (build-time only), installing pam_u2f.so
  │           to -DPAM_DIR=<probed dir> and pamu2fcfg to /usr/bin,
  │           DESTDIR=/out
  │
  ├─→ epson-builder           (Fedora, build environment only)
  │         downloads Epson's binary epson-printer-utility RPM and
  │         unpacks it (no rpm/dnf install) into /out
  │         (scripts/install-epson-utility.sh)
  │
  └─→ final (FROM dakota-base again)
        COPY of all four /out trees (libfprint's overwrites the
        stock library in place; pam-u2f's adds new files alongside
        it), nouveau blacklist, depmod + ldconfig -r, Epson
        post-install steps (symlink, systemd enable, /etc/services
        entry), signing policy (scripts/configure-signing-policy.sh —
        see "Verification"), bootc container lint
```

The `kernel-src-builder`, `nvidia-builder`, `libfprint-builder`,
`pam-u2f-builder` and `epson-builder` stages use Fedora **only as a
build environment** (it has `dnf`, `gcc`, `meson`, `cmake`,
`rpm2cpio`...) — nothing from them ends up in the final image except
what the scripts/build commands explicitly package into `/out`. The
final image is still plain Dakota (GNOME OS, no RPMs) with these
payloads layered on top.

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

## How pam-u2f is installed

Same `lib`-vs-`lib64`-style ambiguity as libfprint above, except for
the PAM module directory: on this image's base it turned out to be
`/usr/lib/x86_64-linux-gnu/security` (Debian-style multiarch, not
Fedora's `/usr/lib64/security`), confirmed by inspecting the published
image directly rather than assuming. A `/usr/lib/security` directory
also exists but only holds an unrelated `pam_apparmor.so` — installing
`pam_u2f.so` there instead would make it silently invisible to PAM.
`pam-u2f-probe` finds the right one by locating `pam_unix.so` (always
present, since it's what local password auth uses) and reading off its
containing directory; `pam-u2f-builder` passes that as CMake's
`-DPAM_DIR`.

Unlike libfprint, this doesn't overwrite anything already shipped —
`pam_u2f.so` and `pamu2fcfg` are new files, added alongside Dakota's
existing PAM modules.

`pam_u2f.so`/`pamu2fcfg` are built directly against Fedora's
`libfido2-devel` (build-time only — nothing from that dnf install
lands in `/out`/the final image). At runtime, their only dependency
not already present in the Dakota base image (confirmed: `libpam.so.0`
and `libcrypto.so.3` both are) is `libfido2.so.1` itself, which this
repo deliberately does **not** bake in — see the `PAM_U2F_REPO`/`REF`
comment in the `Containerfile` and ["Known
limitations"](#known-limitations) below for why that's left to
`brew install libfido2`, and why that hasn't been independently
verified to actually resolve at runtime for a module living in `/usr`.

## Optional: reverting Bluefin's GNOME desktop tweaks

Bluefin (which Dakota is built on) bakes a set of desktop defaults into
`/usr/share/glib-2.0/schemas/zz0-bluefin-modifications.gschema.override`
(plus a second file, `zz3-bluefin-unsupported-stuff.gschema.override`,
that re-lists `enabled-extensions` with a few more entries). These are
GSettings *default-value* overrides — compiled into `gschemas.compiled`
at build time — not hardcoded behavior, and not a per-user dconf
setting, so a user can still change any of them individually with
`gnome-tweaks`/`dconf-editor`; this only changes what a fresh account
starts with.

This repo turns that reversion **on by default** (pass
`--build-arg DISABLE_BLUEFIN_GNOME_TWEAKS=false` to keep Bluefin's own
desktop defaults instead). When enabled, the `final` stage adds one
more override file,
`zz9-dakota-nvidia-580-gnome-tweaks.gschema.override` — named to sort
after Bluefin's own `zz0`/`zz3` files, since `glib-compile-schemas`
resolves same-key collisions in filename order — and reruns
`glib-compile-schemas` (already shipped in the Dakota base image, so no
extra build stage is needed). It reverts:

- **Window titlebar buttons** — Bluefin sets
  `org.gnome.desktop.wm.preferences` `button-layout` to
  `:minimize,maximize,close`; this reverts it to `:close` (close button
  only, no minimize/maximize).
- **Hot corners** — Bluefin sets `org.gnome.desktop.interface`
  `enable-hot-corners` to `false`; this reverts it to `true`.
- **Blur my Shell** (`blur-my-shell@aunetx`) and **Dash to Dock**
  (`dash-to-dock@micxgx.gmail.com`) — force-disabled via
  `org.gnome.shell` `disabled-extensions`, which
  `org.gnome.shell.gschema.xml` documents as taking precedence over
  `enabled-extensions`. This was chosen over editing
  `enabled-extensions` directly because that list is defined in two
  separate Bluefin files and changes over time; overriding
  `disabled-extensions` instead only names the two extensions this
  toggle cares about, regardless of what else Bluefin enables by
  default.

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
only compiles what actually needs compiling (the out-of-tree kmod, the
libfprint fork, and Yubico's pam-u2f) against a kernel tree it
reconstructs itself from upstream source + the image's own shipped
`.config` (see above) — plus unpacking Epson's binary
`epson-printer-utility` RPM, which needs no compilation at all.

## Known limitations

- **`make vmlinux`'s final link needs several GB of RAM** in a single
  non-parallel step. GitHub Actions' hosted runners (16 GB) handle it
  in well under a minute; a memory-constrained machine may need swap
  or closed applications first, or just let CI do the build.
- **BTF generation adds to that.** Dakota ships
  `CONFIG_DEBUG_INFO_BTF=y`, and the reconstructed tree has to keep it
  (see ["`struct module` layout must match the running
  kernel"](#struct-module-layout-must-match-the-running-kernel)), so
  `make vmlinux` also runs `pahole -J` over a fully DWARF-annotated
  `vmlinux` and builds `tools/bpf/resolve_btfids`. Turning it off is
  not an option: it changes `struct module`'s layout, and
  `scripts/module-abi.py` will fail the build if you try.
- **`toolchain-builder` compiles GCC + binutils from source**, adding
  real time to every build (a from-source GCC build, even
  single-stage/C-only, is the slowest single step in this
  Containerfile) — the cost of matching Dakota's kernel toolchain
  exactly instead of approximating with Fedora's own packages. See
  "Compiler/linker version mismatch" below.
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
  kernel release string (vermagic), and none of the affected symbols
  appears in an `#ifdef` inside `struct module`. It is the sole entry in
  `build-kernel-src.sh`'s `allowed_deltas` — every other `.config`
  divergence fails the build (see ["`struct module` layout must match
  the running
  kernel"](#struct-module-layout-must-match-the-running-kernel)). Note
  that Kconfig would drop `CONFIG_RUST` here by itself regardless, since
  `CONFIG_RUST_IS_AVAILABLE` is another tool probe
  (`scripts/rust_is_available.sh`) and this stage installs no `rustc` —
  the explicit `scripts/config --disable RUST` just makes the intent
  visible.
- **Compiler/linker version mismatch** — `nvidia.ko` is built with the
  exact GCC + binutils that built Dakota's own kernel rather than
  something close, on the general principle that an out-of-tree module
  should be compiled by the toolchain its kernel was.

  Be aware of what this does *not* explain, though: the
  `Invalid relocation target, existing value is nonzero` failure in
  `.gnu.linkonce.this_module` that motivated `toolchain-builder` in the
  first place was **not** caused by GCC drift. It was a `struct module`
  layout mismatch from a silently dropped `.config` option, diagnosed
  and fixed separately — see ["`struct module` layout must match the
  running kernel"](#struct-module-layout-must-match-the-running-kernel)
  above. So treat that symptom as a layout problem first (run
  `scripts/module-abi.py`, which pinpoints it in a tenth of a second)
  and a toolchain problem second. Nothing here has since demonstrated
  that a micro-version of GCC drift alone breaks module loading; if you
  ever need to cut build time, dropping `toolchain-builder` for Fedora's
  own compiler is therefore a reasonable thing to *test*, with the ABI
  check as the gate. `toolchain-builder` (see the
  Containerfile) builds GCC 16.2.0 and binutils from official upstream
  source at the exact pins freedesktop-sdk itself uses to build
  Dakota's kernel (`elements/bootstrap/gcc.bst` → tag
  `releases/gcc-16.2.0`; `elements/bootstrap/binutils.bst` → tag
  `binutils-2_47`, commit `6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32`)
  via `scripts/build-toolchain.sh`, and `nvidia-builder` uses that
  toolchain instead of Fedora's own. `kernel-src-builder` stays on
  Fedora's toolchain since its output (`vmlinux`, `ttm.ko`,
  `drm_ttm_helper.ko`) never ships to the real machine — see that
  stage's own comment.

  `build-nvidia.sh` doesn't pass `IGNORE_CC_MISMATCH=1`: kbuild's own
  version check enforces the match, so a future drift fails the build
  loudly instead of producing another unloadable `.ko`. `RANDSTRUCT`
  and `LTO` are both off in the shipped config (the two options most
  likely to make any *remaining* toolchain drift genuinely
  ABI-incompatible on top of this). Test `modprobe nvidia` before
  trusting a build regardless, and re-derive
  `scripts/build-toolchain.sh`'s pins whenever a base-image bump
  changes the kernel's own toolchain — check
  `CONFIG_CC_VERSION_TEXT` in the shipped `.config` for the GCC
  version, and `/proc/version` on the real machine for the binutils
  version (not shown in the `.config`).
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
- **nouveau blacklist alone is not enough** —
  `files/nvidia-blacklist-nouveau.conf` doesn't stop nouveau from
  claiming the GPU, since it binds the PCI device during the
  initramfs/plymouth stage, before `/usr/lib/modprobe.d` is even
  consulted. Fixed via kernel command-line args
  (`rd.driver.blacklist=nouveau`, honored inside the initramfs) baked
  in through `files/nvidia-kargs.toml` → `/usr/lib/bootc/kargs.d/`. A
  machine already running an older build of this image needs a fresh
  `bootc switch`/`upgrade` for the new kargs to take effect — they're
  applied when bootc writes the boot entry, not retroactively to an
  existing deployment.
- **`uwelcome`'s image-identity banner reads
  `/usr/share/ublue-os/image-info.json`, not `/etc/os-release`** — see
  `github.com/projectbluefin/uwelcome`, `internal/system/system.go`,
  `GetImageInfo()`. The final stage overwrites both files with this
  image's own identity (`ghcr.io/lbssousa/dakota-nvidia-580[-gaming]`),
  in the same JSON shape upstream's own build generates (see
  `ublue-os/bluefin`'s `build_files/base/00-image-info.sh`); the
  `/etc/os-release` fields are kept in sync too, as a Universal Blue
  convention other tooling may read, but `image-info.json` is what the
  banner itself actually uses.
- **Fingerprint enrollment/verification on the Goodix 538d** —
  enrolling a second finger (e.g. left index, after the right index is
  already enrolled) can fail with `enroll-duplicate`, and verifying one
  finger against another enrolled finger can false-negative often. This
  is matching-algorithm/driver behavior in the
  [`lbssousa/libfprint`](https://github.com/lbssousa/libfprint) fork
  itself (the `goodixtls53xd` SIGFM matcher) — this image-build repo
  only bundles that fork's build output, so it can't fix this on its
  own; track/fix it in that repo instead.
- **`nvidia-installer` flags** — checked against `--help`/
  `--advanced-options` of recent versions, but they change between
  branches. Re-validate before changing `NVIDIA_VERSION`.
- **libfprint overwrite ABI assumption** — see the section above.
- **pam-u2f's runtime dependency on a Homebrew-provided `libfido2` is
  unverified** — see ["How pam-u2f is
  installed"](#how-pam-u2f-is-installed). This image's base ships no
  `linuxbrew` entry in `/etc/ld.so.conf.d` out of the box (checked
  directly), so whether `pam_u2f.so`/`pamu2fcfg` can actually resolve
  `libfido2.so.1` at runtime depends entirely on how Homebrew itself
  gets installed/registered on the running host. Re-verify with `ldd`
  against the real host before relying on this for login/`sudo`.
- **Actually enabling YubiKey PAM auth (`/etc/pam.d` wiring) is out of
  scope here** — this repo only ensures `pam_u2f.so`/`pamu2fcfg` exist
  in the image; see the pam-u2f bullet near the top of this README.
- **Epson printing**: `ecbd.service` and the CUPS `rastertoepson`
  filter's dependencies are expected to resolve cleanly (the GUI
  utility is no longer shipped at all — see the Epson bullet near the
  top of this README). Actual print jobs through CUPS
  (network-discovered printer + real print job) haven't been exercised
  end-to-end, only the daemon/filter wiring.

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

# The built image contains both the kernel's vmlinux and the modules, so
# the struct module ABI check can be re-run against the finished image —
# nvidia-builder already gated the build on it, but this confirms it
# end-to-end on what actually shipped:
podman run --rm -v "$PWD/scripts/module-abi.py:/module-abi.py:ro,Z" \
  localhost/dakota-nvidia-580:dev sh -c '
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"
    python3 /module-abi.py extract "$kver" \
        "/usr/lib/modules/$kver/vmlinux" /tmp/abi.json
    python3 /module-abi.py verify /tmp/abi.json \
        /usr/lib/modules/"$kver"/extra/*.ko'
```

To change the driver version: `--build-arg NVIDIA_VERSION=580.xx.xx`
(confirm the right version for your GPU at
[nvidia.com/en-us/drivers/unix](https://www.nvidia.com/en-us/drivers/unix/)
before pinning it).

This image reverts Bluefin's minimize/maximize titlebar buttons, Blur
my Shell, Dash to Dock and disabled hot corners back to stock GNOME
behavior **by default**; pass `--build-arg
DISABLE_BLUEFIN_GNOME_TWEAKS=false` to keep Bluefin's own desktop
defaults instead — see the `ARG DISABLE_BLUEFIN_GNOME_TWEAKS` comment
in the `Containerfile` for exactly what it changes and how.

## Using it on a real Dakota host

```bash
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580:stable
# or the gaming variant:
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580-gaming:stable
# or, if the official image already has the ujust recipe:
ujust rebase-helper
```

`:stable` is the tag to track on a real machine — see ["CI and
automatic updates"](#ci-and-automatic-updates) for what it actually
points at and how often it moves. `:latest` also exists (rebuilt on
every push) for testing a fix ahead of that weekly promotion.

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

Tagging mirrors upstream Dakota's own rolling-vs-promoted split
(there, `:testing`/`:next` built continuously and promoted to
`:stable` on a fixed release cadence via a separate workflow), scaled
down to this repo's single rolling tag:

- **`:latest` — `.github/workflows/build.yml`.** Runs a two-way matrix
  (`standard`, `gaming`) from the same `Containerfile`, building and
  publishing both `ghcr.io/lbssousa/dakota-nvidia-580:latest` and
  `ghcr.io/lbssousa/dakota-nvidia-580-gaming:latest` on push to `main`,
  on a daily schedule (covers the case where a Renovate PR was already
  merged without a manual rebuild), and via `workflow_dispatch`. Each
  matrix leg resolves its base image by reading the
  `BASE_IMAGE`/`BASE_IMAGE_GAMING` `ARG` default straight out of the
  `Containerfile` and passing it as `--build-arg BASE_IMAGE=...` — the
  digest lives in one place. `fail-fast: false` means one variant
  failing (e.g. the gaming kernel breaking the kmod build) doesn't
  cancel the other's build/publish. Every push builds a fresh image;
  `IMAGE_TAG` defaults to `latest` in the `Containerfile`, matching
  what's actually published (baked into `/etc/os-release` and
  `image-info.json` — see ["Known limitations"](#known-limitations)),
  so the image's own self-reported identity stays correct even after
  it's later promoted to `:stable` below.
- **`:stable` — `.github/workflows/promote-stable.yml`.** Runs weekly
  (Sundays) and via `workflow_dispatch`. For each variant, resolves the
  current `:latest` digest, `cosign verify`s it against `cosign.pub`,
  and — only if it differs from what `:stable` currently points at —
  retags it to `:stable` with a server-side `skopeo copy
  --preserve-digests` (no rebuild: `:stable` is always some past
  `:latest` digest, never new bytes). This is the tag a real machine
  should track; a rebuild happening on `:latest` doesn't affect a host
  already switched to `:stable` until the next weekly promotion picks
  it up.
- `renovate.json5` tracks both base-image digests — `BASE_IMAGE`
  (`ghcr.io/projectbluefin/dakota:stable`) and `BASE_IMAGE_GAMING`
  (`ghcr.io/projectbluefin/dakota-gaming:stable`) — pinned in the
  `Containerfile`, and opens a **separate** PR per variant when either
  changes upstream — **every bump is a reviewable PR**, not a silent
  rebuild, because a new base image can ship a new kernel and break
  the kmod until you confirm the build still passes. The two are kept
  separate because the gaming (OGC) kernel stream updates
  independently of, and sometimes lags, the standard one.
