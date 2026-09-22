# -*- coding: utf-8 -*-
r"""
Package the assembled payload as the release attachment.

    python scripts/make_payload_zip.py

WHY THIS IS A SCRIPT AND NOT A COMMAND SOMEONE RUNS BY HAND

    It was done by hand until 2026-09-22, and the shipped zip had already gone
    stale without anyone noticing: comparing the v0.2.0-beta.2 payload against the
    working tree showed it was MISSING 21 entries --

        20 x entry/libs/arm64-v8a/jdkhome/...   (produced by prep_jdkconf.py)
         1 x entry/libs/arm64-v8a/probe/probe-mod.jar.so   (no longer produced)

    and nothing extra. That is not a cosmetic difference. jdkhome/conf/security/
    java.security is what Security.<clinit> reads, and without it the JVM cannot
    define a class at runtime at all -- mod loading dies with
    "NoClassDefFoundError: java.security.Security". So anyone who built from the
    old payload got a package whose mods could not load, and the payload looked
    perfectly fine doing it.

    A hand-made zip of a directory that changes is a step that goes wrong
    silently, which is why this project's rule is that every step derived from
    another artifact gets a script with assertions. The assertions below are the
    point of the file; the zipping is incidental.

WHAT IT ASSERTS
    1. Before writing: the entries that have each broken a build at least once are
       present in entry/libs. A missing one is a hard stop with the producing
       script named, rather than a smaller zip nobody checks.
    2. After writing: the zip is reopened and the entry SET is compared against
       what was on disk. Equal or it fails. Writing a file and believing it
       landed is the mistake this whole script exists to prevent, so it is not
       repeated inside the script.

OUTPUT
    dist/<ARTIFACT_NAME>-payload.zip, named from scripts/config.py so the version
    cannot drift from the HAP's.
"""
import hashlib
import io
import os
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

PAYLOAD_README = "README-PAYLOAD.txt"

# path RELATIVE TO config.LIBS -> why its absence is fatal, or who produces it
#
# ⚠️ No "arm64-v8a/" prefix: config.LIBS already ends with it. Writing it in both
# places doubles the path, and the first version of this file did exactly that --
# the assertion fired on a file that was right there, which is how it was found.
# A check that fails on a correct tree is the same defect as one that passes on a
# broken tree: it trains the reader to ignore it.
REQUIRED = {
    "jdk21/lib/jimg.so":
        "the module image (134 MB). Renamed from lib/modules by prep_jdklib.py -- "
        "java.base insists on the name 'modules' and will not accept anything else",
    "jdk21/lib/server/libjvm_real.so":
        "the real JVM. Without it the anchor libjvm.so has nothing to load",
    "jdkhome/conf/security/java.security.so":
        "Security.<clinit> reads this. MISSING IT MAKES EVERY RUNTIME CLASS "
        "DEFINITION FAIL, so mods cannot load -- run scripts/prep_jdkconf.py",
    "jdkhome/lib/security/cacerts.so":
        "the trust store. Without it TLS has no roots and networking fails "
        "in a way that looks like a server problem -- run scripts/prep_jdkconf.py",
    "game/mindustry.so":
        "the game jar, renamed. The classpath points at it",
    # "probe/probe-mod.jar.so" USED TO BE REQUIRED HERE and is no longer, because
    # it is no longer produced: tools/probe-mod/build.sh stopped installing it
    # into libs/, since the ArkTS code that copied it into the game's mods
    # directory at every launch was removed along with the rest of the importer.
    # Leaving the assertion in would now fail on a perfectly good tree -- and a
    # check that fails on a correct tree is the same defect as one that passes on
    # a broken one: it trains the reader to ignore it.
}

# NOT asserted, on purpose: libmain.so and libSDL3.so.
#   They appear in the HAP under libs/arm64-v8a/ but they are BUILD OUTPUTS --
#   hvigor takes them from the CMake tree, and "bash build.sh assembleHap"
#   regenerates both from source. Requiring them here would demand that someone
#   ship compiled objects alongside the source they are compiled from, and the
#   first version of this file did require libmain.so and stopped on a payload
#   that was perfectly good.


def sha256f(path):
    h = hashlib.sha256()
    with io.open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def collect():
    """Every file under entry/libs, as (abs path, path inside the zip)."""
    out = []
    root = config.LIBS
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, os.path.dirname(root))
            out.append((full, rel.replace(os.sep, "/")))
    return out


def main():
    root = config.PROJECT_ROOT
    dist = os.path.join(root, "dist")
    os.makedirs(dist, exist_ok=True)

    if not os.path.isdir(config.LIBS):
        sys.exit("!! %s does not exist -- run the prep_* scripts first" % config.LIBS)

    # --- 1. the assertions, BEFORE anything is written -----------------------
    print("checking the payload")
    for rel, why in sorted(REQUIRED.items()):
        full = os.path.join(config.LIBS, rel)
        if not os.path.isfile(full):
            sys.exit("!! MISSING: entry/libs/%s\n"
                     "   why it matters: %s\n"
                     "   refusing to write a payload that cannot build a working app"
                     % (rel, why))
        print("   ok  %-52s %8.1f MB" % (rel, os.path.getsize(full) / 1048576.0))

    readme = os.path.join(dist, PAYLOAD_README)
    if not os.path.isfile(readme):
        sys.exit("!! %s is missing -- it is the only documentation in the zip" % readme)

    files = collect()
    if not files:
        sys.exit("!! nothing under %s" % config.LIBS)

    # --- 2. write -----------------------------------------------------------
    out = os.path.join(dist, "%s-payload.zip" % config.ARTIFACT_NAME)
    print("\nwriting %s" % os.path.basename(out))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(readme, PAYLOAD_README)
        for full, rel in files:
            z.write(full, rel)

    # --- 3. reopen and compare the SETS ------------------------------------
    # Not the counts: a count matches again if one entry is lost and another
    # gained, which is the exact shape of the drift that was found by hand.
    print("verifying the written zip")
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad is not None:
            sys.exit("!! the zip is corrupt at %s" % bad)
        got = set(z.namelist())
    want = set([PAYLOAD_README] + [rel for _full, rel in files])
    missing = sorted(want - got)
    extra = sorted(got - want)
    if missing or extra:
        sys.exit("!! the zip does not match the directory\n"
                 "   missing: %s\n   unexpected: %s" % (missing[:10], extra[:10]))

    size = os.path.getsize(out)
    print("   %d entries (excluding README), matches the directory exactly"
          % (len(got) - 1))
    print("   %.1f MB   sha256 %s" % (size / 1048576.0, sha256f(out)[:32]))
    print("\n%s" % out)
    print("\nAttach that file to the release. It is not needed to play -- it is what")
    print("someone needs to rebuild the HAP themselves.")


if __name__ == "__main__":
    main()
