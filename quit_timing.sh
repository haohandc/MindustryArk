#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Timing harness for issue #13 -- "the picture freezes on Quit, but the app
# only really exits about 5 seconds later."
#
# The question is not *whether* there is a delay (the user has seen it) but
# WHERE it sits: between which two moments. So this records a timeline of
# three things at once, sampled every ~250 ms, and reports the gaps:
#
#   t        device wall clock, ms
#   pid      is the process still alive?
#   logsize  bytes in stderr.log
#
# From those come two events whose distance IS the delay:
#
#   T_freeze = the last moment logsize changed. The game's own logging
#              (Arc's mixer/GL traffic) stops when the main loop stops, so the
#              last byte written is a proxy for "picture froze".
#   T_exit   = the last sample where pid was still present.
#
# Both proxies are coarse -- sampling caps resolution at ~250 ms, and "freeze"
# is inferred from a side effect rather than observed directly. That is fine
# for a 5-second effect. If the answer comes back under ~1 s, this harness is
# too blunt and the real question becomes different.
#
# The click coordinate is the main-menu Quit button in the mobile grid:
#   screenshot  2800x1840, Quit at displayed (1149, 737) in a 2000x1314 view
#   => 1149 * 1.4 = 1609 ,  737 * 1.4 = 1032   (screen pixels)
#
# Usage:  bash quit_timing.sh [x] [y]
# ---------------------------------------------------------------------------
set -u
export MSYS_NO_PATHCONV=1
HDC="/e/Program Files/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
B=com.haohandc.mindustryark
D="/data/app/el2/100/base/$B/files"
X="${1:-1609}"
Y="${2:-1032}"
LOG="$PWD/_quit_timeline.txt"

sh_() { "$HDC" shell "$1" 2>&1 | tr -d '\r'; }

# One round trip per sample: clock, liveness and log size together. Three
# separate hdc calls would cost ~1 s of jitter and smear the very interval
# we are trying to measure.
sample() {
  sh_ "date +%s%3N; pidof $B || echo NOPID; wc -c < $D/stderr.log 2>/dev/null || echo 0"
}

echo "=== restart to a clean main menu ==="
sh_ "aa force-stop $B" >/dev/null
sleep 2
sh_ "aa start -a EntryAbility -b $B" >/dev/null
for i in $(seq 1 30); do
  sleep 2
  if [ "$(sh_ "grep -c 'Total time to load' $D/stdout.log 2>/dev/null" | tail -1)" != "0" ]; then
    echo "   ready after ~$((i * 2))s"; break
  fi
done
sleep 3

sh_ "hilog -r" >/dev/null
T0=$(sh_ "date +%s%3N" | tail -1)
echo "=== T0 (device ms) = $T0 ==="
echo "=== click Quit at ($X, $Y) ==="
sh_ "uitest uiInput click $X $Y" | sed 's/^/   /'

: > "$LOG"
for i in $(seq 1 60); do
  out=$(sample)
  t=$(echo "$out" | sed -n '1p')
  pid=$(echo "$out" | sed -n '2p')
  sz=$(echo "$out" | sed -n '3p')
  echo "$((t - T0)) $pid $sz" >> "$LOG"
  if [ "$pid" = "NOPID" ] && [ "$i" -gt 4 ]; then break; fi
done

echo
echo "=== timeline (ms_since_click  pid  logsize) ==="
cat "$LOG" | awk '
  NR==1 { pf=$3; print; next }
  {
    flag = ($3 != pf) ? "  <- log advanced" : ""
    if ($2 == "NOPID" && prevpid != "NOPID") flag = flag "  <== PROCESS GONE"
    if (flag != "") print $0 flag
    prevpid = $2; pf = $3
  }'
echo "   (unchanged rows omitted; logsize is NOT a freeze detector --"
echo "    the mixer callback only logs every 100 callbacks, so idle silences"
echo "    of 10+ s are normal. The pid is the honest signal here.)"
echo
echo "=========================== VERDICT ==========================="
awk '
  $2 == "NOPID" { print "   exit delay (click -> process gone) = " $1 " ms"; found=1; exit }
  END { if (!found) print "   process still alive at end of window" }
' "$LOG"
