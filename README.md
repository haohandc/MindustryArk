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
    <img src="https://img.shields.io/badge/HarmonyOS-6.1.1%20%2F%20API%2024-008577?style=flat-square" alt="HarmonyOS 6.1.1 / API 24">
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

在 HarmonyOS / OpenHarmony 上运行 **Mindustry**。

**未对Mindustry游戏本体做任何修改。** 通过加载`jar`补丁到Mindustry的游戏运行框架Arc实现兼容.

| 形态                | 分支                                                           | 带游戏本体                |
|-------------------|--------------------------------------------------------------|----------------------|
| **Mindustry Ark** | `master`                                                     | ✅ 内置 Mindustry       |
| **Ark Launcher**  | [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) | ⛔ 自备 `Mindustry.jar` |

Ark Launcher 只是去除了游戏本体。安装后，
需要把自备的 `Mindustry.jar` 放进`Downloads/应用名/games`文件夹。`.jar`文件名称可以随意更改。

## 仓库内容

| 路径                                                 | 用途                           |
|----------------------------------------------------|------------------------------|
| [`entry/`](entry/)                                 | 应用本体，包含打包进来的运行时与游戏           |
| [`AppScope/`](AppScope/)                           | 应用级配置与图标                     |
| [`scripts/`](scripts/)                             | 构建、打包与校验脚本                   |
| [`docs/`](docs/)                                   | 常见问题 / 已知限制 / 构建 / 权限 / 目录导览 |
| [`payload-src/`](payload-src/)                     | 构建输入的说明与清单                   |
| [`helper-src/`](helper-src/)                       | 启动器辅助 jar 的源码                |
| [`tools/`](tools/)                                 | 探针模组                         |
| [`release-notes/`](release-notes/)                 | 各版本的英文发布说明                   |
| [`assets/`](assets/)                               | 图标                           |
| [`RELEASE.md`](RELEASE.md)                         | 下载与安装                        |
| [`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md) | 维护者手册                        |
| [`THIRD-PARTY.md`](THIRD-PARTY.md)                 | 逐组件的许可义务                     |

## 功能

| 项目          | 状态                            |
|-------------|-------------------------------|
| JVM 启动      | 可用                            |
| 图形          | OpenGL ES，经 SDL3              |
| 音频          | OHAudio，经自编的 `libarcarm64.so` |
| 触屏          | 可用，含双指捏合缩放                    |
| 键盘          | 物理键盘可用；输入使用系统指定的IME           |
| 鼠标 / 手柄     | 鼠标可用；手柄未测试                    |
| 存档导入导出      | 走「下载」里的应用文件夹往返                |
| 模组          | 用游戏自带的「导入模组」按钮导入，不用重启         |
| 桌面 / 移动模式切换 | 可切换，需要重启应用                    |
| 网络 / 联机     | 局域网与公网联机可用                    |

**设备要求**：鸿蒙 6.1.1 / API 24 及以上，平板与手机均可。

## 启动器：多版本与存档管理

启动器拥有独立界面（**首页 / 存档 / 设置**）。

| 功能            | 说明                                                                  |
|---------------|---------------------------------------------------------------------|
| 自选Mindustry版本 | 内置一份，可把任意多个 `Mindustry.jar` 放进 `Download/Mindustry Ark/games/`并自选版本 |
| **版本隔离**      | 每个游戏版本各用一套游戏数据，四档粒度                                                 |
| **存档管理**      | 列出所有版本的存档，查看元数据，复制、移动、跨版本迁移                                         |
| 删除存档          | 可以选择回收（放进回收站）或直接永久删除，保留 3 / 7 / 30 天，也可以归档                          |
| 启动模式          | 每次启动先进启动器，或直接进游戏                                                    |

> [!NOTE]
> 版本隔离：默认「不隔离」
> 启动模式：默认先进启动器

## 下载与安装

**Mindustry Ark**的构建产物目前在**[Releases 页面](https://github.com/haohandc/MindustryArk/releases)** 发布。
包含未签名的 `.hap` 与一个载荷包（只有要从源码构建才需要）。
**Ark Launcher 是计划上架应用商店的版本，不在仓库发布 release** 
—— 需要的话，可以从 [`lite`](https://github.com/haohandc/MindustryArk/tree/lite) 分支自行构建。

**未签名的 HAP 无法直接安装。**

**① 用安装工具（不需要开发环境，推荐）**

| 工具 | 说明 |
|---|---|
| [小白调试助手](https://github.com/likuai2010/auto-installer/releases/latest) | 免费的跨平台鸿蒙调试工具，签名 + 安装一步到位 |
| [HoKit](https://github.com/yabi-zzh/HoKit/releases/latest) | 一键重签名、设备投屏、性能监控、文件管理 |

> [!CAUTION]
> 不要通过任何调试助手打开应用的「游戏模式」，这将导致应用锁60帧

**② 用 DevEco Studio 自己（编译）签名**

用 DevEco Studio 打开本项目 → 项目结构 → 签名配置 →
自动生成签名文件 → `bash deploy.sh`。

> ⚠️ `bash deploy.sh` 会**先卸载再安装**（`hdc uninstall`）⇒ **应用数据会被清空**（存档、
> 以及对下载目录的授权）。想更新而不丢数据，用 `hdc install -r <已签名的 hap>`。

**应用商店（计划中）**：按地区与设备分为三种包。

| 地区   | 手机                                   | 平板 / PC · 2in1                  |
|------|--------------------------------------|---------------------------------|
| 中国大陆 | **Ark Launcher**<br/>管理工具，**不能运行游戏** | **Ark Launcher**<br/>可运行导入的游戏   |
| 海外   | 同上                                   | **Mindustry Ark**<br/>完全体，无任何限制 |

Ark Launcher手机版不带游戏运行时，只有管理功能。原因：商店上架的Release不支持部分ACL权限。
JIT需要的可执行匿名内存权限**只支持平板与 PC / 2in1** 。

Mindustry Ark**自签名安装不受影响**，手机用户可以**正常**游玩。

## 从源码构建

本仓库就是工程根目录，用 DevEco Studio 打开Git后的项目即可。构建完整包需要先按
[`payload-src/`](payload-src/) 凑齐构建输入。

工具链版本、步骤与常见错误见 [`docs/BUILDING.md`](docs/BUILDING.md)。

## 文档

`docs/` 下的文件是双语的（中文段在前、英文段在后，同一个文件）。

| 文档                                             | 说明             |
|------------------------------------------------|----------------|
| **[docs/FAQ.md](docs/FAQ.md)**                 | 常见问题与回答        |
| **[docs/LIMITATIONS.md](docs/LIMITATIONS.md)** | 已知错误，不要当作bug上报 |
| **[docs/BUILDING.md](docs/BUILDING.md)**       | 从源码构建的文档       |
| **[docs/PERMISSIONS.md](docs/PERMISSIONS.md)** | 应用权限使用说明       |
| **[PRIVACY.md](PRIVACY.md)**                   | 隐私政策（不收集任何信息）  |
| **[docs/LAYOUT.md](docs/LAYOUT.md)**           | 项目文件结构说明       |
| [RELEASE.md](RELEASE.md)                       | 下载与安装说明        |
| [THIRD-PARTY.md](THIRD-PARTY.md)               | 许可证信息          |

## 代码与许可证

自有代码采用 **[GPL-3.0](LICENSE)**。Copyright (C) 2026 Haohandc and contributors。
衍生作品也必须以 GPL-3.0 分发，因此**不能**基于本项目做闭源产品。
逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

**非官方项目。** 与 Mindustry 项目及其作者 Anuken 无隶属关系，未获其认可或支持，
也与华为终端有限公司无关联。Mindustry 及相关名称与商标归各自权利人所有。

## 致谢

- [**Mindustry**](https://github.com/Anuken/Mindustry) —— Anuken 开发，游戏本体作者
- [**Arc**](https://github.com/Anuken/Arc) —— Anuken 开发的游戏框架
- [**SDL3**](https://github.com/libsdl-org/SDL) —— 窗口 / 输入 / 音频层
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) —— OpenGL 与 SDL 的 JNI 绑定
- [**OpenJDK 21**](https://github.com/openjdk/jdk) —— 运行时
- [**AMCL**](https://github.com/LZZLHY/amcl) —— 同类项目的参考实现。本项目有几处做法受它启发，
  但它不是本项目的依赖，产物里也不含它的代码。

> [!NOTE]
> 本仓库绝大部分代码、文档和文字由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
