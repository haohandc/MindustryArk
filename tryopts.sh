#!/bin/bash
# Try JVM options WITHOUT rebuilding: pass them as launch parameters, which the
# ArkTS side writes into a file that myapp.c reads before JNI_CreateJavaVM.
#
# The plumbing is necessary because nothing on the host can write into the app's
# sandbox: hdc can read /data/app/el2/.../files but not write it, the app cannot
# read /data/local/tmp, and the Download directory rejects both. Launch
# parameters are the one channel that reaches the app's own file APIs.
#
# Usage:
#   bash tryopts.sh                        # run with no extra options
#   bash tryopts.sh -Xint
#   bash tryopts.sh -Xint -XX:+UseSerialGC

set -o pipefail
cd "$(dirname "$0")" || exit 1

export MSYS_NO_PATHCONV=1

HDC=("E:/Program Files/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe")
BUNDLE="com.haohandc.mindustryark"
ABILITY="EntryAbility"
LOG="/data/app/el2/100/base/$BUNDLE/files/stderr.log"

ARGS=()
i=0
for opt in "$@"; do
    i=$((i + 1))
    # 'aa start' rejects a --ps value starting with '-'; ArkTS puts the dash
    # back. So strip it here and keep the normal command-line spelling.
    ARGS+=(--ps "jvmopt$i" "${opt#-}")
done

echo "== options =="
[ "$#" -eq 0 ] && echo "   (none)" || printf '   %s\n' "$@"

"${HDC[@]}" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
"${HDC[@]}" shell "aa start -a $ABILITY -b $BUNDLE $(printf '%s ' "${ARGS[@]}")" 2>&1 | tail -1
sleep 25

echo
echo "== result =="
"${HDC[@]}" shell "grep -E 'option|JNI_CreateJavaVM|JVM CREATED|HELLO|currentTimeMillis|availableProcessors|FATAL|mapping:|dcps1' $LOG 2>/dev/null" | tail -20
echo
"${HDC[@]}" shell "[ -f /data/app/el2/100/base/$BUNDLE/files/crash.txt ] && tail -2 /data/app/el2/100/base/$BUNDLE/files/crash.txt"
