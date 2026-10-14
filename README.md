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
    <a href="docs/BUILDING.md">从源码构建</a> ·
    <a href="https://github.com/haohandc/MindustryArk/issues">问题反馈</a>
  </p>
</div>

## 项目简介

在 HarmonyOS / OpenHarmony 上运行 **Mindustry**。

**未对Mindustry游戏本体做任何修改。** 通过加载`jar`补丁到Mindustry的游戏运行框架Arc实现兼容.

> [!NOTE]
> Ark Launcher 的 v1.3.3.2 版本**已上架鸿蒙应用市场**，支持平板，兼容分发到PC/2in1。

> [!CAUTION]
> AI生成项目，代码未经个人审核。且存在两个巨型文件(`LauncherHome.ets`和`launcher.c`，5000/2000 行)，可维护性很差，不建议直接参考。
> 
> 目前停止更新，只进行bugfix。正在设计新架构，开发Ark Launcher Pro（闭源）。

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

**设备要求**：鸿蒙 6.1.1 / API 24 及以上，平板与手机均可。

**应用商店（计划中）**：按地区与设备分为三种包。

| 地区   | 手机 暂未上架                              | 平板 / PC · 2in1 已上架                                            |
|------|--------------------------------------|---------------------------------------------------------------|
| 中国大陆 | **Ark Launcher**<br/>管理工具，**不能运行游戏** | **Ark Launcher**<br/>可运行导入的游戏                                 |
| 海外   | 同上                                   | Ark Launcher<br/>已上架<br/>(**Mindustry Ark**未上架<br/>完全体，无任何限制) |

Ark Launcher手机版不带游戏运行时，只有管理功能。原因：商店上架的Release不支持部分ACL权限。
JIT需要的可执行匿名内存权限**只支持平板与 PC / 2in1** 。

Mindustry Ark**自签名安装不受影响**，手机用户可以**正常**游玩。

## 从源码构建

本仓库就是工程根目录，用 DevEco Studio 打开Git后的项目即可。构建完整包需要先按
[`payload-src/`](payload-src/) 凑齐构建输入。

工具链版本、步骤与常见错误见 [`docs/BUILDING.md`](docs/BUILDING.md)。

## 代码与许可证

自有代码采用 **[GPL-3.0](LICENSE)**。Copyright (C) 2026 Haohandc and contributors。
第三方衍生作品也必须以 GPL-3.0 分发，因此**不能**基于本项目做闭源产品。
逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

**非官方项目。** 与 Mindustry 项目及其作者 Anuken 无隶属关系，未获其认可或支持，
也与华为终端有限公司无关联。Mindustry 及相关名称与商标归各自权利人所有。

## 致谢

- [**Mindustry**](https://github.com/Anuken/Mindustry) —— Anuken 开发，游戏本体作者
- [**Arc**](https://github.com/Anuken/Arc) —— Anuken 开发的游戏框架
- [**SDL3**](https://github.com/libsdl-org/SDL) —— 窗口 / 输入 / 音频层
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) —— OpenGL 与 SDL 的 JNI 绑定
- [**OpenJDK 21**](https://github.com/openjdk/jdk) —— 运行时。本项目所用的是
- [**AMCL**](https://github.com/LZZLHY/amcl) 发布的 OpenHarmony 构建（`jdk21-ohos-full-v7.zip`， 上游 `jdk-21.0.5+11`）

> [!NOTE]
> 本仓库绝大部分代码、文档和文字由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
