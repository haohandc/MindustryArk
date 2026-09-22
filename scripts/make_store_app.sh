#!/bin/bash
# Build the AppGallery .app, with the executable-memory permission declared.
#
# WHY THIS EXISTS
#   ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY is needed for the JVM's JIT
#   on some devices -- see RELEASE-MAINTENANCE.md 2.11. Measured: a HarmonyOS 6.1.1
#   (API 24) device refuses mmap(RWX) with errno=22, the launcher never gets past
#   JNI_CreateJavaVM, and the app installs and cannot start.
#
#   It cannot go in src/main/module.json5 unconditionally, because an ORDINARY
#   (debug) profile cannot grant a restricted permission: declaring it makes the
#   local install fail with "install failed due to grant request permissions
#   failed", which this project hit once already -- see the top of deploy.sh.
#
#   So it is declared for the store product only, by this script, and removed
#   again afterwards. hvigor has no per-product module.json5: its own
#   getJsonProfilePath() resolves ONE file per TARGET's source-set root, so a
#   per-product manifest would mean a second copy of the whole source tree.
#
# ⚠️ ORDER MATTERS
#   Do NOT run this until the ACL is GRANTED in AppGallery Connect and the Release
#   profile has been regenerated to carry it. A package that declares a restricted
#   permission its profile cannot grant is a package that will not install -- so
#   running this early makes the store build worse, not better.
#
# WHAT IT GUARANTEES
#   1. It refuses to start unless module.json5 is in the known-clean state, so a
#      previous run killed mid-injection is detected rather than built on.
#   2. module.json5 is restored on EVERY exit path, and the restore is verified by
#      hash -- not assumed. The trap is installed BEFORE the first write.
#   3. The BUILT ARTIFACT is opened and checked for the permission. Injecting a
#      file and hoping it reached the package is the same mistake as trusting a
#      build log; the package is what gets uploaded.
#
# Usage:
#   bash scripts/make_store_app.sh
#
# Output: build/outputs/release/MindustryArk-release-signed.app

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

PY=("${ARK_PYTHON:-python}")
MODJSON="entry/src/main/module.json5"
PERM="ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY"
APPPATH="build/outputs/release/MindustryArk-release-signed.app"
BACKUP="${TEMP:-/tmp}/module.json5.pre-store"

# ---------------------------------------------------------------------------
# RESTORE, INSTALLED FIRST, BEFORE ANYTHING CAN WRITE
#   A trap that is installed after the write protects only the failures that
#   happen later than it. The interesting failure is the write itself.
# ---------------------------------------------------------------------------
restore() {
    rc=$?
    if [ -f "$BACKUP" ]; then
        "${PY[@]}" - "$MODJSON" "$BACKUP" <<'PYEOF'
import hashlib, io, os, shutil, sys
path, b = sys.argv[1], sys.argv[2]
want = io.open(b + ".sha256").read().strip()
shutil.copyfile(b, path)
got = hashlib.sha256(open(path, "rb").read()).hexdigest()
print("   restored %s  (sha256 %s%s)"
      % (path, got[:16], "" if got == want else "  *** MISMATCH, expected %s ***" % want[:16]))
PYEOF
    fi
    exit $rc
}
trap restore EXIT

# ---------------------------------------------------------------------------
# GATE: FORCE_COMPAT_MODE must be false.
#
# That constant forces -Xint on EVERY device, which exists only to measure what
# the interpreter costs on hardware that does not need it. If it were left on and
# a store package were built from this working tree, every user would get an
# interpreted game and nothing on the device would say why.
#
# This is checked here rather than trusted, because "remember to set it back" is
# exactly the kind of instruction that survives right up until it does not.
# ---------------------------------------------------------------------------
FORCE_LINE="$(grep -nE '^const FORCE_COMPAT_MODE' entry/src/main/ets/pages/Index.ets || true)"
case "$FORCE_LINE" in
    *"= false"*) : ;;
    "")  echo "!! could not find FORCE_COMPAT_MODE in Index.ets -- refusing to build" >&2
         exit 1 ;;
    *)   echo "!! FORCE_COMPAT_MODE is not false:" >&2
         echo "!!   $FORCE_LINE" >&2
         echo "!! that forces interpreted mode on every device. Set it back to false" >&2
         echo "!! before building anything that could ship." >&2
         exit 1 ;;
esac
echo "   gate: FORCE_COMPAT_MODE = false"

