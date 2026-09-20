# -*- coding: utf-8 -*-
r"""
Prepare the prebuilt dependency used by our replacement libcxxabi_shim.so.

WHY THIS IS NEEDED
  libjvm.so's DT_NEEDED is [libcxxabi_shim.so, libc.so]. That shim carries the
  C++ ABI pieces the JDK build needs (__cxa_throw, __cxa_guard_acquire, RTTI
  vtables, operator new/delete, ...) -- 35 symbols -- but it does NOT export
  __cxa_thread_atexit, which libjvm.so also needs.

  Measured on device: OHOS's dynamic linker does NOT feed RTLD_GLOBAL libraries
  into the relocation scope of a newly dlopen'd library:
      dlsym(RTLD_DEFAULT, "__cxa_thread_atexit") returned 0
  even though we had just dlopen'd a library exporting it with RTLD_GLOBAL.
  So the symbol has to come from libjvm.so's OWN dependency list.

  Therefore we replace libcxxabi_shim.so with our own library that:
    * exports __cxa_thread_atexit (see cxatls.c), and
    * depends on the ORIGINAL shim, renamed to libcxxabi_real.so, so the other
      35 symbols still resolve.

  The linker matches a DT_NEEDED by SONAME, so renaming the file is not enough
  -- the SONAME string inside it has to change too. Both names are 17 characters,
  so this is an equal-length in-place patch of .dynstr (same technique as
  fix_needed.py in the audio work).

USAGE
  python make_cxxabi_real.py
"""
import io
import os
import shutil
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
CPP = os.path.join(HERE, "entry", "src", "main", "cpp")

# source: the original shim as it ships in the JDK
SRC = os.environ.get(
    "ORIG_SHIM",
    r"E:\User\Desktop\jdk-from-device\jdk21slim\lib\libcxxabi_shim.so")
# destination: a prebuilt next to our own CMakeLists (linked against by our shim)
DST = os.path.join(CPP, "libcxxabi_real.so")

OLD = b"libcxxabi_shim.so\x00"
NEW = b"libcxxabi_real.so\x00"

# entry/libs/arm64-v8a/ must NOT keep the original name, otherwise it would
# shadow the replacement our build produces.
STALE = os.path.join(HERE, "entry", "libs", "arm64-v8a", "libcxxabi_shim.so")


def main():
    if len(OLD) != len(NEW):
        raise SystemExit("!! names differ in length, in-place patch would break ELF layout")
    if not os.path.isfile(SRC):
        raise SystemExit("missing %s" % SRC)

    shutil.copyfile(SRC, DST)
    data = bytearray(open(DST, "rb").read())

    # locate .dynstr via section headers
    e_shoff = struct.unpack("<Q", data[0x28:0x30])[0]
    e_shentsize = struct.unpack("<H", data[0x3A:0x3C])[0]
    e_shnum = struct.unpack("<H", data[0x3C:0x3E])[0]
    e_shstrndx = struct.unpack("<H", data[0x3E:0x40])[0]

    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack("<IIQQQQIIQQ", data[o:o + 64])
        secs.append(dict(name=name, off=off, size=size))

    shstr = secs[e_shstrndx]
    for s in secs:
        raw = bytes(data[shstr["off"] + s["name"]:])
        s["nm"] = raw[:raw.index(b"\x00")].decode()

    dynstr = next((s for s in secs if s["nm"] == ".dynstr"), None)
    if dynstr is None:
        raise SystemExit("no .dynstr found")

    start, end = dynstr["off"], dynstr["off"] + dynstr["size"]
    region = bytes(data[start:end])
    n = region.count(OLD)
    print("  .dynstr: '%s' appears %d time(s)" % (OLD[:-1].decode(), n))
    if n != 1:
        # exactly one: the library's own DT_SONAME string. Refuse anything else so
        # we never patch blindly.
        raise SystemExit("!! expected exactly 1 occurrence, got %d -- aborting" % n)

    idx = 0
    patched = 0
    while True:
        i = region.find(OLD, idx)
        if i < 0:
            break
        off = start + i
        data[off:off + len(OLD)] = NEW
        idx = i + len(OLD)
        patched += 1

    open(DST, "wb").write(bytes(data))
    print("  patched %d occurrence(s)" % patched)
    print("  wrote %s (%d bytes)" % (DST, len(data)))

    if os.path.isfile(STALE):
        os.remove(STALE)
        print("  removed stale %s (the replacement takes that name)" % STALE)

    # verify
    import subprocess
    readelf = os.environ.get(
        "READELF",
        r"E:\Program Files\DevEco Studio\sdk\default\openharmony\native\llvm\bin\llvm-readelf.exe")
    if os.path.isfile(readelf):
        r = subprocess.run([readelf, "-d", DST], capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        print("  --- dynamic section ---")
        for line in r.stdout.splitlines():
            if "SONAME" in line or "NEEDED" in line:
                print("   " + line.strip())


if __name__ == "__main__":
    main()
