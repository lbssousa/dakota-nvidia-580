#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Structural gate against the one class of build bug that produces a
# module which compiles cleanly, passes the kernel's vermagic check,
# and *still* can't be loaded: a `struct module` layout mismatch.
#
# Background. Every .ko carries its own `struct module` instance, emitted
# by modpost into <mod>.mod.c as `__this_module` and linked into a
# dedicated `.gnu.linkonce.this_module` section. Its `init`/`exit`
# function pointers aren't filled in at compile time; the module ships
# R_X86_64_64 relocations against `init_module`/`cleanup_module` in
# `.rela.gnu.linkonce.this_module`, and the kernel's module loader
# writes the resolved addresses into those two slots at load time.
#
# The offsets of those slots are decided by whatever `struct module`
# looked like in the build tree's include/linux/module.h -- which is
# riddled with `#ifdef CONFIG_*` blocks. Build against a tree whose
# .config differs from the running kernel's in any of them and the
# relocation offsets no longer name the fields the running kernel has
# there. Nothing in the normal build catches it:
#
#   - vermagic encodes only version/SMP/preempt/module-unload/
#     modversions, so the version check happily passes.
#   - CRCs (CONFIG_MODVERSIONS) are unset on Dakota, and wouldn't cover
#     struct module's own layout anyway.
#   - the compiler and linker see nothing wrong; the module is
#     internally consistent, just consistent with the wrong kernel.
#
# What happens instead is that load_module() calls module_unload_init()
# -- which does INIT_LIST_HEAD(&mod->source_list) -- *before*
# apply_relocations(). So by relocation time some of struct module is
# already populated, and x86's __write_relocate_add()
# (arch/x86/kernel/module.c) requires every relocation target to still
# be zero. A shifted `exit` offset that lands inside source_list
# therefore fails with:
#
#   module: x86/modules: Invalid relocation target, existing value is
#   nonzero for sec N, idx 1, type 1, loc ..., val ...
#
# and the module load returns -ENOEXEC. That is exactly what this repo
# shipped when the kernel-src-builder stage had no pahole installed:
# `make olddefconfig` silently dropped CONFIG_DEBUG_INFO_BTF (it
# `depends on PAHOLE_VERSION >= 122`) and with it
# CONFIG_DEBUG_INFO_BTF_MODULES, whose 24 bytes of btf_data_size/
# btf_base_data_size/btf_data/btf_base_data sit between `init` and
# `exit` -- moving `exit` from 0x4b0 to 0x498, i.e. onto
# source_list.prev.
#
# scripts/build-kernel-src.sh's post-olddefconfig guard catches the
# *cause* (a shipped option silently flipping). This script catches the
# *effect*, independently of what caused it: it reads the authoritative
# `struct module` layout out of the Dakota base image's own
# /usr/lib/modules/<kver>/vmlinux .BTF section -- the running kernel's
# ground truth, not a reconstruction -- and asserts that every built
# .ko agrees with it. Any future divergence, from a missing tool, a
# .config change, a kernel bump or a header patch, fails the build
# instead of the boot.
#
# Deliberately dependency-free: stdlib only, its own minimal ELF and
# BTF readers. Depending on bpftool/pahole output here would repeat the
# original mistake -- gating a correctness check on a tool that may
# simply not be installed.
#
# Usage:
#   module-abi.py extract <kver> <vmlinux> <out.json>
#       Writes the kernel's struct module layout as JSON. Exits 0 with
#       {"available": false, ...} when the image ships no usable
#       vmlinux/.BTF, leaving the decision to `verify`.
#   module-abi.py verify <layout.json> <module.ko>...
#       Exits non-zero on any mismatch. Set
#       ALLOW_UNVERIFIED_MODULE_ABI=1 to downgrade an *unavailable*
#       layout (never a real mismatch) to a warning.
# ---------------------------------------------------------------------
"""Verify a built .ko's struct module layout against the kernel's BTF."""

import json
import os
import struct
import sys

