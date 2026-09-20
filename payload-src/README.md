# payload-src — the build's inputs

Everything the `prep_*.py` scripts consume lives here. **Nothing in this
directory is committed** (see `.gitignore`), because all of it is either large,
reproducible, or both. This file is committed: it is the list of what has to be
present, and the hashes each file must have.

Two directories in this repository start with `payload` and they are not the
same thing:

| Directory | What | Committed |
|---|---|---|
| `payload-src/` (here) | The **inputs**: jars, JDK pieces, LWJGL set | no |
| `entry/libs/` | The **output**: what the scripts assemble and hvigor packs | no |

`scripts/config.py` is what points the scripts at this directory, and every path
below can be pointed somewhere else instead — see the `ARK_*` variables in that
file. Run `python scripts/config.py` to print the resolved paths and whether
each one is present.

## What goes here

```
payload-src/
├── Mindustry.jar                 the upstream release jar, unmodified
├── mindustry-1.0.jar             DERIVED: the upstream jar + Arc patches
├── mindustry-1.0-audio.jar       DERIVED: the above + the audio natives   <- the pinned one
├── lwjgl-ohos/
│   ├── lwjgl.jar                 LWJGL 3.4.2 Java half
│   ├── lwjgl-opengl.jar
│   ├── lwjgl-sdl.jar
│   ├── liblwjgl.so               LWJGL 3.4.2 native half
│   └── liblwjgl_opengl.so
└── jdk21slim/
    └── lib/
        ├── libcxxabi_shim.so     shipped as-is; verify_hap.py pins its SHA-1
        └── server/libjvm.so      the JVM that gets patched and shipped
```

The three `mindustry-*.jar` files are **derived**, so you do not need to supply
them: drop `Mindustry.jar` in and run the chain in `README.md`. They live here
rather than in a scratch directory so that the chain — patch, repack, variant —
can be re-run in place without anything being copied by hand between stages.

`jdk21slim` is the one thing here that is neither upstream nor reproducible from
this repository: it is an OpenJDK 21 build for OpenHarmony (musl / aarch64)
whose `lib/` and `conf/` have been trimmed to a runtime. A desktop JDK will not
do. It travels in the payload release.

## Where each file comes from

| File | Source |
|---|---|
| `Mindustry.jar` | An official Mindustry release. Any build whose class files are major version 61 (Java 17) works; `patch_mindustry.py` identifies it by content |
| `lwjgl-ohos/` | LWJGL 3.4.2 for this platform. The copy used here was collected from a prebuilt HarmonyOS application that runs this game, which makes it a known-good set — but any 3.4.2 pair will do, and `prep_lwjgl.py` refuses to mix versions |
| `jdk21slim/` | The payload release (see `RELEASE.md`) |
| the three `mindustry-*.jar` | Produced here by `patch_mindustry.py` and `build_variants.py` |

## Why the hashes matter

Every script checks its input's SHA-1 before writing anything, and
`verify_hap.py` re-checks the result inside the built package. This is not
ceremony: this project has twice shipped an artifact that was not the one it
thought it was — once by re-running an upstream stage and forgetting a
downstream one, once by reusing a stale library — and in both cases the build
reported success. The pinned SHA-1 of the audio jar is the anchor that caught
it, and it appears in two places that must be changed together:

- `scripts/prep_game.py` — `SRC_SHA1`
- `scripts/verify_hap.py` — `WANT_GAME`

If you re-run the jar chain, both have to be updated to the new hash, and this
file should be updated too. `prep_game.py` fails loudly if they disagree.

## What does NOT need to be here

`entry/libs/arm64-v8a/jdk21/conf/`, `jdk21/lib/classlist`, `jdk21/lib/jfr/` and
`jdk21/lib/jexec` are not inputs — they are part of the JDK tree that gets
copied to `entry/libs/`, and hvigor drops them during packaging because their
names do not end in `.so`. None of them is read by `libjvm` at runtime; the two
files that *are* opened by name are handled explicitly by `prep_jdklib.py`.
