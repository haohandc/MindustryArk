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

⭐ **本构建不声明那条「让沙箱可执行」的受限权限**
（`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`），
所以**平板和手机都只要一张自动生成的证书就能装**。

⭐⭐ **而且在手机上它也能全速跑。** 调试签名 / 自签名用的 profile 会**临时解禁所有权限**
（不管你声明了什么），Java 运行时因此拿得到 JIT 需要的内存 —— 实测确认：
第三方签名工具（小白调试助手，用它自己的 profile）在手机上一样拿到 JIT。
⭐ **这是手机唯一的安装途径**：应用市场里**没有手机包**，原因见下面「已知限制」。

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

- ⛔ **应用市场里没有手机包，这是有意为之。** 手机的**商店签名拿不到 JIT 需要的内存**
  （那条 ACL 权限只覆盖平板和 PC/2in1），而**「改用解释执行」并不能救** —— 实测：
  装得上，**永远起不来**（解释执行同样需要可执行内存：HotSpot 要先建启动用的桩代码）。
  ⇒ **手机上想玩，请装自签名版本**（见上面「怎么安装」），那条路是好的。
- ⚠️ **手机上自签名后「点开即退」？先换签名工具，别急着当 bug 报。**
  自签名能不能拿到 JIT，取决于**你签名用的 profile 是不是【调试】类型** ——
  **调试 profile 会临时解禁全部权限**，所以 JIT 可用（✅ 实测：小白调试助手在手机上正常，
  启动器报告 `probe=42`）。⚠️ 但**如果工具用的是非调试类型的 profile，应用就会「装得上、点开闪退」，
  而且不给任何线索**：没有 faultlog，沙箱日志也读不到，屏幕上也不会有提示。
  ⇒ **症状是这样，就换一个按调试 profile 签名的工具再试。**（这一条**只能这样描述**：
  失败时应用来不及说任何话，所以判据只有「换工具」这一个动作。）
- ⛔ **没有成就、没有模组浏览器**（与桌面版相比）。
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

### 0.3.0.1 — 2026-09-22

**多人联机与模组。**

- ⭐ **多人联机可用。** 此前整条线被**一个缺失的网络权限**挡住 —— 联机代码一直在包里，
  只是每次启动都因为拿不到权限而失败。局域网联机、搜索公网服务器、在本机开服都已验证。
- ⭐ **模组可以加载了。** 三个入口：游戏自带的「导入模组」按钮、悬浮球菜单的「导入模组」、
  以及应用在「下载」里创建的文件夹 `Download/com.haohandc.mindustryark/`。
  把 `.jar` / `.zip` 丢进去、重启游戏即可生效。
- ⛔ **订正：「改用解释执行」救不了拿不到可执行内存的设备 —— 这条是实测推翻的。**
  之前这里写的是「手机不再『装了却打不开』，会自动改用解释执行，代价是变慢（5~6 秒 → 约 21 秒）」。
  **那是错的，而且从来没有测过。**
  实测（2026-09-22，绑定设备 UDID 的 Release profile、不带可执行内存 ACL）：启动器**正确探到了**
  拿不到内存、也**照做了**加上 `-Xint`，然后**死在 `JNI_CreateJavaVM` 里，此后再无任何输出**。
  根因：**解释执行同样需要可执行内存** —— HotSpot 要先建启动用的桩代码
  （`SharedRuntime` / `StubRoutines`），早于它关心字节码怎么跑。所以那不是「降级模式」，
  而是答错了题。⚠️ 那个 21 秒是**在内存可用的设备上强行打开解释模式**量出来的，
  它证明的是**解释执行的代价**，不是**没内存的设备会怎样**。
  ⇒ 手机的应用市场签名拿不到 ACL（只覆盖平板与 PC/2in1），**商店里因此没有手机包**；
  手机上请装**自签名版本**（调试签名临时解禁全部权限，JIT 可用）。详见
  [docs/LIMITATIONS.md](docs/LIMITATIONS.md)。