# The ELF reader lives in kernel_elf.py, shared with
# gen-module-symvers.py, which reads the same two kinds of file.
from kernel_elf import Elf  # noqa: E402  (kept beside the other imports)


# ---------------------------------------------------------------------
# Minimal BTF reader (see include/uapi/linux/btf.h)
# ---------------------------------------------------------------------

BTF_MAGIC = 0xEB9F
BTF_KIND_STRUCT = 4

# Bytes of kind-specific data trailing each struct btf_type, by kind.
# vlen is the type's member/parameter count.
_BTF_EXTRA = {
    0: lambda vlen: 0,           # UNKN
    1: lambda vlen: 4,           # INT
    2: lambda vlen: 0,           # PTR
    3: lambda vlen: 12,          # ARRAY
    4: lambda vlen: 12 * vlen,   # STRUCT
    5: lambda vlen: 12 * vlen,   # UNION
    6: lambda vlen: 8 * vlen,    # ENUM
    7: lambda vlen: 0,           # FWD
    8: lambda vlen: 0,           # TYPEDEF
    9: lambda vlen: 0,           # VOLATILE
    10: lambda vlen: 0,          # CONST
    11: lambda vlen: 0,          # RESTRICT
    12: lambda vlen: 0,          # FUNC
    13: lambda vlen: 8 * vlen,   # FUNC_PROTO
    14: lambda vlen: 4,          # VAR
    15: lambda vlen: 12 * vlen,  # DATASEC
    16: lambda vlen: 0,          # FLOAT
    17: lambda vlen: 4,          # DECL_TAG
    18: lambda vlen: 0,          # TYPE_TAG
    19: lambda vlen: 12 * vlen,  # ENUM64
}


def btf_find_struct(blob, wanted):
    """Find struct `wanted` in a raw BTF blob -> (size, {member: bit_off})."""
    (magic, _version, _flags, hdr_len, type_off, type_len,
     str_off, str_len) = struct.unpack_from("<HBBIIIII", blob, 0)
    if magic != BTF_MAGIC:
        raise ValueError(f"bad BTF magic 0x{magic:x}")
    types = blob[hdr_len + type_off:hdr_len + type_off + type_len]
    strs = blob[hdr_len + str_off:hdr_len + str_off + str_len]

    def name_at(off):
        end = strs.find(b"\0", off)
        return strs[off:end].decode("utf-8", "replace")

    pos = 0
    while pos + 12 <= len(types):
        name_off, info, size_or_type = struct.unpack_from("<III", types, pos)
        kind = (info >> 24) & 0x1F
        vlen = info & 0xFFFF
        kind_flag = (info >> 31) & 1
        extra = _BTF_EXTRA.get(kind)
        if extra is None:
            raise ValueError(f"unknown BTF kind {kind}; BTF format has grown "
                             f"and this reader needs updating")
        if kind == BTF_KIND_STRUCT and name_at(name_off) == wanted:
            members = {}
            mpos = pos + 12
            for _ in range(vlen):
                m_name_off, _m_type, m_off = struct.unpack_from(
                    "<III", types, mpos)
                # With kind_flag set, `offset` packs bitfield_size in its
                # high 8 bits and the bit offset in the low 24.
                bit_off = (m_off & 0xFFFFFF) if kind_flag else m_off
                members[name_at(m_name_off)] = bit_off
                mpos += 12
            return size_or_type, members
        pos += 12 + extra(vlen)
    return None


# ---------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------

# The two struct module fields a .ko actually relocates against, and the
# modpost-generated symbols whose addresses land in them.
RELOC_FIELDS = {"init_module": "init", "cleanup_module": "exit"}

R_X86_64_64 = 1
THIS_MODULE_SECTION = ".gnu.linkonce.this_module"


def unavailable(out_path, kver, reason):
    with open(out_path, "w") as fh:
        json.dump({"available": False, "kver": kver, "reason": reason}, fh,
                  indent=2)
        fh.write("\n")
    print(f"WARNING: struct module layout not extracted: {reason}",
          file=sys.stderr)
    print(f"'{sys.argv[0]} verify' will refuse to pass the build unless "
          f"ALLOW_UNVERIFIED_MODULE_ABI=1 is set.", file=sys.stderr)
    return 0


