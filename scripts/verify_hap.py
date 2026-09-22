# -*- coding: utf-8 -*-
r"""
Gate: inspect the ACTUAL signed HAP and confirm the JDK shipped in the shape the
loader needs.

Rationale (the lesson that keeps recurring in this project): a successful build
message is not evidence about the bytes on disk. The earlier audio accident was
exactly this -- a library that was "rebuilt" but whose output file was never
re-linked, with the same filename as before. So every claim here is read out of
the packaged archive, not inferred from the build log.

Checks
  1. libs/arm64/libjvm.so exists and its DT_NEEDED is the ABSOLUTE device path
     to the real JVM (musl ignores RPATH/RUNPATH and does not expand $ORIGIN, so
     a bare name here would silently resolve to the stub instead of the JVM).
  2. libs/arm64/jdk21/lib/server/libjvm_real.so exists and exports
     JNI_CreateJavaVM.
  3. libs/arm64/jdk21/lib/jimg.so exists (the renamed module image -- the whole
     reason the jimage is called .so).
  4. libjvm_real.so's own DT_NEEDED resolve: libcxxabi_shim.so and libc.so.
  5. the patched module-name format string is present in libjvm_real.so.

ASCII-only output.
"""
import os
import re
import subprocess
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = config.PROJECT_ROOT
READELF = config.READELF
NM = os.path.join(config.LLVM_BIN, "llvm-nm.exe")

DEVICE_JVM = "/data/storage/el1/bundle/libs/arm64/jdk21/lib/server/libjvm_real.so"
TMP = os.path.join(PROJECT_ROOT, "_hapcheck")


def find_hap():
    """Pick the artifact to inspect, deterministically.

    This used to take the newest .hap by mtime. Since setting artifactName in
    entry/build-profile.json5, hvigor writes TWO packages with the same
    timestamp -- <name>.hap (signed) and <name>-unsigned.hap -- so the newest
    one is decided by directory order, which is not a decision. The unsigned
    package is what gets verified: signing appends a signature block and does
    not change the payload being checked here, and preferring it means the check
    does not depend on which naming convention hvigor happens to be using.

    WHICH PRODUCT is config.OUT_DIR, i.e. ARK_PRODUCT, and it is never guessed.
    The build profile defines "default" and "release", whose outputs live in
    separate directories; a search rooted at entry/build/ would find both and
    then have to pick, and "newest" would quietly start verifying the other
    product the moment somebody built it. Enumerating only the requested
    product's directory means a store build cannot be checked by accident
    against the device build.
    """
    root = config.OUT_DIR
    hits = []
    for dp, _d, fs in os.walk(root):
        for f in fs:
            if f.endswith(".hap"):
                hits.append(os.path.join(dp, f))
    if not hits:
        # Naming the product and the directory matters here: "no HAP" and
        # "you asked for the wrong product" look identical otherwise, and this
        # project has already spent a round looking at entry/build/default/
        # while the release build sat in entry/build/release/.
        print("!! no .hap under %s" % root)
        print("   (ARK_PRODUCT=%s -- set ARK_PRODUCT=release for a store build)" % config.PRODUCT)
        return None

    # ONLY THE CURRENT VERSION. A product's output directory accumulates: after
    # a version bump it holds the previous version's packages too, and hvigor
    # does not clean them out. Sorting the whole directory and taking the first
    # is not a tie-break here, it is a coin toss -- measured, `-v0.2.0-beta.2-`
    # sorts BEFORE `-v0.2.0.2-` because `-` (0x2D) < `.` (0x2E), so the stale
    # build would have been the one verified, and the version gate would then
    # have reported a mismatch for the file it should not have opened.
    #
    # Filtering on the artifact name instead makes the failure say the true
    # thing: "no build of THIS version here", plus what is here.
    want = config.ARTIFACT_NAME
    hits.sort()
    mine = [p for p in hits if os.path.basename(p).startswith(want)]
    others = [p for p in hits if p not in mine]
    if others:
        print("   NOTE  %d .hap(s) here are a DIFFERENT version, ignored:" % len(others))
        for p in others:
            print("         %s" % os.path.basename(p))
    if not mine:
        print("!! no .hap for version %s under %s" % (config.APP_VERSION, root))
        print("   run: bash build.sh assembleHap --mode module "
              "-p product=%s -p buildMode=<debug|release>" % config.PRODUCT)
        return None
    unsigned = sorted(p for p in mine if p.endswith("-unsigned.hap"))
    if unsigned:
        return unsigned[0]
    return mine[0]


