#!/bin/bash
# build -> verify -> install -> launch -> collect log
#
# WHY THIS IS A SCRIPT AND NOT THREE TYPED COMMANDS
#   Each step here exists because skipping it once produced a wrong result that
#   looked like a code problem. Chained, they cannot be forgotten.
#
# THIS INSTALLS *YOUR OWN* BUILD, SIGNED WITH *YOUR OWN* CERTIFICATE
#   The HAP this installs is signed by DevEco with an automatically generated
#   debug profile, and a debug profile names the device UDIDs it is valid for
#   (up to 100, registered in AppGallery Connect). So this build works on the
#   machines whose UDIDs are in that profile and nowhere else -- which is fine
#   here, because this is the local development loop, and it is why the signed
#   HAP is NOT the thing to hand to other people. See RELEASE.md for what to
#   distribute instead.
#
# NO ACL RE-SIGNING
#   This used to re-sign the HAP with a special profile from AGC, because
#   module.json5 requested the restricted permission
#   ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY, which an ordinary
#   profile cannot grant -- the install failed with
#   "install failed due to grant request permissions failed".
#
#   That permission has since been REMOVED, and verified unnecessary: the game
#   runs to its main menu without it. The JDK ships in the HAP's own lib area,
#   which is already executable, and the sandbox only holds DATA (the module
#   image is opened by java.base as a file). Executable memory at runtime comes
#   from anonymous mappings, which this platform permits regardless.
#
#   So the ordinary signing config in build-profile.json5 is enough, and this
#   script installs what hvigor signed. Set that config up once with
#   DevEco: File -> Project Structure -> Signing Configs -> Automatically
#   generate signature.
#
# PATHS
#   ARK_DEVECO_STUDIO, DEVECO_SDK_HOME, ARK_PYTHON -- see build.sh and
#   scripts/config.py. Nothing here is fixed to one machine any more.
#
# Usage:
#   bash deploy.sh              # build + verify + install + launch + log
#   bash deploy.sh --no-build   # reuse the existing HAP

set -o pipefail
cd "$(dirname "$0")" || exit 1

export MSYS_NO_PATHCONV=1

# Bundle name is also in scripts/config.py; keep the two in step.
BUNDLE="com.haohandc.mindustryark"
ABILITY="EntryAbility"

STUDIO="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}"
SDK_HOME="${DEVECO_SDK_HOME:-$STUDIO/sdk}"

# Arrays, per the note in build.sh: these paths contain spaces.
HDC=("$SDK_HOME/default/openharmony/toolchains/hdc.exe")
PY=("${ARK_PYTHON:-python}")

# ---------------------------------------------------------------------------
# WHICH DEVICE
#
# Bare `hdc` calls pick a device themselves when more than one is attached, and
# this script runs `uninstall` -- so guessing can erase the save data of a device
# nobody meant to touch. The target is therefore resolved once, here, and every
# call below goes through hdc() which states it.
#
# With one device attached nothing changes. With several, or none, this stops and
# says which ones it can see rather than choosing.
#
# Override with ARK_HDC_TARGET=<id from 'hdc list targets'>.
# ---------------------------------------------------------------------------
HDC_TARGET="${ARK_HDC_TARGET:-}"
if [ -z "$HDC_TARGET" ]; then
    # The tool has to be checked BEFORE it is used, not after.
    #
    # `2>/dev/null` on the line below means "hdc could not be run" and "hdc ran
    # and saw nothing" both arrive here as empty output -- and empty output is
    # the no-device branch, whose message sends the reader to check a cable that
    # was never the problem. The check for this file existed, but further down,
    # so the misleading message came first. Reproduced by pointing HDC at a
    # path that does not exist.
    [ -f "${HDC[0]}" ] || {
        echo "!! hdc not found: ${HDC[0]}" >&2
        echo "!! set ARK_DEVECO_STUDIO, or DEVECO_SDK_HOME, to the right SDK" >&2
        exit 1
    }
    TARGETS="$("${HDC[@]}" list targets 2>/dev/null | tr -d '\r' \
               | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$')"
    TARGET_N="$(printf '%s\n' "$TARGETS" | grep -c .)"
    if [ "$TARGET_N" -eq 0 ]; then
        echo "!! no device attached -- check the cable, then 'hdc list targets'" >&2
        exit 1
    elif [ "$TARGET_N" -gt 1 ]; then
        echo "!! $TARGET_N devices attached, and this script will not guess:" >&2
        printf '     %s\n' $TARGETS >&2
        echo "!! it runs 'uninstall', so picking wrong wipes the wrong device's data." >&2
        echo "!! choose one:   ARK_HDC_TARGET=<id> bash deploy.sh" >&2
        exit 1
    fi
    HDC_TARGET="$TARGETS"
