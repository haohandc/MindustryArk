#!/bin/bash
# Install the STORE-CONFIGURATION package on a device and collect what it said.
#
# WHY THIS IS NOT deploy.sh
#   deploy.sh refuses to install anything that fails verify_hap.py, and that gate
#   fails BY DESIGN on this package: verify_hap.py pins the DEBUG buildMode's
#   native bytes, while the store configuration strips them. See
#   RELEASE-MAINTENANCE.md 2.2 -- the FAIL is the gate working, not a stale pin,
#   and it is the reason nobody had ever run this configuration.
#
#   So this script does the install and the log collection and skips the gate.
#   It does NOT skip anything else: it checks the install and the launch actually
#   reported success, because "the logs are empty" reads as "it crashed" and is
#   the same mistake deploy.sh was written to stop making.
#
# WHAT IT IS FOR
#   Reproducing "游戏闪退" from the AppGallery review, which the reviewer hit on a
#   Mate 60 with the store package. The package built for this is
#   product=default + buildMode=release: identical variables (release buildMode,
#   stripped natives) but signed with the debug certificate, so it can be
#   sideloaded. Build it with:
#
#     bash build.sh assembleHap --mode module -p product=default -p buildMode=release
#
# Usage:
#   bash scripts/install_repro.sh                  # one device, or ARK_HDC_TARGET
#   ARK_HDC_TARGET=<id> bash scripts/install_repro.sh
#
# ⚠️ It runs `uninstall` first, which ERASES the app sandbox (saves, and the
#    Download-folder grant). Export saves before running it.

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

BUNDLE="com.haohandc.mindustryark"
ABILITY="EntryAbility"
STUDIO="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}"
SDK_HOME="${DEVECO_SDK_HOME:-$STUDIO/sdk}"
HDC=("$SDK_HOME/default/openharmony/toolchains/hdc.exe")
PY=("${ARK_PYTHON:-python}")

[ -f "${HDC[0]}" ] || { echo "!! hdc not found: ${HDC[0]}" >&2; exit 1; }

# ---- which device (same rule as deploy.sh: never guess) --------------------
HDC_TARGET="${ARK_HDC_TARGET:-}"
if [ -z "$HDC_TARGET" ]; then
    TARGETS="$("${HDC[@]}" list targets 2>/dev/null | tr -d '\r' \
               | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$')"
    TARGET_N="$(printf '%s\n' "$TARGETS" | grep -c .)"
    if [ "$TARGET_N" -eq 0 ]; then
        echo "!! no device attached -- check the cable, then 'hdc list targets'" >&2
        exit 1
    elif [ "$TARGET_N" -gt 1 ]; then
        echo "!! $TARGET_N devices attached, and this script will not guess:" >&2
        printf '     %s\n' $TARGETS >&2
        echo "!! choose one:   ARK_HDC_TARGET=<id> bash scripts/install_repro.sh" >&2
        exit 1
    fi
    HDC_TARGET="$TARGETS"
fi
hdc() { "${HDC[@]}" -t "$HDC_TARGET" "$@"; }
echo "device: $HDC_TARGET"

HAP_BASE="$("${PY[@]}" -c 'import sys; sys.path.insert(0,"scripts"); import config; sys.stdout.write(config.ARTIFACT_NAME)')" || exit 1
SIGNED="entry/build/default/outputs/default/$HAP_BASE.hap"
[ -f "$SIGNED" ] || { echo "!! no signed HAP at $SIGNED" >&2; exit 1; }

echo
echo "===== packaged as ====="
"${PY[@]}" - "$SIGNED" <<'EOF'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
v = json.loads(z.read("pack.info").decode())["summary"]["app"]["version"]
j = z.read("libs/arm64-v8a/jdk21/lib/server/libjvm_real.so")
print("  versionName %s  versionCode %s" % (v["name"], v["code"]))
print("  libjvm_real %d B   .symtab=%s   <- stripped means store configuration"
      % (len(j), b".symtab" in j))
EOF

echo
echo "===== install ====="
hdc uninstall "$BUNDLE" >/dev/null 2>&1
INSTALL_OUT="$(hdc install -r "$SIGNED" 2>&1)"
printf '%s\n' "$INSTALL_OUT" | tail -3
printf '%s' "$INSTALL_OUT" | grep -q "install bundle successfully" || {
    echo "!! install did not report success -- refusing to launch" >&2; exit 1; }

echo
echo "===== launch + wait 30 s ====="
hdc shell hilog -r >/dev/null 2>&1
hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
START_OUT="$(hdc shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)"
printf '%s\n' "$START_OUT" | tail -2
printf '%s' "$START_OUT" | grep -q "start ability successfully" \
    || echo "!! launch did not report success -- logs below will be empty" >&2
sleep 30

echo
echo "===== is it still running? ====="
PID="$(hdc shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')"
if [ -n "$PID" ]; then
    echo "  YES  pid=$PID   <- it did NOT crash on launch"
else
    echo "  NO   process is gone  <- it crashed, or exited"
fi

echo
echo "===== the launcher's own stderr.log ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/stderr.log 2>/dev/null" || true
echo
echo "===== the launcher's own crash.txt ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/crash.txt 2>/dev/null" || true

# The faultlog is where a fault that never reached our handler ends up.
# `hdc file recv` reaches it even though `ls` on the same directory is refused.
echo
echo "===== faultlog (pulled, not printed) ====="
OUT_DIR="_faultlog_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
for d in /data/log/faultlog/faultlogger /data/log/faultlog/temp; do
    hdc file recv "$d" "$OUT_DIR" 2>&1 | tail -2
done
echo "  -> $OUT_DIR"
ls -la "$OUT_DIR" 2>/dev/null | tail -12
echo
echo "give the whole $OUT_DIR directory back, plus the two logs above."
