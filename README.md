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

- `:latest` — rebuilt on every push to `main`, on a weekly safety-net
  schedule (Mondays), and on manual dispatch. This is the rolling tag;
  see ["CI and automatic updates"](#ci-and-automatic-updates).
- `:stable` — a straight registry retag of whatever `:latest` digest
  is current at promotion time (no rebuild), promoted weekly. This is
  the tag a real machine should track.

  - `ghcr.io/lbssousa/dakota-nvidia-580` — standard Dakota base.
  - `ghcr.io/lbssousa/dakota-nvidia-580-gaming` — Dakota gaming base
    (Open Gaming Collective/OGC kernel, Steam, gamescope, etc.),
    mirroring the upstream `dakota-nvidia`/`dakota-nvidia-gaming` split.

## Status

Both variants build and publish successfully end-to-end in CI
(`.github/workflows/build.yml`). The container image builds, all five
NVIDIA kernel modules (`nvidia.ko`, `nvidia-uvm.ko`,
`nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-peermem.ko`) compile and
link, and both images are signed with a valid SBOM attestation — see
["Verification"](#verification) for how to check that yourself with
`cosign verify`/`cosign verify-attestation`.

Compiling was not enough, though: images built before the
`struct module` fix produced modules that `insmod` rejected with
`-ENOEXEC` on real hardware. The build now gates on
`scripts/module-abi.py`, which compares each module's `struct module`
layout against the target kernel's own BTF and fails the build on a
mismatch, so a green CI run means the modules can be loaded — see
["`struct module` layout must match the running
kernel"](#struct-module-layout-must-match-the-running-kernel). **An
image built before that fix needs rebuilding**; loading has not yet
been re-confirmed on hardware with a post-fix image.

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
shipped `.config`, runs `make olddefconfig` + `make modules_prepare`
and `tools/objtool/objtool`, and assembles `/usr/src/linux-<kver>/`
with the same file list `linux.bst`/`linux-ogc.bst` themselves copy —
reproducing their exact artifact shape.

It does **not** compile the kernel. `Module.symvers` is derived instead,
straight out of the binaries the image already ships — see
["Deriving `Module.symvers` instead of compiling the
kernel"](#deriving-modulesymvers-instead-of-compiling-the-kernel).

Run this to confirm a given image still ships the `.config` this
approach depends on (a much weaker requirement than the old
`build/Makefile` check, and both variants pass it today):

```bash
./scripts/check-kernel-headers.sh stable dakota
./scripts/check-kernel-headers.sh stable dakota-gaming
```

## Deriving `Module.symvers` instead of compiling the kernel

An out-of-tree module build needs `Module.symvers` for two things:
`modpost` resolves the module's undefined symbols against it (and
derives the `.ko`'s `depends=` from it), and NVIDIA's own `conftest.sh`
greps it for the *exact* export line of each symbol it feature-tests —
silently concluding "not present", and falling back to APIs long removed
from modern kernels, whenever the file is missing or incomplete.
`modules_prepare` alone never produces one.

Dakota's published image ships no `Module.symvers`, so this repo used to
obtain one the obvious way: `make vmlinux`, i.e. compile the whole
kernel, plus two scoped module builds (`ttm.ko`, `drm_ttm_helper.ko`)
for DRM exports that `make vmlinux` leaves out. That was the most
expensive step here after building GCC — a full kernel compile, a final
link needing several GB of RAM in one non-parallel step, and, since
`CONFIG_DEBUG_INFO_BTF` has to stay on for ABI reasons, a `pahole -J`
pass over a fully DWARF-annotated `vmlinux`.

None of it was necessary. The image already contains every export, fully
resolved:

| what | where | how it is stored |
| --- | --- | --- |
| built-in exports | `/usr/lib/modules/<kver>/vmlinux` | `__ksymtab` (a `struct kernel_symbol` per export: three PREL32 refs — value, name, namespace), `__kflagstab` (one byte per export), `__ksymtab_strings` |
| module exports | `/usr/lib/modules/<kver>/kernel/**/*.ko` | the same sections, plus the per-export `__ksymtab_<name>` / `__flags_<name>` / `__kstrtabns_<name>` labels in each module's symbol table |

`scripts/gen-module-symvers.py` reads both and writes `Module.symvers` in
`modpost`'s own `write_dump()` format, in about two seconds. The two file
kinds need different readers: in `vmlinux` the PREL32 refs are resolved,
so the targets are address arithmetic, while a `.ko` is relocatable and
those words are zero with relocations against them — hence the label
route for modules, which needs no relocation processing at all. The
GPL-only flag comes from the `__kflagstab` byte, which `modpost`'s
`get_symbol_flags()` sets to `KSYM_FLAG_GPL_ONLY` or `0` and nothing
else.

The result is *more* complete than what was compiled before: every
module in the image contributes, so a future NVIDIA release needing a
symbol from some other module no longer requires anyone to hunt down and
add its build target. On kernel 7.2.6 that is 16364 built-in exports plus
8568 from 2335 shipped modules.

Validated against two independent sources on a real installation:

- **Built-in exports** — the 16364 names match the `__ksymtab_*` labels
  in the image's own `System.map` exactly: no extras, none missing.
- **Module exports** — compared against `modules.symbols`, which `depmod`
  generates independently. Every difference is accounted for: 99 are
  symbol *namespaces*, which `kmod` lists as though they were symbols,
  and 102 belong to `nvidia`/`nvidia-modeset` in `extra/`, which the
  generator deliberately skips (feeding a previous build's own output
  back into the next build's symbol list would be both circular and
  stale). Nothing appears in the derived file that `depmod` doesn't know
  about.

Two guard rails, because a silently *incomplete* `Module.symvers` is the
failure mode that makes `conftest.sh` pick the wrong API:

- A `__kcrctab` section anywhere means `CONFIG_MODVERSIONS=y`, where real
  CRCs matter and cannot be derived. The generator refuses rather than
  emit zeros that would make every module unloadable.
- Compressed modules (`.ko.xz`/`.ko.zst`) are a hard error too, rather
  than being skipped.

One consequence to know: the assembled tree has no `vmlinux`, so kbuild
skips BTF generation for modules built against it —
`scripts/Makefile.modfinal`'s `cmd_btf_ko` tests for `$(objtree)/vmlinux`
and prints `Skipping BTF generation ... due to unavailability of
vmlinux` instead of failing. That was already true before this change
(the copied file list never included `vmlinux`), it means no `pahole` is
needed in `nvidia-builder`, and module BTF is introspection metadata for
BPF tooling — unrelated to whether the module loads.

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
   change.** It compares the reconciled `.config` against the shipped one
   immediately after `make olddefconfig` — before `modules_prepare` spends
   any time on a tree that is already wrong — and aborts unless every
   changed symbol matches its `allowed_deltas` list. Adding to that list
   requires a comment explaining why the divergence can't affect the
   module ABI; the entries there today are the deliberate Rust disable and
   its one non-obvious knock-on (`CONFIG_ANDROID_BINDER_DEVICES`), plus
   the toolchain probes described below.

   Two things make the comparison mean what it should. A symbol *absent*
   from a `.config` counts as `n`, because Kconfig writes no line at all
   for a symbol whose dependencies are unmet — treating that as a change
   produced six pure non-events on this `.config` and nothing useful. And
   Kconfig recomputes every symbol that has no prompt, evaluating its
   `default` fresh, which for a large family means probing the *installed*
   toolchain: `CONFIG_CC_VERSION_TEXT`, `CONFIG_GCC_VERSION`,
   `CONFIG_PAHOLE_VERSION`, the `CONFIG_CC_HAS_*` results and 60-odd
   others are guaranteed to differ, since this stage runs on Fedora's
   compiler rather than the one freedesktop-sdk built Dakota's kernel
   with. Those are allowed, because a probe only *describes* the
   toolchain: anything it actually gates surfaces in a separate,
   non-probe symbol that the guard still checks. The patterns are
   enumerated rather than family wildcards so that
   `CC_OPTIMIZE_FOR_PERFORMANCE` and the `GCC_PLUGIN_*` family — where
   `GCC_PLUGIN_RANDSTRUCT` lives, which genuinely reorders structs —
   stay policed.
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
  │     │                       the authoritative struct module layout from the
  │     │                       image's own vmlinux .BTF section, and a real
  │     │                       Module.symvers derived from that vmlinux plus
  │     │                       every shipped module
  │     │                       (NOT /usr/lib/modules/<kver>/build — see above)
  │     │                       (scripts/module-abi.py extract,
  │     │                        scripts/gen-module-symvers.py)
  │     │
  │     └─→ kernel-src-builder  (Fedora, build environment only)
  │           fetches matching upstream kernel source (kernel.org or
  │           OpenGamingCollective/linux.git, auto-detected from the
  │           kernel version string), configures it with the shipped
  │           .config, ABORTS if olddefconfig silently changed any
  │           option (see "struct module layout must match the running
  │           kernel" above), runs modules_prepare + objtool, assembles a
  │           real /src/linux-<kver>/ + /lib/modules/<kver>/build around
  │           the Module.symvers passed in from kernel-headers. Does NOT
  │           compile the kernel (scripts/build-kernel-src.sh)
  │           │
  │           └─→ nvidia-builder    (Fedora, build environment only)
  │                 builds the out-of-tree kmod against the reconstructed
  │                 tree above with Fedora's own GCC/binutils (EXPERIMENT:
  │                 a from-source toolchain-builder stage used to supply
  │                 them — see "Compiler/linker version mismatch" below),
  │                 VERIFIES every built .ko against the kernel's own
  │                 struct module layout before packaging
  │                 (scripts/module-abi.py verify), runs nvidia-installer
  │                 --no-kernel-module, and packages the result via a
  │                 filesystem diff (scripts/build-nvidia.sh)
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

## Lock screen occasionally shows no password/fingerprint prompt

Confirmed on real hardware (2026-09-29, via `journalctl` across several
boots) as a two-part chain, only the first part of which this repo can
actually fix:

1. **GNOME Shell's own fingerprint-verify timeout races a cold
   `fprintd`.** `fprintd.service` is D-Bus-activated and, by default,
   exits after being idle for ~30-45s. GNOME Shell periodically
   re-arms fingerprint auth while the screen is locked (observed at an
   almost exact 15-minute cadence, all night, independent of whether
   anyone was actually present) — and since `fprintd` had reliably
   idle-exited between re-arms, every one of these is a *cold* start:
   the Goodix 538d sensor has to be reopened and re-handshake with its
   MCU before `fprintd` can answer. That consistently took longer than
   GNOME Shell's own client-side timeout, logging dozens of times per
   day:
   ```
   gnome-shell: Failed to start gdm-fingerprint verification for user:
   Gio.IOErrorEnum: O tempo limite foi alcançado
     async*begin@resource:///org/gnome/shell/gdm/authPrompt.js:1044:28
     _onReset@resource:///org/gnome/shell/ui/unlockDialog.js:965:26
   ```
2. **Each such D-Bus activation timeout appears to leak a system-bus
   connection slot for UID 0 (root).** Independently confirmed the
   same day: `uupd.service` (Universal Blue's own updater, unrelated
   to fingerprint hardware) crash-looped 84 times in one boot with the
   identical `"The maximum number of active connections for UID 0 has
   been reached (max_connections_per_user=256)"`, and `gdm-password`
   (the process that actually builds the lock screen's password entry)
   failed with the same `LimitsExceeded` error at the same timestamp as
   one of the fingerprint timeouts above. Once UID 0's 256-connection
   cap on the system bus is exhausted, *any* fresh root-owned process
   needing a new system-bus connection fails outright — which is what
   makes the screen occasionally come up with no password/fingerprint
   field at all, impossible to unlock without a hard reboot.

Part 2 is very likely a `dbus-broker`/systemd bug in the Dakota (GNOME
OS) base image itself — not this repo's code, and not fixed here.
Part 1, though, is one of that leak's most frequent and mechanically
regular triggers on this hardware (a clockwork timeout every 15
minutes, all day, regardless of activity), and *is* in scope: the
final stage now ships `files/fprintd-no-timeout.conf` as a
`fprintd.service.d` drop-in forcing `--no-timeout`, so the sensor
handshake stays warm and verification starts fast enough not to time
out in the first place. This should substantially reduce how often
the underlying leak gets fed, likely enough to avoid hitting the cap
in a normal day's uptime — but doesn't address the leak itself. See
["Known limitations"](#known-limitations) for the residual risk.

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

- **No stage compiles anything large any more (on this branch).**
  `kernel-src-builder` no longer compiles the kernel (see ["Deriving
  `Module.symvers` instead of compiling the
  kernel"](#deriving-modulesymvers-instead-of-compiling-the-kernel)), so
  the several-GB-RAM `vmlinux` link and the `pahole -J` pass over it are
  both gone. `CONFIG_DEBUG_INFO_BTF=y` still has to be preserved in the
  reconstructed `.config` — it changes `struct module`'s layout — but
  keeping the option no longer means paying for BTF generation, since
  nothing here links a `vmlinux` to generate it from. `pahole` is still
  installed for exactly one reason: so Kconfig doesn't drop the option.
- ~~**`kernel-src-builder` covers `vmlinux` + `ttm.ko` +
  `drm_ttm_helper.ko`'s exports, not every loadable module's.**~~ No
  longer a limitation: `Module.symvers` is now derived from the image's
  own `vmlinux` *and* every module it ships, so a future NVIDIA version
  needing a symbol from some other module needs no build target added.
- **NVIDIA's legacy 580.xxx driver may need patches for kernel 7.x.**
  The pin is `580.178.04`, the newest release in the 580 branch;
  `580.65.06` (the original pin) doesn't compile against kernel 7.x at
  all. `build-nvidia.sh` applies:
  - `KCFLAGS="-Wno-implicit-function-declaration -Wno-int-conversion
    -Wno-incompatible-pointer-types"` — GCC 14+ (the build stage)
    promotes these to hard errors unconditionally, not just via
    `-Werror`; delivered via `KCFLAGS` since kernel 7.2.6's top-level
    `Makefile` no longer reads `EXTRA_CFLAGS`. Kept even though
    `580.178.04` no longer trips the first two, since they only demote
    diagnostics and a later 580.x can reintroduce the pattern.
  - A `strncpy()` → `sized_strscpy()` compatibility shim,
    `#include`-injected into the files that call the old name
    (`strncpy()` was removed from the kernel's public string API on
    7.x). **Which files those are is derived at build time**, by
    grepping the extracted source — it used to be a hardcoded list of
    four and a documented chore on every version bump, and it shifts
    between releases: `580.173.02` had four such files, `580.178.04`
    has none at all, so on the current pin the shim is skipped
    entirely.

  What is still hardcoded, and therefore still worth a look when
  `NVIDIA_VERSION` changes, is the `nvidia-installer` flag list
  (`--advanced-options` output is not a stable interface across
  branches). All thirteen flags this repo passes were re-confirmed
  against `580.178.04`.
- **`CONFIG_RUST` is force-disabled** in the reconstructed tree
  (`scripts/config --disable RUST` before `olddefconfig`). Both
  variants ship `CONFIG_RUST=y` for unrelated in-tree Rust drivers;
  with it on, `make modules_prepare` requires a matching
  `rustc`/`bindgen` toolchain that Fedora's `kernel-src-builder`
  doesn't provide and NVIDIA's C-only module doesn't need. This
  doesn't change any C struct layout, calling convention, or the
  kernel release string (vermagic), and none of the affected symbols
  appears in an `#ifdef` inside `struct module`. The cascade is allowed in
  `build-kernel-src.sh`'s `allowed_deltas`, and reaches exactly one symbol
  whose name gives no hint of Rust: Dakota builds the *Rust* binder rather
  than the C one, so `CONFIG_ANDROID_BINDER_DEVICES` (which
  `depends on ANDROID_BINDER_IPC || ANDROID_BINDER_IPC_RUST`) loses its
  last satisfied dependency. Every other `.config` divergence still fails
  the build (see ["`struct module` layout must match the running
  kernel"](#struct-module-layout-must-match-the-running-kernel)). Note
  that Kconfig would drop `CONFIG_RUST` here by itself regardless, since
  `CONFIG_RUST_IS_AVAILABLE` is another tool probe
  (`scripts/rust_is_available.sh`) and this stage installs no `rustc` —
  the explicit `scripts/config --disable RUST` just makes the intent
  visible.
- **Compiler/linker version mismatch — being re-tested on this branch.**
  `nvidia.ko` is built here with Fedora's own GCC/binutils. A
  `toolchain-builder` stage used to build GCC 16.2.0 and binutils 2.47
  from upstream source, at the pins freedesktop-sdk uses for Dakota's own
  kernel, on the belief that Fedora's compiler was not good enough — the
  evidence being an `Invalid relocation target, existing value is
  nonzero` failure in `.gnu.linkonce.this_module` at `insmod` time,
  attributed to a micro-version of GCC drift.

  That attribution was wrong. The cause was a `struct module` layout
  mismatch from a silently dropped `.config` option — see ["`struct
  module` layout must match the running
  kernel"](#struct-module-layout-must-match-the-running-kernel) — now
  fixed, and guarded structurally by `scripts/module-abi.py`. Since the
  from-source toolchain was the slowest step in every CI run and rested
  on a superseded explanation, this branch removes it to find out whether
  it is needed.

  What is verifiably true either way is that **nothing in the build
  distinguishes the two compilers**:

  - NVIDIA's own `cc_sanity_check` (`kernel/conftest.sh`) parses only
    *major.minor* out of `include/generated/compile.h`'s
    `LINUX_COMPILER` and compares it to `__GNUC__`/`__GNUC_MINOR__`.
    Dakota's kernel GCC is 16.2.0 and Fedora 44's is 16.2.1 — both
    `16.2` — so it passes with or without the stage, and is blind to
    precisely the micro-version drift it was credited with catching.
  - The reconstructed tree's `CONFIG_CC_VERSION_TEXT` is *Fedora's*, not
    Dakota's (`"gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)"`), because
    `make olddefconfig` recomputes it from the compiler present in
    `kernel-src-builder`. Building with Fedora's gcc therefore makes the
    module and the tree it compiles against self-consistent for the
    first time; with `toolchain-builder` they never were.

  So the old claim that `build-nvidia.sh` omitting `IGNORE_CC_MISMATCH=1`
  "enforces the match" was never true. It is still omitted, since it
  costs nothing and would catch a major/minor jump.

  **What this branch cannot prove.** `scripts/module-abi.py` gates
  `struct module`'s *layout*, which is decided by the `.config` and
  headers — not by the compiler. It will pass either way, so it is not
  evidence about compiler compatibility. `RANDSTRUCT` and `LTO` are both
  off in the shipped config, which removes the two options most likely to
  make toolchain drift genuinely ABI-incompatible, and a module built by
  16.2.1 against a kernel built by 16.2.0 is very likely fine — but "very
  likely" is not proof. **Only `modprobe nvidia` on real hardware, plus
  some use under load, settles it.** That is the one test that has to
  happen before this is merged.

  **What the local test did show.** The whole `nvidia-builder` stage was
  run locally with Fedora's toolchain (GCC 16.2.1, GNU ld 2.46.1) against
  the reconstructed tree, and the five resulting modules were compared
  against the reference build made with the from-source toolchain
  (GCC 16.2.0, binutils 2.47):

  - All five compile and link, and pass `scripts/module-abi.py`.
  - **Section-name sets are identical** in all five.
  - **Undefined-symbol sets are identical** in all five, with one
    difference that is not the compiler's: the reference build's
    `nvidia-modeset.ko` and `nvidia-uvm.ko` also need `sized_strscpy`,
    because they were built when the `strncpy()` shim still had callers
    to patch. `580.178.04` has none, so the shim is skipped — exactly as
    intended.
  - **Zero unresolved external symbols** across all five, checked against
    the derived `Module.symvers` (the kernel's own exports plus every
    module the image ships) together with the NVIDIA set's own. So no
    `Unknown symbol in module` at `insmod` time either.

  In other words, at every level the build itself can observe, the module
  built with Fedora's toolchain is indistinguishable from the one built
  with the from-source toolchain. What remains unobserved is codegen, and
  no static comparison settles that.

  Note also that the **linker** drifts further than the compiler does:
  Fedora 44 ships GNU ld 2.46.1 where Dakota's kernel was built with a
  2.47 snapshot. Since the module's final link (`ld -r`) is what emits
  `.gnu.linkonce.this_module` and its relocations, that is the more
  plausible half of any residual risk here — a point in favour of
  actually testing rather than reasoning about it.

  If it turns out to be needed, `scripts/build-toolchain.sh` is still in
  the tree on `main`, with pins `elements/bootstrap/gcc.bst` → tag
  `releases/gcc-16.2.0` and `elements/bootstrap/binutils.bst` → tag
  `binutils-2_47`, commit `6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32`.
  Those need re-deriving whenever a base-image bump changes the kernel's
  own toolchain: `CONFIG_CC_VERSION_TEXT` in the shipped `.config` for
  the GCC version, `/proc/version` on the real machine for binutils.
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
- **System-bus D-Bus connection leak on activation timeout (not this
  repo's bug, not fixed here)** — see ["Lock screen occasionally shows
  no password/fingerprint prompt"](#lock-screen-occasionally-shows-no-passwordfingerprint-prompt).
  `files/fprintd-no-timeout.conf` removes fingerprint re-arm as one
  trigger, but any other D-Bus service-activation timeout (observed
  independently from `NetworkManager`'s dispatcher and
  `org.freedesktop.Flatpak.SystemHelper`) can still feed the same leak
  given enough uptime. If the lock screen (or anything else needing a
  fresh root D-Bus connection, e.g. `uupd.service`) still fails this
  way, `busctl list --system | wc -l` climbing well past normal and
  `journalctl` showing `"maximum number of active connections for
  UID 0"` confirms it — the only known full recovery once hit is a
  reboot.
- **`nvidia-installer` flags** — they change between branches, so
  they are re-validated against `--help`/`--advanced-options` on every
  `NVIDIA_VERSION` change. All thirteen currently passed were confirmed
  present in `580.178.04`.
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
  on a weekly schedule (Mondays 04:17 UTC), and via
  `workflow_dispatch`. Each
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

  **Why weekly and not daily.** The schedule used to be daily, to cover a
  Renovate base-digest bump that got merged without anyone triggering a
  rebuild. It never needed to: `renovate.json5` sets no automerge, so
  those PRs are merged by hand, and merging one *is* a push to `main`,
  which triggers this workflow — and the PR itself is built beforehand via
  `pull_request`, so a new kernel is validated before it lands. The daily
  run was therefore rebuilding everything from scratch, including a
  from-source GCC, to produce an equivalent image six days out of seven.

  What the periodic run is actually worth keeping for is drift in what
  this repo does *not* pin: the builder stages' `dnf install` lines take
  whatever Fedora currently ships, and `LIBFPRINT_REF`/`PAM_U2F_REF` are
  git tags that Renovate isn't configured to track (no `# renovate:`
  datasource annotations, and its rules here cover only the two base
  images). A weekly build surfaces breakage from those on its own
  schedule rather than in the middle of an unrelated change. It runs
  **Mondays** so that `promote-stable.yml`'s premise survives: that
  workflow promotes whatever `:latest` is every Sunday at 06:00 UTC, and
  its whole point is letting a build soak on `:latest` first — a Sunday
  build would be promoted about 100 minutes later, a Monday one gets
  nearly a week.
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
- **NVIDIA driver releases —
  `.github/workflows/nvidia-driver-update.yml`.** Polls
  [NVIDIA's Unix driver index](https://download.nvidia.com/XFree86/Linux-x86_64/)
  daily (and on `workflow_dispatch`), and opens a PR bumping
  `ARG NVIDIA_VERSION` when a newer release appears **in the branch
  currently pinned**. It reads both the pinned version and — from its
  major — the branch to track straight out of the `Containerfile`, so
  it has no pin of its own to drift. Deliberate behaviors:
  - **It never proposes a branch change.** NVIDIA publishes newer
    branches (590/595/610/615 at the time of writing) which still list
    this repo's target Pascal GPUs as current, but moving to one would
    make the `580` in the repo and image names wrong and require
    re-deriving the kernel-7.x workarounds. A newer branch is mentioned
    in the PR body and the run summary, and left as a manual decision.
  - **It won't downgrade**, and it won't propose a release whose
    `x86_64` installer isn't downloadable yet (a release directory can
    show up before the file `build-nvidia.sh` fetches is in it, and
    that PR would just burn a CI run on a 404).
  - **It won't nag.** A version already proposed — whether that PR was
    merged or closed — is never proposed again.
  - **A parse of zero versions is a hard failure**, not a quiet "no
    news": the index's link format has changed before (double to single
    quotes), and a silently broken parser looks exactly like NVIDIA
    never releasing anything again.
  - **`build.yml` runs on the PR**, which is the point — the kmod gets
    compiled against both Dakota kernels, including
    `scripts/module-abi.py`'s loadability gate, before anything merges.
    For that to happen automatically the PR must be created by a real
    token: GitHub deliberately does not trigger workflows from PRs made
    with the default `GITHUB_TOKEN`. Add a `NVIDIA_WATCH_PR_TOKEN`
    repository secret (a fine-grained PAT with `contents: write` and
    `pull-requests: write` on this repo) and the workflow uses it; with
    no such secret the PR still opens and says in its body to
    close/reopen it to start CI.
- `renovate.json5` tracks both base-image digests — `BASE_IMAGE`
  (`ghcr.io/projectbluefin/dakota:stable`) and `BASE_IMAGE_GAMING`
  (`ghcr.io/projectbluefin/dakota-gaming:stable`) — pinned in the
  `Containerfile`, and opens a **separate** PR per variant when either
  changes upstream — **every bump is a reviewable PR**, not a silent
  rebuild, because a new base image can ship a new kernel and break
  the kmod until you confirm the build still passes. The two are kept
  separate because the gaming (OGC) kernel stream updates
  independently of, and sometimes lags, the standard one. Renovate
  handles the base images only; the NVIDIA driver has no Renovate
  datasource, which is what the watcher above is for.
