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
#   bash scripts/make_store_app.sh tablet
#
# ⚠️⚠️ THERE IS NO PHONE MODE, AND NOT BUILDING ONE IS THE POINT.
#
# A phone mode was written and is now gone, deliberately. It would have produced a
# package that DECLARES NO executable-memory permission and targets phone only,
# with the JVM expected to run interpreted. Measured 2026-09-22 -- see
# RELEASE-MAINTENANCE.md 2.13b -- that package CANNOT WORK:
#
#   On a device-bound RELEASE profile with no executable-memory ACL, the launcher
#   probes the capability, gets -1, forces -Xint, and then dies inside
#   JNI_CreateJavaVM with no further output at all. The interpreter still needs
#   executable memory: HotSpot builds its startup stubs before it ever looks at how
#   bytecode will be run.
#
# ⇒ A phone cannot be granted the ACL (the policy covers tablet and PC/2in1), and
#   the interpreted fallback does not save it, so a phone store package would
#   install and never start -- the worst submission there is. Phones are served by
#   the SELF-SIGNED build instead, where a debug profile temporarily unlocks every
#   permission and the JIT works. That route is documented; it is not a package
#   this script produces.
#
# ⚠️ AND module.json5 STILL LISTS "phone" IN deviceTypes -- ALSO DELIBERATELY.
#    deviceTypes is enforced at INSTALL time, not only at listing time, so removing
#    "phone" from the manifest would make the self-signed build uninstallable on a
#    phone as well, destroying the one route phones have. The narrowing belongs
#    here, at build time: this is the layer that decides what the STORE offers.
#
# The executable-memory permission is granted through a restricted (ACL)
# application, whose supported devices are "tablet and PC/2in1". This build
# declares it and targets tablet + 2in1. The user confirmed with Huawei that one
# Release Profile covers it, and that AppGallery filters by deviceTypes -- which is
# why deviceTypes is rewritten here rather than left at the toolchain template's
# ["phone","tablet","2in1","tv"]. "tv" is dropped: this project has never tested a
# TV, and declaring an untested platform is a claim, not a default.
#
# THE MODE ARGUMENT IS STILL REQUIRED, not defaulted. It is the one place where the
# package says out loud which platforms it claims, and a default should not be
# allowed to answer that.
#
# Output: dist/store/MindustryArk-<mode>.app

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

MODE="${1:-}"
case "$MODE" in
    tablet) WANT_PERM=yes; WANT_DEVICES='["tablet", "2in1"]' ;;
    phone)
        # Named explicitly so the answer is an explanation rather than a usage
        # error. Someone typing "phone" is not mistyping -- they are asking for the
        # package this project decided not to build, and "usage: tablet" alone
        # would read as if the argument were merely unrecognised.
        echo "!! there is no phone mode, and that is a decision rather than an omission." >&2
        echo "!! A phone store package would install and never start: the ACL covers" >&2
        echo "!! tablet and PC/2in1 only, and the interpreted fallback does not rescue a" >&2
        echo "!! device that was refused executable memory. Phones are served by the" >&2
        echo "!! self-signed build. See the header of this file, and" >&2
        echo "!! RELEASE-MAINTENANCE.md 2.13b." >&2
        exit 2
        ;;
    *)
        echo "usage: bash scripts/make_store_app.sh tablet" >&2
        echo >&2
        echo "  tablet  tablet + 2in1, WITH the executable-memory ACL (JIT)" >&2
        echo >&2
        echo "The mode is required: it is where the package says out loud which" >&2
        echo "platforms it claims, and a default should not be allowed to answer that." >&2
        exit 2
        ;;
esac

PY=("${ARK_PYTHON:-python}")
MODJSON="entry/src/main/module.json5"
PERM="ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY"
BUILT_APP="build/outputs/release/MindustryArk-release-signed.app"
OUTDIR="dist/store"
OUTAPP="$OUTDIR/MindustryArk-$MODE.app"
BACKUP="${TEMP:-/tmp}/module.json5.pre-store"

echo "############ store build: mode = $MODE ############"
echo "   permission $PERM: $([ "$WANT_PERM" = yes ] && echo INJECTED || echo absent)"
echo "   deviceTypes: $WANT_DEVICES"

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
"${PY[@]}" - "$MODJSON" "$PERM" "$BACKUP" "$WANT_PERM" "$WANT_DEVICES" "$MODE" <<'PYEOF' || exit 1
import hashlib, io, os, re, sys
path, perm, backup, want_perm, want_devices, mode = sys.argv[1:7]
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
       + indent + "// The ACL's supported devices are tablet and PC/2in1, which is why the\n"
       + indent + "// package this script produces claims those and nothing else.\n"
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
out = src[:after] + "\n" + NEW + src[after:] if want_perm == "yes" else src

