# -*- coding: utf-8 -*-
r"""
Assemble the two native pieces the JDK needs, into entry/libs/arm64-v8a/.

BACKGROUND (why any of this is necessary)
  Two rules fight each other:

   (1) Only the HAP's own lib area is executable. A library in the app's
       writable sandbox cannot be dlopen'd, even holding
       ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY. (AMCL gets around this
       with a hand-written ELF loader; we do not need one.)

   (2) HotSpot derives java.home by stripping three components off libjvm.so's
       own path and then requiring "<java.home>/lib/<module image>" to exist.
       -Djava.home is overwritten unconditionally (os_linux.cpp).

  So the JVM must live NESTED:
        <bundle>/libs/arm64/jdk21/lib/server/libjvm_real.so
                                  ^lib/server -> lib -> jdk21 = java.home
  ...while every other JDK library declares DT_NEEDED on the BARE name
  "libjvm.so", which the loader can only resolve from its search path -- the
  FLAT directory <bundle>/libs/arm64/.

  Two facts about the OHOS loader shape the solution:
    * it ignores DT_RPATH / DT_RUNPATH entirely (measured: an absolute rpath was
      ignored), and it does not expand $ORIGIN (a glibc extension), and
    * it DOES take a DT_NEEDED containing '/' literally, no search involved.

  Hence: a tiny anchor named libjvm.so sits on the search path, and its
  DT_NEEDED is an ABSOLUTE device path to the real JVM. To get a 66-character
  absolute path into DT_NEEDED the linker has to be given a 66-character path in
  the first place, so we hand it a padded host path and then rewrite that string
  in place (equal length, so no ELF offset moves).

WHAT THIS SCRIPT PRODUCES
  entry/libs/arm64-v8a/libjvm.so                       <- the anchor
  entry/libs/arm64-v8a/jdk21/lib/server/libjvm_real.so <- the patched real JVM

USAGE
    python prep_vendor.py
"""
import io
import os
import shutil
import struct
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

import config

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = config.PROJECT_ROOT
CPP = config.CPP
LIBS = config.LIBS
JDK_SERVER = os.path.join(LIBS, "jdk21", "lib", "server")
PAD_DIR = os.path.join(HERE, "_anchorpad")          # host-only scratch, not shipped

SDK = config.NATIVE_SDK
CLANG = config.CLANG
SYSROOT = config.SYSROOT

# the unmodified libjvm as it comes out of the JDK
SRC_JVM = config.SRC_JVM

# where the real JVM has to end up ON DEVICE -- its length is what we must match
DEVICE_JVM = "/data/storage/el1/bundle/libs/arm64/jdk21/lib/server/libjvm_real.so"


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", **kw)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit("command failed: %s" % (" ".join(cmd[:3])))
    return r


def patch_jvm(src, dst):
    """Delegate to patch_libjvm.py (module-image name + SONAME removal)."""
    print("== 1. patch the real libjvm ==")
    run([sys.executable, os.path.join(HERE, "patch_libjvm.py"), src, dst])


def build_anchor_padded():
    """
    Compile the anchor and give its DT_NEEDED a placeholder string whose LENGTH
    equals DEVICE_JVM's, so it can be rewritten in place afterwards.
    """
    print()
    print("== 2. build the anchor (libjvm.so) ==")
    os.makedirs(PAD_DIR, exist_ok=True)

    src = os.path.join(CPP, "libjvm_anchor.c")
    if not os.path.isfile(src):
        raise SystemExit("missing %s" % src)

    # a placeholder library whose PATH (as given to the linker) has the same
    # length as the device path we actually want in DT_NEEDED
    pad = os.path.join(PAD_DIR, "p" * max(1, len(DEVICE_JVM) - len(PAD_DIR) - 1))
    pad = pad[:len(DEVICE_JVM)]
    if len(pad) != len(DEVICE_JVM):
        raise SystemExit("cannot size the pad path (%d vs %d)"
                         % (len(pad), len(DEVICE_JVM)))

    stub_c = os.path.join(PAD_DIR, "stub.c")
    io.open(stub_c, "w", encoding="utf-8", newline="\n").write(
        "int pad_stub(void){return 0;}\n")
    run([CLANG, "--target=aarch64-linux-ohos", "--sysroot=" + SYSROOT,
         "-shared", "-fPIC", "-o", pad, stub_c])
    print("   pad target : %s (%d chars)" % (pad, len(pad)))

    anchor = os.path.join(LIBS, "libjvm.so")
    # --no-as-needed so the DT_NEEDED is recorded even though no symbol from the
    # pad object is referenced. No -soname: that way the linker records the PATH
    # we passed rather than a soname.
    run([CLANG, "--target=aarch64-linux-ohos", "--sysroot=" + SYSROOT,
         "-shared", "-fPIC", "-o", anchor, src,
         "-Wl,--no-as-needed", pad, "-Wl,--as-needed"])
    print("   anchor     : %s" % anchor)
    return pad


def rewrite_needed(path, old, new):
    """Replace a DT_NEEDED string in place (.dynstr), equal length only."""
    if len(old) != len(new):
        raise SystemExit("!! lengths differ (%d vs %d) -- in-place edit impossible"
                         % (len(old), len(new)))
    data = bytearray(open(path, "rb").read())

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    secs = [struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
            for i in range(e_shnum)]
    shstr = secs[e_shstrndx]

    def nm(sec):
        raw = bytes(data[shstr[4] + sec[0]:])
        return raw[:raw.index(b"\x00")].decode()

    dynstr = next((s for s in secs if nm(s) == ".dynstr"), None)
    if dynstr is None:
        raise SystemExit("no .dynstr")
    off, size = dynstr[4], dynstr[5]

    region = bytes(data[off:off + size])
    cnt = region.count(old)
    print("   %d occurrences in .dynstr of the %d-char pad string" % (cnt, len(old)))
    if cnt != 1:
        raise SystemExit("!! expected exactly 1 -- aborting")

    i = off + region.index(old)
    data[i:i + len(old)] = new
    open(path, "wb").write(bytes(data))
    print("   DT_NEEDED rewritten -> %s" % new)


def main():
    if not os.path.isfile(SRC_JVM):
        raise SystemExit("missing %s" % SRC_JVM)

    os.makedirs(JDK_SERVER, exist_ok=True)
    real = os.path.join(JDK_SERVER, "libjvm_real.so")
    patch_jvm(SRC_JVM, real)

    pad = build_anchor_padded()
    anchor = os.path.join(LIBS, "libjvm.so")

    print()
    print("== 3. rewrite the anchor's DT_NEEDED to the device path ==")
    rewrite_needed(anchor, pad.encode(), DEVICE_JVM.encode())

    print()
    print("== 4. verify ==")
    readelf = os.path.join(SDK, "llvm", "bin", "llvm-readelf.exe")
    for f in (anchor, real):
        r = subprocess.run([readelf, "-d", f], capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        print("  %s" % f.replace(HERE, "."))
        for line in r.stdout.splitlines():
            if any(k in line for k in ("NEEDED", "SONAME", "RPATH", "RUNPATH")):
                print("     " + line.strip())


if __name__ == "__main__":
    main()
