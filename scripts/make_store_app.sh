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
#   bash scripts/make_store_app.sh phone
#
# THE TWO MODES EXIST BECAUSE THE STORE WANTS TWO PACKAGES.
#
# The executable-memory permission is granted through a restricted (ACL)
# application, and Huawei's policy for it lists its supported devices as
# "tablet and PC/2in1" -- phones are excluded. So one package cannot serve both:
#
#   tablet   declares ALLOW_WRITABLE_CODE_MEMORY and targets tablet + 2in1.
#            The ACL is what lets the JVM's JIT run, so this is the fast one.
#   phone    declares no such permission and targets phone only. It must not:
#            a phone package carrying a permission the ACL cannot cover is a
#            package the store refuses. The JVM runs interpreted, which the
#            launcher now decides by probing rather than by device type.
#
# The user confirmed with Huawei that ONE Release Profile covers both (a profile
# carrying the ACL entry is fine for a package that does not declare it), that no
# separate review is needed, and that AppGallery filters by deviceTypes -- which
# is why deviceTypes is split per mode rather than left as the template's
# ["phone","tablet","2in1","tv"]. "tv" is dropped in both: this project has never
# tested a TV, and declaring an untested platform is a claim, not a default.
#
# THE MODE IS REQUIRED, not defaulted. A default would make it possible to build
# the phone package while believing you built the tablet one, and the two are
# distinguished by a permission that is invisible once uploaded.
#
# Output: dist/store/MindustryArk-<mode>.app  (so the two cannot overwrite each
# other -- the build itself writes one fixed path per product)

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

MODE="${1:-}"
case "$MODE" in
    tablet) WANT_PERM=yes; WANT_DEVICES='["tablet", "2in1"]' ;;
    phone)  WANT_PERM=no;  WANT_DEVICES='["phone"]' ;;
    *)
        echo "usage: bash scripts/make_store_app.sh {tablet|phone}" >&2
        echo >&2
        echo "  tablet  tablet + 2in1, WITH the executable-memory ACL (JIT)" >&2
        echo "  phone   phone only, WITHOUT it (JVM runs interpreted)" >&2
        echo >&2
        echo "The mode is required: the two packages differ by a permission that is" >&2
        echo "invisible in the store listing, so \"which one did I just build\" is not" >&2
        echo "a question a default should be allowed to answer." >&2
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
       + indent + "// ONLY IN THE tablet MODE. The ACL's supported devices are tablet and PC/\n"
       + indent + "// 2in1; a phone package carrying it is one the store refuses.\n"
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
#
# ⚠️ CONDITIONAL, and it has to be: in phone mode "the permission is absent" is
# the required outcome, so an unconditional check would refuse to build the phone
# package at all. Each mode asserts its own shape.
decl = ('"name": "%s"' % perm) in out
if want_perm == "yes" and not decl:
    print("!! the injection produced a file without the permission in it")
    sys.exit(1)
if want_perm == "no" and decl:
    print("!! phone mode must not declare %s, and this file does" % perm)
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
# MODE-AWARE. The invariant is not "the permission is present" any more, it is
# "the package has the shape this mode is supposed to produce":
#
#   tablet  the ACL permission IS declared, and deviceTypes is tablet + 2in1
#   phone   the ACL permission is NOT declared, and deviceTypes is phone only
#
# A gate that only ever demanded the permission would have passed a phone package
# that wrongly carried it, which is the failure that gets a submission refused.
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
# THE CHECKS. Read the shape this mode promised and compare it to the package.
#
# 1. The permission is present IF AND ONLY IF the mode says so. Both directions
#    matter: missing it in tablet mode means no JIT (and, worse, a silent
#    slowdown), present in phone mode means a package the ACL cannot cover, which
#    is what gets a submission refused.
#
# 2. deviceTypes matches the mode. This is what makes the store offer the right
#    package to the right device, and it is the reason the two modes exist at all
#    rather than one package carrying a per-device permission.
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
if want_perm == "yes" and not has:
    sys.exit("!! THE PACKAGE IS MISSING THE INJECTED PERMISSION: %s -- do not upload"
             % perm)
if want_perm == "no" and has:
    sys.exit("!! mode=phone must NOT declare %s, and this package does -- the ACL "
             "cannot cover a phone, so the store will refuse it. Do not upload." % perm)
print("   ok: permission %s as mode=%s requires" % ("present" if has else "absent", mode))

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
    if [ "$MODE" = tablet ]; then
        echo "   mode=tablet: tablet + 2in1, WITH the executable-memory ACL."
        echo "   Needs the Release Profile that carries that ACL entry."
    else
        echo "   mode=phone: phone only, with NO executable-memory permission."
        echo "   The same Release Profile is fine -- the user confirmed a profile"
        echo "   carrying the ACL entry works for a package that does not declare it."
        echo "   Expect the JVM to run interpreted on these devices; the launcher"
        echo "   decides that by probing, so a device that CAN get the memory keeps"
        echo "   the JIT either way."
    fi
    echo
    echo "   If you are building the other mode too, run this script again with the"
    echo "   other argument. Both artifacts live in $OUTDIR/ and neither overwrites"
    echo "   the other."
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
