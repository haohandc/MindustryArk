# Ark Launcher

[English](README.en.md) | **简体中文**

> [!IMPORTANT]
> **本分支是 [`MindustryArk`](https://github.com/haohandc/MindustryArk) 的 `lite` 分支。**
> 它与 `master` 的**唯一区别**是：**包里不带游戏本体**，玩家自己提供 `.jar`。
> ⇒ **第一次打开会停在启动器界面**（此刻一个 jar 都没有）。把 Mindustry 的 `.jar` 放进
> 界面显示的那个文件夹，下拉刷新、选中它，再点「启动游戏」。
> 其余一切 —— 设备要求、已知限制、构建方式、许可证 —— 与 `master` **完全一致**。

在 **HarmonyOS / OpenHarmony** 上运行 **Mindustry**，使用自建启动器，而不是套一层现成的模拟层。

启动器内嵌一套 JDK，从 native 代码创建 JVM，再把一个真正的 SDL3 窗口交给游戏。
本仓库就是这套启动器。

⛔ **游戏本体不在包里**（这是本分支与 `master` 的唯一区别）—— 你把自己那份 `.jar` 放进来即可，
**它不会被改动，启动器只读它的版本号**。被改造的是它下层的框架：
`arc/backend/sdl/` 的 12 个源文件里有 10 个是我们的
（7 个改过，3 个只存在于本构建：`GLBootstrap` / `GLDiag` / `GLDispatchFix`），
另加 `arc/graphics/gl/`。编译后装进**一份独立的补丁 jar**（26 个 class 条目），在游戏之前加载。
⚠️ 补丁必须在 classpath 上**排在游戏前面** —— JVM 取第一个匹配，顺序反了补丁会静默失效。

> [!IMPORTANT]
> **非官方项目。** 与 Mindustry 项目及 Anuken 无隶属关系，未获其认可或支持。
> 详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

---

## 当前状态

已在 HarmonyOS 7 / API 26 的设备上跑通（**HUAWEI MatePad Pro 12.2" 2025** 平板、**HUAWEI Mate 80 Pro** 手机）：
主菜单正常渲染、采用移动端布局、音频经 OHAudio 播放、触屏与物理键盘均可用。

⭐ **哪些设备能跑**：**鸿蒙 7 / API 26 及以上**，**平板和手机都行**。按发布说明**自签名安装**即可全速运行。
全速依赖应用拿到「可执行内存」—— 从 API 26 起，系统会为**调试** profile 自动申请受支持的 ACL 权限，
手机上同样有效；**这也是应用商店里没有手机包的原因**（**release** 签名永远拿不到）。
⚠️ **鸿蒙 5 / 6** 没有自动授予机制（商店渠道不适用），自签名安装**未验证**。

| 项目 | 状态 |
|---|---|
| JVM 启动 | 可用 —— 但启动器**必须**传 `-XX:UseSVE=0`，否则 JIT 会生成本设备无法执行的 SVE 指令，进程直接 SIGILL |
| 图形 | OpenGL ES，经 SDL3 |
| 音频 | OHAudio，经自编的 `libarcarm64.so`（含 SDL3 后端） |
| 触屏 | 可用，**含双指捏合缩放** |
| 键盘 | 可用（物理键盘；WASD 与 ESC）。往游戏输入框里打字用**带输入法的弹出式输入框** —— 见[已知限制](docs/LIMITATIONS.md) |
| 鼠标 / 手柄 | 鼠标可用；手柄**未测试** |
| 存档导入导出 | 走「下载」里的应用文件夹往返（选择器模式，**两台设备均实测可用，且不需要任何权限**）。⚠️ **仍未验证**：游戏自带的文件浏览器能否读那个路径（它走 libc 用路径，而应用的授权是按 URI 持有的）—— 见[已知限制](docs/LIMITATIONS.md) |
| 模组 | 可用。用**游戏自带的「导入模组」按钮**导入 —— 这是**唯一**入口，且不用重启。应用**故意不**自己去 Download 里收文件：把文件放进 `Download/Ark Launcher/` 后，在那个浏览器里**选一下**即可。见[已知限制](docs/LIMITATIONS.md) |
| 桌面 / 移动模式切换 | 可切换，但**需要重启应用** —— 见[常见问题](docs/FAQ.md) |
| 网络 / 联机 | **平台层面已通**（`socket` / `epoll` / DNS / TCP / TLS / HTTP 全部实测可用）。**局域网、公网服务器搜索、在本机开服三项均已实测，并且已经实际打完过一局**（2026-09-23） |

## 启动器：多版本与存档管理

启动器自己有界面（**首页 / 存档 / 设置**三个页签），与游戏无关，**不启动游戏也能用**。

| 能做什么 | 说明 |
|---|---|
| 选游戏版本 | 把任意多个 jar 放进**界面上印出来的那个文件夹**（启动器会把它显示在列表上方），逐个选。版本号从 jar 文件里读出来，不靠文件名 |
| **版本隔离** | 每个游戏版本各用一套游戏数据。四档粒度：不隔离（出厂）/ 大版本 / 构建号 / 小版本 |
| **存档管理** | 列出**所有版本**的存档（按「共用同一份数据」分组），看元数据（版本 / 地图 / 时长 / 模组），复制、移动、跨版本搬 |
| 删除 = 垃圾站 | 删除不是抹掉，是搬进垃圾站：保留 3 / 7 / 30 天，或**归档**（永不自动清理）。随时可以放回 |
| 启动模式 | 每次启动先进启动器，或直接进游戏 |

⭐ 隔离的一条保证：**数据最初的那一份永不被搬动** —— 换 jar、换粒度、换版本都不会让它消失。

> [!NOTE]
> 隔离是**玩家主动打开**的 —— 出厂就是「不隔离」。打开时可以选择把现有数据复制过去，或从空开始。

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

- [**Mindustry**](https://github.com/Anuken/Mindustry) —— Anuken 开发，游戏本体（**本分支不带，由你自己提供**），**加载时未做修改**
- [**Arc**](https://github.com/Anuken/Arc) —— Anuken 开发的游戏框架，本平台补丁装在其中
- [**SDL3**](https://github.com/libsdl-org/SDL) —— 窗口 / 输入 / 音频层
- [**LWJGL**](https://github.com/LWJGL/lwjgl3) —— OpenGL 与 SDL 的 JNI 绑定
- [**OpenJDK 21**](https://github.com/openjdk/jdk) —— 运行时
> [!NOTE]
> 本仓库绝大部分代码、文档和文字由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
