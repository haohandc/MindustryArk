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
    <img src="https://img.shields.io/badge/HarmonyOS-6.1.1%20%2F%20API%2024-008577?style=flat-square" alt="HarmonyOS 6.1.1 / API 24">
    <img src="https://img.shields.io/github/v/release/haohandc/MindustryArk?style=flat-square&label=release" alt="Latest release">
    <img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="Licence">
    <img src="https://img.shields.io/github/stars/haohandc/MindustryArk?style=flat-square&label=stars" alt="GitHub stars">
  </p>
  <p>
    <a href="docs/BUILDING.md">Build from source</a> ·
    <a href="https://github.com/haohandc/MindustryArk/issues">Issues</a>
  </p>
</div>

## About

Runs **Mindustry** on HarmonyOS / OpenHarmony.

**Nothing in Mindustry itself is modified.** The compatibility work targets **Arc**, the
framework the game runs on: it is a jar patch loaded before the game.

Ark Launcher v1.3.3.2 **has already been uploaded to AppGallery.**

> [!CAUTION]
> AI-generated project; the code has not been reviewed by a person. It also has two giant
> files (`LauncherHome.ets` and `launcher.c`, 5000 / 2000 lines), so maintainability is poor —
> not recommended to reference directly.
>
> Development has stopped for now. A new architecture is being designed, and Ark Launcher Pro
> (closed source) is being built.

| Form | Branch | Ships the game |
|---|---|---|
| **Mindustry Ark** | `master` | Yes — a bundled Mindustry |
| **Ark Launcher** | [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) | No — you supply the `.jar` |

Ark Launcher is the same thing with the game removed. After installing it, put your own
`Mindustry.jar` into the `Downloads/<app name>/games` folder. The `.jar` file name does not matter.

## Repository contents

| Path | What it is |
|---|---|
| [`entry/`](entry/) | The app: ArkTS screens, the native (C) launcher, the bundled runtime and game |
| [`AppScope/`](AppScope/) | App-level configuration and icons |
| [`scripts/`](scripts/) | Build, packaging and verification scripts |
| [`docs/`](docs/) | FAQ / limitations / building / permissions / layout |
| [`payload-src/`](payload-src/) | Where the build inputs are described, and what they are |
| [`helper-src/`](helper-src/) | Source for the launcher's helper jar |
| [`tools/`](tools/) | A probe mod |
| [`release-notes/`](release-notes/) | English release notes per version |
| [`assets/`](assets/) | Icons |
| [`RELEASE.md`](RELEASE.md) | Downloading and installing |
| [`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md) | Maintainer's handbook |
| [`THIRD-PARTY.md`](THIRD-PARTY.md) | Per-component licence obligations |

**Requires** HarmonyOS 6.1.1 / API 24 or newer. Tablet and phone both work.

**App stores (planned)**: three packages, by region and device.

| Region | Phone | Tablet / PC · 2-in-1 |
|---|---|---|
| Mainland China | **Ark Launcher**, a management tool — **cannot run the game** | **Ark Launcher** — runs imported games |
| Elsewhere | same as above | **Mindustry Ark** — the full build, no restrictions |

The phone build of Ark Launcher carries no game runtime, so it can only manage. The reason: a
store release cannot declare some ACL permissions, and the anonymous executable memory permission
that JIT needs **covers tablets and PC / 2-in-1 only**.

A self-signed install of Mindustry Ark is unaffected — phone users can play normally.

## Building from source

The repository root is the project — open what you cloned in DevEco Studio. Building a complete
package needs the build inputs gathered first, as described in [`payload-src/`](payload-src/).

Toolchain versions, steps and common errors are in [`docs/BUILDING.md`](docs/BUILDING.md).

## Code and licence

Our own code is **[GPL-3.0](LICENSE)**. Copyright (C) 2026 Haohandc and contributors.
**Third-party** derivative works must also be distributed under GPL-3.0, so a closed-source
product **cannot** be built on this project. Per-component obligations are in
[THIRD-PARTY.md](THIRD-PARTY.md).

**Unofficial project.** Not affiliated with the Mindustry project or its author Anuken,
and not endorsed by them; also unaffiliated with Huawei Device Co., Ltd.
Mindustry and related names and marks belong to their respective owners.

## Credits

- [**Mindustry**](https://github.com/Anuken/Mindustry) — the game, by Anuken
- [**Arc**](https://github.com/Anuken/Arc) — the game framework, by Anuken
- [**SDL3**](https://github.com/libsdl-org/SDL) — window, input and audio
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) — JNI bindings for OpenGL and SDL
- [**OpenJDK 21**](https://github.com/openjdk/jdk) — the runtime. Ours is
- [**AMCL**](https://github.com/LZZLHY/amcl)'s published OpenHarmony build (`jdk21-ohos-full-v7.zip`,
  upstream `jdk-21.0.5+11`)

> [!NOTE]
> Almost all of the code, documentation and prose in this repository was produced with AI
> assistance (Claude via Cherry Studio, model deepseek-flash v4.1).
