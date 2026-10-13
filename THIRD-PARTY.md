# Third-party components

What this project redistributes, and under what terms.

Each licence below was **read from the upstream repository's own licence file**,
not from memory. Source and date are recorded so the claim can be re-checked.
Retrieved 2026-09-20; the Arc entry re-checked 2026-10-13.

The licence texts themselves ship with the app, in
`entry/src/main/resources/rawfile/licenses/` — and in the payload zip under
`licenses/`. That directory holds **copies**: when a licence changes, re-copy it
there. `make_payload_zip.py` fails if the `THIRD-PARTY.md` copy diverges from
this file.

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
- The Arc sources the build compiles against (`ARK_ARC_SRC`) — Apache-2.0,
  modified by this project; see the Arc section for the changes and how the
  notice obligation is met. They are not committed to this repository.
- The LWJGL payload — BSD-3-Clause.

Each keeps its own terms; they merely have to be compatible with GPL-3.0, and
they are.

## Obligations that apply to this project

### Mindustry — GPL-3.0

A build redistributes an upstream release jar as
`entry/libs/arm64-v8a/game/mindustry.so` — the `.so` name is a packaging
requirement, not a modification (see README).

**The shipped jar is the upstream release, byte for byte.** Since 2026-09-29 the
build no longer writes anything into it: `scripts/patch_mindustry.py` only
*asserts* that `mindustry/desktop/DesktopLauncher.class` and
`mindustry/Vars.class` are still present, so that a jar that is not what it
claims to be fails loudly. The SHA-256 pin in `prep_game.py` (checked in
`verify_hap.py`) identifies exactly which release is shipped.

**Our Arc changes ship beside that jar, not inside it.** They are packed into a
separate jar — `entry/libs/arm64-v8a/patchjar/arcpatch.so` — that the launcher
puts first on `-Djava.class.path`. JVM class resolution takes the first match, so
the patch jar's classes win over the upstream classes of the same name still
present in the game jar. That jar is a build of **Arc**, not of Mindustry, so it
is covered by the Arc section below, not by this one.

**Source obligation.** GPL-3.0 requires the corresponding source to be available
to anyone who receives the binary. Two things satisfy it:

- **This project's own source**, which is why this repository exists and is
  published under GPL-3.0. The build scripts are part of it — they are what
  produce the artifact.
- **Mindustry's source** — upstream, at <https://github.com/Anuken/Mindustry>.
  The game code redistributed here is unmodified, so pointing at upstream is
  sufficient and no fork is needed.

Keep the licence text with any redistribution.

### Arc — Apache-2.0

**Arc's source is modified by this project, and the modified classes are what
ship** — compiled into the patch jar described above by
`scripts/build_arc_patch.py` and packed by `scripts/make_patch_jar.py`. The
compiled classes are what a recipient gets, so the notices required below live
on the sources and are recorded here.

Nine upstream files are modified and three are added:

| File | Change |
|---|---|
| `arc/backend/sdl/SdlApplication.java` | GL context profile and the mobile-mode flag read from system properties; SDL is told the app entered through `SDL_main` |
| `arc/backend/sdl/SdlConfig.java` | `forcedGLVersion` (`-Darc.sdl.glVersion`), so the GL version is requested before the window is created |
| `arc/backend/sdl/SdlInput.java` | Touch pointer handling — finger events, per-pointer state |
| `arc/backend/sdl/SdlFiles.java` | File-browser root separated from the game data path |
| `arc/backend/sdl/SdlGraphics.java` | Select the GL dispatch-table fix, and fall back to a full rebuild when the minimal one is not enough |
| `arc/backend/sdl/SdlGL20.java` | GLES path: `glClearDepth`→`glClearDepthf`, `glDepthRange`→`glDepthRangef`, plus optional call tracing |
| `arc/backend/sdl/SdlGL30.java` | GLES path: `glGetBufferParameteri64`→`...i64v`, `glGetSamplerParameterIiv`→`...iv` |
| `arc/graphics/gl/GLVersion.java` | Read the GLES/desktop flavour out of the version string |
| `arc/graphics/gl/Shader.java` | Pick the GLSL version from the GL flavour, not the application type; explicit precision qualifier on GLES |
| `arc/backend/sdl/GLBootstrap.java` *(new)* | Rebuild LWJGL's GL function-pointer table on a non-desktop context |
| `arc/backend/sdl/GLDispatchFix.java` *(new)* | Minimal `FunctionProvider` wrapper that lets LWJGL fill the table itself |
| `arc/backend/sdl/GLDiag.java` *(new)* | Read-only probe that reports what the dispatch table is missing |

Apache-2.0 §4 obligations, and where each is met:

- **§4(b) — notices on modified files.** Every modified and added source file
  carries a header notice stating that it was changed and when (added
  2026-10-13). The table above is the change record.
