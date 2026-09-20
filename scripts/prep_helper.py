# -*- coding: utf-8 -*-
r"""Compile the launcher's Java helper and install it into the HAP.

WHY A JAR, AND WHY A SEPARATE ONE
    The helper has to be on the class path, and a class path entry that is a
    directory would not survive packaging: hvigor copies only files whose name
    ends in ".so", and renaming NativeLoader.class to .so would stop the JVM
    finding it by name. A single-file jar does survive, under a .so name, for the
    same reason the game jar does.

    It is a separate jar rather than an extra class inside the game jar so that
    the game jar remains byte-for-byte the artifact that was verified on device.
    Its SHA-1 is pinned in prep_game.py and checked again in verify_hap.py, and
    injecting into it would quietly invalidate both.

WHY IT IS COMPILED RATHER THAN COMMITTED AS A .class
    A checked-in binary class file cannot be reviewed, and a stale one would not
    announce itself -- it would just behave like the source used to. Compiling
    from helper-src/ on every prep run keeps the two in step, and the script
    verifies the class is actually inside the jar it produced.

Usage:  python prep_helper.py [--check]
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
# this file lives in scripts/, so the project root is one level up
PROJECT_ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(PROJECT_ROOT, "helper-src")
ENTRY = "com/haohandc/launcher/NativeLoader.class"
DEST_DIR = os.path.join(PROJECT_ROOT, "entry", "libs", "arm64-v8a", "launcher")
DEST = os.path.join(DEST_DIR, "helper.so")

JAVAC = r"C:\Program Files\Java\jdk-17\bin\javac.exe"
JAR = r"C:\Program Files\Java\jdk-17\bin\jar.exe"


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

    if a.check:
        if not os.path.isfile(DEST):
            print("   %s ABSENT" % DEST)
            return 1
        with zipfile.ZipFile(DEST) as z:
            ok = ENTRY in z.namelist()
        print("   %s  %d bytes  %s"
              % (DEST, os.path.getsize(DEST), "OK" if ok else "CLASS MISSING"))
        return 0 if ok else 1

    for tool in (JAVAC, JAR):
        if not os.path.isfile(tool):
            print("FAIL missing %s" % tool)
            return 1
    if not os.path.isdir(SRC_DIR):
        print("FAIL missing %s" % SRC_DIR)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        classes = os.path.join(tmp, "classes")
        os.makedirs(classes)
        sources = []
        for dp, _d, fs in os.walk(SRC_DIR):
            sources += [os.path.join(dp, f) for f in fs if f.endswith(".java")]
        if not sources:
            print("FAIL no .java under %s" % SRC_DIR)
            return 1

        # -source/-target 17: the runtime is 21, but the game's classes are 17 and
        # there is no reason for the helper to demand more than the game does.
        cmd = [JAVAC, "-source", "17", "-target", "17",
               "-encoding", "UTF-8", "-nowarn", "-d", classes] + sources
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode != 0:
            print("FAIL javac")
            print(r.stdout)
            print(r.stderr)
            return 1
        if r.stdout.strip() or r.stderr.strip():
            print(r.stdout + r.stderr)

        produced = os.path.join(classes, *ENTRY.split("/"))
        if not os.path.isfile(produced):
            print("FAIL javac produced no %s" % ENTRY)
            return 1

        jar_tmp = os.path.join(tmp, "helper.jar")
        r = subprocess.run([JAR, "cf", jar_tmp, "-C", classes, "."],
                           capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode != 0:
            print("FAIL jar")
            print(r.stdout + r.stderr)
            return 1

        # Verify the jar really carries the class, rather than trusting jar(1).
        with zipfile.ZipFile(jar_tmp) as z:
            if ENTRY not in z.namelist():
                print("FAIL %s is not in the produced jar" % ENTRY)
                return 1

        os.makedirs(DEST_DIR, exist_ok=True)
        shutil.copyfile(jar_tmp, DEST)
        with zipfile.ZipFile(DEST) as z:
            if ENTRY not in z.namelist():
                os.remove(DEST)
                print("FAIL the installed copy lost %s" % ENTRY)
                return 1

    print("   %s" % DEST)
    print("   %d bytes, sha1 %s" % (os.path.getsize(DEST), sha1f(DEST)[:12]))
    print("   contains %s" % ENTRY)
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
