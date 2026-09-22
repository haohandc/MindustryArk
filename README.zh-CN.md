# MindustryArk

[English](README.md) | **简体中文**

在 **HarmonyOS / OpenHarmony** 上运行 **Mindustry**，使用自建启动器，而不是套一层现成的模拟层。

启动器内嵌一套 JDK，从 native 代码创建 JVM，再把一个真正的 SDL3 窗口交给游戏。
本仓库就是这套启动器。**Mindustry 自身的代码未经修改**；被改动的是它下层的框架 ——
Arc 的四个后端类被重新编译后写回 jar，因为平台相关的改造都在那里。

> **非官方项目。** 与 Mindustry 项目及 Anuken 无隶属关系，未获其认可或支持。
> 详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

---

## 当前状态

已在 HarmonyOS 7 / API 26 的设备上跑通（**HUAWEI MatePad Pro 12.2" 2025** 平板、**HUAWEI Mate 80 Pro** 手机）：
主菜单正常渲染、采用移动端布局、音频经 OHAudio 播放、
触屏与物理键盘均可用。⚠️ 「从下载目录导入存档」**只在部分机型上可用** —— 见[已知限制](docs/LIMITATIONS.md)。

| 项目 | 状态 |
|---|---|
| JVM 启动 | 可用 —— 但启动器**必须**传 `-XX:UseSVE=0`，否则 JIT 会生成本设备无法执行的 SVE 指令，进程直接 SIGILL |
| 图形 | OpenGL ES，经 SDL3 |
| 音频 | OHAudio，经自编的 `libarcarm64.so`（含 SDL3 后端） |
| 触屏 | 可用，**含双指捏合缩放** |
| 键盘 | 可用（物理键盘；WASD 与 ESC）。往游戏输入框里打字用**带输入法的弹出式输入框** —— 见[已知限制](docs/LIMITATIONS.md) |
| 鼠标 / 手柄 | 鼠标可用；手柄**未测试** |
| 存档导入导出 | 走「下载」里的应用文件夹往返。⚠️ **游戏的浏览器能否读那个路径尚未验证**（它走 libc 用路径，而应用的授权是按 URI 持有的）—— 见[已知限制](docs/LIMITATIONS.md) |
| 模组 | 可用。三个入口：游戏自带的「导入模组」按钮、悬浮球菜单的「导入模组」、或把文件放进 `Download/com.haohandc.mindustryark/`（**启动时自动搬入**）。⚠️ **只有悬浮球那个入口需要重启生效** —— 见[已知限制](docs/LIMITATIONS.md) |
| 桌面 / 移动模式切换 | 可切换，但**需要重启应用** —— 见[常见问题](docs/FAQ.md) |
| 网络 / 联机 | **平台层面已通**（`socket` / `epoll` / DNS / TCP / TLS / HTTP 全部实测可用，见下）。⚠️ **但还没实测过一局真实联机** |

## 如何下载、安装

现成产物在 **[Releases 页面](https://github.com/haohandc/MindustryArk/releases)**：
未签名的 HAP（应用本体）与一个载荷包（**只有要从源码构建才需要**）。

未签名的 HAP 无法安装。以下两种方法：

**① 用安装工具（不需要开发环境，推荐）**

| 工具 | 说明 |
|---|---|
| [小白调试助手](https://github.com/likuai2010/auto-installer/releases/latest) | 免费的跨平台鸿蒙调试工具，**签名 + 安装一步到位** |
| [HoKit](https://github.com/yabi-zzh/HoKit/releases/latest) | **一键重签名**、设备投屏、性能监控、文件管理。支持 Windows / macOS / Linux |

> 本项目也收录在 [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)（鸿蒙 Next HAP 安装包合集）中。

**② 用 DevEco Studio 自己签名**

用 DevEco Studio 打开本项目 → **File → Project Structure → Signing Configs →
Automatically generate signature** → `bash deploy.sh`。

> 只想装、不想构建：把下载的 HAP 放进 `entry/build/default/outputs/default/`，再跑 `bash deploy.sh`。

更细的说明、以及**什么绝不能发布**，见 [RELEASE.md](RELEASE.md)。

## 文档

以下每一块都是独立文档。**`docs/` 下的文件是双语的 —— 中文段在前、英文段在后，在同一个文件里。**

| 文档 | 什么时候看 |
|---|---|
| **[docs/FAQ.md](docs/FAQ.md)** | 有具体疑问，先看这里 |
| **[docs/LIMITATIONS.md](docs/LIMITATIONS.md)** | 想报 bug 之前，先确认是不是已知行为 |
| **[docs/BUILDING.md](docs/BUILDING.md)** | 要自己从源码构建 |
| **[docs/PERMISSIONS.md](docs/PERMISSIONS.md)** | 想知道这应用要什么权限 |
| **[PRIVACY.md](PRIVACY.md)** | 想知道它收集什么数据（答案：什么都不收集）|
| **[docs/LAYOUT.md](docs/LAYOUT.md)** | 刚克隆下来，不知道东西在哪 |
| [RELEASE.md](RELEASE.md) | 下载了构建，想知道该下哪个、怎么装、验证过什么 |
| [RELEASE-MAINTENANCE.md](RELEASE-MAINTENANCE.md) | 要发下一个版本 |
| [THIRD-PARTY.md](THIRD-PARTY.md) | 要审计许可证 |
| [payload-src/README.md](payload-src/README.md) | 在凑构建的输入 |

## 许可证

**GPL-3.0** —— 见 [LICENSE](LICENSE)。

Copyright (C) 2026 Haohandc and contributors.

**特别注意**：衍生作品也必须以 GPL-3.0 分发，
所以**不能**基于本项目做闭源产品。

逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 致谢

- [**Mindustry**](https://github.com/Anuken/Mindustry) —— Anuken 开发，游戏本体，**加载时未做修改**
- [**Arc**](https://github.com/Anuken/Arc) —— Anuken 开发的游戏框架；`arc/backend/sdl/**` 与 `arc/graphics/gl/**` 带有本平台补丁
- [**SDL3**](https://github.com/libsdl-org/SDL) —— 窗口 / 输入 / 音频层
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) —— OpenGL 与 SDL 的 JNI 绑定
- [**OpenJDK 21**](https://github.com/openjdk/jdk) —— 运行时

各组件许可证与再分发条款见 [THIRD-PARTY.md](THIRD-PARTY.md)。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
所有测量、真机测试，以及「当测量结果与假设冲突时如何取舍」的判断，都全程对照**一手来源**复核过；
源码注释里记着那些有意思的失败 —— **包括我自己造成的那几个**。