fi
echo "device: $HDC_TARGET"

# Every device call goes through this, so the target is stated exactly once.
hdc() { "${HDC[@]}" -t "$HDC_TARGET" "$@"; }


OUT_DIR="entry/build/default/outputs/default"
# Matches targets[].output.artifactName in entry/build-profile.json5 -- bump the
# two together, with versionName in AppScope/app.json5. verify_hap.py checks
# that all three agree.
#
# NOTE the asymmetry, which is hvigor's and not a typo here: with an
# artifactName of X it writes X.hap SIGNED and X-unsigned.hap unsigned. Measured
# -- the default entry-default-signed.hap name only appears because the default
# artifactName has no version in it.
#
# The signed one is for THIS machine only (see the top of this file) and is not
# a release artifact. What gets published is the unsigned HAP, plus the payload
# zip -- see RELEASE.md.
for f in "${HDC[0]}"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
command -v "${PY[0]}" >/dev/null 2>&1 || [ -f "${PY[0]}" ] || {
    echo "python not found: ${PY[0]} (set ARK_PYTHON)" >&2; exit 1; }

# The HAP's name is ASKED FOR, not written down here.
#
# It used to be a fourth hand-kept copy of the version, and it went stale exactly
# as that predicts: at the v0.1.0-beta1 -> v0.2.0-beta.1 bump this line was not
# touched, so the script looked for a file that no longer existed and stopped at
# "no unsigned hap". verify_hap.py's docstring already names this file as one of
# the places that carry the version, but nothing ever checked it.
#
# scripts/config.py derives the name (ARTIFACT_NAME), so deriving it here removes
# the copy instead of remembering to update it. `|| exit` and the emptiness test
# are both load-bearing: an empty HAP_BASE would become a search for
# "-unsigned.hap", which reads as a missing build rather than as this failure.
HAP_BASE="$("${PY[@]}" -c 'import sys; sys.path.insert(0, "scripts"); import config; sys.stdout.write(config.ARTIFACT_NAME)')" || exit 1
[ -n "$HAP_BASE" ] || {
    echo "!! could not read ARTIFACT_NAME from scripts/config.py" >&2; exit 1; }
UNSIGNED="$OUT_DIR/$HAP_BASE-unsigned.hap"
SIGNED="$OUT_DIR/$HAP_BASE.hap"

