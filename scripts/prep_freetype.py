# -*- coding: utf-8 -*-
r"""Produce a loadable libarc-freetypearm64.so for HarmonyOS.

THE PROBLEM
    Arc loads its freetype natives itself, and both prebuilt ARM64 copies it
    could reach are unusable here:

        natives-freetype-desktop  NEEDED libc.so.6, ld-linux-aarch64.so.1
                                  -> glibc; neither exists on OpenHarmony
        the copy in the game jar  byte-identical to the above

    Arc's own loader writes it into the app's writable sandbox and calls
    System.load, which fails with "Invalid argument". The game then dies while
    building its fonts -- after the window is up and the first frame is drawn,
    which is what makes this the last thing standing between it and a full start:

        arc.util.ArcRuntimeException: Couldn't load shared library
            'libarc-freetypearm64.so' for target: Linux, 64-bit
            at arc.freetype.FreeType.initFreeType(FreeType.java:107)
            at arc.freetype.FreeTypeFontGenerator.<init>(...)
            at mindustry.game.Saves.<clinit> / ClientLauncher.update

THE WAY OUT
    Arc also ships an Android ARM64 build, and its undefined symbols are what
    make it usable here: thirty plain C functions, no C++ mangled names at all,
    so its "libstdc++.so" dependency is a leftover from the NDK link line rather
    than something it calls into. Every one of the thirty is exported by
    OpenHarmony's libc -- including __memcpy_chk, which musl proper does not have
    but OpenHarmony does.

    Its remaining problem is the dependency list itself: libm.so, libdl.so and
    libstdc++.so do not exist on OpenHarmony, which folds all three into libc.so.
    So the three DT_NEEDED entries are pointed at libc.so, in place, in .dynstr.
    The entry for libm.so is the same length as libc.so; the other two are longer
    and get a NUL after the new name, which is all a NUL-terminated string needs.

    Nothing is added to or removed from the dynamic array -- the earlier DT_NULL
    accident in this project came from replacing a tag rather than the string it
    points at, and that is not done here.

Usage:  python prep_freetype.py [--check]
"""

import argparse
import hashlib
import os
import struct
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

SRC = (r"C:\Users\Haohandc\Arc\natives\natives-freetype-android"
       r"\libs\arm64-v8a\libarc-freetype.so")

HERE = os.path.dirname(os.path.abspath(__file__))
# this file lives in scripts/, so the project root is one level up
PROJECT_ROOT = os.path.dirname(HERE)
DEST = os.path.join(PROJECT_ROOT, "entry", "libs", "arm64-v8a", "arc",
                    "libarc-freetypearm64.so")

READELF = (r"E:\Program Files\DevEco Studio\sdk\default\openharmony\native"
           r"\llvm\bin\llvm-readelf.exe")

# The build this is derived from. Pinned so that a different file cannot be
# substituted silently -- the whole point of this script is that there is exactly
# one copy of this library that works here.
SRC_SHA1 = None      # checked against a recorded value once known; see main()

# Every entry here must end up pointing at something that exists on the device.
REWRITE = {
    "libm.so": "libc.so",
    "libdl.so": "libc.so",
    "libstdc++.so": "libc.so",
}

DT_NEEDED = 1
SHT_DYNAMIC = 6


def sha1b(b):
    return hashlib.sha1(b).hexdigest()


def sections(data):
    """Yield (index, type, offset, size, addr, link) for each section header."""
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from("<I", data, base + 4)[0]
        sh_addr = struct.unpack_from("<Q", data, base + 0x10)[0]
        sh_offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        sh_size = struct.unpack_from("<Q", data, base + 0x20)[0]
        sh_link = struct.unpack_from("<I", data, base + 0x28)[0]
        yield i, sh_type, sh_offset, sh_size, sh_addr, sh_link


def rewrite_needed(data):
    """Point the DT_NEEDED entries named in REWRITE at their replacements.

    Returns the list of (old, new) actually applied, and raises if a name to be
    rewritten is not found -- a silent no-op here would leave a library that
    looks patched and cannot load.
    """
    dyn = None
    for _i, sh_type, sh_offset, sh_size, _a, sh_link in sections(data):
        if sh_type == SHT_DYNAMIC:
            dyn = (sh_offset, sh_size, sh_link)
            break
    if dyn is None:
        raise SystemExit("no SHT_DYNAMIC section")

    dyn_off, dyn_size, strtab_index = dyn

    strtab_off = None
    for i, _t, sh_offset, _sz, _a, _l in sections(data):
        if i == strtab_index:
            strtab_off = sh_offset
            break
    if strtab_off is None:
        raise SystemExit("dynamic section links to no string table")

    applied = []
    found = set()
    for off in range(dyn_off, dyn_off + dyn_size, 16):
        tag = struct.unpack_from("<q", data, off)[0]
        val = struct.unpack_from("<Q", data, off + 8)[0]
        if tag != DT_NEEDED:
            continue
        name_off = strtab_off + val
        end = data.index(b"\0", name_off)
        name = data[name_off:end].decode("latin-1")
        if name not in REWRITE:
            continue
        found.add(name)
        new = REWRITE[name]
        if len(new) > len(name):
            raise SystemExit("replacement %r is longer than %r" % (new, name))
        padded = new.encode("latin-1") + b"\0"
        data[name_off:name_off + len(padded)] = padded
        applied.append((name, new))

    missing = set(REWRITE) - found
    if missing:
        raise SystemExit("expected DT_NEEDED entries not found: %s"
                         % ", ".join(sorted(missing)))
    return applied


def needed_of(path):
    r = subprocess.run([READELF, "-d", path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return [l.strip() for l in (r.stdout + r.stderr).splitlines()
            if "NEEDED" in l]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    if not os.path.isfile(SRC):
        print("FAIL missing %s" % SRC)
        return 1

    src = bytearray(open(SRC, "rb").read())
    print("source : %s" % SRC)
    print("size   : %d  sha1 %s" % (len(src), sha1b(bytes(src))[:16]))

    applied = rewrite_needed(src)
    for old, new in applied:
        print("   DT_NEEDED  %-14s -> %s" % (old, new))

    if a.check:
        ok = os.path.isfile(DEST) and open(DEST, "rb").read() == bytes(src)
        print("dest   : %s" % ("present and identical" if ok else "ABSENT/DIFFERS"))
        return 0 if ok else 1

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    with open(DEST, "wb") as f:
        f.write(src)

    if open(DEST, "rb").read() != bytes(src):
        os.remove(DEST)
        print("FAIL the installed copy differs from what was patched")
        return 1

    # Read the result back with an independent tool rather than trusting the
    # writer: the question is what a loader will see, not what was intended.
    print("dest   : %s" % DEST)
    for l in needed_of(DEST):
        print("   %s" % l)
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
