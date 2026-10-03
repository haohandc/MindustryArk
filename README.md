[English](README.en.md) | **简体中文**

<div align="center">
  <p>
    <img src="./assets/icon-mindustry-ark-216.png" width="112" height="112" alt="Mindustry Ark 图标">
    &nbsp;&nbsp;
    <img src="./assets/icon-ark-launcher-216.png" width="112" height="112" alt="Ark Launcher 图标">
  </p>
  <h1>Mindustry Ark (Ark Launcher)</h1>
  <p><strong>Mindustry 的 HarmonyOS 启动器</strong></p>
  <p>
    <img src="https://img.shields.io/badge/HarmonyOS-7%20%2F%20API%2026-008577?style=flat-square" alt="HarmonyOS 7 / API 26">
    <img src="https://img.shields.io/github/v/release/haohandc/MindustryArk?style=flat-square&label=release" alt="最新版本">
    <img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="许可证">
    <img src="https://img.shields.io/github/stars/haohandc/MindustryArk?style=flat-square&label=stars" alt="GitHub stars">
  </p>
  <p>
    <a href="https://github.com/haohandc/MindustryArk/releases/latest">下载最新版本</a> ·
    <a href="docs/BUILDING.md">从源码构建</a> ·
    <a href="docs/FAQ.md">常见问题</a> ·
    <a href="docs/LIMITATIONS.md">已知限制</a> ·
    <a href="PRIVACY.md">隐私政策</a> ·
    <a href="https://github.com/haohandc/MindustryArk/issues">问题反馈</a>
  </p>
</div>

## 项目简介

在 HarmonyOS / OpenHarmony 上运行 **Mindustry**：内嵌一套 JDK，从 native 代码创建 JVM，
再把一个真正的 SDL3 窗口交给游戏。

**游戏本体是上游原版，未做任何修改。** 改造的是它下层的框架，编译后装进一份独立的补丁 jar，
在游戏之前加载。

| 形态 | 分支 | 带游戏本体 |
|---|---|---|
| **Mindustry Ark** | `master` | ✅ 内置一份 Mindustry |
| **Ark Launcher** | [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) | ⛔ 玩家自备 `.jar` |

同一个启动器的两种分发形态，差别只在包里带不带游戏本体。Ark Launcher 装上后，
把自备的 `.jar` 放进启动器显示的文件夹即可。

## 仓库内容