# ---------------------------------------------------------------------------
# 1. PRECONDITION, BACKUP, INJECT
# ---------------------------------------------------------------------------
"${PY[@]}" - "$MODJSON" "$PERM" "$BACKUP" <<'PYEOF' || exit 1
import hashlib, io, os, re, sys
path, perm, backup = sys.argv[1], sys.argv[2], sys.argv[3]
src = io.open(path, encoding="utf-8").read()

# ⚠️ Match the DECLARATION, not the name. module.json5 deliberately mentions
# this permission in a comment -- the paragraph explaining why it is absent --
# so a substring test says "already declared" on a clean tree and refuses to
# run. Measured: the bare name occurs once (line 36, in a comment) and
# '"name": "<perm>"' occurs zero times.
DECL = '"name": "%s"' % perm
if DECL in src:
    print("!! %s ALREADY declares %s." % (path, perm))
    print("!! Either a previous run died before restoring it, or it was added by")
    print("!! hand. Restore it (git checkout -- %s) before running this --" % path)
    print("!! otherwise the backup below would capture the WRONG 'original'.")
    sys.exit(1)

io.open(backup, "w", encoding="utf-8", newline="").write(src)
digest = hashlib.sha256(src.encode("utf-8")).hexdigest()
io.open(backup + ".sha256", "w").write(digest)
print("   original saved: sha256 %s" % digest[:16])

# ⚠️ THE ANCHOR IS THE ARRAY, NOT A PERMISSION ENTRY.
#
# This used to insert before the READ_WRITE_DOWNLOAD_DIRECTORY entry, which was
# convenient because that entry existed and was unmistakably not a comment. It
# was also a trap: any revision that removed or renamed that permission would
# take this script down with it, at the worst possible moment -- the ACL has just
# been granted and the store build is what you are trying to produce.
#
# The array itself is structural. It does not move when permissions are added or
# removed, and if it is gone then module.json5 is not a manifest any more and
# failing loudly is the correct answer.
m = re.search(r'"requestPermissions"\s*:\s*\[', src)
if not m:
    print("!! could not find the requestPermissions array in %s" % path)
    print("!! this script injects INTO that array; without it there is nowhere to")
    print("!! put the permission, and the manifest is not what this expects.")
    sys.exit(1)
after = m.end()

# Indentation taken from the array's first entry, so the injected text lines up
# with whatever is already there. Falls back to the manifest's usual six spaces
# for an empty array.
nm = re.search(r'\n([ \t]+)\S', src[after:])
indent = nm.group(1) if nm else '      '

NEW = (indent + "// STORE BUILD ONLY -- injected by scripts/make_store_app.sh and removed\n"
       + indent + "// again on exit. See RELEASE-MAINTENANCE.md 2.11 for why this cannot be\n"
       + indent + "// declared unconditionally. Never commit a module.json5 containing this.\n"
       + indent + '{ "name": "%s", "reason": "$string:perm_reason_CODE_MEMORY", '
                  # `always`, not `inuse`. The JVM's JIT needs this memory from
                  # process start to process exit, and which ability is in the
                  # foreground has nothing to do with it. It also has to MATCH the
                  # AGC ACL form, where the timing is set to always -- a package
                  # whose usedScene disagrees with its own ACL application is a
                  # disagreement not worth shipping.
                  '"usedScene": { "abilities": [ "EntryAbility" ], "when": "always" } },\n' % perm)

# Inserted as the FIRST entry rather than last: the closing bracket of an array
# written as `[]` sits immediately after the `[`, and a first-entry insert works
# the same way whether the array was empty or populated.
out = src[:after] + "\n" + NEW + src[after:]

# Cheap sanity on the write itself, before it reaches the disk. The build gate
# below checks the ARTIFACT; this one catches a mangled edit while the backup is
# still fresh.
if ('"name": "%s"' % perm) not in out:
    print("!! the injection produced a file without the permission in it")
    sys.exit(1)

io.open(path, "w", encoding="utf-8", newline="\n").write(out)
print("   injected %s" % perm)
PYEOF

# ---------------------------------------------------------------------------
# 2. BUILD
# ---------------------------------------------------------------------------
echo
echo "############ building the store .app ############"
bash build.sh assembleApp --mode project -p product=release -p buildMode=release --no-daemon > /tmp/store_app.log 2>&1
if [ $? -ne 0 ] || ! grep -q "BUILD SUCCESSFUL" /tmp/store_app.log; then
    grep -Ei "BUILD (SUCCESSFUL|FAILED)" /tmp/store_app.log | head -1
    echo "!! build failed -- tail of the log:" >&2
    tail -25 /tmp/store_app.log >&2
    exit 1
