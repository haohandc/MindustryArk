# Mindustry Ark · 发布说明

> 维护者记录（为什么要这样做、版本对照表、事故记录、发布前检查）在
> **[`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md)**。本文件只讲用户要的东西。

---

# 中文

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry —— 内嵌 JDK、从 native
代码创建 JVM、把真正的 SDL3 窗口交给游戏，不套任何现成的模拟层。

⚠️ **非官方项目。** 与 Mindustry 及 Anuken 无隶属关系。以 **GPL-3.0** 分发
（构建产物再分发了 GPL-3.0 的 Mindustry）。

内嵌的游戏版本：**Mindustry `v8 Build 160.4`**（游戏内显示 `release build 160.4`）。
⚠️ 这是 **Mindustry 自己的**版本号，与本项目的版本号是**两套体系**，各走各的。

## 下载哪个文件

| 文件 | 说明 |
|---|---|
| `MindustryArk-<版本>-unsigned.hap` | **应用本体。** 未签名，需自签一次（见下）|
| `MindustryArk-<版本>-payload.zip` | 载荷包。**只有要从源码构建才需要**，玩游戏不必下 |

## 怎么安装

⚠️ **未签名的 HAP 装不上** —— HarmonyOS 要求每个 `.hap` 先签名。

### 方法一：用安装工具（**不需要开发环境**，推荐）

| 工具 | 说明 |
|---|---|
| [**小白调试助手**](https://github.com/likuai2010/auto-installer/releases/latest) | 免费的跨平台鸿蒙调试工具，**签名 + 安装一步到位** |
| [**HoKit**](https://github.com/yabi-zzh/HoKit/releases/latest) | 一站式工具：**一键重签名**、设备投屏、性能监控、文件管理。支持 Windows / macOS / Linux |

🔗 本项目也收录在 **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
（鸿蒙 Next HAP 安装包合集）的列表中。

### 方法二：用 DevEco Studio 自己签名

1. 用 DevEco Studio 打开本项目
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

⭐ **本项目不申请任何受限权限**（没有需要向 AppGallery Connect 申请的 ACL 权限），
所以**自动生成的证书就够了**，不必去申请任何东西。

### 只想装、不想构建

把下载的 HAP 放进 `entry/build/default/outputs/default/`，再跑 `bash deploy.sh`。

## 已验证

HarmonyOS 7 / API 26 真机验证：**HUAWEI MatePad Pro 12.2" 2025** 平板、
**HUAWEI Mate 80 Pro** 手机。

| 项目 | 状态 |
|---|---|
| 主菜单与渲染 | ✅ 移动端布局 |
| 音频 | ✅ OHAudio |
| 触屏 | ✅ 点击、长按、**双指捏合缩放** |
| 软键盘 | ✅ 点游戏里的输入框自动弹出，**接系统输入法 ⇒ 中文可打**；打字、退格、ESC 关闭正常 |
| 实体键盘 | ✅ WASD；ESC 打开菜单，**不被系统当作「返回」**；应用自己的输入框在屏幕上时**也能打中文** |
| 鼠标 | ✅ 全部按键 + 滚轮 |
| 悬浮球 | ✅ 拖动、吸附、半隐藏、点击恢复、位置持久化 |
| 沉浸模式 | ✅ 全屏（平板 / 手机）|
| 键盘不再遮挡输入框 | ✅ 键盘弹出时框架把游戏输入框推到可见位置 |
| 存档与数据导入导出 | ✅ 从「下载」目录往返 |
| 退出 | ✅ 正常关闭，不被系统标记为崩溃 |

## 已知限制

**完整的限制清单（附实测证据）在 [docs/LIMITATIONS.md](docs/LIMITATIONS.md)。**
这里只留**下载前就该知道的**：

- ⛔ **没有多人联机、没有成就、没有模组浏览器**（与桌面版相比）。
- ⚠️ **实体键盘在「应用自己的输入框不在屏幕上」时只能打 ASCII** ——
  **点一下游戏里的输入框**，让应用自己的输入框弹出（它接系统输入法），实体键盘**也能打中文**。
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
- **只在上面那两台设备上验证过**，其他鸿蒙设备未测试。能否可用取决于平台对**可执行内存**的策略，
  策略不同的设备会以本项目无法预测的方式失败。

## 常见问题

完整 FAQ 是独立的一篇：**[docs/FAQ.md](docs/FAQ.md)**（双语 —— 中文段在前、英文段在后）。
放在这里会让三个文档说同一件事，所以只留最常被问的两条：

- **返回键好像没反应？** 返回键 = 游戏内的 **ESC**（退一层）；
  **主界面上 ESC 无处可去**，所以那里看起来没反应。有意为之。
  **退出请用游戏主菜单的 Quit。**
- **DevEco 报 `cppcrash`？** 那里混了**两件性质完全不同**的事，其中一件**不是崩溃**。
  ⚠️ 并且**别照报告里的函数名去查代码** —— 那两个位置经反汇编核对**都不是内存访问指令**。

## 从源码构建

```bash
unzip -o MindustryArk-<版本>-payload.zip
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

（签名按上面「怎么安装」配置）

## 致谢与许可

Mindustry 与 Arc 由 **Anuken** 开发；窗口 / 输入 / 音频层 **SDL3**；JNI 绑定 **LWJGL**；
运行时 **OpenJDK 21**。逐组件条款见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，deepseek-flash v4.1）。

---

# English

Run Mindustry on HarmonyOS / OpenHarmony with a **self-built launcher** — an embedded JDK,
a JVM created from native code, and a real SDL3 window handed to the game. No existing
emulation layer involved.

⚠️ **Unofficial.** Not affiliated with, endorsed by, or supported by the Mindustry project
or Anuken. Distributed under **GPL-3.0** (the build redistributes GPL-3.0 Mindustry).

Embedded game version: **Mindustry `v8 Build 160.4`** (in-game: `release build 160.4`).
⚠️ That is the *game's* version, not this project's — the two move independently.

## Which file to download

| File | What it is |
|---|---|
| `MindustryArk-<version>-unsigned.hap` | **The app.** Unsigned — sign it once yourself (below) |
| `MindustryArk-<version>-payload.zip` | Build inputs. **Only needed to build from source** |

## Installing

⚠️ **An unsigned HAP will not install** — HarmonyOS requires every `.hap` to be signed.

### Option 1: an installer tool (**no dev environment needed**, recommended)

| Tool | What it does |
|---|---|
| [**小白调试助手** (Auto-Installer)](https://github.com/likuai2010/auto-installer/releases/latest) | Free cross-platform HarmonyOS debugging tool — **signing and installing in one step** |
| [**HoKit**](https://github.com/yabi-zzh/HoKit/releases/latest) | All-in-one: **one-click re-signing**, device mirroring, perf monitoring, file management. Windows / macOS / Linux |

🔗 This project is also listed in **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
(a HarmonyOS Next HAP collection).

### Option 2: sign it yourself with DevEco Studio

1. Open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

⭐ **This project requests no restricted permission** (no ACL permission requiring an
AppGallery Connect application), so **an automatically generated certificate is
sufficient**.

### Install only, without building

Drop the downloaded HAP into `entry/build/default/outputs/default/` and run `bash deploy.sh`.

## Verified

On a **HUAWEI MatePad Pro 12.2" 2025** tablet and a **HUAWEI Mate 80 Pro** phone, both
HarmonyOS 7 / API 26.

| Area | State |
|---|---|
| Menu and rendering | ✅ mobile layout |
| Audio | ✅ OHAudio |
| Touch | ✅ tap, long-press, **two-finger pinch zoom** |
| On-screen keyboard | ✅ appears on tapping a field in the game, **wired to the system input method ⇒ Chinese works**; backspace and ESC work |
| Physical keyboard | ✅ WASD; ESC opens the menu and is **not** treated as Back; **Chinese too** while the app's own field is up |
| Mouse | ✅ all buttons and the wheel |
| Floating ball | ✅ drag, snap, half-hide, tap to restore, position remembered |
| Immersive mode | ✅ full-screen (tablet and phone) |
| Keyboard no longer covers the field | ✅ the framework pushes the game's field clear |
| Save and data import/export | ✅ via the Download folder |
| Quitting | ✅ clean exit, not flagged as a crash |

## Known limitations

**The full list, with the measurements behind it, is in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).**
Only what you should know *before downloading* is kept here:

- ⛔ **No multiplayer, achievements or mod browser**, compared with the desktop release.
- ⚠️ **A physical keyboard is ASCII-only while the app's own text field is NOT on screen** —
  **tap a text field in the game** so the app's own field comes up (it is wired to the system
  input method) and the physical keyboard **types Chinese too**.
- **Importing game data makes the game exit on purpose**, so it restarts with the new data.
  It looks like a crash and is not one.
- **Verified on those two devices only.** Whether it works elsewhere depends on the platform's
  policy on executable memory, and a device that enforces it differently would fail in ways
  this project has no way to predict.

## FAQ

The full FAQ is its own document: **[docs/FAQ.md](docs/FAQ.md)** (bilingual — Chinese
section first, then English). Keeping it here too would have three documents saying the
same thing, so only the two most-asked ones stay:

- **Back does nothing?** Back is the game's **ESC** ("up one level");
  **on the main menu ESC has nowhere to go**, so it looks dead there. Deliberate.
  **To quit, use Quit on the game's main menu.**
- **DevEco reports `cppcrash`?** That conflates **two completely different things**, one of
  which is **not** a crash. ⚠️ And **do not go looking for code based on the function names
  in that report** — disassembly shows those two frames are **not memory accesses at all**.

## Building from source

```bash
unzip -o MindustryArk-<version>-payload.zip
bash deploy.sh          # build + verify + install + launch + collect log
```

(configure signing as under "Installing")

## Credits and licences

Mindustry and Arc by **Anuken**; windowing, input and audio **SDL3**; JNI bindings **LWJGL**;
runtime **OpenJDK 21**. Per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Most of the code here was written with AI assistance (Claude via Cherry Studio,
deepseek-flash v4.1).
