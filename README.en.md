[简体中文](README.md) | **English**

<div align="center">
  <p>
    <img src="./assets/icon-mindustry-ark-216.png" width="112" height="112" alt="Mindustry Ark icon">
    &nbsp;&nbsp;
    <img src="./assets/icon-ark-launcher-216.png" width="112" height="112" alt="Ark Launcher icon">
  </p>
  <h1>Mindustry Ark (Ark Launcher)</h1>
  <p><strong>A Mindustry launcher for HarmonyOS</strong></p>
  <p>
    <img src="https://img.shields.io/badge/HarmonyOS-7%20%2F%20API%2026-008577?style=flat-square" alt="HarmonyOS 7 / API 26">
    <img src="https://img.shields.io/github/v/release/haohandc/MindustryArk?style=flat-square&label=release" alt="Latest release">
    <img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="Licence">
    <img src="https://img.shields.io/github/stars/haohandc/MindustryArk?style=flat-square&label=stars" alt="GitHub stars">
  </p>
  <p>
    <a href="https://github.com/haohandc/MindustryArk/releases/latest">Download</a> ·
    <a href="docs/BUILDING.md">Build from source</a> ·
    <a href="docs/FAQ.md">FAQ</a> ·
    <a href="docs/LIMITATIONS.md">Known limitations</a> ·
    <a href="PRIVACY.md">Privacy</a> ·
    <a href="https://github.com/haohandc/MindustryArk/issues">Issues</a>
  </p>
</div>

## About

Runs **Mindustry** on HarmonyOS / OpenHarmony: the launcher embeds a JDK, creates a JVM
from native code, and hands the game a real SDL3 window.

**The game is the upstream build, unmodified.** What is patched is the framework beneath it;
the patch is compiled into a separate jar that is loaded before the game.

| Form | Branch | Ships the game |
|---|---|---|
| **Mindustry Ark** | `master` | Yes — a bundled Mindustry |
| **Ark Launcher** | [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) | No — you supply the `.jar` |

Two distributions of the same launcher; the difference is only whether the game is in the
package. With Ark Launcher, put your own `.jar` into the folder the launcher shows.

## Repository contents

