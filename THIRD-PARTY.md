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

## Obligations that apply to this project

### Mindustry — GPL-3.0

A build redistributes an **unmodified upstream jar** as
`entry/libs/arm64-v8a/game/mindustry.so` (the `.so` name is a packaging
requirement, not a modification — see README).

Redistributing a GPL-3 work means the corresponding source must be available to
whoever receives it. Because the jar is unmodified, pointing at upstream
satisfies this: the exact release is identified by the SHA-1 pinned in
`prep_game.py` and checked in `verify_hap.py`, and the source for it is at
<https://github.com/Anuken/Mindustry>. If that ever stops being true — if the
jar is ever patched — this section must be rewritten, because it would then be a
modified work and the source obligation changes.

Keep the licence text with any redistribution.

### Arc — Apache-2.0

**Arc's source is modified by this project.** `tools/build_arc_patch.py`
recompiles three classes from patched sources and `tools/patch_mindustry.py`
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
