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

Working on HarmonyOS 7 / API 26 devices — a HUAWEI MatePad Pro 12.2" 2025 tablet
and a HUAWEI Mate 80 Pro phone. The main menu renders, the mobile layout is
used, audio plays through OHAudio, touch and physical keyboard both work, and
saves can be imported from the Download folder.

| Area | State |
|---|---|
| JVM startup | Works — the launcher must pass `-XX:UseSVE=0`. Without it the JIT emits SVE instructions this device cannot execute and the process dies with SIGILL |
| Graphics | OpenGL ES via SDL3 |
| Audio | OHAudio, through a self-built `libarcarm64.so` with an SDL3 backend |
| Touch | Works, including two-finger pinch zoom |
| Keyboard | Works (physical keyboard; WASD and ESC). Typing into game text fields uses an on-screen field with full input-method support — see [limitations](docs/LIMITATIONS.md) |
| Gamepad / mouse | Mouse works. Gamepad untested |
| Save import/export | Works, from/to the Download folder |
| Desktop/mobile mode switch | Switches, but needs an app restart — see the [FAQ](docs/FAQ.md) |

## How to download and install

Prebuilt artifacts are on the
**[Releases page](https://github.com/haohandc/MindustryArk/releases)**:
the unsigned HAP (the app) and a payload zip (only needed to build from source).

An unsigned HAP will not install. Two ways around that:

**① An installer tool (no dev environment needed, recommended)**

| Tool | What it does |
|---|---|
| [小白调试助手 (Auto-Installer)](https://github.com/likuai2010/auto-installer/releases/latest) | Free cross-platform HarmonyOS debugging tool — **signing and installing in one step** |
| [HoKit](https://github.com/yabi-zzh/HoKit/releases/latest) | **One-click re-signing**, device mirroring, perf monitoring, file management. Windows / macOS / Linux |

> This project is also listed in
> [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps), a HarmonyOS Next HAP collection.

**② Sign it yourself with DevEco Studio**

Open the project, **File → Project Structure → Signing Configs → Automatically
generate signature**, then `bash deploy.sh`.

> Install only, without building: drop the downloaded HAP into
> `entry/build/default/outputs/default/` and run `bash deploy.sh`.

More detail, including what must **not** be published, is in [RELEASE.md](RELEASE.md).

## Documentation

Everything below is a separate document. **The files under `docs/` are bilingual —
Chinese section first, then English, in the same file.**

| Document | Open it when |
|---|---|
| **[docs/FAQ.md](docs/FAQ.md)** | You have a specific question — start here |
| **[docs/LIMITATIONS.md](docs/LIMITATIONS.md)** | Before reporting a bug: is this known? |
| **[docs/BUILDING.md](docs/BUILDING.md)** | You want to build it from source |
| **[docs/PERMISSIONS.md](docs/PERMISSIONS.md)** | You want to know what it asks for |
| **[PRIVACY.md](PRIVACY.md)** | You want to know what data it collects (answer: none) |
| **[docs/LAYOUT.md](docs/LAYOUT.md)** | You just cloned it and can't find things |
| [RELEASE.md](RELEASE.md) | You downloaded a build: which file, how to install, what's verified |
| [RELEASE-MAINTENANCE.md](RELEASE-MAINTENANCE.md) | You're cutting a release |
| [THIRD-PARTY.md](THIRD-PARTY.md) | You're auditing licences |
| [payload-src/README.md](payload-src/README.md) | You're assembling the build's inputs |

## Licence

**GPL-3.0** — see [LICENSE](LICENSE).

Copyright (C) 2026 Haohandc and contributors.

**Note in particular**: derivative works must also be distributed under GPL-3.0, so
this **cannot** be used as the basis of a closed-source product.

Per-component obligations are in [THIRD-PARTY.md](THIRD-PARTY.md).

## Credits

- [**Mindustry**](https://github.com/Anuken/Mindustry) — by Anuken, the game, **loaded unmodified**
- [**Arc**](https://github.com/Anuken/Arc) — by Anuken, the game framework; `arc/backend/sdl/**` and `arc/graphics/gl/**` carry patches for this platform
- [**SDL3**](https://github.com/libsdl-org/SDL) — the windowing / input / audio layer
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) — the JNI bindings for OpenGL and SDL
- [**OpenJDK 21**](https://github.com/openjdk/jdk) — the runtime

Licensing and redistribution terms for each are in [THIRD-PARTY.md](THIRD-PARTY.md).

Most of the code in this repository was written with AI assistance
(Claude via Cherry Studio, model deepseek-flash v4.1). The measurements, the
device testing and the decisions about what to do when a measurement disagreed
with an assumption were reviewed against primary sources throughout; the
interesting failures are documented in the source comments, including the ones
that were my fault.
