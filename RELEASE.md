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

本项目也收录在 **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
（鸿蒙 Next HAP 安装包合集）的列表中。

### 方法二：用 DevEco Studio 自己签名

1. 用 DevEco Studio 打开本项目
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

**本构建不声明那条「让沙箱可执行」的受限权限**
（`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`），
所以**平板和手机都只要一张自动生成的证书就能装**。

**而且在手机上它也能全速跑 —— 条件是鸿蒙 7 / API 26 及以上。** 调试签名 / 自签名用的 profile
会**临时解禁所有权限**（不管你声明了什么），Java 运行时因此拿得到 JIT 需要的内存 —— 实测确认：
第三方签名工具（小白调试助手，用它自己的 profile）在手机上一样拿到 JIT。
⚠️ **鸿蒙 5 / 6 没有这个机制**，应用商店渠道不可用；自签名安装**未验证**。
**这是手机唯一的安装途径**：应用市场里**没有手机包**，原因见下面「已知限制」。

⚠️ **上架应用市场用的是另一份产物**，由 `bash scripts/make_store_app.sh tablet` 生成：
它**会**声明那条权限，所以需要一份带 ACL 授权的 Release Profile ——
因为商店签名**不带**调试签名那个临时解禁。见
[BUILDING.md](docs/BUILDING.md) 的「ACL（受限权限）」。

### 只想装、不想构建

把下载的 HAP 放进 `entry/build/default/outputs/default/`，再跑 `bash deploy.sh`。

## 已验证

HarmonyOS 7 / API 26 真机验证：**HUAWEI MatePad Pro 12.2" 2025** 平板、
**HUAWEI Mate 80 Pro** 手机。

| 项目 | 状态 |
|---|---|
| 主菜单与渲染 | 移动端布局 |
| 音频 | OHAudio |
| 触屏 | 点击、长按、**双指捏合缩放** |
| 软键盘 | 点游戏里的输入框自动弹出，**接系统输入法 ⇒ 中文可打**；打字、退格、ESC 关闭正常 |
| 实体键盘 | WASD；ESC 打开菜单，**不被系统当作「返回」**；应用自己的输入框在屏幕上时**也能打中文** |
| 鼠标 | 全部按键 + 滚轮 |
| 悬浮球 | 拖动、吸附、半隐藏、点击恢复、位置持久化 |
| 沉浸模式 | 全屏（平板 / 手机）|
| 键盘不再遮挡输入框 | 键盘弹出时框架把游戏输入框推到可见位置 |
| 存档与数据导入导出 | 从「下载」目录往返 |
| 退出 | 正常关闭，不被系统标记为崩溃 |

## 已知限制

**完整的限制清单（附实测证据）在 [docs/LIMITATIONS.md](docs/LIMITATIONS.md)。**
这里只留**下载前就该知道的**：

**按设备**

| 设备 | 自签名安装 | 应用商店 |
|---|---|---|
| **平板** | 可用 | ACL 批准后可用 |
| **手机** | 部分可用（见下） | **不提供** |
| **PC · 2in1** | 未测试 | 未测试 |

- **手机为什么没有应用商店版本**：可执行内存权限（ACL，`ALLOW_WRITABLE_CODE_MEMORY`）**只向平板与 PC / 2in1 开放**。而 Java 的 JIT 需要该项能力。
- **手机为什么是「部分可用」**：取决于系统版本，见下。符合版本的手机上，自签名安装和平板一样。

**按系统版本**

- 本应用声明的最低版本是 **6.1.1（API 24）**，该下限**未实测**。
- **API 26（鸿蒙 7）起**：调试安装会**自动申请**受支持的 ACL 权限 ⇒ 手机自签名可用。
- **鸿蒙 5 / 6**：没有这个机制，能否自签名安装**请以实机结果为准**。

更多限制：

- ⚠️ **手机上自签名后「点开即退」？先换签名工具，别急着当 bug 报。**
  自签名能不能拿到 JIT，取决于**你签名用的 profile 是不是【调试】类型** ——
  **调试 profile 会临时解禁全部权限**，所以 JIT 可用（实测：小白调试助手在手机上正常，
  启动器报告 `probe=42`）。⚠️ 但**如果工具用的是非调试类型的 profile，应用就会「装得上、点开闪退」，
  而且不给任何线索**：没有 faultlog，沙箱日志也读不到，屏幕上也不会有提示。
  ⇒ **症状是这样，就换一个按调试 profile 签名的工具再试。**（这一条**只能这样描述**：
  失败时应用来不及说任何话，所以判据只有「换工具」这一个动作。）