# --- deviceTypes, rewritten in BOTH modes --------------------------------
#
# The manifest ships the toolchain template's value, ["phone","tablet","2in1",
# "tv"], which is a starting point rather than a decision. Each mode narrows it
# to what that package is for, and "tv" is dropped from both: nothing here has
# ever run on a TV, and a declared platform is a promise.
#
# The user confirmed AppGallery filters by this, so the split is what keeps a
# phone user from being offered the tablet package -- which for them would be the
# *worse* one, since they cannot be granted the ACL it expects.
dm = re.search(r'"deviceTypes"\s*:\s*\[[^\]]*\]', out)
if not dm:
    print("!! no deviceTypes array in %s" % path)
    print("!! without it a package declares no platform, and the split between the")
    print("!! two store builds has nowhere to live.")
    sys.exit(1)
out = out[:dm.start()] + '"deviceTypes": %s' % want_devices + out[dm.end():]
print("   deviceTypes -> %s" % want_devices)

# Cheap sanity on the write itself, before it reaches the disk. The build gate
# below checks the ARTIFACT; this one catches a mangled edit while the backup is
# still fresh.
decl = ('"name": "%s"' % perm) in out
if not decl:
    print("!! the injection produced a file without the permission in it")
    sys.exit(1)

io.open(path, "w", encoding="utf-8", newline="\n").write(out)
print("   %s" % ("injected %s" % perm if want_perm == "yes"
                else "no permission injected (phone mode)"))
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
# 2b. COPY ASIDE UNDER A MODE-SPECIFIC NAME
#
# hvigor writes ONE fixed path per product, so building the second mode would
# overwrite the first -- and the two packages are told apart by a permission that
# is invisible in a file listing. Renaming here means both can exist at once and
# the filename says which is which.
#
# A COPY, not a move: the gate below reads $BUILT_APP, and a failed gate should
# leave the build tree as hvigor left it.
# ---------------------------------------------------------------------------
echo
echo "############ keeping the artifact as MindustryArk-$MODE.app ############"
if [ ! -f "$BUILT_APP" ]; then
    echo "!! the build reported success but there is no .app at $BUILT_APP" >&2
    echo "!! do not go looking for an older one -- that is how a stale package gets" >&2
    echo "!! uploaded. Check the build log above." >&2
    exit 1
fi
mkdir -p "$OUTDIR"
cp -f "$BUILT_APP" "$OUTAPP"
echo "   $OUTAPP"

# ---------------------------------------------------------------------------
# 2c. WAS A SIGNATURE ACTUALLY APPENDED?
#
# The closing message tells the reader this file is release-signed. That is a
# claim about a SIGNATURE, and the signature is not a zip entry -- HarmonyOS
# appends it after the archive -- so listing the .app proves nothing either way.
# Measured, and the reason this check exists: nothing in the script used to
# verify it at all.
#
# hvigor emits both variants side by side, and the signed one is bigger by
# exactly the signature block (measured: 153,246,249 vs 153,231,519 = +14,730 B).
# Comparing the two turns the claim into a measurement.
#
# If the signing config is missing or wrong, hvigor still succeeds and still
# writes a file called "-signed" -- which is precisely the failure this catches.
# ---------------------------------------------------------------------------
UNSIGNED_APP="${BUILT_APP%-signed.app}-unsigned.app"
if [ -f "$UNSIGNED_APP" ]; then
    SZ_SIGNED=$(wc -c < "$BUILT_APP")
    SZ_UNSIGNED=$(wc -c < "$UNSIGNED_APP")
    if [ "$SZ_SIGNED" -le "$SZ_UNSIGNED" ]; then
        echo "!! '$BUILT_APP' is NOT LARGER than the unsigned variant:" >&2
        echo "!!   signed   $SZ_SIGNED B" >&2
        echo "!!   unsigned $SZ_UNSIGNED B" >&2
        echo "!! The file is named -signed but no signature was appended, which means" >&2
        echo "!! the release signingConfig did not take effect. Check the 'release'" >&2
        echo "!! entry in the root build-profile.json5 (it is skip-worktree, so it is" >&2
        echo "!! not in git and cannot be reviewed by 'git diff'). Do not upload." >&2
        exit 1
    fi
    echo "   signature present: +$((SZ_SIGNED - SZ_UNSIGNED)) B over the unsigned variant"
else
    echo "   (no -unsigned variant to compare against; the signature is not verified)" >&2
fi

