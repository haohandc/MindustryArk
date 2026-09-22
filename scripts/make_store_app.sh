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
# 1. PRECONDITION, BACKUP, INJECT
# ---------------------------------------------------------------------------
"${PY[@]}" - "$MODJSON" "$PERM" "$BACKUP" <<'PYEOF' || exit 1
import hashlib, io, os, sys
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

# ⚠️ The anchor is found, then the WHOLE LINE is checked. module.json5 carries
# commented-out permission entries (MICROPHONE, CAMERA, INTERNET, ...), and a
# bare substring search would happily match one of those -- inserting the new
# permission inside a comment, where it would have no effect and would look
# like it had been added.
ANCHOR = '{ "name": "ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY"'
i = src.find(ANCHOR)
if i < 0:
    print("!! could not find the DOWNLOAD permission entry to insert before")
    sys.exit(1)
line_start = src.rfind("\n", 0, i) + 1
line = src[line_start:src.find("\n", i)]
if line.lstrip().startswith("//"):
    print("!! the DOWNLOAD permission is COMMENTED OUT, so inserting before it")
    print("!! would put the new one inside a comment:")
    print("!!   %s" % line.strip()[:100])
    sys.exit(1)
indent = src[line_start:i]
NEW = (indent + "// STORE BUILD ONLY -- injected by scripts/make_store_app.sh and removed\n"
       + indent + "// again on exit. See RELEASE-MAINTENANCE.md 2.11 for why this cannot be\n"
       + indent + "// declared unconditionally. Never commit a module.json5 containing this.\n"
       + indent + '{ "name": "%s", "reason": "$string:perm_reason_CODE_MEMORY", '
                  '"usedScene": { "abilities": [ "EntryAbility" ], "when": "inuse" } },\n' % perm)
io.open(path, "w", encoding="utf-8", newline="\n").write(src[:line_start] + NEW + src[line_start:])
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
import hashlib, io, json, os, sys, zipfile
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
missing = [p for p in (perm, "ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY")
           if p not in names]
if missing:
    sys.exit("!! THE PACKAGE IS MISSING: %s -- do not upload this" % missing)
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
