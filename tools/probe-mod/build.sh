#!/bin/bash
# Build the probe mod jar -- the artifact that answers one question:
#   can a class loaded at runtime out of a mod jar be defined and executed
#   under this launcher's JVM?
#
# WHY IT IS BUILT AGAINST THE GAME JAR
#   Mindustry checks, at load time, that the mod's superclass came from the SAME
#   class loader as mindustry.mod.Mod, and refuses the mod if it did not
#   ("This mod/plugin has loaded Mindustry dependencies from its own class
#   loader..."). So mindustry.jar must be a COMPILE-time dependency and must NOT
#   end up inside the output. That is why the classpath is passed to javac and
#   the jar is assembled from the class files alone -- never from the classpath.
#
# Output: tools/probe-mod/out/probe-mod.jar
#
# Usage:
#   bash tools/probe-mod/build.sh

set -o pipefail
cd "$(dirname "$0")/../.." || exit 1

JDK="${ARK_JDK:-C:/Program Files/Java/jdk-17}"
JAVAC="$JDK/bin/javac.exe"
JAR="$JDK/bin/jar.exe"
GAME_JAR="payload-src/mindustry-1.0.jar"
SRC="tools/probe-mod/ProbeMod.java"
OUT="tools/probe-mod/out"
CLASSES="$OUT/classes"

[ -f "$JAVAC" ] || { echo "!! javac not found: $JAVAC  (set ARK_JDK)" >&2; exit 1; }
[ -f "$JAR" ]   || { echo "!! jar not found: $JAR" >&2; exit 1; }
[ -f "$GAME_JAR" ] || { echo "!! game jar not found: $GAME_JAR" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$CLASSES"

echo "=== compiling (against the game jar, so this must match its bytecode level) ==="
# The game is Java 17 (class file major 61). --release 17 keeps the probe at the
# same level; a newer level would be refused at load time with no useful message.
"$JAVAC" --release 17 -cp "$GAME_JAR" -d "$CLASSES" "$SRC" || exit 1
echo "   ok"

echo
echo "=== packaging ==="
cp tools/probe-mod/mod.json "$CLASSES/mod.json"
"$JAR" --create --file "$OUT/probe-mod.jar" -C "$CLASSES" . || exit 1

echo
echo "=== the built artifact ==="
"$JAR" --list --file "$OUT/probe-mod.jar" | sed 's/^/   /'
echo
echo "   $OUT/probe-mod.jar   $(stat -c%s "$OUT/probe-mod.jar") B"
echo "   sha256 $(sha256sum "$OUT/probe-mod.jar" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
# GATE: the output must NOT contain any Mindustry classes.
#
# javac is given the game jar on its classpath, and it would be an easy mistake
# to later "simplify" this script into packaging the classpath into the jar. The
# game refuses such a mod by name, but it refuses it AT RUNTIME on the device,
# which costs a build and a 171 MB install to discover. Check it here instead.
# ---------------------------------------------------------------------------
echo
if "$JAR" --list --file "$OUT/probe-mod.jar" | grep -qE '^(mindustry|arc|rhino)/'; then
    echo "!! the probe jar contains game classes -- the game will refuse it:" >&2
    "$JAR" --list --file "$OUT/probe-mod.jar" | grep -E '^(mindustry|arc|rhino)/' | head -5 >&2
    exit 1
fi
echo "   gate: no game classes bundled"

# ---------------------------------------------------------------------------
# THIS NO LONGER INSTALLS ANYTHING INTO THE BUNDLE, and that is the change.
#
# It used to copy the jar to entry/libs/arm64-v8a/probe/probe-mod.jar.so, from
# where ArkTS (seedProbeMod in Index.ets) copied it into the game's mods
# directory at every launch. BOTH HALVES ARE GONE:
#
#   * the seeding was an UNCONDITIONAL overwrite at every launch, so deleting
#     probe-mod.jar in the game put it back -- the same defect as the folder scan
#     and the floating ball's import row, all three removed together.
#   * with nothing copying it out, installing it into libs/ only ships 1.2 KB of
#     unused jar inside every HAP.
#
# The build itself still works and still gates the result, so this remains the
# description of how the probe is made. To use one now, copy the jar below into
# the game's mods directory by hand (through the game's own import button), or
# restore the seeding from git history if an automatic planting is really wanted
# again.
#
# ⚠️ Do not re-add the copy into libs/ without also deciding what happens when
#    the player deletes the mod. The old answer was "it comes back", and that is
#    the answer the whole importer was removed for.
# ---------------------------------------------------------------------------
echo
echo "   built -> $OUT/probe-mod.jar"
echo "   (not installed into the bundle; see the note above)"
