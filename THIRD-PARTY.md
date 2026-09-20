# Third-party components

What this project redistributes, and under what terms.

> **Status: the licence identifiers below are stated from prior knowledge and
> have NOT been verified against the upstream repositories or the files
> themselves.** The Mindustry jar in this project ships no licence file, so
> nothing could be confirmed from the artifacts on hand. Before publishing a
> release, verify each row against its upstream project and correct anything
> that is wrong. This is the one part of the repository that is a claim rather
> than a measurement.

## Redistributed as part of a build

| Component | Licence (unverified) | How it is used here | What that likely obliges |
|---|---|---|---|
| **Mindustry** | GPL-3.0 | The game, loaded unmodified. A build's `entry/libs/arm64-v8a/game/mindustry.so` **is** an upstream release jar | Redistributing a GPL binary: the licence text must accompany it, and the corresponding source must be made available |
| **Arc** | Apache-2.0 | The game framework. `arc/backend/sdl/**` and `arc/graphics/gl/**` are **modified** (`tools/build_arc_patch.py`) | Modified files redistributed: keep the licence and attribution notices, and state that the files were changed |
| **LWJGL** | BSD-3-Clause | JNI bindings for OpenGL and SDL | Keep the copyright notice and licence text |
| **SDL3** | Zlib | Windowing, input, audio | Keep the notice; it must not be misrepresented as the original |
| **OpenJDK 21** | GPL-2.0-with-classpath-exception | The embedded runtime | Redistributing binaries: the licence text must accompany them. The Classpath Exception is what allows this to be linked and shipped with a non-GPL application |

## Not redistributed

The Mindustry jar and the JDK are **not** in this git repository
(see `.gitignore`). They are supplied by whoever builds it, or shipped as
Release assets. That reduces, but does not remove, the obligations above --
Release assets are still redistribution.

## Attribution

- Mindustry and Arc are by **Anuken** — <https://github.com/Anuken/Mindustry>,
  <https://github.com/Anuken/Arc>
- SDL3 — <https://github.com/libsdl-org/SDL>
- LWJGL — <https://www.lwjgl.org/>
- OpenJDK — <https://openjdk.org/>

## This project is unofficial

Not affiliated with, endorsed by, or supported by any of the projects above.
"Mindustry" refers to the upstream game and is used only to describe what this
launcher runs.