def cmd_extract(kver, vmlinux, out_path):
    if not os.path.isfile(vmlinux):
        return unavailable(out_path, kver, f"{vmlinux} does not exist")
    elf = Elf(vmlinux)
    try:
        sec = elf.find(".BTF")
        if sec is None:
            return unavailable(
                out_path, kver,
                f"{vmlinux} has no .BTF section (CONFIG_DEBUG_INFO_BTF "
                f"is presumably unset in this image's kernel)")
        found = btf_find_struct(elf.raw(sec), "module")
    finally:
        elf.close()

    if found is None:
        return unavailable(out_path, kver,
                           f"no 'struct module' type in {vmlinux}'s BTF")
    size, bit_members = found

    members = {}
    for name, bit_off in bit_members.items():
        if bit_off % 8:
            # A bitfield member. None of the fields we relocate against is
            # one; record it as-is rather than lying about a byte offset.
            members[name] = {"bit_offset": bit_off}
        else:
            members[name] = bit_off // 8

    layout = {
        "available": True,
        "kver": kver,
        "source": vmlinux,
        "struct_module": {"size": size, "members": members},
    }
    with open(out_path, "w") as fh:
        json.dump(layout, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(f"==> struct module from {vmlinux} (.BTF): "
          f"sizeof = {size} (0x{size:x}) bytes, {len(members)} members")
    for sym, field in sorted(RELOC_FIELDS.items()):
        off = members.get(field)
        if isinstance(off, int):
            print(f"      .{field:<6} at offset {off} (0x{off:x})"
                  f"  <- relocated against {sym}()")
        else:
            print(f"      .{field:<6} ABSENT from this kernel's struct module")
    print(f"==> wrote {out_path}")
    return 0


# ---------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------

def ko_this_module_layout(path):
    """-> (sizeof, {symbol_name: (reloc_offset, reloc_type)}) for one .ko."""
    elf = Elf(path)
    try:
        tm = elf.find(THIS_MODULE_SECTION)
        if tm is None:
            raise ValueError(
                f"{path}: no {THIS_MODULE_SECTION} section -- this doesn't "
                f"look like a modpost-processed kernel module")
        rela = elf.find(".rela" + THIS_MODULE_SECTION)
        if rela is None:
            return tm.size, {}
        names = elf.symbol_names(elf.sections[rela.link])
        relocs = {}
        raw = elf.raw(rela)
        for off in range(0, len(raw), 24):
            r_offset, r_info, _addend = struct.unpack_from("<QQq", raw, off)
            relocs[names[r_info >> 32]] = (r_offset, r_info & 0xFFFFFFFF)
        return tm.size, relocs
    finally:
        elf.close()


def cmd_verify(layout_path, ko_paths):
    with open(layout_path) as fh:
        layout = json.load(fh)

    if not layout.get("available"):
        reason = layout.get("reason", "unknown reason")
        if os.environ.get("ALLOW_UNVERIFIED_MODULE_ABI") == "1":
            print(f"WARNING: skipping struct module ABI verification: "
                  f"{reason}", file=sys.stderr)
            print("WARNING: ALLOW_UNVERIFIED_MODULE_ABI=1 is set, so the "
                  "build continues. The resulting modules may fail to load "
                  "with '-ENOEXEC / Invalid relocation target'.",
                  file=sys.stderr)
            return 0
        print(f"ERROR: can't verify the built modules' struct module layout: "
              f"{reason}", file=sys.stderr)
        print("", file=sys.stderr)
        print("This check reads the authoritative layout from the Dakota base "
              "image's own", file=sys.stderr)
        print("/usr/lib/modules/<kver>/vmlinux .BTF section. If that image "
              "genuinely no", file=sys.stderr)
        print("longer ships it, either find another source of ground truth or "
              "re-run with", file=sys.stderr)
        print("ALLOW_UNVERIFIED_MODULE_ABI=1 -- knowing that a silent "
              "struct module", file=sys.stderr)
        print("mismatch then becomes an unloadable module instead of a build "
              "failure.", file=sys.stderr)
        return 1

    sm = layout["struct_module"]
    want_size = sm["size"]
    members = sm["members"]
    kver = layout.get("kver", "?")
    problems = []

    print(f"==> Verifying struct module layout of {len(ko_paths)} module(s) "
          f"against kernel {kver}'s own BTF")
    for ko in sorted(ko_paths):
        base = os.path.basename(ko)
        got_size, relocs = ko_this_module_layout(ko)
        mine = []
        if got_size != want_size:
            mine.append(
                f"{base}: sizeof(struct module) is {got_size} "
                f"(0x{got_size:x}) bytes, kernel {kver}'s is {want_size} "
                f"(0x{want_size:x})")
        checked = []
        for sym, (got_off, rtype) in sorted(relocs.items()):
            field = RELOC_FIELDS.get(sym)
            if field is None:
                mine.append(
                    f"{base}: unexpected relocation against '{sym}' in "
                    f"{THIS_MODULE_SECTION}; this check only knows "
                    f"{sorted(RELOC_FIELDS)} and must be taught the new one "
                    f"rather than ignore it")
                continue
            if rtype != R_X86_64_64:
                mine.append(
                    f"{base}: relocation against '{sym}' has type {rtype}, "
                    f"expected R_X86_64_64 ({R_X86_64_64})")
            want_off = members.get(field)
            if not isinstance(want_off, int):
                mine.append(
                    f"{base}: relocates against '{sym}', but kernel {kver}'s "
                    f"struct module has no usable '{field}' field")
                continue
            if got_off != want_off:
                mine.append(
                    f"{base}: '{sym}' relocation targets offset {got_off} "
                    f"(0x{got_off:x}) but kernel {kver} keeps .{field} at "
                    f"{want_off} (0x{want_off:x}) -- off by "
                    f"{got_off - want_off:+d} bytes")
            else:
                checked.append(f".{field}@0x{got_off:x}")
        detail = " ".join(checked) if checked else "(no init/exit relocs)"
        print(f"    {'FAIL' if mine else '  OK'}  {base:<20} "
              f"sizeof=0x{got_size:x} {detail}")
        problems.extend(mine)

    if problems:
        sys.stdout.flush()
        print("", file=sys.stderr)
        print("ERROR: struct module layout mismatch -- these modules would "
              "compile and pass", file=sys.stderr)
        print("the kernel's vermagic check, then fail to load at boot.",
              file=sys.stderr)
        print("", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("", file=sys.stderr)
        print("The build tree the modules were compiled against has a "
              ".config that differs", file=sys.stderr)
        print("from the running kernel's in at least one of struct module's "
              "#ifdef CONFIG_*", file=sys.stderr)
        print("blocks (include/linux/module.h). Compare the reconciled "
              ".config that", file=sys.stderr)
        print("scripts/build-kernel-src.sh produced against the shipped one "
              "-- its own", file=sys.stderr)
        print("post-olddefconfig guard prints that diff -- and make sure "
              "every build tool", file=sys.stderr)
        print("Kconfig probes for is installed in the Containerfile's "
              "kernel-src-builder", file=sys.stderr)
        print("stage (pahole/dwarves for CONFIG_DEBUG_INFO_BTF, for "
              "instance).", file=sys.stderr)
        return 1

    print(f"==> All {len(ko_paths)} module(s) agree with kernel {kver}'s "
          f"struct module layout.")
    return 0


def main(argv):
    if len(argv) >= 5 and argv[1] == "extract":
        return cmd_extract(argv[2], argv[3], argv[4])
    if len(argv) >= 4 and argv[1] == "verify":
        return cmd_verify(argv[2], argv[3:])
    print(__doc__.strip(), file=sys.stderr)
    print("", file=sys.stderr)
    print(f"usage: {argv[0]} extract <kver> <vmlinux> <out.json>",
          file=sys.stderr)
    print(f"       {argv[0]} verify <layout.json> <module.ko>...",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
