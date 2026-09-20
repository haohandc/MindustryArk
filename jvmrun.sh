#!/bin/bash
# Launch the app with a given set of JVM options and report the OUTCOME OF THIS RUN.
#
# WHY THIS EXISTS SEPARATELY FROM tryopts.sh
#   tryopts.sh prints whatever is in stderr.log, which is fine for a human reading
#   one run. It is NOT safe to grep for a success string, because the app truncates
#   that file only when it actually starts: if a launch silently fails (screen
#   locked, app cannot spawn, memory pressure), the file still holds the PREVIOUS
#   run's content and a naive grep reports the previous run's outcome.
#
#   That is the same stale-artifact trap this project has hit twice before -- once
#   with a HAP that was never rebuilt, once with a library that was never
#   re-linked. Here it produced "10/10 success" from a log showing a crash.
#
# HOW THIS AVOIDS IT
#   Record the log file's size and mtime BEFORE launching. After launching, require
#   that both changed -- that is proof this run wrote the file -- and only then
#   look at the content. If they did not change, the outcome is "did not start",
#   which is reported as its own result rather than being confused with success or
#   with a crash.
#
# Usage:  bash jvmrun.sh [-q] [-w seconds] [jvm options...]
#         prints one line:  OK | CRASH <addr> | NOSTART | BADOPT | <other>

set -o pipefail
cd "$(dirname "$0")" || exit 1
export MSYS_NO_PATHCONV=1

HDC=("E:/Program Files/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe")
BUNDLE="com.haohandc.mindustryark"
ABILITY="EntryAbility"
DIR="/data/app/el2/100/base/$BUNDLE/files"
LOG="$DIR/stderr.log"

QUIET=0
if [ "$1" = "-q" ]; then QUIET=1; shift; fi

# How long to let the app run before reading the log. 24 s was tuned for a
# launcher that only started a VM and printed three numbers; once the game's
# main() is called, startup includes loading Megabyte-scale classes and can
# produce its first useful output much later. Override with -w <seconds>.
WAIT=30
if [ "$1" = "-w" ]; then WAIT="$2"; shift 2; fi

before="$("${HDC[@]}" shell "stat -c '%Y %s' $LOG 2>/dev/null" | tr -d '\r\n')"

# ALWAYS send at least one parameter, and make the first one CLEAROPT.
#
# Why: the ArkTS side only rewrites jvm.options when it receives at least one
# jvmopt* parameter. With no parameters it leaves the previous file in place, so a
# run "with no options" silently inherits whatever the previous run set. That is
# not hypothetical -- it produced three bogus "baseline succeeded" results here
# that looked like a flaky crash and nearly buried the actual finding.
#
# CLEAROPT is consumed by the launcher and never passed to the JVM.
ARGS=(--ps "jvmopt0" "CLEAROPT")
i=0
for opt in "$@"; do
    i=$((i + 1))
    ARGS+=(--ps "jvmopt$i" "${opt#-}")
done

"${HDC[@]}" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
"${HDC[@]}" shell "aa start -a $ABILITY -b $BUNDLE $(printf '%s ' "${ARGS[@]}")" >/dev/null 2>&1
sleep "$WAIT"

after="$("${HDC[@]}" shell "stat -c '%Y %s' $LOG 2>/dev/null" | tr -d '\r\n')"
body="$("${HDC[@]}" shell "cat $LOG 2>/dev/null")"

if [ "$before" = "$after" ]; then
    echo "NOSTART     (stderr.log unchanged: this run never wrote it)"
    [ "$QUIET" = "0" ] && echo "$body" | tail -3
    exit 2
fi

# "OK" means the LAUNCHER's own acceptance passed -- the VM came up. That is step
# 3's criterion and it stays meaningful on its own, so the game's outcome is
# reported separately rather than folded into it: the two can and do diverge.
if echo "$body" | grep -q "STEP 4 OK"; then
    echo "STEP4OK     (the game's entry point ran to completion)"
    [ "$QUIET" = "0" ] && echo "$body" | grep -E "JAVA IS RUNNING|class found|calling mindustry|STEP 4 OK"
elif echo "$body" | grep -qE "mindustry\.|arc\.backend|arc\.util\.|arc\.files\."; then
    echo "GAMEFAIL    (the game started and then threw -- see the stack below)"
    [ "$QUIET" = "0" ] && echo "$body" | grep -E "^\s+at (mindustry|arc)\.|Caused by|Exception" | head -6
elif echo "$body" | grep -q "JAVA IS RUNNING"; then
    echo "OK          (VM up; the game did not get far enough to report)"
    [ "$QUIET" = "0" ] && echo "$body" | grep -E "availableProcessors|maxMemory|JAVA IS RUNNING"
elif echo "$body" | grep -q "FATAL SIGNAL"; then
    addr="$(echo "$body" | grep -oE "at 0x[0-9a-f]+" | head -1)"
    echo "CRASH       $addr"
    [ "$QUIET" = "0" ] && echo "$body" | grep -A1 "FATAL SIGNAL" | head -4
elif echo "$body" | grep -q "Unrecognized"; then
    echo "BADOPT      $(echo "$body" | grep Unrecognized | head -1)"
else
    echo "OTHER       $(echo "$body" | tail -2 | head -1)"
fi
