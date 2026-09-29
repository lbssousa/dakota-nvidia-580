#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Reconstructs Module.symvers for an out-of-tree module build straight
# from the binaries a Dakota image already ships, instead of compiling
# the kernel to produce one.
#
# Why this exists. An external module build needs Module.symvers for two
# things: modpost resolves the module's undefined symbols against it (and
# derives the .ko's `depends=` from it), and NVIDIA's conftest.sh greps it
# to decide which kernel-version-specific code path to compile -- an
# empty or missing file silently steers it toward APIs long removed from
# modern kernels. The published Dakota image ships no Module.symvers, so
# scripts/build-kernel-src.sh used to obtain one the only obvious way:
# `make vmlinux`, i.e. compile the entire kernel. That is the single most
# expensive step in this repo after building GCC -- a full kernel build, a
# final link needing several GB of RAM in one non-parallel step, and,
# since CONFIG_DEBUG_INFO_BTF=y has to stay on for ABI reasons, a `pahole
# -J` pass over a fully DWARF-annotated vmlinux. Plus two scoped module
# builds (ttm.ko, drm_ttm_helper.ko) for exports `make vmlinux` leaves out.
#
# None of that work is necessary, because the exports are already present,
# fully resolved, in the image:
#
#   /usr/lib/modules/<kver>/vmlinux           -> everything built into the
#                                                kernel exports
#   /usr/lib/modules/<kver>/kernel/**/*.ko    -> every loadable module's
#                                                exports, including the DRM
#                                                ones this repo used to
#                                                compile by hand
#
# The result is also strictly more complete than what `make vmlinux` plus
# two hand-picked modules produced: every module in the image contributes,
# so a future NVIDIA release needing a symbol from some other module works
# without anyone having to find and add its build target.
#
# How the exports are stored (include/linux/export-internal.h). Each one
# contributes:
#
#   __ksymtab          struct kernel_symbol -- three PREL32 refs, in order
#                      value, name, namespace, each relative to the address
#                      of its own field (".long sym - .")
#   __kflagstab        one byte per symbol, same order
#   __ksymtab_strings  the name, then the namespace ("" when none)
#
# The byte in __kflagstab comes from modpost's get_symbol_flags(), which
# returns `sym->is_gpl_only ? KSYM_FLAG_GPL_ONLY : 0` -- GPL-only is the
# only flag it ever sets, so a non-zero byte means EXPORT_SYMBOL_GPL
# whatever that bit's numeric value happens to be.
#
# vmlinux and .ko need different readers. In vmlinux the PREL32 refs are
# resolved, so the targets are plain address arithmetic. A .ko is
# relocatable: those words are zero with relocations against them, so
# instead the per-export labels modpost emits -- __ksymtab_<name>,
# __flags_<name>, __kstrtabns_<name> -- are read out of the module's own
# symbol table, which gives the same three pieces without resolving a
# single relocation.
#
# Output format is modpost's write_dump() verbatim:
#   "0x%08x\t%s\t%s\tEXPORT_SYMBOL%s\t%s\n"
#   crc, symbol, module, "_GPL" if gpl-only, namespace
# The module field is literally "vmlinux" for built-in exports -- modpost
# keys `is_vmlinux` off that exact string, and getting it wrong would give
# every built module a bogus `depends=` entry. For a real module it is the
# path under the modules directory with ".ko" removed, which is the form a
# genuine Module.symvers carries and whose basename modpost uses for
# `depends=`.
#
# Usage: gen-module-symvers.py <modules-dir> <out-file>
#   <modules-dir>  /usr/lib/modules/<kver> of the target image
# ---------------------------------------------------------------------
"""Derive Module.symvers from a Dakota image's own vmlinux and modules."""

import os
import struct
import sys

from kernel_elf import Elf

KSYMTAB = "__ksymtab"
KFLAGSTAB = "__kflagstab"
KSTRINGS = "__ksymtab_strings"
KCRCTAB = "__kcrctab"

# struct kernel_symbol: value_offset, name_offset, namespace_offset
KSYM_ENTSIZE = 12