if [ "$1" != "--no-build" ]; then
    echo "############ 0/4 check inputs ############"
    # Cheap, and it turns "25 minutes into the build, one input missing" into an
    # immediate, named failure.
    "${PY[@]}" scripts/config.py | sed 's/^/  /'

    echo
    echo "############ 1/4 build ############"

    # GATE: hvigor's native step reports success even when it decides the CMake
    # output is up to date, and it has done exactly that while a source file was
    # NEWER than the object -- so the edit silently never reached the binary and
    # the device kept running the previous build. That failure mode is invisible
    # from the outside: the build says SUCCESSFUL and the on-device log looks like
    # a fresh run. Compare timestamps ourselves and force a rebuild if stale.
    OBJ="entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libmain.so"
    STALE=""
    if [ -f "$OBJ" ]; then
        for src in entry/src/main/cpp/*.c entry/src/main/cpp/*.h; do
            [ -f "$src" ] || continue
            [ "$src" -nt "$OBJ" ] && STALE="$src"
        done
    else
        STALE="(no previous object)"
    fi
    if [ -n "$STALE" ]; then
        echo "!! native object is older than $STALE"
        echo "!! forcing a clean native rebuild"
        rm -rf entry/build/default/intermediates/cmake/default/obj
    fi

    # Remove the previous packages FIRST. Without this a failed build leaves the
    # old HAP in place, every later step succeeds on it, and the device silently
    # receives the PREVIOUS build -- which is precisely what happened here twice.
    # "The file is there" is not evidence that it is this build's file.
    rm -f "$UNSIGNED" "$SIGNED"

    # No "|| true" and no grep-away of the exit status: if the build fails, stop.
    # Swallowing the status is how 3 compile errors in launcher.c went unnoticed
    # while the deploy reported success and installed a stale HAP.
    build_log="$(mktemp)"
    if ! ./build.sh assembleHap >"$build_log" 2>&1; then
        echo "!! BUILD FAILED -- showing errors" >&2
        grep -Ei "error|Error Message" "$build_log" | head -20 >&2
        rm -f "$build_log"
        exit 1
    fi
    grep -Ei "BUILD (SUCCESSFUL|FAILED)|tasks in total" "$build_log"
    grep -Ei "\berror\b" "$build_log" | head -20
    rm -f "$build_log"

    [ -f "$UNSIGNED" ] || {
        echo "no unsigned hap at $UNSIGNED" >&2
        echo "if the name changed, check artifactName in entry/build-profile.json5" >&2
        exit 1
    }

    # same gate, after the fact: prove the artifact is newer than the source now
    if [ -f "$OBJ" ]; then
        for src in entry/src/main/cpp/*.c entry/src/main/cpp/*.h; do
            [ -f "$src" ] || continue
            if [ "$src" -nt "$OBJ" ]; then
                echo "!! STILL STALE after build: $src is newer than $OBJ" >&2
                exit 1
            fi
        done
        echo "native artifact is up to date with sources"
    fi
fi

echo
echo "############ 2/4 verify packaging ############"
PYTHONIOENCODING=utf-8 "${PY[@]}" scripts/verify_hap.py || exit 1
PYTHONIOENCODING=utf-8 "${PY[@]}" scripts/scan_needed.py || exit 1

echo
echo "############ 3/4 install ############"
# Prefer the signed HAP. hvigor only writes one if build-profile.json5 has a
# signing config -- without it there is nothing installable, and saying so here
# is far clearer than an install error about an invalid package.
if [ ! -f "$SIGNED" ]; then
    echo "!! no signed HAP at $SIGNED" >&2
    echo "!! set up signing once: DevEco -> File -> Project Structure ->" >&2
    echo "!! Signing Configs -> Automatically generate signature" >&2
    exit 1
fi
hdc uninstall "$BUNDLE" >/dev/null 2>&1
# Install, and actually check that it happened.
#
# The previous form was `install -r "$SIGNED" 2>&1 | tail -3`, which masked a
# failure twice over: a pipeline's status is tail's and never hdc's, and keeping
# only the last three lines discards a one-line error outright. Measured
# consequence: two runs printed `[Fail]ExecuteCommand need connect-key` and then
# carried on to launch an app that was not installed, while looking for all the
# world like a successful deploy.
#
# The success string is matched positively because a negative check ("no [Fail]")
# cannot tell a failed install from an hdc that printed nothing at all. The exact
# wording is what this hdc emits; a different one would show up as a loud refusal
# rather than as a silent stale install, which is the trade we want.
INSTALL_OUT="$(hdc install -r "$SIGNED" 2>&1)"
printf '%s\n' "$INSTALL_OUT" | tail -3
if ! printf '%s' "$INSTALL_OUT" | grep -q "install bundle successfully"; then
    echo "!! install did not report success -- refusing to launch" >&2
    echo "!! (hdc is flaky on this device: rerun, or check 'hdc list targets')" >&2
    exit 1
fi

echo
echo "############ 4/4 launch + collect ############"
# hilog throttles and drops lines when a failing probe loop repeats the same
# message many times, which is exactly when we most need the full text. The app
# already mirrors stdout/stderr into its own sandbox (redirect_io), and that
# directory IS readable over hdc -- so read the file instead of the log buffer.
#
# NOTE: hdc cannot WRITE into the sandbox, so these logs cannot be cleared from
# here. stdout.log is truncated by the app itself at startup; stderr.log is not,
# so treat it as append-only across runs when reading it after this.
LOG="/data/app/el2/100/base/$BUNDLE/files/stderr.log"
hdc shell hilog -r >/dev/null 2>&1
hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
START_OUT="$(hdc shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)"
printf '%s\n' "$START_OUT" | tail -2
# Same masking as the install above. A failed launch here used to be discovered
# only by noticing that the logs below were empty -- which reads as "the app
# crashed on startup", a completely different problem, and one this project has
# already chased once.
if ! printf '%s' "$START_OUT" | grep -q "start ability successfully"; then
    echo "!! launch did not report success -- the logs below will be empty" >&2
fi
echo "waiting 30 s ..."
sleep 30
echo
echo "===== stderr.log ====="
hdc shell "cat $LOG 2>/dev/null" || true
echo
echo "===== crash.txt ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/crash.txt 2>/dev/null" || true