- **没有成就，也没有创意工坊** —— 两者都是 **Steam 平台**的功能，Mindustry 本身不含。模组用游戏自带的浏览器导入，它**带有联网搜索**，只是不如创意工坊方便。
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

## 版本历史

### 1.0.0.1 — 2026-09-22 · 1.0.0 的 RC 1

功能已冻结，之后只修阻断性问题。

**新增**

| 项目 | 说明 |
|---|---|
| **多人联机** | 局域网联机、搜索公网服务器、在本机开服 |
| **模组加载** | 支持 `.jar` / `.zip` 格式的模组。放进 `Download/Mindustry Ark/`（真实路径 `Download/com.haohandc.mindustryark/`）|
| **悬浮球 · 关于** | 悬浮球菜单新增「关于」，可查看版本号与仓库地址 |

**变动**

| 项目 | 说明 |
|---|---|
| **文件夹权限** | 不再申请「下载」文件夹权限，改用应用自己创建的指定文件夹。详见「新增 · 模组加载」|

**修复**

| 问题 | 说明 |
|---|---|
| **模组导入入口过多** | 现在只有游戏自带的「导入模组」按钮。悬浮球菜单里的「导入模组」已移除（该入口未在已发布版本中出现过），应用也不再自动扫描文件夹 |
| **悬浮球菜单点击区域过小** | 每个选项原来只有约 19vp 高，且挨得很近；已放大并加上分隔 |

手机相关说明见上面「[已知限制](#已知限制)」。

### 0.2.0.2 — 2026-09-22 · 未单独发布

**变动**

| 项目 | 说明 |
|---|---|
| **版本名** | 改成纯数字和点（应用市场准入要求）|
| **隐私政策** | 新增 |

**修复**

| 问题 | 说明 |
|---|---|
| **屏幕键盘** | 三个问题：收起后弹回、输入框下方按钮被挡住、强杀重开时自弹 |

### 0.2.0-beta.1 — 2026-09-21 · 已发布

**新增**

| 项目 | 说明 |
|---|---|
| **悬浮球** | 可拖动、可半隐藏、菜单里能切换 PC / 触屏模式 |
| **沉浸模式** | 隐藏状态栏与导航栏，全屏游戏 |
| **屏幕键盘** | 中文可输入 |
| **返回键** | 退一层 UI（第一次当 ESC，不直接退出应用）|

### 0.1.0-beta.1 — 2026-09-20 · 首个可运行版本

自建启动器跑通：内嵌 JDK、从 native 创建 JVM、把真正的 SDL3 窗口交给游戏。

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

This project is also listed in **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
(a HarmonyOS Next HAP collection).

### Option 2: sign it yourself with DevEco Studio

1. Open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

**This build does not declare the restricted permission that makes the sandbox
executable** (`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`), so **an
automatically generated certificate is sufficient to install it** — on a tablet
**or on a phone**.

**And on a phone it runs at full speed — provided the phone is on HarmonyOS 7 / API 26 or
later.** A debug / self-signed profile *temporarily unlocks every permission*, regardless of
what the package declares, so the Java runtime gets the memory its JIT needs — measured and
confirmed: a third-party signing tool (小白调试助手, with its own profile) gets the JIT on a phone.
⚠️ **HarmonyOS 5 / 6 has no such mechanism**, so the app store route is unavailable; a self-signed install is **untested**.
**This is the only route phones have**: there is **no phone package in the store**,
for the reason under "Known limitations" below.

⚠️ **The AppGallery submission is a different artifact**, built by
`bash scripts/make_store_app.sh tablet`. It **does** declare that permission, so it
needs a Release Profile carrying the matching ACL grant — a store signature does not
come with the debug unlock. See "ACL (restricted permissions)" in
[BUILDING.md](docs/BUILDING.md).

### Install only, without building

Drop the downloaded HAP into `entry/build/default/outputs/default/` and run `bash deploy.sh`.

## Verified

On a **HUAWEI MatePad Pro 12.2" 2025** tablet and a **HUAWEI Mate 80 Pro** phone, both
HarmonyOS 7 / API 26.

| Area | State |
|---|---|
| Menu and rendering | mobile layout |
| Audio | OHAudio |
| Touch | tap, long-press, **two-finger pinch zoom** |
| On-screen keyboard | appears on tapping a field in the game, **wired to the system input method ⇒ Chinese works**; backspace and ESC work |
| Physical keyboard | WASD; ESC opens the menu and is **not** treated as Back; **Chinese too** while the app's own field is up |
| Mouse | all buttons and the wheel |
| Floating ball | drag, snap, half-hide, tap to restore, position remembered |
| Immersive mode | full-screen (tablet and phone) |
| Keyboard no longer covers the field | the framework pushes the game's field clear |
| Save and data import/export | via the Download folder |
| Quitting | clean exit, not flagged as a crash |

## Known limitations

**The full list, with the measurements behind it, is in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).**
Only what you should know *before downloading* is kept here:

**By device**

| Device | Self-signed install | App store |
|---|---|---|
| **Tablet** | Works | Available once the ACL is approved |
| **Phone** | Partial (see below) | **Not offered** |
| **PC · 2in1** | Untested | Untested |

- **Why there is no app store version for phones**: the executable-memory permission (ACL, `ALLOW_WRITABLE_CODE_MEMORY`) is granted to **tablets and PC / 2in1 only**. Java's JIT needs it.
- **Why a phone is "partial"**: it depends on the system version — see below. On a supported version, a self-signed install works the same as on a tablet.

**By system version**

- The app declares a minimum of **6.1.1 (API 24)**; that floor is **untested**.
- **From API 26 (HarmonyOS 7)**: a debug install is granted the supported ACL permissions **automatically** ⇒ a phone can install self-signed.
- **HarmonyOS 5 / 6**: no such mechanism; whether a self-signed install works **is untested — go by what the device does**.

More limitations:

- ⚠️ **Phone, self-signed, closes the instant you tap it? Change your signing tool before
  reporting a bug.** Whether a self-signed install gets the JIT depends on **whether the profile
  you sign with is a DEBUG one** — a debug profile *temporarily unlocks every permission*, so the
  JIT works (measured: 小白调试助手 is fine on a phone; the launcher reports `probe=42`).
  ⚠️ But if the tool signs with a non-debug profile, the app **installs and closes on launch with
  no clues at all**: no faultlog, the sandbox logs are unreadable, and nothing appears on screen.
  ⇒ **If that is your symptom, re-sign with a tool that uses a debug profile.**
  (This is the only way the problem *can* be described: the app never gets far enough to say
  anything, so the only available action is "try another tool".)
- **No achievements and no Steam Workshop** — both are **Steam-platform** features rather than part of the game. Mods are imported with the game's own browser, which **includes online search**; it is just less convenient than the Workshop.
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

## Changelog

### 1.0.0.1 — 2026-09-22 · RC 1 of 1.0.0

Features are frozen; only blocking fixes from here.

**Added**

| Item | Notes |
|---|---|
| **Multiplayer** | LAN games, the public server list, and hosting on the device |
| **Mod loading** | `.jar` and `.zip` mods. Put them in `Download/Mindustry Ark/` (real path `Download/com.haohandc.mindustryark/`) |
| **Floating ball · About** | A new "About" entry in the floating ball's menu, showing the version and the repository address |

**Changed**

| Item | Notes |
|---|---|
| **Folder permission** | No longer requests permission for the system Download folder; uses an app-created folder instead. See "Added · Mod loading" |

**Fixed**

| Problem | Notes |
|---|---|
| **Too many ways to import a mod** | There is now only the game's own "import mod" button. The floating ball's "导入模组" has been removed (that entry never appeared in a released version), and the app no longer scans the folder by itself |
| **The floating ball's menu options were too small to tap** | Each row was about 19 vp tall and the rows were close together; they are now larger and separated |

Phones are covered under "[Known limitations](#known-limitations)" above.

### 0.2.0.2 — 2026-09-22 · not released on its own

**Changed**

| Item | Notes |
|---|---|
| **Version name** | Now digits and dots only (required for store admission) |
| **Privacy policy** | Added |

**Fixed**

| Problem | Notes |
|---|---|
| **On-screen keyboard** | Three problems: it bounced back after being dismissed, it covered the buttons under the text field, and it opened by itself after a force-stop |

### 0.2.0-beta.1 — 2026-09-21 · released

**Added**

| Item | Notes |
|---|---|
| **Floating ball** | Draggable, half-hides itself, and its menu switches PC / touch mode |
| **Immersive mode** | Hides the status and navigation bars for full-screen play |
| **On-screen keyboard** | Chinese input works |
| **Back key** | Goes up one level (ESC first; it does not quit the app) |

### 0.1.0-beta.1 — 2026-09-20 · first runnable version

The self-built launcher works end to end: embedded JDK, a JVM created from native code, and a
real SDL3 window handed to the game.

## Credits and licences

Mindustry and Arc by **Anuken**; windowing, input and audio **SDL3**; JNI bindings **LWJGL**;
runtime **OpenJDK 21**. Per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Most of the code here was written with AI assistance (Claude via Cherry Studio,
deepseek-flash v4.1).