fi
grep -Ei "BUILD (SUCCESSFUL|FAILED)" /tmp/store_app.log | head -1

# ---------------------------------------------------------------------------
# 3. GATE -- the package is what gets uploaded, so check the package
# ---------------------------------------------------------------------------
echo
echo "############ gate: the ARTIFACT declares the permission ############"
"${PY[@]}" - "$APPPATH" "$PERM" <<'PYEOF'
import hashlib, io, json, os, re, sys, zipfile
app, perm = sys.argv[1], sys.argv[2]
if not os.path.exists(app):
    sys.exit("!! no .app at %s" % app)
z = zipfile.ZipFile(app)
inner = [n for n in z.namelist() if n.endswith(".hap")]
if not inner:
    sys.exit("!! the .app contains no .hap")
h = zipfile.ZipFile(io.BytesIO(z.read(inner[0])))
mod = json.loads(h.read("module.json").decode())["module"]
names = [p["name"] for p in mod.get("requestPermissions", [])]
print("   declared permissions: %s" % names)

# ---------------------------------------------------------------------------
# TWO CHECKS, AND THE SECOND ONE IS THE STRONGER
#
# 1. The injected permission is in the package. That is this script's job, and
#    injecting a file and hoping it reached the package is the same mistake as
#    trusting a build log -- the package is what gets uploaded.
#
# 2. Every permission module.json5 declares on an UNCOMMENTED line is in the
#    package. This is the invariant that would have caught the trap this script
#    used to have: it anchored the injection on the DOWNLOAD permission entry, so
#    removing that permission would have broken the build. It also catches the
#    general case -- a manifest edited in a way the package does not reflect --
#    which nothing checked before.
#
# Check 1 used to also require READ_WRITE_DOWNLOAD_DIRECTORY. It no longer does,
# because that permission has no use in this app any more (see the manifest) and
# is going to be removed; requiring it would have made removing it break the
# store build. Check 2 still covers it for as long as it is declared.
# ---------------------------------------------------------------------------
missing = [p for p in [perm] if p not in names]
if missing:
    sys.exit("!! THE PACKAGE IS MISSING THE INJECTED PERMISSION: %s -- do not upload"
             % missing)

# The script cds to the project root at the top, so this is already the right
# base -- computing "../.." hops from the .app's directory is how the first
# version of this got the depth wrong by one.
manifest = "entry/src/main/module.json5"
declared = []
if os.path.exists(manifest):
    for line in io.open(manifest, encoding="utf-8"):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        # Anchored on "ohos.permission." ON PURPOSE. A bare `"name": "..."` also
        # matches the module name, the ability names and the extension names --
        # measured, they all came back in the first version of this and would
        # have been reported as "declared but missing from the package", failing
        # the build for three things that are not permissions at all.
        for nm in re.findall(r'"name"\s*:\s*"(ohos\.permission\.[^"]+)"', stripped):
            if nm not in declared:
                declared.append(nm)
    # The injected one is not in module.json5 -- it is added by this script.
    absent = [p for p in declared if p not in names]
    print("   module.json5 declares %d, package carries %d" % (len(declared), len(names)))
    if absent:
        sys.exit("!! DECLARED IN THE MANIFEST BUT NOT IN THE PACKAGE: %s -- do not upload"
                 % absent)
else:
    print("   (module.json5 not found at %s -- skipped the manifest cross-check)" % manifest)
v = json.loads(z.read("pack.info").decode())["summary"]["app"]["version"]
print()
print("   %s" % inner[0])
print("   versionName %s   versionCode %s" % (v["name"], v["code"]))
print("   size %d B" % os.path.getsize(app))
print("   sha256 %s" % hashlib.sha256(open(app, "rb").read()).hexdigest())
PYEOF
GATE_RC=$?

echo
if [ "$GATE_RC" -eq 0 ]; then
    echo "############ OK -- upload this file ############"
    echo "   $APPPATH"
    echo
    echo "   Signed with the RELEASE certificate, so it cannot be sideloaded and"
    echo "   cannot be tested on your own hardware. Same constraint as 2.10/2.11."
else
    echo "############ GATE FAILED -- do not upload ############" >&2
fi
exit $GATE_RC