class Unsupported(Exception):
    pass


def _reject_modversions(elf):
    """CONFIG_MODVERSIONS=y would need real CRCs, which aren't derivable."""
    if elf.find(KCRCTAB) is not None:
        raise Unsupported(
            f"{elf.path} has a {KCRCTAB} section, so this kernel was built "
            f"with CONFIG_MODVERSIONS=y. A derived Module.symvers would carry "
            f"zero CRCs and every module built against it would be rejected at "
            f"load time. Teach this script to read {KCRCTAB} before using it on "
            f"such a kernel -- do not just let the zeros through.")


def exports_from_vmlinux(path):
    """-> [(name, gpl_only, namespace)] for everything built into the kernel."""
    with Elf(path) as elf:
        _reject_modversions(elf)
        ksym = elf.find(KSYMTAB)
        strs = elf.find(KSTRINGS)
        flags_sec = elf.find(KFLAGSTAB)
        if ksym is None or strs is None:
            raise Unsupported(
                f"{path} has no {KSYMTAB}/{KSTRINGS} section; it does not look "
                f"like a linked kernel image.")
        if ksym.size % KSYM_ENTSIZE:
            raise Unsupported(
                f"{path}: {KSYMTAB} is {ksym.size} bytes, not a multiple of "
                f"{KSYM_ENTSIZE} -- struct kernel_symbol has changed shape and "
                f"this reader needs updating.")
        count = ksym.size // KSYM_ENTSIZE
        flags = elf.raw(flags_sec) if flags_sec is not None else b""
        if flags and len(flags) != count:
            raise Unsupported(
                f"{path}: {KFLAGSTAB} holds {len(flags)} bytes for {count} "
                f"exports; the one-byte-per-symbol assumption no longer holds.")

        data = elf.raw(ksym)
        sdata = elf.raw(strs)

        def cstr(addr):
            off = addr - strs.addr
            if not 0 <= off < len(sdata):
                return None
            end = sdata.find(b"\0", off)
            return sdata[off:end].decode("utf-8", "replace") if end >= 0 else None

        out = []
        for i in range(count):
            _value, name_off, ns_off = struct.unpack_from("<iii", data,
                                                          i * KSYM_ENTSIZE)
            base = ksym.addr + i * KSYM_ENTSIZE
            name = cstr(base + 4 + name_off)
            ns = cstr(base + 8 + ns_off)
            if not name:
                raise Unsupported(
                    f"{path}: export #{i}'s name does not resolve into "
                    f"{KSTRINGS}; the PREL32 layout is not what this reader "
                    f"assumes.")
            out.append((name, bool(flags[i]) if flags else False, ns or ""))
        return out


def exports_from_module(path):
    """-> [(name, gpl_only, namespace)] for one relocatable .ko."""
    with Elf(path) as elf:
        _reject_modversions(elf)
        ksym = elf.find(KSYMTAB)
        if ksym is None or ksym.size == 0:
            return []
        symtab = elf.find(".symtab")
        if symtab is None:
            raise Unsupported(
                f"{path} exports symbols but has no .symtab, so the "
                f"__ksymtab_<name> labels this reader needs are gone. It was "
                f"probably stripped.")
        strs = elf.find(KSTRINGS)
        flags_sec = elf.find(KFLAGSTAB)
        flags = elf.raw(flags_sec) if flags_sec is not None else b""

        # Each label is only trusted when it actually lives in the section it
        # is supposed to index -- st_value is an offset into that section, so
        # an identically named symbol somewhere else would silently read the
        # wrong byte.
        ksym_idx = ksym.index
        strs_idx = strs.index if strs is not None else -1
        flags_idx = flags_sec.index if flags_sec is not None else -1

        names, ns_at, flag_at = [], {}, {}
        for sym in elf.symbols(symtab):
            if sym.name.startswith("__ksymtab_") and sym.shndx == ksym_idx:
                names.append(sym.name[len("__ksymtab_"):])
            elif sym.name.startswith("__kstrtabns_") and sym.shndx == strs_idx:
                ns_at[sym.name[len("__kstrtabns_"):]] = sym.value
            elif sym.name.startswith("__flags_") and sym.shndx == flags_idx:
                flag_at[sym.name[len("__flags_"):]] = sym.value

        expected = ksym.size // KSYM_ENTSIZE
        if len(names) != expected:
            raise Unsupported(
                f"{path}: found {len(names)} __ksymtab_* labels but {KSYMTAB} "
                f"holds {expected} entries; the two must agree.")

        out = []
        for name in names:
            gpl = False
            off = flag_at.get(name)
            if off is not None and off < len(flags):
                gpl = bool(flags[off])
            ns = ""
            off = ns_at.get(name)
            if off is not None and strs is not None:
                ns = elf.cstr_at(strs, off) or ""
            out.append((name, gpl, ns))
        return out


