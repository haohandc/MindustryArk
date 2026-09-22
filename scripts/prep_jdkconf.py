# -*- coding: utf-8 -*-
"""Ship the JDK files that java.home-relative lookups need.

THE BUG THIS FIXES
    Mod loading failed with:

        java.lang.NoClassDefFoundError: Could not initialize class java.security.Security
        Caused by: java.lang.InternalError: Error loading java.security file

    The launcher points java.home at a SANDBOX directory (<files>/jdk) because
    the module image has to be reachable as "<java.home>/lib/modules" and the
    bundle can only hold it under a ".so" name. That sandbox directory was built
    from a hand-written list of two files -- lib/modules and lib/tzdb.dat --
    and nothing else.

    But java.home is not just where the module image lives. The JDK also reads
    paths RELATIVE to it, and the one that broke class loading is
    <java.home>/conf/security/java.security, which java.security.Security reads
    during its static initialiser. Every defineClass() needs a ProtectionDomain,
    which needs FilePermission, which needs Security -- so with that file absent,
    NO class can be loaded at runtime, by any mechanism.

    This is the SECOND time a missing java.home-relative file has surfaced as a
    runtime failure: the launcher's own comment on lib/tzdb.dat records that
    ZoneInfoFile failed to initialise and Mindustry asks for a DateFormat in
    Saves.<clinit>. Two instances, two different features, same cause.

WHY IT SHIPS A WHOLE TREE INSTEAD OF ONE MORE FILE
    Adding java.security to the list would fix this bug and leave the mechanism
    that produced it exactly as it was -- a list that is correct until a feature
    exercises the next entry. So this ships the source trees that java.home
    lookups reach into, whole:

        conf/            the JDK's own configuration, including the security
                         policy. 115 KB.
        lib/security/    the default truststore and policy. 369 KB. Not needed
                         to load a mod -- needed the moment anything does TLS,
                         which is what networking will want.

    Together under half a megabyte, next to a 140 MB module image that is
    already copied on first launch. The cost of being complete is nil; the cost
    of another incomplete list is another round of "a feature does not work and
    the reason is a file we did not ship".

WHY ".so" ON EVERY FILE
    Measured, by building with three files under libs/ and reading the HAP back:

        libs/arm64-v8a/_pkgtest/plain.txt          -> NOT in the HAP
        libs/arm64-v8a/_pkgtest/sub/dotted.policy  -> NOT in the HAP
        libs/arm64-v8a/_pkgtest/suffixed.so        -> in the HAP, path preserved

    hvigor carries *.so out of libs/ and drops everything else silently. So the
    destination tree mirrors the real layout with ".so" appended to each file
    name, and the launcher strips exactly one trailing ".so" while copying. This
    is the same trick the module image (jimg.so) and tzdb.dat (tzdb.so) use.

    The appended names are NOT ELF, which is fine: scripts/scan_needed.py skips
    anything that is not an ELF before it looks for DT_NEEDED.

Usage:
    python scripts/prep_jdkconf.py            # build the tree
    python scripts/prep_jdkconf.py --check    # verify it matches the JDK
"""

import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import config  # noqa: E402

JDK = os.path.join(config.LIBS, "jdk21")
DEST = os.path.join(config.LIBS, "jdkhome")

# The subtrees of the JDK that <java.home> lookups reach into, given as path
# components so the same tuple is both the JDK-relative source and the
# java.home-relative destination. Order is not significant.
TREES = [
    ("conf",),
    ("lib", "security"),
]

SUFFIX = ".so"


def walk_files(root):
    """Every regular file under root, as paths relative to root (posix-ish)."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            out.append(os.path.relpath(full, root))
    return out


def build_plan():
    """[(source_path, destination_path)] for the whole tree."""
    plan = []
    for parts in TREES:
        src_root = os.path.join(JDK, *parts)
        if not os.path.isdir(src_root):
            raise SystemExit("!! not in the JDK: %s" % src_root)
        for rel in walk_files(src_root):
            src = os.path.join(src_root, rel)
            dst = os.path.join(DEST, *parts, rel + SUFFIX)
            plan.append((src, dst))
    return plan


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    check_only = "--check" in sys.argv
    plan = build_plan()

    if check_only:
        bad = 0
        for src, dst in plan:
            if not os.path.exists(dst) or sha256(src) != sha256(dst):
                print("  STALE  %s" % os.path.relpath(dst, config.PROJECT_ROOT))
                bad += 1
        extra = []
        if os.path.isdir(DEST):
            wanted = set(os.path.normpath(d) for _s, d in plan)
            for dirpath, _d, files in os.walk(DEST):
                for f in files:
                    p = os.path.normpath(os.path.join(dirpath, f))
                    if p not in wanted:
                        extra.append(p)
        for p in extra:
            print("  EXTRA  %s" % os.path.relpath(p, config.PROJECT_ROOT))
            bad += 1
        print()
        if bad:
            print("jdkhome: %d problem(s) -- re-run without --check" % bad)
            return 1
        print("jdkhome: %d file(s), all match the JDK" % len(plan))
        return 0

    # Rebuilt from scratch rather than merged. A stale file left behind by a
    # previous revision would be copied onto the device and would look exactly
    # like a current one -- the same "path did not change, contents did" trap
    # this project has hit before.
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)

    print("jdkhome: %s" % os.path.relpath(DEST, config.PROJECT_ROOT))
    total = 0
    for src, dst in plan:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        total += os.path.getsize(dst)
        print("  %-56s %8d B  %s"
              % (os.path.relpath(dst, DEST),
                 os.path.getsize(dst),
                 sha256(dst)[:16]))

    print()
    print("  %d file(s), %d bytes total" % (len(plan), total))
    print()
    print("Each name carries a trailing %r so hvigor will package it; the" % SUFFIX)
    print("launcher strips exactly one while copying. See the module docstring.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
