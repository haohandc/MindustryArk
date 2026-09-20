# Third-party components

What this project redistributes, and under what terms.

Each licence below was **read from the upstream repository's own licence file**,
not from memory. Source and date are recorded so the claim can be re-checked.
Retrieved 2026-09-20.

| Component | Licence | Verified from |
|---|---|---|
| Mindustry | **GPL-3.0** | <https://raw.githubusercontent.com/Anuken/Mindustry/master/LICENSE> |
| Arc | **Apache-2.0** | <https://raw.githubusercontent.com/Anuken/Arc/master/LICENSE> |
| SDL3 | **Zlib** | <https://raw.githubusercontent.com/libsdl-org/SDL/main/LICENSE.txt> |
| LWJGL | **BSD-3-Clause** | <https://raw.githubusercontent.com/LWJGL/lwjgl3/master/LICENSE.md> |
| OpenJDK 21 | **GPL-2.0 with Classpath Exception** | <https://raw.githubusercontent.com/openjdk/jdk/master/LICENSE> — GPL v2 text plus an explicit `"CLASSPATH" EXCEPTION TO THE GPL` section |

## Why this project is GPL-3.0

A build redistributes Mindustry, so the licence of this project is not a free
choice. GPL-3.0 §5 defines an "aggregate" as a compilation of works that are
*not* extensions of one another and are *not* combined so as to form a larger
program; the covered work can sit in an aggregate without pulling the rest under
its licence. That exemption does not apply here:

- a HAP is a single installable unit, not a directory of independent programs;
- the launcher exists to run Mindustry and does nothing else;
- the game jar is packaged into the same artifact as the launcher.

That is a combined work, so the whole is GPL-3.0. Choosing it deliberately is
also the cheapest option: for a project that is open anyway it costs nothing,
and it removes the question entirely.

**Compatibility check.** Every other component permits this combination:

| Component | Compatible with GPL-3.0? |
|---|---|
| Arc (Apache-2.0) | Yes. Apache-2.0 is compatible with GPL-3 — note it is *not* compatible with GPL-2, which is why the version matters |
| SDL3 (Zlib) | Yes, permissive |
| LWJGL (BSD-3) | Yes, permissive |
| OpenJDK 21 (GPL-2 + Classpath Exception) | Yes, **because of the Classpath Exception**, which explicitly permits linking the library with independent modules and distributing the resulting executable under terms of the user's choice |

Two different GPL versions appear in this stack — v3 for Mindustry, v2 for
OpenJDK — and they are not interchangeable. The JDK side only works out because
of the exception.

> This is a reading of the licence texts, not legal advice. The texts were
> fetched and read (sources above) rather than recalled, but if the distinction
> matters commercially, have someone qualified check it.

## Third-party files are not relicensed

The GPL-3.0 above covers this project. It does not relicense the third-party
files vendored inside it:

- `entry/src/main/cpp/SDL/` — Zlib-licensed SDL3, with local modifications.
  Zlib condition 2 requires that altered versions be **plainly marked as such**
  and not misrepresented as the original, so do not describe this tree as plain
  SDL3.
- Vendored Arc sources referenced by `scripts/` — Apache-2.0, unchanged in
  licence by being built against.
- The LWJGL payload — BSD-3-Clause.

Each keeps its own terms; they merely have to be compatible with GPL-3.0, and
they are.

## Obligations that apply to this project

### Mindustry — GPL-3.0

A build redistributes an upstream release jar as
`entry/libs/arm64-v8a/game/mindustry.so` — the `.so` name is a packaging
requirement, not a modification (see README).

**Which parts of that jar are modified, precisely**, because the source
obligation depends on it:

| Part of the jar | State |
|---|---|
| `mindustry/**` (the game itself) | **Unmodified.** `scripts/patch_mindustry.py` does not rewrite these; it only *asserts* that `mindustry/desktop/DesktopLauncher.class` and `mindustry/Vars.class` are still present, so that a jar that is not what it claims to be fails loudly |
| `arc/backend/sdl/**` and `arc/graphics/gl/**` (the framework) | **Replaced** with builds from patched sources — see the Arc section |
| `arc/backend/sdl/jni/**` | Preserved deliberately: Mindustry's own classes still reference them |

So the jar as a whole is **not** byte-identical to upstream; it is an upstream
jar with the framework's backend classes swapped. The pinned SHA-1 in
`prep_game.py` (checked in `verify_hap.py`) identifies exactly which build is
shipped.

**Source obligation.** GPL-3.0 requires the corresponding source to be available
to anyone who receives the binary. That now covers two things:

- **This project's own source**, which is why this repository exists and is
  published under GPL-3.0. The build scripts are part of it — they are what
  produce the artifact.
- **Mindustry's source**, for the unmodified game code — upstream, at
  <https://github.com/Anuken/Mindustry>. Because those classes are unmodified,
  pointing at upstream is sufficient and no fork is needed.

Keep the licence text with any redistribution.

### Arc — Apache-2.0

**Arc's source is modified by this project.** `scripts/build_arc_patch.py`
recompiles three classes from patched sources and `scripts/patch_mindustry.py`
writes them into the jar:

| Class | What was changed |
|---|---|
| `arc/backend/sdl/SdlApplication.java` | GL context profile and mobile-mode flag read from system properties |
| `arc/backend/sdl/SdlInput.java` | Touch pointer handling: finger events, per-pointer state |
| `arc/backend/sdl/SdlFiles.java` | File-browser root separated from the game data path |

Apache-2.0 §4(b) requires modified files to carry prominent notices stating that
they were changed, and §4(a)/(c) require the licence and attribution notices to
be retained. The patch scripts are what actually produce those files, so the
provenance is reproducible even though the compiled classes are what ship.

### SDL3 — Zlib

**SDL3's source is modified by this project** (OpenHarmony input, windowing and
audio paths under `entry/src/main/cpp/SDL/`).

Zlib's conditions require that (1) the origin not be misrepresented, (2) **altered
source versions be plainly marked as such** and not passed off as the original,
and (3) the notice not be removed. Point 2 is the one to keep an eye on: this
repository ships a modified SDL tree, so **do not describe it as plain SDL3**.
The modifications are confined to the OpenHarmony backend directories.

### OpenJDK 21 — GPL-2.0 with Classpath Exception

The embedded runtime is redistributed. The Classpath Exception is what permits
linking and shipping it alongside a work under other terms; without it this
project's combination would be a GPL-2.0 work as a whole.

Note that this is GPL **v2**, unlike Mindustry's v3 — two different GPL versions
are involved here, and they are not interchangeable.

### LWJGL — BSD-3-Clause

Redistributed as jars and natives. Retain the copyright notice, the list of
conditions and the disclaimer, and do not use the "Lightweight Java Game
Library" name to endorse this project.

## Not in this repository

The Mindustry jar, the JDK and the Arc natives are **not committed**
(see `.gitignore`). They are supplied by whoever builds the project, or shipped
as Release assets. That reduces the size of the repository but does **not**
remove any of the obligations above — Release assets are still redistribution.

## Attribution

- Mindustry and Arc, by **Anuken** — <https://github.com/Anuken/Mindustry>,
  <https://github.com/Anuken/Arc>
- SDL3 — <https://github.com/libsdl-org/SDL>
- LWJGL — <https://www.lwjgl.org/>
- OpenJDK — <https://openjdk.org/>

## This project is unofficial

Not affiliated with, endorsed by, or supported by any of the projects above.
"Mindustry" refers to the upstream game and is used only to say what this
launcher runs.
