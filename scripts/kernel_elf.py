# ---------------------------------------------------------------------
# Minimal little-endian ELF64 reader, shared by scripts/module-abi.py and
# scripts/gen-module-symvers.py.
#
# Deliberately stdlib-only. Both callers exist to check or reconstruct
# something the build would otherwise get silently wrong, and gating that
# on a tool (bpftool, pahole, binutils) being installed in the right
# stage is exactly the class of mistake that produced the unloadable
# nvidia.ko this repo shipped once. See README.md, "struct module layout
# must match the running kernel".
# ---------------------------------------------------------------------
"""Just enough ELF64 to read sections and symbols out of vmlinux and .ko."""

import struct

SHT_NOBITS = 8


class Section:
    __slots__ = ("index", "name", "_name_off", "type", "flags", "addr",
                 "offset", "size", "link", "info", "entsize")


class Sym:
    __slots__ = ("name", "info", "shndx", "value", "size")


class Elf:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        ident = self.f.read(16)
        if ident[:4] != b"\x7fELF":
            raise ValueError(f"{path}: not an ELF file")
        if ident[4] != 2 or ident[5] != 1:
            raise ValueError(f"{path}: only little-endian ELF64 is supported")
        self.f.seek(16)
        (self.e_type, _machine, _version, _entry, _phoff, shoff, _flags,
         _ehsize, _phentsize, _phnum, shentsize, e_shnum,
         e_shstrndx) = struct.unpack("<HHIQQQIHHHHHH", self.f.read(48))

        # A section count/name-index of 0/SHN_XINDEX means the real values
        # live in section header 0 (ELF's escape hatch for >= 0xff00
        # sections). vmlinux stays well under that, but honouring it costs
        # three lines and avoids a mystifying failure if that ever changes.
        first = self._read_shdr(shoff, shentsize, 0)
        if e_shnum == 0:
            e_shnum = first.size
        if e_shstrndx == 0xFFFF:
            e_shstrndx = first.link

        self.sections = [self._read_shdr(shoff, shentsize, i)
                         for i in range(e_shnum)]
        shstrtab = self.raw(self.sections[e_shstrndx])
        for sec in self.sections:
            end = shstrtab.find(b"\0", sec._name_off)
            sec.name = shstrtab[sec._name_off:end].decode("utf-8", "replace")

    def _read_shdr(self, shoff, shentsize, i):
        self.f.seek(shoff + i * shentsize)
        (name_off, sh_type, flags, addr, offset, size, link, info,
         _align, entsize) = struct.unpack("<IIQQQQIIQQ", self.f.read(64))
        sec = Section()
        sec.index, sec._name_off, sec.name = i, name_off, ""
        sec.type, sec.flags, sec.addr = sh_type, flags, addr
        sec.offset, sec.size = offset, size
        sec.link, sec.info, sec.entsize = link, info, entsize
        return sec

    def raw(self, sec):
        if sec is None or sec.type == SHT_NOBITS or sec.size == 0:
            return b""
        self.f.seek(sec.offset)
        return self.f.read(sec.size)

    def find(self, name):
        for sec in self.sections:
            if sec.name == name:
                return sec
        return None

    def _strtab_of(self, symtab):
        return self.raw(self.sections[symtab.link])

    def symbols(self, symtab):
        """Full Elf64_Sym records of `symtab`, in table order."""
        data = self.raw(symtab)
        strtab = self._strtab_of(symtab)
        out = []
        for off in range(0, len(data), 24):
            (name_off, info, _other, shndx, value,
             size) = struct.unpack_from("<IBBHQQ", data, off)
            end = strtab.find(b"\0", name_off)
            s = Sym()
            s.name = strtab[name_off:end].decode("utf-8", "replace")
            s.info, s.shndx, s.value, s.size = info, shndx, value, size
            out.append(s)
        return out

    def symbol_names(self, symtab):
        """Symbol names of `symtab`, indexed by symbol number."""
        data = self.raw(symtab)
        strtab = self._strtab_of(symtab)
        names = []
        for off in range(0, len(data), 24):
            (name_off,) = struct.unpack_from("<I", data, off)
            end = strtab.find(b"\0", name_off)
            names.append(strtab[name_off:end].decode("utf-8", "replace"))
        return names

    def cstr_at(self, sec, offset):
        """NUL-terminated string at `offset` within `sec`'s contents."""
        data = self.raw(sec)
        if not 0 <= offset < len(data):
            return None
        end = data.find(b"\0", offset)
        return data[offset:end].decode("utf-8", "replace") if end >= 0 else None

    def close(self):
        self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
        return False