- ⭐ **不再靠「机型 + 系统版本」猜这件事了 —— 启动器现在自己探。**
  原先的规则是「手机且 API < 26 才降级」，那对**已测过的那一台**是对的，**一般情况是错的**：
  手机在 API 26 上、用的是应用市场签名、又拿不到 ACL 时，系统**一样**拒绝可执行内存，
  JIT 一样起不来，而规则**不会触发** —— 装上去就是**卡在启动**。
  （另一面：平板**没有** ACL 时也会这样，而机型规则**根本不管平板**。）
  现在启动器直接测「能不能拿到可执行内存」，拿不到就强制解释执行。
  ⚠️ **但这个强制是「如实照做」，不是「救回来」** —— 见上一条：拿不到内存的设备，
  加了 `-Xint` 依然起不来。探针的价值在于**如实报告**，不在于它能修好什么。
- 修：悬浮球菜单**选项太小、挨得太近** —— 可点区域原来只有约 19vp。
- 修：拿不到「下载」目录时，游戏的文件浏览器会打开在**文件系统根目录**
  （实测：空值等于「显式设置成空」，而不是「不设置」）。

### 0.2.0.2 — 2026-09-22 · 未单独发布

- 版本名改成**纯数字和点**（应用市场准入要求），并加入隐私政策。
- 修：屏幕键盘的三个问题 —— 收起后弹回、输入框下方按钮被挡住、强杀重开时自弹。

### 0.2.0-beta.1 — 2026-09-21 · 已发布

- **悬浮球**：可拖动、可半隐藏、菜单里能切换 PC / 触屏模式。
- **沉浸模式**：隐藏状态栏与导航栏，全屏游戏。
- **屏幕键盘**：中文可输入。
- **返回键**退一层 UI（第一次当 ESC，不直接退出应用）。

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

🔗 This project is also listed in **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
(a HarmonyOS Next HAP collection).

### Option 2: sign it yourself with DevEco Studio

1. Open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

⭐ **This build does not declare the restricted permission that makes the sandbox
executable** (`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`), so **an
automatically generated certificate is sufficient to install it** — on a tablet
**or on a phone**.

⭐⭐ **And on a phone it runs at full speed.** A debug / self-signed profile
*temporarily unlocks every permission*, regardless of what the package declares, so
the Java runtime gets the memory its JIT needs — measured and confirmed: a
third-party signing tool (小白调试助手, with its own profile) gets the JIT on a phone.
⭐ **This is the only route phones have**: there is **no phone package in the store**,
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

- ⛔ **There is no phone package in the store, and that is deliberate.** A store-signed phone
  cannot be granted the memory the JIT needs (the ACL covers tablet and PC/2in1 only), and
  **"fall back to interpreted" does not save it** — measured: it installs and **never starts**
  (the interpreter needs executable memory too: HotSpot builds its startup stubs first).
  ⇒ **To play on a phone, install the self-signed build** (see "Installing" above); that route works.
- ⚠️ **Phone, self-signed, closes the instant you tap it? Change your signing tool before
  reporting a bug.** Whether a self-signed install gets the JIT depends on **whether the profile
  you sign with is a DEBUG one** — a debug profile *temporarily unlocks every permission*, so the
  JIT works (✅ measured: 小白调试助手 is fine on a phone; the launcher reports `probe=42`).
  ⚠️ But if the tool signs with a non-debug profile, the app **installs and closes on launch with
  no clues at all**: no faultlog, the sandbox logs are unreadable, and nothing appears on screen.
  ⇒ **If that is your symptom, re-sign with a tool that uses a debug profile.**
  (This is the only way the problem *can* be described: the app never gets far enough to say
  anything, so the only available action is "try another tool".)
- ⛔ **No achievements or mod browser**, compared with the desktop release.
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

