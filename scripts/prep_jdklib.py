# -*- coding: utf-8 -*-
r"""Ship the JDK's non-library files that the runtime reads by name.

WHY THIS IS NEEDED
    hvigor copies entry/libs/arm64-v8a/** into the HAP only for names ending in
    ".so", and it drops everything else silently. Two files under
    jdk21/lib/ are not libraries but are opened by name at runtime:

        modules     the module image; renamed in place to jimg.so by
                    patch_libjvm.py, so it already travels. java.home is then
                    pointed at a sandbox directory holding a copy named
                    "modules" -- see prepare_java_home() in launcher.c.
        tzdb.dat    the time-zone database. java.base opens
                    $java.home/lib/tzdb.dat while initialising
                    sun.util.calendar.ZoneInfoFile, which happens the first time
                    anything asks for a date format -- and Mindustry asks for one
                    in Saves.<clinit>, so its absence stops the game from
                    starting at all:

                        FileNotFoundException: <...>/jdk21/lib/tzdb.dat
                            at sun.util.calendar.ZoneInfoFile.loadTZDB
                            at sun.util.calendar.ZoneInfo.getTimeZone
                            at java.text.DateFormat.getDateTimeInstance
                            at mindustry.game.Saves.<clinit>(Saves.java:27)

    So tzdb.dat gets the same treatment: shipped under a ".so" name and copied
    into place at startup, next to the module image.

NOT SHIPPED, deliberately -- each is only read by tooling that never runs here:
    jvm.cfg       read by the `java` launcher, not by libjvm
    classlist     CDS class list; CDS is not used
    jrt-fs.jar    the jrt filesystem provider, for javac and friends
    jfr/, jexec, jspawnhelper
If one of those is ever needed the failure will name it, the same way this one
named tzdb.dat.

Usage:  python prep_jdklib.py [--check]
"""

import argparse
import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

PROJECT_ROOT = config.PROJECT_ROOT
JDK_LIB = os.path.join(config.LIBS, "jdk21", "lib")

# source name -> (shipped name, sha1)
FILES = {
    "tzdb.dat": ("tzdb.so", "330a69ed889539d7b8f9ec8bcb00f49b5ee2895d"),
}


def sha1f(p):
    h = hashlib.sha1()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    bad = 0
    for src_name, (shipped, want) in FILES.items():
        src = os.path.join(JDK_LIB, src_name)
        dst = os.path.join(JDK_LIB, shipped)

        if not os.path.isfile(src):
            print("   %-12s source MISSING at %s" % (src_name, src))
            bad += 1
            continue
        got = sha1f(src)
        if got != want:
            print("   %-12s SHA1 MISMATCH %s" % (src_name, got))
            bad += 1
            continue

        if a.check:
            ok = os.path.isfile(dst) and sha1f(dst) == want
            print("   %-12s -> %-12s %s" % (src_name, shipped,
                                            "present" if ok else "ABSENT/DIFFERS"))
            if not ok:
                bad += 1
            continue

        shutil.copyfile(src, dst)
        if sha1f(dst) != want:
            os.remove(dst)
            print("   %-12s -> %-12s WRITE FAILED" % (src_name, shipped))
            bad += 1
            continue
        print("   %-12s -> %-12s %8d bytes, sha1 verified"
              % (src_name, shipped, os.path.getsize(dst)))

    if bad:
        print("RESULT: FAIL (%d problem(s))" % bad)
        return 1
    print("RESULT: %s" % ("PASS (check only)" if a.check else "PASS"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