| Path | What it is |
|---|---|
| [`entry/`](entry/) | The app: ArkTS screens, the native (C) launcher, the bundled runtime and game |
| [`AppScope/`](AppScope/) | App-level configuration and icons |
| [`scripts/`](scripts/) | Build, packaging and verification scripts |
| [`docs/`](docs/) | FAQ / limitations / building / permissions / layout |
| [`payload-src/`](payload-src/) | What the build inputs are, and a manifest |
| [`helper-src/`](helper-src/) | Source for the launcher's helper jar |
| [`tools/`](tools/) | A probe mod |
| [`release-notes/`](release-notes/) | English release notes per version |
| [`assets/`](assets/) | Icons |
| [`RELEASE.md`](RELEASE.md) | Downloading and installing |
| [`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md) | Maintainer's handbook |
| [`THIRD-PARTY.md`](THIRD-PARTY.md) | Per-component licence obligations |

## Features

| Item | State |
|---|---|
| JVM startup | Works |
| Graphics | OpenGL ES, through SDL3 |
| Audio | OHAudio, through our own `libarcarm64.so` |
| Touch | Works, pinch-to-zoom included |
| Keyboard | Physical keyboards work; in-game text uses a pop-up input field |
| Mouse / gamepad | Mouse works; gamepad untested |
| Save import and export | Through the app folder under Downloads |
| Mods | Imported with the game's own "Import mod" button; no restart |
| Desktop / mobile mode | Switchable; needs a restart |
| Networking | LAN and internet multiplayer work |

**Requires** HarmonyOS 7 / API 26 or newer. Tablet and phone both work.

## The launcher: versions and saves

The launcher has its own screens (**Home / Saves / Settings**) and is independent of the game —
**it works without ever launching the game**.

| What you can do | How it works |
|---|---|
| Pick a game version | One is bundled, and any number of jars can be dropped into `Download/Mindustry Ark/games/` |
| **Version isolation** | Each game version gets its own set of game data, at one of four granularities |
| **Save management** | Every version's saves in one list, with metadata, copied or moved across versions |
| Delete means vault | Deleting moves a save into a vault: kept 3 / 7 / 30 days or archived, restorable at any time |
| Startup mode | Either the launcher first, or straight into the game |

> [!NOTE]
> Isolation is turned on by the player; it is off out of the box.

## Download and install

The artifacts on the **[releases page](https://github.com/haohandc/MindustryArk/releases)** are
**Mindustry Ark**: an unsigned HAP and a payload zip (needed only to build from source).
**Ark Launcher is the version headed for app stores, and is not published as a release here** —
build it from the [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) branch if you need it.

**An unsigned HAP cannot be installed directly.**

**① Use an installer tool (no development environment needed; recommended)**

| Tool | What it does |
|---|---|
| [小白调试助手](https://github.com/likuai2010/auto-installer/releases/latest) | A free cross-platform HarmonyOS debug tool: signs and installs in one step |
| [HoKit](https://github.com/yabi-zzh/HoKit/releases/latest) | Re-signing, screen mirroring, performance monitoring, file management |

> ⚠️ Using them to **sign or install** is fine — but **do not use them to open the app's "game
> mode"**: that pins the app to 60 fps and the interface will look choppy. Start it normally.

This project is also listed in [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps).

**② Sign it yourself in DevEco Studio**

Open this project in DevEco Studio → **File → Project Structure → Signing Configs →
Automatically generate signature** → `bash deploy.sh`.

> ⚠️ `bash deploy.sh` **uninstalls before installing** (`hdc uninstall`), so **the app's data
> is wiped** — saves, and the Downloads-folder authorisation. To update without losing data,
> use `hdc install -r <the signed hap>`.

> To install without building: drop the downloaded HAP into
> `entry/build/default/outputs/default/` and run `bash deploy.sh`.

**App stores (planned)**: three packages, by region and device.

| Region | Phone | Tablet / PC · 2-in-1 |
|---|---|---|
| Mainland China | **Ark Launcher, tool build** — a management tool; **cannot run the game** | **Ark Launcher** |
| Elsewhere | same as above | **Mindustry Ark** |

The phone build carries no game runtime, so it manages saves and mods only. A build that can
run the game needs a system permission that **covers tablets and PC / 2-in-1 only**, and so
cannot be installed on a phone.

## Building from source

The repository root is the project — open it in DevEco Studio. Building a complete package
needs the build inputs gathered first, as described in [`payload-src/`](payload-src/);
the payload zip on the releases page exists for exactly that.

Toolchain versions, steps and common errors are in [`docs/BUILDING.md`](docs/BUILDING.md).

## Documentation

Files under `docs/` are bilingual — Chinese first, English after, in the same file.

| Document | When to read it |
|---|---|
| **[docs/FAQ.md](docs/FAQ.md)** | You have a specific question |
| **[docs/LIMITATIONS.md](docs/LIMITATIONS.md)** | Before reporting a bug, to check it is not known behaviour |
| **[docs/BUILDING.md](docs/BUILDING.md)** | You want to build from source |
| **[docs/PERMISSIONS.md](docs/PERMISSIONS.md)** | You want to know what it asks for |
| **[PRIVACY.md](PRIVACY.md)** | You want to know what it collects (nothing) |
| **[docs/LAYOUT.md](docs/LAYOUT.md)** | You just cloned it and cannot find things |
| [RELEASE.md](RELEASE.md) | You are cutting the next release |
| [THIRD-PARTY.md](THIRD-PARTY.md) | You are auditing licences |
| [payload-src/README.md](payload-src/README.md) | You are gathering build inputs |

## Code and licence

Our own code is **[GPL-3.0](LICENSE)**. Copyright (C) 2026 Haohandc and contributors.
Derivative works must also be distributed under GPL-3.0, so a closed-source product
**cannot** be built on this project. Per-component obligations are in
[THIRD-PARTY.md](THIRD-PARTY.md).

**Unofficial project.** Not affiliated with the Mindustry project or its author Anuken,
and not endorsed by them; also unaffiliated with Huawei Device Co., Ltd.
Mindustry and related names and marks belong to their respective owners.

## Credits

- [**Mindustry**](https://github.com/Anuken/Mindustry) — the game, by Anuken
- [**Arc**](https://github.com/Anuken/Arc) — the game framework, by Anuken
- [**SDL3**](https://github.com/libsdl-org/SDL) — window, input and audio
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) — JNI bindings for OpenGL and SDL
- [**OpenJDK 21**](https://github.com/openjdk/jdk) — the runtime
- [**AMCL**](https://github.com/LZZLHY/amcl) — a reference implementation of the same idea.
  A few of our approaches were inspired by it; it is not a dependency, and none of its code
  is in our artifacts.

> [!NOTE]
> Almost all of the code, documentation and prose in this repository was produced with AI
> assistance (Claude via Cherry Studio, model deepseek-flash v4.1).
