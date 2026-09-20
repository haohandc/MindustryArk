# -*- coding: utf-8 -*-
r"""Put Arc's own native libraries where they can actually be loaded from.

THE PROBLEM
    Arc loads its natives itself: ArcNativesLoader -> SharedLibraryLoader.load("arc")
    reads libarcarm64.so out of the jar, writes it into a directory under
    java.io.tmpdir, and calls System.load on the copy. That works on a desktop.
    Here the copy lands in the app's writable sandbox, and dlopen refuses it:

        UnsatisfiedLinkError: /data/storage/el2/base/temp/arc/a8f0c58/libarcarm64.so:
        Error loading shared library ...: Invalid argument

    The same library loads without complaint from the read-only bundle area --
    the probe in myapp.c measures exactly this, with two libraries across six
    candidate directories and a bundle control that passes. So the executable
    area is the one place it can live.

THE FIX, AND WHY IT IS DONE THIS WAY
    Ship them in the bundle and load them BEFORE the game starts, then tell Arc
    they are loaded so its own loader does not try. The marking is not a hack
    around Arc: SharedLibraryLoader.setLoaded(String) is public and static, and
    load(String) returns immediately for a name that is already marked. It is
    the same call Arc makes for itself after a successful load.

    Doing it here also means the libraries are the ones this project controls,
    rather than whatever happens to be inside a jar -- which is what step 6 of
    the blueprint asks for anyway.

Source
    the same pinned jar the game ships as, so the natives and the Java classes
    that call into them cannot drift apart

Usage:  python prep_arc.py [--check]
"""

import argparse
import hashlib
import os
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

PROJECT_ROOT = config.PROJECT_ROOT
# The same pinned build prep_game.py ships, so the natives and the Java classes
# that call into them cannot be taken from two different jars.
JAR = config.GAME_JAR
DEST_DIR = os.path.join(PROJECT_ROOT, "entry", "libs", "arm64-v8a", "arc")

# name inside the jar -> sha1
#
# libarc-freetypearm64.so is NOT in this table, deliberately. The copy in the jar
# is a glibc build (DT_NEEDED libc.so.6 and ld-linux-aarch64.so.1) and cannot load
# on OpenHarmony at all. It is produced by prep_freetype.py instead, from Arc's
# Android build, and that script owns the destination file. Listing it here would
# overwrite the working copy with the unusable one, and the game would die in
# font setup again -- after the window and the first frame, so it would look like
# a regression in something else.
NATIVES = {
    "libarcarm64.so":             "db9d78b196beaa237a153b622b781e06be973462",
    "libarc-filedialogsarm64.so": "0ac27bdfd455ed1190ff9ba0ce97c7ddeb0cc049",
}


def sha1b(b):
    return hashlib.sha1(b).hexdigest()


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

    if not os.path.isfile(JAR):
        print("FAIL missing %s" % JAR)
        return 1

    bad = 0
    with zipfile.ZipFile(JAR) as z:
        names = z.namelist()
        for name, want in NATIVES.items():
            if name not in names:
                print("   %-30s MISSING from the jar" % name)
                bad += 1
                continue
            data = z.read(name)
            got = sha1b(data)
            if got != want:
                print("   %-30s SHA1 MISMATCH %s" % (name, got))
                bad += 1
                continue
            dst = os.path.join(DEST_DIR, name)
            if a.check:
                ok = os.path.isfile(dst) and sha1f(dst) == want
                print("   %-30s %9d  %s" % (name, len(data),
                                            "present" if ok else "ABSENT/DIFFERS"))
                if not ok:
                    bad += 1
                continue
            os.makedirs(DEST_DIR, exist_ok=True)
            with open(dst, "wb") as f:
                f.write(data)
            if sha1f(dst) != want:
                os.remove(dst)
                print("   %-30s WRITE FAILED" % name)
                bad += 1
                continue
            print("   %-30s %9d  sha1 verified" % (name, len(data)))

    if bad:
        print("RESULT: FAIL (%d problem(s))" % bad)
        return 1
    print("RESULT: %s" % ("PASS (check only)" if a.check else "PASS"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
