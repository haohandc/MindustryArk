# Ark Launcher

**English** | [简体中文](README.md)

> [!IMPORTANT]
> **This branch is the `lite` branch of
> [`MindustryArk`](https://github.com/haohandc/MindustryArk).** Its **only**
> difference from `master` is that **the package carries no game** — the player
> supplies the `.jar`. So **the first launch stops at the launcher screen** (there
> is no jar yet): drop Mindustry's `.jar` into the folder the screen prints,
> pull to refresh, pick it, then press "Launch game". Everything else —
> device requirements, known limitations, how to build, licence — is
> **identical to `master`**.

Run **Mindustry** on HarmonyOS / OpenHarmony, using a self-built launcher instead
of an existing emulation layer.

The launcher embeds a JDK, creates a JVM from native code, and hands the game a
real SDL3 window. This repository is the launcher.

⛔ **The game is not in the package** (the one difference from `master`) — you supply a `.jar`
and **it is not modified; the launcher only reads its version number.**
What gets patched is the framework underneath it: ten of the twelve sources under
`arc/backend/sdl/` are ours (seven modified, three that exist only in this build:
`GLBootstrap`, `GLDiag`, `GLDispatchFix`), plus `arc/graphics/gl/`. They are
recompiled into **a patch jar of their own** (26 class entries), loaded ahead of
the game.
⚠️ The patch has to come **first** on the class path — JVM resolution takes the
first match, so the other order makes the patch silently do nothing.

> [!IMPORTANT]
> **Unofficial.** Not affiliated with, endorsed by, or supported by the Mindustry
> project or Anuken. See [THIRD-PARTY.md](THIRD-PARTY.md).

---

## Status

Working on HarmonyOS 7 / API 26 devices — a HUAWEI MatePad Pro 12.2" 2025 tablet
and a HUAWEI Mate 80 Pro phone. The main menu renders, the mobile layout is used,
audio plays through OHAudio, and touch and physical keyboard both work.

⭐ **Which devices can run it**: **HarmonyOS 7 / API 26 or later**, tablet **or phone**. Install it
self-signed (see the release notes) and it runs at full speed on either. Full-speed operation
depends on the app getting anonymous executable memory, and from API 26 the system supplies it to
a **debug** profile on a phone as well as a tablet — which is also why **there is no phone package
in the store**: a store (release) signature never gets it. ⚠️ **HarmonyOS 5 / 6**: no automatic ACL grant, so the store route does not apply, and a self-signed install is untested.

| Area | State |
|---|---|
| JVM startup | Works — the launcher must pass `-XX:UseSVE=0`. Without it the JIT emits SVE instructions this device cannot execute and the process dies with SIGILL |
| Graphics | OpenGL ES via SDL3 |
| Audio | OHAudio, through a self-built `libarcarm64.so` with an SDL3 backend |
| Touch | Works, including two-finger pinch zoom |
| Keyboard | Works (physical keyboard; WASD and ESC). Typing into game text fields uses an on-screen field with full input-method support — see [limitations](docs/LIMITATIONS.md) |
| Gamepad / mouse | Mouse works. Gamepad untested |
| Save import/export | Via the app's folder in Download, using the picker — **measured working on both devices, and it needs no permission at all**. ⚠️ **Still unverified**: whether the game's own browser can read that path — it uses a path through libc, while the app's grant is held per URI — see [limitations](docs/LIMITATIONS.md) |
| Mods | Work. Import them with the **game's own "import mod" button** — that is the only way in, and it needs no restart. The app deliberately does **not** take files from Downloads by itself; drop one in `Download/Ark Launcher/` and pick it in that browser. See [limitations](docs/LIMITATIONS.md) |
| Desktop/mobile mode switch | Switches, but needs an app restart — see the [FAQ](docs/FAQ.md) |
| Networking / multiplayer | **The platform side works** — `socket`, `epoll`, DNS, TCP, TLS and HTTP all measured working here. **LAN, public-server search and hosting on the device have each been tested, and a match has actually been played** (2026-09-23) |

## The launcher: game versions and save management

The launcher has a UI of its own — **Home / Saves / Settings** — which is
independent of the game and **usable without starting it**.

| What you can do | How it works |
|---|---|
| Pick a game version | Drop any number of jars into **the folder the screen prints** (the launcher shows it above the list) and choose between them. The version is read out of the jar, not guessed from the file name |
| **Version isolation** | Each game version gets its own set of game data. Four tiers: off (the factory setting) / major version / build / patch |
| **Save management** | Lists the saves of **every** version (grouped by which versions share the same data), shows the metadata (version / map / playtime / mods), and copies, moves or carries them across versions |
| Delete = vault | A delete is not an erase: the save moves to a vault for 3 / 7 / 30 days, or is **archived** (never auto-removed). It can be put back at any time |
| Launch mode | Show the launcher first each time, or go straight into the game |

⭐ One guarantee about isolation: **the first copy of the data is never moved** — no
change of jar, tier or version can make it disappear.

> [!NOTE]
> Isolation is something the player **turns on** — the factory setting is off. Turning
> it on offers either copying the existing data across or starting empty.

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

- [**Mindustry**](https://github.com/Anuken/Mindustry) — by Anuken, the game (**not bundled in this branch — you supply it**), **loaded unmodified**
- [**Arc**](https://github.com/Anuken/Arc) — by Anuken, the game framework; this platform's patches live in it
- [**SDL3**](https://github.com/libsdl-org/SDL) — the windowing / input / audio layer
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) — the JNI bindings for OpenGL and SDL
- [**OpenJDK 21**](https://github.com/openjdk/jdk) — the runtime

> [!NOTE]
> Most of the code, phrases and documents in this repository were written with AI assistance
> (Claude via Cherry Studio, model deepseek-flash v4.1).
