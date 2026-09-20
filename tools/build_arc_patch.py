# -*- coding: utf-8 -*-
r"""Recompile the patched Arc classes that go into the game jar.

WHY THIS IS A SCRIPT WITH GATES
    patch_mindustry.py replaces arc/backend/sdl/** in the game jar with whatever
    is sitting in %TEMP%\arcbuild\sdl3. Nothing checks that those class files were
    built from the sources that are on disk now -- so editing Arc and forgetting
    to rebuild produces a jar that looks updated and is not. That is the same
    shape of failure as the library that was "rebuilt" without being re-linked,
    and the jar's hash would not catch it either, because the hash is taken after
    the fact.

    So: the source is checked for the change, the compile is required to succeed,
    and the produced class is checked for the property name that only the new
    code contains.

Usage:  python build_arc_patch.py
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")

ARC = r"C:\Users\Haohandc\Arc"
SRC = os.path.join(ARC, "backends", "backend-sdl3", "src",
                   "arc", "backend", "sdl", "SdlApplication.java")
# The touch/pinch patch lives here. Recompiled by the same run, and gated the
# same way -- see MARKER3/MARKER4 and the note about why one marker is not
# enough for a file that gets edited over time.
SRC_INPUT = os.path.join(ARC, "backends", "backend-sdl3", "src",
                         "arc", "backend", "sdl", "SdlInput.java")
# Decouples the file browser's root from the game's data directory, so "import
# save" can open somewhere the player can actually put a file.
SRC_FILES = os.path.join(ARC, "backends", "backend-sdl3", "src",
                         "arc", "backend", "sdl", "SdlFiles.java")
SRC_ROOT = os.path.join(ARC, "backends", "backend-sdl3", "src")
CORE_ROOT = os.path.join(ARC, "arc-core", "src")

LWJGL = r"<path to the lwjgl-ohos source dir>"
ARCBUILD = os.path.join(os.environ.get("TEMP", tempfile.gettempdir()), "arcbuild")
OUT_SDL3 = os.path.join(ARCBUILD, "sdl3", "arc", "backend", "sdl")

JAVAC = r"C:\Program Files\Java\jdk-17\bin\javac.exe"

# Present in the new code, absent from the old. Checking the compiled class for it
# is what distinguishes "recompiled" from "the previous class files are still
# sitting there".
MARKER = b"arc.sdl.glEs"
# Both properties must be in the compiled class. Checking one would pass while the
# other edit was never picked up, which is the failure this whole script exists to
# prevent -- and they are edited at different times, so "recompiled since the last
# change I remember" is not a safe assumption.
MARKER2 = b"arc.sdl.mobile"

# Present in the new SdlInput code, absent from the old (which ignored
# SDL_EVENT_FINGER_* entirely and answered every pointer query with pointer 0).
# These are field names, so they land in the class constant pool through the
# field references the new methods make.
MARKER3 = b"MAX_TOUCH_POINTERS"
MARKER4 = b"pointerJustDown"

# Present in the new SdlFiles code, absent from the old (the browser root used
# to be inseparable from the game data path).
MARKER5 = b"arc.sdl.chooserPath"
MARKER6 = b"chooserPath"

PRODUCES = ["SdlApplication.class",
            "SdlApplication$SdlError.class",
            "SdlApplication$1.class",
            "SdlInput.class"]


def main():
    # Each source is checked for its own markers, against its own contents. A
    # marker found in the wrong file would prove nothing, which is why these are
    # paired up rather than pooled into one list.
    for path, markers in ((SRC, (MARKER, MARKER2)), (SRC_INPUT, (MARKER3, MARKER4)),
                          (SRC_FILES, (MARKER5, MARKER6))):
        if not os.path.isfile(path):
            print("FAIL missing %s" % path)
            return 1
        src_text = open(path, encoding="utf-8", errors="replace").read()
        for marker in markers:
            name = marker.decode()
            if name not in src_text:
                print("FAIL %s does not contain the change (%s)."
                      % (os.path.basename(path), name))
                print("     Edit it first.")
                return 1
            print("%s carries the change: %s" % (os.path.basename(path), name))

    jars = [os.path.join(LWJGL, f) for f in sorted(os.listdir(LWJGL))
            if f.endswith(".jar")]
    cp = os.pathsep.join([os.path.join(ARCBUILD, "core"),
                          os.path.join(ARCBUILD, "sdl3")] + jars)

    with tempfile.TemporaryDirectory() as tmp:
        cmd = [JAVAC, "--release", "17", "-nowarn", "-implicit:none",
               "-encoding", "UTF-8",
               "-cp", cp,
               "-sourcepath", os.pathsep.join([SRC_ROOT, CORE_ROOT]),
               "-d", tmp, SRC, SRC_INPUT, SRC_FILES]
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode != 0:
            print("FAIL javac")
            print(r.stdout)
            print(r.stderr)
            return 1
        out = (r.stdout or "") + (r.stderr or "")
        if out.strip():
            print(out)

        # Both classes are read back from what javac actually wrote, with their
        # own markers. Bytecode major 61 (Java 17) is checked per class, because
        # a class compiled for the wrong release would only fail on the device.
        for cls, markers in (("SdlApplication.class", (MARKER, MARKER2)),
                             ("SdlInput.class", (MARKER3, MARKER4)),
                             ("SdlFiles.class", (MARKER5, MARKER6))):
            produced = os.path.join(tmp, "arc", "backend", "sdl", cls)
            if not os.path.isfile(produced):
                print("FAIL javac produced no %s" % cls)
                return 1
            blob = open(produced, "rb").read()
            major = struct.unpack(">H", blob[6:8])[0]
            if major != 61:
                print("FAIL %s bytecode major is %d, the jar's classes are 61"
                      % (cls, major))
                return 1
            for marker in markers:
                if marker not in blob:
                    print("FAIL the compiled %s does not contain %r" % (cls, marker))
                    return 1
            print("compiled: %s major=61, contains %s"
                  % (cls, ", ".join(repr(m.decode()) for m in markers)))

        os.makedirs(OUT_SDL3, exist_ok=True)
        installed = 0
        for dp, _d, fs in os.walk(os.path.join(tmp, "arc", "backend", "sdl")):
            for f in fs:
                if (f.startswith("SdlApplication") or f.startswith("SdlInput")
                        or f.startswith("SdlFiles")):
                    src_p = os.path.join(dp, f)
                    dst_p = os.path.join(OUT_SDL3, f)
                    shutil.copyfile(src_p, dst_p)
                    installed += 1
        print("installed %d class file(s) into %s" % (installed, OUT_SDL3))

    # Verify from the installed copy, not from the temporary one.
    for name in PRODUCES:
        p = os.path.join(OUT_SDL3, name)
        if not os.path.isfile(p):
            print("FAIL %s was not installed" % name)
            return 1
    for cls, marker in (("SdlApplication.class", MARKER), ("SdlInput.class", MARKER3),
                        ("SdlFiles.class", MARKER5)):
        installed_blob = open(os.path.join(OUT_SDL3, cls), "rb").read()
        if marker not in installed_blob:
            print("FAIL the installed %s lost the marker" % cls)
            return 1
    print("installed copies verified")
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
