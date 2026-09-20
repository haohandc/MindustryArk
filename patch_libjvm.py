# -*- coding: utf-8 -*-
r"""
Point HotSpot at a module image that can actually ship inside a HAP.

THE PROBLEM
  Two constraints collide:
    (a) Only the HAP's lib area is executable, and the HAP packer keeps ONLY
        *.so files from entry/libs/**. Measured:  a file named `modules` placed
        under libs/ is silently dropped, the same bytes named `xmod.so` ship.
    (b) HotSpot insists on <java.home>/lib/modules existing:
            Arguments::set_java_home(<path derived from libjvm.so, 3 levels up>)
            if (!set_boot_path('/', ':')) vm_exit_during_initialization(...)
        and `modules` is not a .so name, so it cannot be shipped.

THE FIX
  Rename the jimage to `jimg.so` (7 chars -- same length as `modules`, so the
  patch is a pure in-place substitution that cannot shift any ELF offset) and
  rewrite the two path-building format strings in libjvm.so accordingly.

  Strings changed (both contain the literal `modules`):
      "%s%slib%smodules"   ->  "%s%slib%sjimg.so"
      "%/lib/modules"      ->  "%/lib/jimg.so"
  Deliberately NOT touched:
      "%/modules/java.base"  -- that is a path INSIDE the jimage, not on disk.

  This is a 7-byte-for-7-byte edit in the file, verified both before and after.

NOTE ON LICENSING
  OpenJDK is GPLv2+CE. Modifying it for local use is fine; redistributing the
  modified binary would mean shipping the corresponding source. Keep that in
  mind if this ever goes beyond a personal build.

USAGE
    python patch_libjvm.py <in.so> <out.so>
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# equal length by construction: both are 7 bytes
OLD_NAME = b"modules"
NEW_NAME = b"jimg.so"
assert len(OLD_NAME) == len(NEW_NAME), "patch would shift offsets"

# the full format strings we are willing to touch
TARGETS = [
    (b"%s%slib%s" + OLD_NAME, b"%s%slib%s" + NEW_NAME),
    (b"%/" + b"lib/" + OLD_NAME, b"%/" + b"lib/" + NEW_NAME),
]
# must never be touched: it is a logical path inside the image
FORBIDDEN = b"%/" + OLD_NAME + b"/java.base"


def dynamic_range(data):
    """(offset, size) of the .dynamic section, or (None, None)."""
    import struct as _s
    e_shoff = _s.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = _s.unpack_from("<H", data, 0x3A)[0]
    e_shnum = _s.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = _s.unpack_from("<H", data, 0x3E)[0]
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        secs.append(_s.unpack_from("<IIQQQQIIQQ", data, o))
    shstr = secs[e_shstrndx]

    def nm(sec):
        raw = bytes(data[shstr[4] + sec[0]:])
        return raw[:raw.index(b"\x00")].decode()

    dyn = next((s for s in secs if nm(s) == ".dynamic"), None)
    return (dyn[4], dyn[5]) if dyn else (None, None)


def drop_soname(data):
    """
    NO LONGER CALLED -- kept because the trap it describes is easy to walk into.

    Original intent: the anchor library was going to be LINKED AGAINST the real
    JVM by name, and a linker records a dependency's SONAME in DT_NEEDED rather
    than its path. With libjvm.so carrying SONAME "libjvm.so" that would have
    produced a self-referential dependency, so the SONAME had to go.

    prep_vendor.py now takes a different route: it links the anchor against a
    padded placeholder path and then rewrites that string in .dynstr in place.
    The real JVM's SONAME is irrelevant to that, so this whole step was a leftover
    -- and it is not a neutral one. Blanking the tag to DT_NULL TRUNCATES the
    dynamic array, because DT_NULL is the list terminator: RELA (121,769
    relocations), JMPREL, SYMTAB, STRTAB and GNU_HASH became invisible to the
    loader and the library could not be dlopen'd at all, reporting only
    "Invalid argument".

    Restoring the SONAME is also the more faithful configuration: the unmodified
    library carries it, so every configuration that is known to work -- including
    AMCL's on this device -- has it.

    Remove DT_SONAME (tag 14) from .dynamic by SHIFTING later entries down.

    This used to just overwrite the tag with DT_NULL, which looks like "removing"
    the entry but actually TRUNCATES the array: DT_NULL is the list terminator, so
    every entry after it -- RELA (121,769 relocations here), JMPREL, SYMTAB,
    STRTAB, GNU_HASH, INIT, VERSYM, VERDEF -- became invisible to the loader.
    The resulting library cannot be dlopen'd at all; on OHOS it surfaces as
    dlerror "Invalid argument", which points nowhere near the real cause.

    readelf still cheerfully prints the surviving entries, which is why this went
    unnoticed: the tool showed a plausible-looking dynamic section, just a very
    short one. verify_dynamic() below now asserts the table is complete.

    The array keeps its byte length (the freed slot becomes one more DT_NULL).
    """
    import struct as _s
    off, size = dynamic_range(data)
    if off is None:
        return 0

    entries = []
    o = off
    while o + 16 <= off + size:
        tag, val = _s.unpack_from("<qQ", data, o)
        entries.append((tag, val))
        if tag == 0:          # DT_NULL terminates; do not read past it
            break
        o += 16

    kept = [e for e in entries if e[0] != 14]
    removed = len(entries) - len(kept)
    if removed == 0:
        return 0

    # pad back to the original byte length with extra terminators
    while len(kept) * 16 < size:
        kept.append((0, 0))

    for j, (tag, val) in enumerate(kept):
        _s.pack_into("<qQ", data, off + j * 16, tag, val)
    return removed


# Tags a loadable shared object must still expose. This is written as an
# INVARIANT LIST, not as "the things I changed" -- an earlier version of this
# gate only checked that my two edited strings were edited and that my one
# protected string was intact. All of that passed while the library was in fact
# unloadable, because 23 dynamic entries had silently vanished.
REQUIRED_TAGS = {
    1:  "NEEDED", 5: "STRTAB", 6: "SYMTAB", 10: "STRSZ",
    7:  "RELA", 8: "RELASZ", 9: "RELAENT",
    0x6ffffef5: "GNU_HASH",
    0x19: "INIT_ARRAY", 0xc: "INIT",
}
# DT_SONAME (14) is REQUIRED now -- the unmodified library carries it and every
# known-working configuration has it, so its absence would itself be a deviation.
REQUIRED_SONAME = 14


def verify_dynamic(data, label):
    """Fail loudly if the dynamic table lost anything it needs."""
    import struct as _s
    off, size = dynamic_range(data)
    if off is None:
        raise SystemExit("!! %s has no .dynamic" % label)
    tags = set()
    o = off
    while o + 16 <= off + size:
        tag, _val = _s.unpack_from("<qQ", data, o)
        if tag == 0:
            break
        tags.add(tag)
        o += 16

    missing = [(t, n) for t, n in REQUIRED_TAGS.items() if t not in tags]
    print("  %s: %d dynamic entries, missing required: %s"
          % (label, len(tags), [n for _t, n in missing] or "none"))
    if missing:
        raise SystemExit("!! %s would not load -- refusing to write it" % label)
    if REQUIRED_SONAME not in tags:
        raise SystemExit("!! %s lost its DT_SONAME -- deviation from the "
                         "unmodified library" % label)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: python patch_libjvm.py <in.so> <out.so>")
    src, dst = sys.argv[1], sys.argv[2]

    data = bytearray(open(src, "rb").read())
    print("input : %s (%d bytes)" % (src, len(data)))

    # safety: the forbidden string must be present and must stay intact
    if data.count(FORBIDDEN) == 0:
        raise SystemExit("!! expected to find %r -- wrong libjvm?" % FORBIDDEN)
    print("  found %d x %r (left alone)" % (data.count(FORBIDDEN), FORBIDDEN))

    changed = 0
    for old, new in TARGETS:
        n = data.count(old)
        if n == 0:
            print("  !! %r not found -- aborting" % old)
            raise SystemExit(1)
        data = data.replace(old, new)
        changed += n
        print("  %-24r -> %-24r  (%d occurrence%s)"
              % (old, new, n, "" if n == 1 else "s"))

    # --- DT_SONAME: deliberately LEFT ALONE (2026-09-19) ---------------------
    # It used to be blanked so the anchor could be linked against this file by
    # name. The anchor now carries a rewritten absolute path instead, so the
    # SONAME is irrelevant to it -- and keeping the library as unmodified as
    # possible is worth more than the tidiness of removing it. See drop_soname()
    # below for why the old way of removing it was actively harmful.
    print()
    print("  DT_SONAME : left intact (unmodified, as the JDK ships it)")

    # verify BEFORE writing, so a bad patch never reaches the libs directory
    print()
    print("  --- dynamic table integrity ---")
    verify_dynamic(data, os.path.basename(dst))
    out = bytes(data)
    open(dst, "wb").write(out)

    ok_len = len(out) == os.path.getsize(src)
    print()
    print("  length unchanged : %s (%d)" % (ok_len, len(out)))
    print("  forbidden intact : %s" % (out.count(FORBIDDEN) == 1))
    print("  no bare 'modules' left in those strings : %s"
          % (out.count(b"%s%slib%s" + OLD_NAME) == 0))
    print("  output : %s" % dst)


if __name__ == "__main__":
    main()