def module_name_for(ko_path, kernel_dir):
    """Path under the modules tree, minus .ko -- what modpost writes."""
    rel = os.path.relpath(ko_path, kernel_dir)
    for suffix in (".ko.xz", ".ko.zst", ".ko.gz", ".ko"):
        if rel.endswith(suffix):
            return rel[:-len(suffix)]
    return rel


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <modules-dir> <out-file>", file=sys.stderr)
        return 2
    modules_dir, out_path = argv[1], argv[2]
    vmlinux = os.path.join(modules_dir, "vmlinux")
    # Only kernel/ is walked, never extra/: that is where this repo installs
    # its own NVIDIA modules, and letting a previous build's output feed the
    # next build's symbol list would be both circular and stale.
    kernel_dir = os.path.join(modules_dir, "kernel")

    if not os.path.isfile(vmlinux):
        print(f"ERROR: {vmlinux} does not exist, so the kernel's own exports "
              f"can't be read.", file=sys.stderr)
        print("This image cannot be used without falling back to building "
              "vmlinux from source.", file=sys.stderr)
        return 1
    if not os.path.isdir(kernel_dir):
        print(f"ERROR: {kernel_dir} does not exist.", file=sys.stderr)
        return 1

    lines = []
    compressed = []

    def emit(entries, modname):
        for name, gpl, ns in entries:
            lines.append("0x00000000\t{}\t{}\tEXPORT_SYMBOL{}\t{}\n".format(
                name, modname, "_GPL" if gpl else "", ns))

    try:
        builtin = exports_from_vmlinux(vmlinux)
        emit(builtin, "vmlinux")

        ko_paths = []
        for root, _dirs, files in os.walk(kernel_dir):
            for fn in files:
                if fn.endswith(".ko"):
                    ko_paths.append(os.path.join(root, fn))
                elif ".ko." in fn:
                    compressed.append(os.path.join(root, fn))
        ko_paths.sort()

        mod_total = 0
        for ko in ko_paths:
            entries = exports_from_module(ko)
            mod_total += len(entries)
            emit(entries, module_name_for(ko, kernel_dir))
    except Unsupported as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    if compressed:
        # depmod handles .ko.xz/.zst transparently; this reader does not, and
        # silently skipping them would produce a Module.symvers missing
        # exports, which is the failure mode that makes NVIDIA's conftest.sh
        # pick the wrong API. Fail instead.
        print(f"ERROR: {len(compressed)} compressed module(s) found, e.g. "
              f"{compressed[0]}.", file=sys.stderr)
        print("This script reads uncompressed .ko only; their exports would "
              "be silently missing.", file=sys.stderr)
        return 1

    with open(out_path, "w") as fh:
        fh.writelines(lines)

    gpl = sum(1 for line in lines if "EXPORT_SYMBOL_GPL" in line)
    print(f"==> Module.symvers derived from {modules_dir}")
    print(f"      {len(builtin):6} exports from vmlinux")
    print(f"      {mod_total:6} exports from {len(ko_paths)} shipped modules")
    print(f"      {len(lines):6} total ({gpl} GPL-only, "
          f"{len(lines) - gpl} plain)")
    print(f"==> wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