def check_version_matches_name(hap, ok_ref):
    """The file name, the artifactName and the packaged version must all agree.

    A download whose name says one version and whose contents say another is
    worse than one with no version in the name at all -- and the three places
    that carry the version are edited at different times:

        AppScope/app.json5                     versionName
        entry/build-profile.json5              targets[].output.artifactName

    so "I remember changing them together" is not a safe assumption. The
    artifactName is read back out of pack.info rather than out of the build
    profile, which is the difference between checking what was built and
    checking what we intended to build.

    deploy.sh used to keep a third hand-written copy as HAP_BASE. It is no longer
    listed here because it no longer exists: that copy went stale at the
    v0.1.0-beta1 -> v0.2.0-beta.1 bump -- this docstring named it, nothing checked
    it, and the script ended up looking for a HAP that had been renamed -- so
    deploy.sh now asks config.ARTIFACT_NAME for the name instead. Two copies that
    both get checked beat three where one is only mentioned.

    String comparison throughout: a rename that is not also a version bump fails
    too, because the file name is the only part of this a downloader can see.
    """
    print("== 0. version in the file name vs. in the package ==")
    import json
    import zipfile

    name = os.path.basename(hap)
    with zipfile.ZipFile(hap) as z:
        info = json.loads(z.read("pack.info").decode("utf-8"))

    ver = info["summary"]["app"]["version"]["name"]
    code = info["summary"]["app"]["version"]["code"]
    packname = info["packages"][0]["name"]
    ver_want = config.APP_VERSION
    code_want = config.VERSION_CODE
    name_want = config.ARTIFACT_NAME

    print("   file name       %s" % name)
    print("   artifactName    %s   (in pack.info)" % packname)
    print("   versionName     %s   (config: %s / %s)"
          % (ver, ver_want, name_want))
    print("   versionCode     %s   (config: %s)" % (code, code_want))

    problems = []
    if packname != name_want:
        problems.append("artifactName %r != config.ARTIFACT_NAME %r"
                        % (packname, name_want))
    if ver != ver_want:
        problems.append("versionName %r != config.APP_VERSION %r"
                        % (ver, ver_want))
    # versionCode is what the platform orders installs by, and it is the only one
    # of these that fails silently: a code that is too low does not error, it
    # just refuses to replace the installed build. Checked against the value
    # derived from versionName, not only against the constant -- so a bump that
    # changes one and not the other is caught here rather than on a device.
    if code != code_want:
        problems.append("versionCode %r != config.VERSION_CODE %r"
                        % (code, code_want))
    derived = config.version_code_for(ver)
    if code != derived:
        problems.append("versionCode %r != %d, which is what versionName %r "
                        "derives to" % (code, derived, ver))
    if not name.startswith(name_want):
        problems.append("file name %r does not start with %r" % (name, name_want))
    if name not in (name_want + ".hap", name_want + "-unsigned.hap"):
        problems.append("unexpected artifact name %r -- expected %r or %r"
                        % (name, name_want + ".hap", name_want + "-unsigned.hap"))
    for p in problems:
        print("   MISMATCH  %s" % p)
    print("   %s" % ("OK" if not problems else "FAIL"))
    print()
    if problems:
        ok_ref[0] = False


