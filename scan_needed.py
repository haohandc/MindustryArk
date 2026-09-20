# -*- coding: utf-8 -*-
r"""
Gate: every .so that ships inside the HAP must have DT_NEEDED entries that the
DEVICE loader can actually resolve.

Why this exists (twice-burned lesson)
  A DT_NEEDED string that contains a host absolute path is recorded verbatim by
  the linker and taken literally by musl -- so the device looks for a Windows
  path and fails, while nothing on the host looks wrong at all. This already bit
  the libjvm anchor; the C++ shim is built the same way and can bite too.

  Two absolute-path shapes are legitimate and expected:
     /data/storage/...   the device path we deliberately injected
  Everything else with a separator in it is a bug.

ASCII-only output, no emoji.
"""
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = r"E:\Program Files\DevEco Studio\sdk\default\openharmony\native"
READELF = os.path.join(SDK, "llvm", "bin", "llvm-readelf.exe")
ROOT = os.path.join(HERE, "entry", "libs", "arm64-v8a")

OK_PREFIX = "/data/storage/"


def is_elf(path):
    try:
        return open(path, "rb").read(4) == b"\x7fELF"
    except OSError:
        return False


def dynamic_entries(path):
    r = subprocess.run([READELF, "-d", path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = []
    for line in r.stdout.splitlines():
        if ("NEEDED" in line or "SONAME" in line
                or "RPATH" in line or "RUNPATH" in line):
            out.append(line.strip())
    return out


def main():
    bad = 0
    checked = 0
    for dirpath, _dirs, files in os.walk(ROOT):
        for f in sorted(files):
            if not f.endswith(".so"):
                continue
            p = os.path.join(dirpath, f)
            if not is_elf(p):
                continue
            checked += 1
            for line in dynamic_entries(p):
                # pull the bracketed value, if any
                if "[" not in line or "]" not in line:
                    continue
                val = line[line.index("[") + 1:line.rindex("]")]
                if val.startswith(OK_PREFIX):
                    continue
                # a separator in a NEEDED/SONAME name means the loader will treat
                # it as a path -- which is only sane if it is a device path
                if "/" in val or os.sep in val or ":" in val:
                    print("  !! %s" % p.replace(HERE + os.sep, ""))
                    print("       %s" % line)
                    bad += 1

    print()
    print("checked %d ELF .so files under %s" % (checked, ROOT.replace(HERE + os.sep, "")))
    if bad:
        print("RESULT: %d suspects -- fix them or the device will not resolve them" % bad)
        return 1
    print("RESULT: clean -- every DT_NEEDED is either a bare soname or a %s path"
          % OK_PREFIX)
    return 0


if __name__ == "__main__":
    sys.exit(main())