- **§4(a) — a copy of the licence.** The Apache-2.0 text ships with the app at
  `entry/src/main/resources/rawfile/licenses/Apache-2.0.txt`, and in the payload
  zip under `licenses/`.
- **§4(c) — retain attribution.** Upstream's copyright headers are left in place;
  Arc is credited in the README.
- **§4(d) — NOTICE file.** Not applicable: upstream Arc has no `NOTICE` file.

Apache-2.0 lets this project distribute the modified classes; it does not require
the modified Arc *source* to be published — only the notices and the licence. The
modified sources live in the Arc checkout the build reads (`ARK_ARC_SRC`), which
is not committed here; the licence and this change record are what travel with
the artifact.

**This section does not apply to `Ark Launcher`.** That package is built in the
`tools` form (`scripts/make_store_app.sh tools`), which removes the whole
`entry/libs/arm64-v8a/` tree — no game jar, no patch jar, no JDK — so it carries
none of the code discussed here.

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
project's combination would be a GPL-2.0 work as a whole. The GPL-2.0 text,
including the Classpath Exception section, ships with the app at
`entry/src/main/resources/rawfile/licenses/OpenJDK-GPLv2-CE.txt`.

The runtime is a prebuilt OpenJDK 21 build for OpenHarmony (musl / aarch64),
taken as-is rather than compiled here. Precisely: it is the build AMCL publishes
as `jdk21-ohos-full-v7.zip` (release `v21.0.5-ohos-7` of
<https://github.com/LZZLHY/mc-ohos-resources>, sha256 `21556d0d…`), which
corresponds to upstream `jdk-21.0.5+11`
(<https://github.com/openjdk/jdk>, commit `dfcd8d2eecfe62e91070244d8eb10906dc3c812d`)
with AMCL's OpenHarmony patches. Every JDK file this project ships was verified
byte-for-byte against that asset; the only difference is the 14 bytes in
`libjvm.so` described below.

**OpenJDK is also modified by this project, and the modified binary is what
ships.** `scripts/prep_vendor.py` calls `scripts/patch_libjvm.py`, which rewrites
`libjvm.so` in place, 7 bytes for 7 bytes: the module image's name `modules`
becomes `jimg.so` in two path format strings. Nothing else in the library is
touched — the `DT_SONAME` is left intact, exactly as the JDK ships it. The result
ships as `jdk21/lib/server/libjvm_real.so` and `verify_hap.py` asserts the patch
is present. GPL-2.0 §2 requires a notice stating the file was changed and when;
§3 requires the corresponding source of the modified binary to be available —
that is upstream OpenJDK (<https://github.com/openjdk/jdk>) plus
`scripts/patch_libjvm.py`, which is the entire change. The other JDK files that
ship (`jimg.so`, `tzdb.so`, and the `conf/` and `lib/security/` trees) are
renamed or copied, not modified.

Note that this is GPL **v2**, unlike Mindustry's v3 — two different GPL versions
are involved here, and they are not interchangeable.

### LWJGL — BSD-3-Clause

Redistributed as jars and natives. Retain the copyright notice, the list of
conditions and the disclaimer, and do not use the "Lightweight Java Game
Library" name to endorse this project.

**Provenance**, because it is not obvious from the files: the LWJGL 3.4.2 set
this project ships was not compiled here. It was taken from a prebuilt
HarmonyOS application that runs this game, which is what makes it a known-good
pair for this platform — the jars and the natives are version-checked against
each other by `prep_lwjgl.py`, and every file is pinned by SHA-1 there. They are
LWJGL's own released binaries; what the other application contributed is the
evidence that they work here, not a modification.

## Not in this repository

Neither the payload nor the inputs it is assembled from are committed (see
`.gitignore`): the Mindustry jar, the JDK, and the LWJGL and Arc natives. They
are supplied by whoever builds the project — `payload-src/README.md` says which
files and where they come from — or shipped as Release assets.

That reduces the size of the repository but does **not** remove any of the
obligations above: **a Release asset is redistribution too**, so a published HAP
or payload zip carries every licence and source obligation listed here exactly as
a clone would. `RELEASE.md` covers what may be published at all.

## Attribution

- Mindustry and Arc, by **Anuken** — <https://github.com/Anuken/Mindustry>,
  <https://github.com/Anuken/Arc>
- SDL3 — <https://github.com/libsdl-org/SDL>
- LWJGL — <https://www.lwjgl.org/>
- OpenJDK — <https://openjdk.org/>; the OpenHarmony build redistributed here is
  published by **AMCL** — <https://github.com/LZZLHY/amcl>

## This project is unofficial

Not affiliated with, endorsed by, or supported by any of the projects above.
"Mindustry" refers to the upstream game and is used only to say what this
launcher runs.
