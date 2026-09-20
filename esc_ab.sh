#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A/B harness for issue #11 -- ESC is treated as the system Back button.
#
# It measures exactly two things per run, and reports them as a pair:
#   (1) did SDL still receive the raw keycode?   -> sdl_keys.log delta
#   (2) did the app stay in the foreground?      -> aa dump -l mission state
#
# Why a pair: the whole question is whether consuming the key in ArkUI blocks
# the native callback. Either half alone is useless -- "app stayed" without
# "SDL saw it" would mean we broke the game's ESC handling instead of fixing
# the system one.
#
# Two measurement traps this harness is built to avoid:
#
#   * sdl_keys.log lives in the sandbox, which the host can read but NOT write,
#     so it cannot be truncated. It is opened O_APPEND by the probe and grows
#     across runs. We therefore record its size first and read only the bytes
#     past that offset. Reading the whole file would show the PREVIOUS run's
#     keys and look exactly like a positive result -- this project has already
#     lost a round to a stale log once.
#
#   * The app needs ~10-20 s before the main menu is up. Injecting earlier
#     would test nothing, because no window exists to receive the key yet. We
#     poll stdout.log for the load-complete marker instead of guessing.
#
#     stdout.log IS truncated when the app starts (measured: 12693 bytes before
#     a restart, 12531 after), so a plain grep over it can only ever match this
#     run. sdl_keys.log is the opposite -- append-only, never truncated -- which
#     is why only that one uses an offset.
#
# Usage:  bash esc_ab.sh <label>
# ---------------------------------------------------------------------------
set -u
export MSYS_NO_PATHCONV=1
HDC="/e/Program Files/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
BUNDLE=com.haohandc.mindustryark
D="/data/app/el2/100/base/$BUNDLE/files"
KEYS="$D/sdl_keys.log"
OUT="$D/stdout.log"
LABEL="${1:-run}"

sh_() { "$HDC" shell "$1" 2>&1 | tr -d '\r'; }
size_of() { sh_ "wc -c < $1 2>/dev/null || echo 0" | tail -1 | tr -d ' '; }

# Mission state of our ability, as the system reports it.
fg_state() {
  sh_ "aa dump -l" \
    | grep -A20 "myapplication:entry:EntryAbility" \
    | grep -m1 "state #" \
    | sed 's/^ *//'
}

echo "=============================================================="
echo " RUN: $LABEL"
echo "=============================================================="

KEY0=$(size_of "$KEYS")
echo "offset before: sdl_keys.log=$KEY0  (stdout.log is truncated at start)"

echo "-- fresh start --"
sh_ "aa force-stop $BUNDLE" >/dev/null
sleep 2
sh_ "aa start -a EntryAbility -b $BUNDLE" >/dev/null

echo "-- waiting for the main menu (polling stdout.log for the marker) --"
ready=no
waited=0
for i in $(seq 1 30); do
  sleep 2
  waited=$((i * 2))
  if [ "$(sh_ "grep -c 'Total time to load' $OUT" | tail -1)" != "0" ]; then
    ready=yes
    break
  fi
done
echo "   ready=$ready  (waited ${waited}s)"
if [ "$ready" != yes ]; then
  echo "   !! never reached the main menu -- result would be meaningless"
  echo "   !! tail of stdout.log:"
  sh_ "tail -5 $OUT" | sed 's/^/      /'
  exit 1
fi
sleep 3
echo "   foreground BEFORE inject: $(fg_state)"

echo "-- inject ESC (keyEvent 2070) --"
sh_ "uitest uiInput keyEvent 2070" | sed 's/^/   /'
sleep 3

echo "   foreground AFTER  inject: $(fg_state)"
echo

echo "-- sdl_keys.log delta (bytes $KEY0..end) --"
KEY1=$(size_of "$KEYS")
if [ "$KEY1" -le "$KEY0" ]; then
  echo "   (no new bytes at all -- SDL received NOTHING)"
else
  sh_ "tail -c +$((KEY0 + 1)) $KEYS" | sed 's/^/   /'
fi
echo

echo "-- verdict --"
n2070=$(sh_ "tail -c +$((KEY0 + 1)) $KEYS" | grep -c "raw_code=2070")
state=$(fg_state)
echo "   SDL saw ESC      : $n2070 line(s) with raw_code=2070"
echo "   app foreground   : $state"
if [ "$n2070" -gt 0 ] && echo "$state" | grep -q FOREGROUND; then
  echo "   => PASS: ESC reached the game AND the app stayed put"
elif [ "$n2070" -eq 0 ]; then
  echo "   => FAIL(cut): consuming the key killed the native callback too"
else
  echo "   => FAIL(exit): SDL saw the key, but the app still left the foreground"
fi
