# -*- coding: utf-8 -*-
r"""Place the game jar inside the HAP's library area, under a *.so name.

WHY A *.so NAME
    hvigor copies entry/libs/arm64-v8a/** into the HAP only for names ending in
    ".so"; content is never inspected. Measured on the built HAP: the 140 MB
    module image ships as jdk21/lib/jimg.so and the real JVM as libjvm_real.so,
    both at exactly their project sizes, while everything under jdk21/conf/ was
    dropped silently. A jar is no more of an ELF than the module image is, so it
    takes the same road. The JVM opens a class-path entry by content, not by
    name, so the extension is invisible to it.

WHY A SUBDIRECTORY
    The top-level names in libs/arm64-v8a/ are the ones the platform treats as
    the app's native libraries. A jar is not one. Placing it one level down
    matches where the module image already lives and is known not to be mapped.

WHY THIS IS A SCRIPT AND NOT A COPY COMMAND
    This file is derived from a versioned artifact that was itself the product of
    a multi-stage build (patch -> repack -> variant). This project has already
    shipped a wrong jar once, by re-running an upstream stage and forgetting a
    downstream one, and a stale library once more. So the source is identified by
    its SHA-1, not by its file name, and the result is verified after the copy.
    A mismatch aborts without touching the destination.

Usage:  python prep_game.py [--check]
        --check  verify only; do not copy
"""

import argparse
import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

# This file lives in scripts/, so the project root is one level up.
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)

SRC = r"E:\User\Desktop\mindustry-ohos\mindustry-1.0-audio.jar"

# The pinned variant: the audio-fixed build (SDL3/OHAudio backend, providerall GL
# dispatch) PLUS the OpenGL ES profile request in Arc's SDL backend, which
# OpenHarmony needs because it has no desktop GL at all. Built by
# build_arc_patch.py -> patch_mindustry.py -> build_variants.py, each of which
# refuses to run on a stale input.
SRC_SHA1 = "732ead5a45fa4d4d4a595e23e65ba952d86cbed3"

DEST = os.path.join(PROJECT_ROOT,
                    "entry", "libs", "arm64-v8a", "game", "mindustry.so")


def sha1_of(path, chunk=1 << 20):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    if not os.path.isfile(SRC):
        print("FAIL source jar is missing: %s" % SRC)
        return 1

    actual = sha1_of(SRC)
    print("source : %s" % SRC)
    print("size   : %d" % os.path.getsize(SRC))
    print("sha1   : %s" % actual)
    if actual != SRC_SHA1:
        print("FAIL this is NOT the pinned artifact.")
        print("     expected %s" % SRC_SHA1)
        print("     Rebuild it through build_variants.py rather than using it as is.")
        return 1
    print("       -> matches the pinned variant")

    if a.check:
        if os.path.isfile(DEST):
            ok = sha1_of(DEST) == SRC_SHA1
            print("dest   : present, %s" % ("matches" if ok else "DIFFERS"))
            return 0 if ok else 1
        print("dest   : ABSENT")
        return 1

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    shutil.copyfile(SRC, DEST)

    # Verify what actually landed on disk, not what we intended to write.
    if sha1_of(DEST) != SRC_SHA1:
        print("FAIL the copy does not match the source; removing it")
        os.remove(DEST)
        return 1

    print("dest   : %s" % DEST)
    print("       : %d bytes, sha1 verified" % os.path.getsize(DEST))
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
