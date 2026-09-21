# -*- coding: utf-8 -*-
r"""Every path the build needs, in one place.

WHY THIS FILE EXISTS
    The toolchain used to name its inputs as literals inside each script. That
    made a fresh checkout depend on the original author's directory layout --
    which is not something a public repository can ask of anyone -- and it meant
    one fact ("where does the game jar live") was written down in four files and
    could drift between them.

    Everything here is overridable from the environment, so a different machine
    only has to set variables rather than edit scripts. The defaults point at
    payload-src/, which is where the inputs are expected to sit (see
    payload-src/README.md).

WHAT IS NOT HERE
    Scratch directories (the Arc build tree, the extracted natives) stay local to
    the scripts that own them: they are recreated on every run and nobody needs
    to configure them.

HOW TO SEE WHAT IT RESOLVES TO
    python scripts/config.py            print each path and whether it exists
    python scripts/config.py --json     the same, as JSON, for scripts

NAMING
    Environment variables use the ARK_ prefix so they cannot collide with
    anything else. DEVECO_SDK_HOME is the exception and is read as-is, because
    hvigor and DevEco already define it and build.sh exports it -- honouring the
    existing name means the prep scripts inherit the same SDK when they are run
    from deploy.sh.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)


def _env(name, default):
    """Environment override, or the default. An empty variable counts as unset:
    'export ARK_ARC_SRC=' in a shell should not produce the empty path."""
    v = os.environ.get(name)
    return v if v else default


# ---------------------------------------------------------------------------
# DevEco Studio / HarmonyOS SDK
# ---------------------------------------------------------------------------
# Studio root contains sdk/ and tools/; the SDK root contains default/, which
# contains the OpenHarmony native toolchain. Keeping the two separate means the
# node and hvigor paths below do not have to be configured independently.
DEVECO_STUDIO = _env("ARK_DEVECO_STUDIO", r"E:\Program Files\DevEco Studio")
DEVECO_SDK_HOME = _env("DEVECO_SDK_HOME", os.path.join(DEVECO_STUDIO, "sdk"))

NATIVE_SDK = _env("ARK_NATIVE_SDK",
                  os.path.join(DEVECO_SDK_HOME, "default", "openharmony", "native"))
SYSROOT = os.path.join(NATIVE_SDK, "sysroot")

CLANG = os.path.join(NATIVE_SDK, "llvm", "bin", "clang.exe")
LLVM_BIN = os.path.join(NATIVE_SDK, "llvm", "bin")
READELF = os.path.join(LLVM_BIN, "llvm-readelf.exe")

# device tooling -- one level up from native/ inside the same SDK
HDC = os.path.join(DEVECO_SDK_HOME, "default", "openharmony", "toolchains", "hdc.exe")

NODE = _env("ARK_NODE", os.path.join(DEVECO_STUDIO, "tools", "node", "node.exe"))
HVIGOR = _env("ARK_HVIGOR",
              os.path.join(DEVECO_STUDIO, "tools", "hvigor", "bin", "hvigorw.js"))

# ---------------------------------------------------------------------------
# Host tools
# ---------------------------------------------------------------------------
# javac/jar are not on PATH on the machine this was developed on, so the JDK is
# named explicitly. Only the Arc patches and the one-class helper jar need it.
JAVA_HOME = _env("ARK_JAVA_HOME", r"C:\Program Files\Java\jdk-17")
JAVAC = _env("ARK_JAVAC", os.path.join(JAVA_HOME, "bin", "javac.exe"))
JAR = _env("ARK_JAR", os.path.join(JAVA_HOME, "bin", "jar.exe"))

PYTHON = _env("ARK_PYTHON", sys.executable or "python")

TMP = os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"

# ---------------------------------------------------------------------------
# Payload inputs -- what the prep_*.py scripts consume
# ---------------------------------------------------------------------------
PAYLOAD_SRC = _env("ARK_PAYLOAD_SRC", os.path.join(PROJECT_ROOT, "payload-src"))

# The upstream Mindustry release jar. Replaceable by anyone: the patch script
# identifies the build by content, not by name.
UPSTREAM_JAR = _env("ARK_UPSTREAM_JAR", os.path.join(PAYLOAD_SRC, "Mindustry.jar"))

# Produced from UPSTREAM_JAR by patch_mindustry.py, then by build_variants.py.
# Kept under the same directory so the chain can be re-run in place.
PATCHED_JAR = _env("ARK_PATCHED_JAR", os.path.join(PAYLOAD_SRC, "mindustry-1.0.jar"))
GAME_JAR = _env("ARK_GAME_JAR", os.path.join(PAYLOAD_SRC, "mindustry-1.0-audio.jar"))

# Arc's sources, for the three classes that are recompiled into the jar.
ARC_SRC = _env("ARK_ARC_SRC", r"C:\Users\Haohandc\Arc")

# LWJGL: the Java jars and the natives, all in one directory.
LWJGL_SRC = _env("ARK_LWJGL_SRC", os.path.join(PAYLOAD_SRC, "lwjgl-ohos"))

# The trimmed JDK the runtime is built from: its lib/server/libjvm.so is the JVM
# that gets shipped, and its lib/libcxxabi_shim.so is what the replacement shim
# links against.
JDK_SLIM = _env("ARK_JDK_SLIM", os.path.join(PAYLOAD_SRC, "jdk21slim"))
SRC_JVM = _env("ARK_SRC_JVM", os.path.join(JDK_SLIM, "lib", "server", "libjvm.so"))
SRC_CXXABI_SHIM = _env("ARK_SRC_SHIM", os.path.join(JDK_SLIM, "lib", "libcxxabi_shim.so"))

# ---------------------------------------------------------------------------
# Outputs inside the project
# ---------------------------------------------------------------------------
CPP = os.path.join(PROJECT_ROOT, "entry", "src", "main", "cpp")
LIBS = os.path.join(PROJECT_ROOT, "entry", "libs", "arm64-v8a")
OUT_DIR = os.path.join(PROJECT_ROOT, "entry", "build", "default", "outputs", "default")

# The three things that have to agree with entry/build-profile.json5's
# artifactName and AppScope/app.json5's versionName. verify_hap.py reads the
# artifact name back out of the built package and compares, so a bump applied to
# one of the three and not the others fails the build rather than producing a
# file whose name lies about its contents.
APP_NAME = "MindustryArk"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
# versionName and artifactName have DIFFERENT allowed characters, which is the
# trap here -- both were measured by building, not read off a document:
#
#   versionName   must start with a digit or a dot (hvigor's schema pattern is
#                 ^[0-9.]+|(?=.*[{])(?=.*[}])[0-9a-zA-Z_.{}]+$, whose first
#                 branch is a PREFIX match, so almost anything after the first
#                 character passes -- including spaces and exclamation marks).
#                 A leading "v" is rejected.
#   artifactName  ^[\da-zA-Z0-9._-]+$ -- no spaces, no "+".
#
# So the leading "v" belongs to the release tag and the artifact name, never to
# the version name, and the safe alphabet for both is digits, letters, dot,
# underscore and hyphen.
APP_VERSION = "0.2.0-beta.2"

# versionCode is the integer the platform actually orders installs by.
#
#   base = major*1000000 + minor*10000 + patch*100
#   then +1..98 for a pre-release, +99 for the final release of that version
#
# which keeps the ordering a semver reader expects (a beta sorts below its own
# final release) while staying a plain int32, which is all the field accepts:
# measured, 0 <= versionCode <= 2147483647.
#
#   0.1.0-beta1 -> 10001        0.1.0-beta2 -> 10002        0.1.0 -> 10099
#   0.1.1-beta1 -> 10101        0.2.0-beta1 -> 20001        1.0.0 -> 1000099
#
# The pre-release number may be written with or without a dot -- 0.2.0-beta1 and
# 0.2.0-beta.1 both give 20001, since neither the spelling nor the letters enter
# the arithmetic. This project moved to the dotted form at 0.2.0.
#
# version_code_for() below derives it, and the module checks its own constant
# against the derivation, so a version bump that forgets the code fails on
# import rather than shipping an install that cannot replace the previous one.
VERSION_CODE = 20002


def version_code_for(version):
    """versionCode for a version string, per the rule above.

    Handles the only shapes this project uses: M[.m[.p]][-pre[.]N]. Anything else
    raises rather than guessing -- a wrong versionCode is invisible until an
    install silently refuses to upgrade, which is a bad way to find out.

    The dot before the pre-release number is OPTIONAL, and deliberately so. The
    pre-release part is not read for the code -- only the digit after it is -- so
    `beta.1` and `beta1` are the same version as far as install ordering goes and
    both must parse. Making the dot required would have turned every older version
    string, including ones already released, into a hard failure.

    (The difference between the two spellings is real but not ours to enforce:
    semver reads `beta.1` as two identifiers and `beta1` as one, and only
    identifiers that are purely numeric compare numerically. That matters when a
    project reaches `beta10`; it does not change the ordering here, which comes
    from versionCode.)
    """
    import re

    m = re.fullmatch(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([a-z]+)\.?(\d+))?", version)
    if not m:
        raise ValueError("unrecognised version %r; expected M[.m[.p]][-pre[.]N]"
                         % version)
    major = int(m.group(1))
    minor = int(m.group(2) or 0)
    patch = int(m.group(3) or 0)
    pre = int(m.group(5) or 0)
    if pre > 98:
        raise ValueError("pre-release number %d is too large (max 98; 99 means "
                         "the final release)" % pre)
    return major * 1000000 + minor * 10000 + patch * 100 + (pre if pre else 99)


if version_code_for(APP_VERSION) != VERSION_CODE:
    raise SystemExit(
        "FAIL VERSION_CODE %d does not match %s (%d). Fix one of them:\n"
        "     APP_VERSION = %r\n"
        "     VERSION_CODE = %d"
        % (VERSION_CODE, APP_VERSION, version_code_for(APP_VERSION),
           APP_VERSION, version_code_for(APP_VERSION)))

ARTIFACT_NAME = "%s-v%s" % (APP_NAME, APP_VERSION)
BUNDLE_NAME = "com.haohandc.mindustryark"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def sha1f(path):
    """SHA-1 of a file on disk. Streamed, because several inputs are >100 MB."""
    import hashlib
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def require(path, what):
    """Fail loudly and early. A missing input that a script silently works around
    is how a build ends up shipping the previous artifact -- which this project
    has done twice."""
    if not os.path.exists(path):
        raise SystemExit("FAIL missing %s\n     %s\n"
                         "     set the matching ARK_* variable, or see "
                         "payload-src/README.md" % (what, path))
    return path


# The set reported by --json / printed below. Grouped so a human can scan it.
GROUPS = [
    ("DevEco / SDK", [
        ("DevEco Studio", DEVECO_STUDIO),
        ("SDK home", DEVECO_SDK_HOME),
        ("native SDK", NATIVE_SDK),
        ("hdc", HDC),
        ("node", NODE),
        ("hvigor", HVIGOR),
    ]),
    ("Host tools", [
        ("javac", JAVAC),
        ("jar", JAR),
        ("python", PYTHON if os.path.sep in PYTHON else "(from PATH: %s)" % PYTHON),
        ("temp", TMP),
    ]),
    ("Payload inputs", [
        ("upstream jar", UPSTREAM_JAR),
        ("patched jar", PATCHED_JAR),
        ("game jar (pinned)", GAME_JAR),
        ("Arc sources", ARC_SRC),
        ("LWJGL", LWJGL_SRC),
        ("JDK (slim)", JDK_SLIM),
    ]),
    ("Outputs", [
        ("native sources", CPP),
        ("payload dest", LIBS),
        ("hap output", OUT_DIR),
    ]),
]


def _main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    if "--json" in sys.argv:
        import json
        print(json.dumps({k: v for _, items in GROUPS for k, v in items}, indent=2))
        return 0

    print("project root: %s" % PROJECT_ROOT)
    print()
    missing = 0
    for title, items in GROUPS:
        print("[%s]" % title)
        for label, path in items:
            real = path if os.path.sep in path else ""
            if not real:
                print("  %-20s %s" % (label, path))
                continue
            ok = os.path.exists(path)
            if not ok:
                missing += 1
            # Inputs that must exist versus outputs that are expected to be
            # absent on a clean checkout -- reporting both as FAIL would train
            # the reader to ignore the word.
            expected = title != "Outputs"
            mark = "ok" if ok else ("MISSING" if expected else "not yet built")
            print("  %-20s %-4s %s" % (label, mark, path))
        print()

    if missing:
        print("%d input(s) missing -- see payload-src/README.md" % missing)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