### 0.3.0.1 — 2026-09-22

**Multiplayer and mods.**

- ⭐ **Multiplayer works.** The whole feature was blocked by **one missing network
  permission** -- the multiplayer code has always been in the jar, and fail it did on every
  launch for want of that grant. LAN play, browsing public servers and hosting a server on
  the device are all verified.
- ⭐ **Mods load.** Three ways in: the game's own "import mod" button, "导入模组" in the
  floating ball's menu, and the folder the app creates in Downloads at
  `Download/com.haohandc.mindustryark/`. Drop a `.jar` / `.zip` in and restart the game.
- ⛔ **Correction: "fall back to interpreted mode" does NOT save a device that was refused
  executable memory.** An earlier draft of these notes said phones on API 24 and below would
  merely load more slowly (about 21 s instead of 5-6 s). **That was wrong, and it was never
  measured.** Measured 2026-09-22 on a device-bound RELEASE profile with no executable-memory
  ACL: the launcher **correctly detected** the refusal, **did** add `-Xint`, and then **died
  inside `JNI_CreateJavaVM` with no further output at all**. The interpreter needs executable
  memory too -- HotSpot builds its startup stubs (`SharedRuntime` / `StubRoutines`) before it
  ever looks at how bytecode will run -- so interpreted is not a degraded mode, it answers a
  question that was never the blocker. ⚠️ And the 21-second figure was measured by forcing
  interpretation **on a device that did have the memory**: it is the *cost of interpretation*,
  not what a device without the memory does.
  ⇒ A store-signed phone cannot be granted the ACL (which covers tablet and PC/2in1 only), so
  **the store has no phone package**; on a phone, install the **self-signed build** -- a debug
  profile unlocks every permission, so the JIT works. See
  [docs/LIMITATIONS.md](docs/LIMITATIONS.md).
- ⭐ **Whether the JIT is available is now MEASURED, not guessed from device type and system
  version.** The old rule ("phone and API < 26") was right for the one device it came from and
  wrong in general: a phone at API 26 with a store signature and no ACL is refused the memory
  just the same, its JIT fails just the same, and the rule **would not fire**. (The mirror
  case: a tablet without the ACL, which the device rule did not consider at all.) The launcher
  now probes the capability directly and adds the interpreter option when it is absent.
  ⚠️ **That is honest compliance, not a rescue** -- see the bullet above: on a device that was
  refused the memory, adding `-Xint` still does not start. The probe's value is that it reports
  the truth.
- Fixed: the floating ball's menu options were **too small and too close together** -- the
  tap target was about 19 vp.
- Fixed: with no Download directory available, the game's file browser opened at the
  **filesystem root** (measured: an empty value means "explicitly set to empty", which is
  not the same as "not set").

### 0.2.0.2 — 2026-09-22 · not released on its own

- The version name became **digits and dots only** (required for store admission), and a
  privacy policy was added.
- Fixed three on-screen-keyboard problems: it bounced back after being dismissed, it covered
  the buttons under the text field, and it opened by itself after a force-stop.

### 0.2.0-beta.1 — 2026-09-21 · released

- **Floating ball**: draggable, half-hiding, with a menu that switches PC / touch mode.
- **Immersive mode**: status bar and navigation bar hidden, full-screen game.
- **On-screen keyboard**, Chinese included.
- The **Back gesture** goes up one level of UI (it acts as ESC rather than leaving the app).

### 0.1.0-beta.1 — 2026-09-20 · first runnable version

The self-built launcher worked end to end: an embedded JDK, a JVM created from native code,
and a real SDL3 window handed to the game.

## Credits and licences

Mindustry and Arc by **Anuken**; windowing, input and audio **SDL3**; JNI bindings **LWJGL**;
runtime **OpenJDK 21**. Per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Most of the code here was written with AI assistance (Claude via Cherry Studio,
deepseek-flash v4.1).