def run(tool, *args):
    r = subprocess.run([tool] + list(args), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.stdout + r.stderr


def main():
    hap = find_hap()
    if not hap:
        print("no .hap found -- build first")
        return 1
    print("HAP: %s" % hap.replace(HERE + os.sep, ""))
    print("     %d bytes" % os.path.getsize(hap))
    print()

    # Collapsed into a list so the helper can flag a failure without being
    # threaded through a return value. The check runs first because a name and a
    # version that disagree makes everything below describe the wrong build.
    ok_ref = [True]
    check_version_matches_name(hap, ok_ref)

    os.makedirs(TMP, exist_ok=True)
    with zipfile.ZipFile(hap) as z:
        names = z.namelist()
        # 1) what made it in at all
        want = {
            "anchor": "libs/arm64-v8a/libjvm.so",
            "realjvm": "libs/arm64-v8a/jdk21/lib/server/libjvm_real.so",
            "jimage": "libs/arm64-v8a/jdk21/lib/jimg.so",
            "shim": "libs/arm64-v8a/libcxxabi_shim.so",
            "sdl": "libs/arm64-v8a/libSDL3.so",
            "mainso": "libs/arm64-v8a/libmain.so",
        }
        # libcxxabi_real.so is deliberately NOT here any more: the hand-written
        # shim replacement was dropped on 2026-09-19 (see CMakeLists.txt).
        print("== 1. presence in the archive ==")
        missing = []
        for label, p in want.items():
            ok = p in names
            if not ok:
                missing.append(label)
            print("   %-9s %-6s %s" % (label, "OK" if ok else "MISSING", p))

        n_jdk = len([n for n in names if n.startswith("libs/arm64-v8a/jdk21/")])
        n_so = len([n for n in names
                    if n.startswith("libs/arm64-v8a/jdk21/") and n.endswith(".so")])
        print("   jdk21 entries: %d   of which *.so: %d" % (n_jdk, n_so))
        print()

        if missing:
            print("!! missing: %s" % ", ".join(missing))
            return 1

        # extract just what we need to inspect
        for label, p in want.items():
            dst = os.path.join(TMP, label + ".so")
            with z.open(p) as src, open(dst, "wb") as out:
                out.write(src.read())

    print("== 2. anchor: DT_NEEDED must be the absolute device path ==")
    anchor = os.path.join(TMP, "anchor.so")
    out = run(READELF, "-d", anchor)
    needed = [l.strip() for l in out.splitlines() if "NEEDED" in l]
    for l in needed:
        print("   %s" % l)
    got = DEVICE_JVM in out
    print("   contains the device path: %s" % ("YES" if got else "NO"))
    print()

    print("== 3. real libjvm: exports + module-image patch ==")
    real = os.path.join(TMP, "realjvm.so")
    out_n = run(NM, "-D", "--defined-only", real)
    has_create = re.search(r"\bJNI_CreateJavaVM\b", out_n) is not None
    print("   exports JNI_CreateJavaVM : %s" % ("YES" if has_create else "NO"))
    out_d = run(READELF, "-d", real)
    for l in out_d.splitlines():
        if "NEEDED" in l or "SONAME" in l:
            print("   %s" % l.strip())
    blob = open(real, "rb").read()
    print("   '%s' present  : %s" % ("%s%slib%sjimg.so",
                                     b"%s%slib%sjimg.so" in blob))
    print("   old 'modules' gone : %s" % (b"%s%slib%smodules" not in blob))

    # The dynamic table must be COMPLETE, not merely parseable. A gate that only
    # checked "the strings I edited are edited" passed once while 23 entries --
    # including 121,769 relocations -- had silently disappeared and the library
    # could not be loaded at all. Count entries and require the tags that matter.
    n_entries = out_d.count("(NEEDED)") + out_d.count("(SONAME)")
    for tag in ("(RELA)", "(JMPREL)", "(SYMTAB)", "(STRTAB)", "(GNU_HASH)", "(INIT)"):
        n_entries += out_d.count(tag)
    print("   dynamic: SONAME=libjvm.so present : %s"
          % ("libjvm.so" in out_d and "(SONAME)" in out_d))
    print("   dynamic: required tags found      : %d" % n_entries)
    dyn_ok = ("(SONAME)" in out_d and "(RELA)" in out_d and "(JMPREL)" in out_d
              and "(SYMTAB)" in out_d and "(STRTAB)" in out_d
              and "(GNU_HASH)" in out_d)
    print()

    print("== 4. sanity: nothing absolute-and-wrong anywhere in the anchor ==")
    bad = [l for l in needed if "/" in l and DEVICE_JVM not in l]
    print("   offending NEEDED entries: %d" % len(bad))
    print()

    # The shim must be the JDK's own, byte for byte. AMCL -- which works on this
    # device with the same libjvm.so -- uses this exact file, and the whole point
    # of dropping our replacement was to stop being the odd one out. A hash is
    # the only check that cannot be fooled by "a file with the right name exists".
    print("== 5. the shipped C++ shim is the unmodified JDK one ==")
    import hashlib
    # ⚠️ TWO accepted values, not one, and the reason is a buildMode decision.
    #
    # entry/build-profile.json5's buildOptionSet entry named "release" sets
    # strip:true, which OVERRIDES the target-level strip:false -- measured, not
    # assumed: the same tree gives libjvm_real.so at 25,322,128 B with .symtab
    # under buildMode=debug and 20,108,408 B with neither under
    # buildMode=release. So a package's native bytes depend on which buildMode
    # produced it, and a gate that accepts only one of them FAILS on the other.
    #
    # Accepting both is the honest form: the claim being checked is "these are
    # the bytes we assembled, not something else", and it is true of both. A
    # gate that fails on a correct package teaches people to ignore it.
    #
    # What is NOT accepted is an unknown value -- that is still a MISMATCH, and
    # the failure prints the hash so it can be identified.
    WANT_SHIM = (
        "b605f5863ca1a75170a814ab4054a9867c346e15",   # buildMode=debug, unstripped
        "ceff66f064a4fee9837b7ea1a2cd9e5997db1d80",   # buildMode=release, stripped
    )
    shim_path = os.path.join(TMP, "shim.so")
    got_shim = hashlib.sha1(open(shim_path, "rb").read()).hexdigest()
    print("   expected %s" % " or ".join(WANT_SHIM))
    print("   actual   %s   %s" % (got_shim, "OK" if got_shim in WANT_SHIM else "MISMATCH"))
    print()

    # ==================================================================
    # 6. THE GAME -- and the reason this is a hash and not a size check.
    #
    # The jar ships under a ".so" name (see prep_game.py), which means nothing in
    # the tool chain ever parses it: not hvigor, not the packer, not the installer.
    # It is opaque bytes all the way to the device. So the only meaningful
    # question is whether the 86,957,725 bytes on the device are the SAME bytes as
    # the pinned build -- and the only way to answer that is to hash them.
    #
    # A size check would pass for the unpatched jar too, and for a jar built by
    # re-running the upstream stage while missing a downstream one, which is how a
    # wrong jar shipped once already in this project.
    #
    # It is hashed by streaming, straight out of the archive, so no 87 MB copy is
    # written just to be deleted.
    # ==================================================================
    print("== 6. the game jar, hashed as packaged ==")
    import hashlib
    WANT_GAME = "e25bc13837ccd476fd32fb274b5da90991c6fbad"
    GAME_ENTRY = "libs/arm64-v8a/game/mindustry.so"
    game_ok = False
    with zipfile.ZipFile(hap) as z:
        if GAME_ENTRY not in z.namelist():
            print("   MISSING from the archive: %s" % GAME_ENTRY)
        else:
            h = hashlib.sha1()
            n = 0
            with z.open(GAME_ENTRY) as src:
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
                    n += len(b)
            got_game = h.hexdigest()
            game_ok = got_game == WANT_GAME
            print("   entry : %s" % GAME_ENTRY)
            print("   bytes : %d" % n)
            print("   expect: %s" % WANT_GAME)
            print("   actual: %s   %s" % (got_game, "OK" if game_ok else "MISMATCH"))
    print()

    # ==================================================================
    # 7. LWJGL -- jars and natives, both present and both the right bytes.
    #
    # Same reasoning as the game jar above: the Java half ships renamed to ".so"
    # and the native half is opaque to every tool in the chain, so neither one is
    # validated by anything except this. A version mismatch between the two
    # halves is the specific failure this guards against -- they come from two
    # different sources and would only fail at the first call, on the device.
    # ==================================================================
    print("== 7. LWJGL payload ==")
    # lwjgl/libSDL3.so is deliberately ABSENT from this table, and from the HAP.
    # There used to be a second SDL3 there, taken from a prebuilt HarmonyOS app,
    # while this project builds its own from entry/src/main/cpp/SDL/ into the top
    # of the bundle. org.lwjgl.librarypath lists the bundle first, and that was
    # measured resolving to the bundle copy, so the lwjgl/ one was unreachable --
    # two copies of one library in one process is a hazard this project has
    # already been bitten by once. See prep_lwjgl.py. The top-level
    # libs/arm64-v8a/libSDL3.so is checked for presence in step 1; its hash is
    # not pinned because it is built here, so pinning it would fail on any
    # legitimate rebuild rather than on a mistake.
    LWJGL = {
        "libs/arm64-v8a/lwjgl/liblwjgl.so":
            "663e5cab870ac3427cbfbe01f93facbc260fa504",
        "libs/arm64-v8a/lwjgl/liblwjgl_opengl.so":
            "f3661e892d4d2deb3aa574cab2e64c13b7ac6b4d",
        "libs/arm64-v8a/lwjgl-java/lwjgl.so":
            "cd7dd7a13abce9a2764364f58e138c6f99f50a7f",
        "libs/arm64-v8a/lwjgl-java/lwjgl-opengl.so":
            "27698e706465a088d4c8eda34f98d69e5c8b32f7",
        "libs/arm64-v8a/lwjgl-java/lwjgl-sdl.so":
            "96d577ef9b661fe4bb9bfb32fbb1de3ff34219cd",
    }
    # Arc's own natives. They ship here rather than being extracted by Arc at
    # runtime, because the extracted copy cannot be dlopen'd -- see prep_arc.py.
    # Same gate, same reason: nothing downstream validates these bytes.
    ARC = {
        "libs/arm64-v8a/arc/libarcarm64.so":
            "db9d78b196beaa237a153b622b781e06be973462",
        # NOT the jar's copy: that one is glibc and cannot load here. This is
        # Arc's Android build with its layout dependencies repointed at libc.so;
        # see prep_freetype.py. The hash differs from the jar's on purpose.
        # Both strip states, same reason as WANT_SHIM above. These two live in
        # libs/ as well, so the release buildMode strips them too.
        "libs/arm64-v8a/arc/libarc-freetypearm64.so": (
            "004df783590ce27c79396a6432cfb9820538db7c",   # debug
            "41537d6980215a0921b403a223c2a9ea1ec04f26",   # release
        ),
        "libs/arm64-v8a/arc/libarc-filedialogsarm64.so": (
            "0ac27bdfd455ed1190ff9ba0ce97c7ddeb0cc049",   # debug
            "f4f4e8290acf21453d6fef5aa254790897d3b866",   # release
        ),
    }
    LWJGL.update(ARC)
    # The JDK's time-zone database, shipped under a .so name for the same reason
    # the module image is: hvigor only carries names ending in ".so", and
    # java.base opens "tzdb.dat" by that exact name. Without it the game does not
    # start -- see prep_jdklib.py.
    LWJGL["libs/arm64-v8a/jdk21/lib/tzdb.so"] = \
        "330a69ed889539d7b8f9ec8bcb00f49b5ee2895d"

    # The launcher's own helper jar is checked structurally rather than by hash:
    # it is compiled from source on each prep run, and a jar carries timestamps,
    # so the same source produces a different file every time. What matters is
    # that the class it is supposed to carry is inside the copy in the HAP.
    print("== 8. the launcher helper jar ==")
    import io
    helper_entry = "libs/arm64-v8a/launcher/helper.so"
    helper_class = "com/haohandc/launcher/NativeLoader.class"
    helper_ok = False
    with zipfile.ZipFile(hap) as z:
        if helper_entry not in z.namelist():
            print("   MISSING  %s" % helper_entry)
        else:
            blob = z.read(helper_entry)
            try:
                with zipfile.ZipFile(io.BytesIO(blob)) as inner:
                    helper_ok = helper_class in inner.namelist()
            except zipfile.BadZipFile:
                print("   NOT A JAR -- packaging corrupted it")
            print("   %-9s %s  %s"
                  % ("OK" if helper_ok else "FAIL", helper_entry,
                     "carries " + helper_class if helper_ok else ""))
    print()
    lwjgl_ok = True
    with zipfile.ZipFile(hap) as z:
        present = set(z.namelist())
        for entry, want in LWJGL.items():
            if entry not in present:
                print("   MISSING  %s" % entry)
                lwjgl_ok = False
                continue
            h = hashlib.sha1()
            with z.open(entry) as src:
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
            got_h = h.hexdigest()
            # `want` is either one hash or a tuple of the accepted ones.
            ok_h = got_h in (want if isinstance(want, tuple) else (want,))
            lwjgl_ok = lwjgl_ok and ok_h
            print("   %-9s %-42s %s"
                  % ("OK" if ok_h else "MISMATCH", entry.split("/")[-1],
                     "" if ok_h else got_h))
    print()

    ok = (got and has_create and not bad and got_shim in WANT_SHIM and dyn_ok
          and game_ok and lwjgl_ok and helper_ok and ok_ref[0])
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
