# -*- coding: utf-8 -*-
r"""Bring LWJGL into the HAP: the Java jars AND the native libraries.

WHY LWJGL IS NEEDED AT ALL
    The game jar does not contain LWJGL. Its Arc SDL3 backend calls the platform
    through org.lwjgl.opengl.* and org.lwjgl.sdl.*, and those classes come from
    somewhere else -- the launcher that previously ran this game supplied them
    from its own libraries directory, which is exactly why the game ran there and
    would not run here without this step.

    Measured on the packaged jar: zero entries under org/, and the SDL3 backend
    classes reference org/lwjgl/opengl/{GL11..GL43,GLCapabilities,EXTFramebufferObject}
    and org/lwjgl/sdl/*. So the dependency is real and external.

WHERE THE TWO HALVES GO, AND WHY THEY DIFFER
    The native libraries are real ELF shared objects and need no disguise, but
    they must sit in the app's executable area -- the sandbox is not executable.
    They go in a subdirectory of the bundle library area.

    The Java jars are not ELF at all. hvigor copies entry/libs/arm64-v8a/** into
    the HAP only for names ending in ".so", so they are renamed on the way in,
    exactly as the module image is (see prep_game.py). The JVM opens a class-path
    entry by content, not by name.

WHERE THE FILES COME FROM
    payload-src/lwjgl-ohos/, which holds the three Java jars and the two natives
    together. They were collected from a prebuilt HarmonyOS application that
    demonstrably runs this game on this platform, which makes them a known-good
    set rather than whatever a build server happens to produce. Every file is
    identified by SHA-1 below, so a substituted one is caught, not shipped.

WHY THE VERSION MATCH IS CHECKED AND NOT ASSUMED
    A Java jar and a native library from different LWJGL releases can look fine
    and fail at the first call, because the generated function tables are built
    from the library's symbol list. Both halves now come from one directory, but
    that directory is assembled by hand, so the script still refuses to proceed
    unless the jar's manifest says the version the natives were built for.

WHY THERE IS NO libSDL3.so HERE
    This script used to ship a third native, libSDL3.so, taken from the same
    application. That made two SDL3 libraries in one HAP: that copy under lwjgl/,
    and the one this project builds from entry/src/main/cpp/SDL/ at the top level
    of the bundle. org.lwjgl.librarypath lists the bundle before lwjgl/ (see
    opt_lwjglpath in launcher.c), and it was measured resolving to the bundle copy --
    "SAME instance as the launcher's" -- so the lwjgl/ copy was already
    unreachable by the loader and is not shipped any more. The two places that
    still mention lwjgl/libSDL3.so are diagnostics that stat or dlopen it and
    report the result; both were repointed at the bundle copy.

Usage:  python prep_lwjgl.py [--check]
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
LIBS = config.LIBS
NATIVE_DEST = os.path.join(LIBS, "lwjgl")        # real .so, executable area
JAVA_DEST = os.path.join(LIBS, "lwjgl-java")     # jars, renamed to .so

# One directory for both halves, so the version check below cannot be defeated by
# someone pointing the jars and the natives at different releases.
JAR_DIR = config.LWJGL_SRC

# The version the whole set must agree on. Arc's own build targets 3.4.2, and the
# natives collected for this platform are from that line.
WANT_VERSION = "3.4.2"

# source file name -> sha1. The destination name is the same: these are real
# shared objects and the loader looks them up by exactly these names.
NATIVES = {
    "liblwjgl.so":        "663e5cab870ac3427cbfbe01f93facbc260fa504",
    "liblwjgl_opengl.so": "f3661e892d4d2deb3aa574cab2e64c13b7ac6b4d",
}

# source file name -> (destination name, sha1)
JARS = {
    "lwjgl.jar":        ("lwjgl.so",        "cd7dd7a13abce9a2764364f58e138c6f99f50a7f"),
    "lwjgl-opengl.jar": ("lwjgl-opengl.so", "27698e706465a088d4c8eda34f98d69e5c8b32f7"),
    "lwjgl-sdl.jar":    ("lwjgl-sdl.so",    "96d577ef9b661fe4bb9bfb32fbb1de3ff34219cd"),
}


def sha1b(b):
    return hashlib.sha1(b).hexdigest()


def sha1f(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def write_verified(path, data, want_sha):
    """Write, then re-read from disk and hash -- the file that matters is the one
    that landed, not the one intended."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    got = sha1f(path)
    if got != want_sha:
        os.remove(path)
        return None, got
    return True, got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    bad = 0
    print("== 1. the version both halves must agree on: %s ==" % WANT_VERSION)
    mf = os.path.join(JAR_DIR, "lwjgl.jar")
    if not os.path.isfile(mf):
        print("FAIL missing %s" % mf)
        return 1
    with zipfile.ZipFile(mf) as z:
        m = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
    ver = ""
    for line in m.splitlines():
        if line.startswith("Specification-Version:"):
            ver = line.split(":", 1)[1].strip()
    print("   lwjgl.jar Specification-Version = %s" % (ver or "(absent)"))
    if ver != WANT_VERSION:
        print("FAIL the jars are not %s; the natives are. Refusing to mix them."
              % WANT_VERSION)
        return 1
    print()

    print("== 2. native libraries ==")
    for name, want in NATIVES.items():
        srcp = os.path.join(JAR_DIR, name)
        if not os.path.isfile(srcp):
            print("   %-22s MISSING source" % name)
            bad += 1
            continue
        data = open(srcp, "rb").read()
        got = sha1b(data)
        if got != want:
            print("   %-22s SHA1 MISMATCH  %s" % (name, got))
            bad += 1
            continue
        dst = os.path.join(NATIVE_DEST, name)
        if a.check:
            ok = os.path.isfile(dst) and sha1f(dst) == want
            print("   %-22s %9d  %s" % (name, len(data),
                                        "present" if ok else "ABSENT/DIFFERS"))
            if not ok:
                bad += 1
            continue
        res, got2 = write_verified(dst, data, want)
        print("   %-22s %9d  sha1=%s  %s"
              % (name, len(data), got2[:12], "OK" if res else "WRITE FAILED"))
        if not res:
            bad += 1
    print()

    print("== 3. the Java jars, renamed so hvigor will carry them ==")
    for src, (dstname, want) in JARS.items():
        srcp = os.path.join(JAR_DIR, src)
        if not os.path.isfile(srcp):
            print("   %-18s MISSING source" % src)
            bad += 1
            continue
        got = sha1f(srcp)
        if got != want:
            print("   %-18s SHA1 MISMATCH  %s" % (src, got))
            bad += 1
            continue
        data = open(srcp, "rb").read()
        dst = os.path.join(JAVA_DEST, dstname)
        if a.check:
            ok = os.path.isfile(dst) and sha1f(dst) == want
            print("   %-18s -> %-20s %s" % (src, dstname,
                                            "present" if ok else "ABSENT/DIFFERS"))
            if not ok:
                bad += 1
            continue
        res, got2 = write_verified(dst, data, want)
        print("   %-18s -> %-20s %9d  %s"
              % (src, dstname, len(data), "OK" if res else "WRITE FAILED"))
        if not res:
            bad += 1
    print()

    if bad:
        print("RESULT: FAIL (%d problem(s))" % bad)
        return 1
    print("RESULT: %s" % ("PASS (check only)" if a.check else "PASS"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