| 路径 | 用途 |
|---|---|
| [`entry/`](entry/) | 应用本体：ArkTS 界面、native（C）启动器、打包进来的运行时与游戏 |
| [`AppScope/`](AppScope/) | 应用级配置与图标 |
| [`scripts/`](scripts/) | 构建、打包与校验脚本 |
| [`docs/`](docs/) | 常见问题 / 已知限制 / 构建 / 权限 / 目录导览 |
| [`payload-src/`](payload-src/) | 构建输入的说明与清单 |
| [`helper-src/`](helper-src/) | 启动器辅助 jar 的源码 |
| [`tools/`](tools/) | 探针模组 |
| [`release-notes/`](release-notes/) | 各版本的英文发布说明 |
| [`assets/`](assets/) | 图标 |
| [`RELEASE.md`](RELEASE.md) | 下载与安装 |
| [`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md) | 维护者手册 |
| [`THIRD-PARTY.md`](THIRD-PARTY.md) | 逐组件的许可义务 |

## 功能

| 项目 | 状态 |
|---|---|
| JVM 启动 | 可用 |
| 图形 | OpenGL ES，经 SDL3 |
| 音频 | OHAudio，经自编的 `libarcarm64.so` |
| 触屏 | 可用，含双指捏合缩放 |
| 键盘 | 物理键盘可用；游戏内输入走弹出式输入框 |
| 鼠标 / 手柄 | 鼠标可用；手柄未测试 |
| 存档导入导出 | 走「下载」里的应用文件夹往返 |
| 模组 | 用游戏自带的「导入模组」按钮导入，不用重启 |
| 桌面 / 移动模式切换 | 可切换，需要重启应用 |
| 网络 / 联机 | 局域网与公网联机可用 |

**设备要求**：鸿蒙 7 / API 26 及以上，平板与手机均可。

## 启动器：多版本与存档管理

启动器有独立界面（**首页 / 存档 / 设置**），与游戏无关，**不启动游戏也能用**。

| 能做什么 | 说明 |
|---|---|
| 选游戏版本 | 内置一份，也可把任意多个 jar 放进 `Download/Mindustry Ark/games/` 逐个选 |
| **版本隔离** | 每个游戏版本各用一套游戏数据，四档粒度 |
| **存档管理** | 列出所有版本的存档，看元数据，复制、移动、跨版本搬 |
| 删除 = 垃圾站 | 删除是搬进垃圾站，保留 3 / 7 / 30 天或归档，随时可以放回 |
| 启动模式 | 每次启动先进启动器，或直接进游戏 |

> [!NOTE]
> 隔离由玩家主动打开，出厂为「不隔离」。

## 下载与安装

**[Releases 页面](https://github.com/haohandc/MindustryArk/releases)** 上的产物属于 **Mindustry Ark**：
未签名的 HAP 与一个载荷包（只有要从源码构建才需要）。
**Ark Launcher 是计划上架应用商店的版本，不在仓库发布 release** —— 需要的话，从 [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) 分支自行构建。

**未签名的 HAP 无法直接安装。**

**① 用安装工具（不需要开发环境，推荐）**

| 工具 | 说明 |
|---|---|
| [小白调试助手](https://github.com/likuai2010/auto-installer/releases/latest) | 免费的跨平台鸿蒙调试工具，签名 + 安装一步到位 |
| [HoKit](https://github.com/yabi-zzh/HoKit/releases/latest) | 一键重签名、设备投屏、性能监控、文件管理 |

> ⚠️ 用它们**签名 / 安装**没问题，但**不要用它们打开应用的「游戏模式」** ——
> 那会把应用锁在 60 帧，动画会顿。装好后用正常方式启动。

本项目也收录在 [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)（鸿蒙 Next HAP 安装包合集）中。

**② 用 DevEco Studio 自己签名**

用 DevEco Studio 打开本项目 → **File → Project Structure → Signing Configs →
Automatically generate signature** → `bash deploy.sh`。

> ⚠️ `bash deploy.sh` 会**先卸载再安装**（`hdc uninstall`）⇒ **应用数据会被清空**（存档、
> 以及对下载目录的授权）。想更新而不丢数据，用 `hdc install -r <已签名的 hap>`。

> 只想装、不想构建：把下载的 HAP 放进 `entry/build/default/outputs/default/`，再跑 `bash deploy.sh`。

**应用商店（计划中）**：按地区与设备分为三种包。

| 地区 | 手机 | 平板 / PC · 2in1 |
|---|---|---|
| 中国大陆 | **Ark Launcher 工具版** —— 管理工具，**不能运行游戏** | **Ark Launcher** |
| 海外 | 同上 | **Mindustry Ark** |

手机版不带游戏运行时，只能管理存档与模组；能运行游戏的包需要一条**仅覆盖平板与
PC / 2in1** 的系统权限，装不到手机上。

## 从源码构建

工程根目录就是本仓库，用 DevEco Studio 打开即可。构建完整包需要先按
[`payload-src/`](payload-src/) 凑齐构建输入 —— Releases 里的载荷包正是为此准备的。

工具链版本、步骤与常见错误见 [`docs/BUILDING.md`](docs/BUILDING.md)。

## 文档

`docs/` 下的文件是双语的（中文段在前、英文段在后，同一个文件）。

| 文档 | 什么时候看 |
|---|---|
| **[docs/FAQ.md](docs/FAQ.md)** | 有具体疑问 |
| **[docs/LIMITATIONS.md](docs/LIMITATIONS.md)** | 报 bug 之前，先确认是不是已知行为 |
| **[docs/BUILDING.md](docs/BUILDING.md)** | 要从源码构建 |
| **[docs/PERMISSIONS.md](docs/PERMISSIONS.md)** | 想知道要什么权限 |
| **[PRIVACY.md](PRIVACY.md)** | 想知道收集什么数据（什么都不收集）|
| **[docs/LAYOUT.md](docs/LAYOUT.md)** | 刚克隆下来，不知道东西在哪 |
| [RELEASE.md](RELEASE.md) | 要发下一个版本 |
| [THIRD-PARTY.md](THIRD-PARTY.md) | 要审计许可证 |
| [payload-src/README.md](payload-src/README.md) | 在凑构建的输入 |

## 代码与许可证

自有代码采用 **[GPL-3.0](LICENSE)**。Copyright (C) 2026 Haohandc and contributors。
衍生作品也必须以 GPL-3.0 分发，因此**不能**基于本项目做闭源产品。
逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

**非官方项目。** 与 Mindustry 项目及其作者 Anuken 无隶属关系，未获其认可或支持，
也与华为终端有限公司无关联。Mindustry 及相关名称与商标归各自权利人所有。

## 致谢

- [**Mindustry**](https://github.com/Anuken/Mindustry) —— Anuken 开发，游戏本体
- [**Arc**](https://github.com/Anuken/Arc) —— Anuken 开发的游戏框架
- [**SDL3**](https://github.com/libsdl-org/SDL) —— 窗口 / 输入 / 音频层
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) —— OpenGL 与 SDL 的 JNI 绑定
- [**OpenJDK 21**](https://github.com/openjdk/jdk) —— 运行时
- [**AMCL**](https://github.com/LZZLHY/amcl) —— 同类项目的参考实现。本项目有几处做法受它启发，
  但它不是本项目的依赖，产物里也不含它的代码。

> [!NOTE]
> 本仓库绝大部分代码、文档和文字由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
