# MindustryArk

**English** | [简体中文](README.zh-CN.md)

Run **Mindustry** on HarmonyOS / OpenHarmony, using a self-built launcher instead
of an existing emulation layer.

The launcher embeds a JDK, creates a JVM from native code, and hands the game a
real SDL3 window. This repository is the launcher. **Mindustry's own code is
loaded unmodified**; what gets patched is the framework underneath it — four of
Arc's backend classes are recompiled and written into the jar, because that is
where the platform-specific work lives.

> **Unofficial.** Not affiliated with, endorsed by, or supported by the Mindustry
> project or Anuken. See [THIRD-PARTY.md](THIRD-PARTY.md).

---

## Status

Working on a HarmonyOS 7 tablet (MatePad Pro, API 26): the main menu renders, the
mobile layout is used, audio plays through OHAudio, touch and physical keyboard
both work, and saves can be imported from the Download folder.

| Area | State |
|---|---|
| JVM startup | Works — the launcher must pass `-XX:UseSVE=0`. Without it the JIT emits SVE instructions this device cannot execute and the process dies with SIGILL |
| Graphics | OpenGL ES via SDL3 |
| Audio | OHAudio, through a self-built `libarcarm64.so` with an SDL3 backend |
| Touch | Works, including two-finger pinch zoom |
| Keyboard | Works (physical keyboard; WASD and ESC) |
| Gamepad / mouse | Mouse works. Gamepad untested |
| Save import/export | Works, from/to the Download folder |
| Desktop/mobile mode switch | **Not implemented** |

## Requirements

- DevEco Studio with the HarmonyOS SDK (`compatibleSdkVersion 6.1.1(24)`,
  `targetSdkVersion 26.0.0`)
- A HarmonyOS device or emulator
- Python 3.12, JDK 17 (only for the Arc patches and the helper jar)

## Building

The payload is **not** in this repository (see `.gitignore` for why). You must
supply it before the project will build, because the HAP embeds all of it.

### 1. Get the payload into `entry/libs/arm64-v8a/`

| Path in the repo | What it is | Where it comes from |
|---|---|---|
| `jdk21/` | An OpenJDK 21 build for OpenHarmony (musl / aarch64). A desktop JDK will not work | The payload release, or a similar build obtained elsewhere |
| `game/mindustry.so` | The Mindustry jar, renamed | An official Mindustry release jar |
| `lwjgl/`, `lwjgl-java/` | LWJGL 3 natives and jars for this platform | An LWJGL build for OpenHarmony |
| `arc/` | Arc's natives | Built from the Arc sources |
| `libjvm.so`, `libcxxabi_shim.so` | Derived from the JDK | Produced by `prep_vendor.py` |
| `launcher/` | A one-class helper jar | Built by `prep_helper.py` from `helper-src/` |

The `prep_*.py` scripts do the derivation and each one checks its input's hash
before writing anything, so a stale or wrong input fails loudly instead of
producing a jar that silently differs from the one that was tested.

### 2. Build

```bash
bash build.sh assembleHap        # just compile
bash deploy.sh                   # build + verify + install + launch + log
```

`deploy.sh` refuses to continue on a stale native object, a failed build, or a
packaging check that fails, because each of those once produced a green build
that installed the *previous* binary.

Signing must be configured once: DevEco Studio → File → Project Structure →
Signing Configs → Automatically generate signature. `deploy.sh` installs the
signed HAP that hvigor produces; there is no ACL re-signing step, because this
app needs no restricted permissions (see below).

---

## Permissions

Only `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`, so the player can import
saves and game-data exports from Download.

Deliberately **not** requested: `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`.
That is the restricted ACL permission for making the writable sandbox
executable. It was measured unnecessary -- the JDK lives in the HAP, and the
sandbox holds only data -- and leaving it out is what lets anyone install this
build without a special signing profile.

## Known limitations

- **Desktop/mobile mode cannot be switched at runtime.** The mode is fixed at
  launch. Mindustry has an in-game "mouse + keyboard control" toggle that covers
  most of the same ground.
- `libarc-filedialogsarm64.so` is linked against glibc and cannot load here, so
  Arc falls back to Mindustry's own in-game file browser. This is why the
  browser path had to be redirected to Download.
- Importing game data makes the game exit on purpose (`Core.app.exit()`), so
  that it restarts with the new data. This looks like a crash and is not one.
- Tested on exactly one device (MatePad Pro, HarmonyOS 7). Other devices are
  untested.

The reasoning behind each of those is in the source comments where the code is, rather than here -- `entry/src/main/cpp/myapp.c` is the place to start.

## Repository layout

| Path | What |
|---|---|
| `entry/src/main/cpp/myapp.c` | The launcher: sandbox setup, JVM options, game launch, exit handshake |
| `entry/src/main/cpp/SDL/` | SDL3, with patches for OpenHarmony input, windowing and audio |
| `entry/src/main/ets/` | ArkTS: the XComponent page and key handling, and the ability |
| `entry/libs/` | The payload (not in git -- see `.gitignore`) |
| `prep_*.py` | Produce the payload from its inputs |
| `tools/` | Rebuild the patched game jar (Arc patches applied to an upstream jar) |
| `deploy.sh`, `build.sh` | Build and deploy, with gates |
| `esc_ab.sh`, `quit_timing.sh` | The measurement harnesses used to fix input and shutdown |
| `verify_hap.py`, `scan_needed.py` | Read the packaged HAP back and check the bytes |

## Licence

**GPL-3.0** — see [LICENSE](LICENSE).

Copyright (C) 2026 Haohandc and contributors.

This project is not free to choose a permissive licence, because a build
redistributes Mindustry, which is GPL-3.0. A HAP is a single installable unit
whose only purpose is to run that game, so it is a combined work rather than a
mere aggregation of independent programs, and GPL-3.0 applies to the whole of
it. The practical consequence worth knowing before contributing: **derivative
works must also be GPL-3.0**, so this cannot be built into a closed-source
product.

Every other component in the stack is compatible with GPL-3.0, which is what
makes this combination distributable at all — including the JDK, whose
Classpath Exception is the specific provision that permits shipping it
alongside a work under other terms. Details, and the obligations that come with
each component, are in [THIRD-PARTY.md](THIRD-PARTY.md).

**Third-party files keep their own licences.** `entry/src/main/cpp/SDL/` is
Zlib-licensed SDL3 with local modifications; it is not relicensed by this
project's GPL, and Zlib requires that modified copies not be presented as the
original. The same applies to the LWJGL payload and to the vendored Arc sources
referenced by `tools/`.

## Credits

- **Mindustry** by Anuken -- the game, loaded unmodified
- **Arc** by Anuken -- the game framework; `arc/backend/sdl/**` and
  `arc/graphics/gl/**` carry patches for this platform
- **SDL3** -- the windowing/input/audio layer
- **LWJGL** -- the JNI bindings for OpenGL and SDL
- **OpenJDK 21** -- the runtime

Licensing and redistribution terms for each are in
[THIRD-PARTY.md](THIRD-PARTY.md).

Most of the code in this repository was written with AI assistance
(Claude via Cherry Studio, model deepseek-flash v4.1). The measurements, the
device testing and the decisions about what to do when a measurement disagreed
with an assumption were reviewed against primary sources throughout; the
interesting failures are documented in the source comments, including the ones
that were my fault.