# ---------------------------------------------------------------------------
# 3. GATE -- the package is what gets uploaded, so check the package
#
# Two invariants, and the first one is now the load-bearing one:
#
#   1. deviceTypes is EXACTLY tablet + 2in1. This is what keeps the store from
#      offering the app to a phone, which is the entire reason the phone mode is
#      gone: a phone install of this app cannot start. A package that accidentally
#      carried "phone" would be offered to devices it cannot serve.
#   2. The ACL permission IS declared. Without it there is no JIT, and the install
#      never starts -- silently, from the outside. The only evidence is whether the
#      launcher logs "executable memory works (probe=42)".
# ---------------------------------------------------------------------------
echo
echo "############ gate: the ARTIFACT has the shape mode=$MODE requires ############"
"${PY[@]}" - "$BUILT_APP" "$PERM" "$WANT_PERM" "$WANT_DEVICES" "$MODE" <<'PYEOF'
import hashlib, io, json, os, re, sys, zipfile
app, perm, want_perm, want_devices, mode = sys.argv[1:6]
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
print("   deviceTypes: %s" % mod.get("deviceTypes"))

# ---------------------------------------------------------------------------
# THE CHECKS.
#
# 1. deviceTypes matches what this build claims, checked FIRST because it is the
#    one that decides who is offered the package at all. "phone" appearing here
#    means the store will offer an app to devices that cannot run it.
#
# 2. The permission is present. Its absence is the failure that looks like a slow
#    tablet rather than a broken package.
#
# 3. Every permission module.json5 declares on an UNCOMMENTED line is in the
#    package. This is the general invariant -- a manifest edited in a way the
#    package does not reflect -- and it is unchanged from the single-mode version.
#    It was what caught the old trap where the injection was anchored on a
#    permission entry that later got removed.
# ---------------------------------------------------------------------------
expected = json.loads(want_devices)
actual = mod.get("deviceTypes") or []
if sorted(actual) != sorted(expected):
    sys.exit("!! mode=%s expects deviceTypes %s but the package declares %s -- do not upload"
             % (mode, expected, actual))

has = perm in names
if not has:
    sys.exit("!! THE PACKAGE IS MISSING THE INJECTED PERMISSION: %s -- do not upload. "
             "Without it there is no JIT, and the app installs and does not start." % perm)
print("   ok: deviceTypes %s, permission declared" % sorted(actual))

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
    # The injected one is not in module.json5 -- it is added by this script on
    # the way to disk, and only in tablet mode, so it is not "declared" here.
    absent = [p for p in declared if p not in names]
    print("   module.json5 declares %d, package carries %d" % (len(declared), len(names)))
    if absent:
        sys.exit("!! DECLARED IN THE MANIFEST BUT NOT IN THE PACKAGE: %s -- do not upload"
                 % absent)
else:
    print("   (module.json5 not found at %s -- skipped the manifest cross-check)" % manifest)
v = json.loads(z.read("pack.info").decode())["summary"]["app"]["version"]
print()
print("   %s" % os.path.basename(app))
print("   versionName %s   versionCode %s" % (v["name"], v["code"]))
print("   size %d B" % os.path.getsize(app))
print("   sha256 %s" % hashlib.sha256(open(app, "rb").read()).hexdigest())
PYEOF
GATE_RC=$?

# ---------------------------------------------------------------------------
# 4. PUT THE MANIFEST BACK, AND SAY SO
#
# The trap on EXIT does this, but the message matters: a reader who sees the
# build succeed needs to know whether the tree is clean, because the next thing
# they might do is `git diff` or another build.
# ---------------------------------------------------------------------------
echo
if [ -f "$BACKUP" ]; then
    echo "   manifest restored (the trap will do it again on exit; that is harmless)"
fi

echo
if [ "$GATE_RC" -eq 0 ]; then
    echo "############ OK -- upload this file ############"
    echo "   $OUTAPP"
    echo
    echo "   tablet + 2in1, WITH the executable-memory ACL."
    echo "   Needs the Release Profile that carries that ACL entry."
    echo "   Phones are deliberately NOT covered: the ACL cannot reach them and the"
    echo "   interpreted fallback does not save them, so a phone package would install"
    echo "   and never start. Self-signed installs are how phones are served."
    echo
    echo "   Signed with the RELEASE certificate, so it cannot be sideloaded and"
    echo "   cannot be tested on your own hardware. Same constraint as 2.10/2.11."
    echo "   ⚠️ Which means the ACL is UNVERIFIED until it is in the store: if the"
    echo "   grant does not take effect the app still runs, just interpreted -- so a"
    echo "   failed ACL looks like a slow tablet and nothing else. The launcher log"
    echo "   line to look for is 'executable memory works (probe=42)'."
else
    echo "############ GATE FAILED -- do not upload ############" >&2
fi
exit $GATE_RC
