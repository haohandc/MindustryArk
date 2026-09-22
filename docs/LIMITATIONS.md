# 已知限制 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

> 这些是**已知且有意保留**的行为，不是待修的缺陷清单。
> 频繁问到的问题另见 **[FAQ.md](FAQ.md)**。

---
# 中文

- **文字输入，以及两条路各自能做什么。** 点游戏里的输入框（存档名、蓝图名、导出时的文件名），
  应用会**自己弹出一个输入框**并接上系统输入法 ⇒ **软键盘出现、可用输入法组合，中文也能打**。
  实体键盘同样可用，**能打什么取决于焦点在哪**：
    - **我们的输入框在屏幕上时**，键盘也走系统输入法 ⇒ **实体键盘同样能打中文**；
    - **不在时**，键盘直接交给游戏、走 SDL 的「按键→字符」通路 ⇒ **只支持 ASCII**。
  焦点只有一个，所以只有这两种状态。
  - **两条路并存，是因为 SDL 自己的输入法通路在这里根本走不通。**
    本进程把 `libSDL3.so` **映射了两次**，ArkTS 把输入法 controller 交给了**不跑游戏的那一份**，
    而 `napi_ref` 无法跨这两份搬移 ⇒ SDL 永远弹不出键盘。取而代之的做法：
    应用**监听游戏要文字的请求**（通过文件）、弹出一个 ArkUI `TextInput`，
    再把用户输入**喂回 SDL 的文本事件队列**。
    代码在 `SDL_openharmony.c`、`SDL_openharmonyevents.c` 与 `ets/pages/Index.ets`。
  - **一处粗糙之处，直说**：应用读不到游戏输入框的**光标位置**，所以发的是与
    「它认为输入框已有内容」的**差**。**在末尾打字与退格是精确的**；
    **在中间插入/修改**会被「撤回重发」方式修复 —— 结果正确，但那段字会在屏幕上**重打一遍**。
- **桌面/移动模式无法在运行期切换**：模式在启动时固定。Mindustry 游戏内自带
  「鼠标 + 键盘操控」开关，能覆盖大部分同类需求。切换方式见 [FAQ.md](FAQ.md)。
- `libarc-filedialogsarm64.so` 链接的是 **glibc**，本平台加载不了，
  因此 Arc 回退到 Mindustry **自带的游戏内文件浏览器**。这也是浏览器根目录必须重定向到「下载」的原因。
- **导入游戏数据后游戏会主动退出**（`Core.app.exit()`），以便用新数据重启。
  **这看起来像崩溃，但不是。**
- **目前验证了两台设备**：**MatePad Pro 12.2" 2025** 平板与 **Mate 80 Pro** 手机，均为 HarmonyOS 7 / API 26。
  其他设备**未测试** —— 本项目依赖平台对「可执行内存」的策略，
  若某设备在这点上做法不同，出错方式我们无法预判。
- **`2in1`（PC）上沉浸模式不生效** —— 任务栏与窗口标题栏会留着。
  这是平台限制，不是没做。**实测确认**。功能不受影响：悬浮球在 PC 上**能正常隐藏**。
- ⚠️ **每次正常退出时，`hiview/AppKilledReporter` 都会打一条 `reason: CppCrash`。
  它不是崩溃，也归不到本应用头上 —— 你看到的就是这行，不必惊慌。**
  游戏内点 Quit 正常退出时实测，同一个 5 毫秒窗口内：

  | 组件 | 结论（带归属信息） |
  |---|---|
  | `AppMS` | `Kill Reason: app exit`，`pid=… processName=com.haohandc.mindustryark` |
  | `sceneboard` | `onProcessDied, uid: …, bundleName: com.haohandc.mindustryark, pid: …` |
  | `aidataservice` | `process died, bundleName: com.haohandc.mindustryark` |
  | `hiview` | `uid: 0`、`bundleName:` **空**、`reason: CppCrash` |

  **唯一没有归属的那个在喊崩溃，而它被另外三个反驳。** 而且没有任何产物：
  没有 `faultlog`、没有 `cppcrash` 目录、没有转储、没有非零退出信号，
  启动器**真遇到**致命信号时才写的 `crash.txt` 一直是空的。
  产生那三条有归属记录的退出握手在 `EntryAbility.ets` 里。

以上各条背后的原因写在**对应代码的注释里**，而不在这份文档里 —— 入口是 `entry/src/main/cpp/launcher.c`。

---
## ⚠️ 局域网里同一个服务器可能被列出两次

**现象**：开一台服务器，另一台设备在「加入游戏」的局域网列表里**看到两条**，
指向同一台机器。

**原因在 ArcNet 自己**（游戏用的网络库，不在我们这层）：`Client.discoverHosts()`
会**同时**发两个独立探测 —— 一个 **UDP 广播**、一个**多播**，各自一个 socket，
各自对每个回应回调一次，**全程没有按地址去重**。一个**同时响应这两种探测**的服务器
就会上报两次，界面于是画两条。

🔶 **推断部分**：上面那句「两种探测都成功」我**没有实测**，是从本平台网络探测
（`socket`/`epoll`/广播都通）推出来的。可确定的是**代码里确实没有去重**。

⇒ **不影响使用**：两条指向同一台服务器，点哪条都能进。
⚠️ 这是**上游行为**，不是本移植引入的；手机/平板上都可能有。

## ⚠️ 在部分设备上应用装了却起不来

**现象**：应用安装成功，一点就退，**没有任何崩溃提示**。

**已知条件**（2026-09-22 实测）：在**华为自检**分配的设备（**HarmonyOS 6.1.1 / API 24**）上，
启动器发完 JVM 参数、调用 `JNI_CreateJavaVM` 之后**再无输出**，进程随即消失。
同一份包在 **HarmonyOS 7 / API 26** 的设备上正常进入主菜单。

**原因（实测）**：该设备**拒绝一切匿名可执行内存**：

```
!! mmap(RWX) FAILED: errno=22 (Invalid argument)
 [1] clear_cache   (CONTROL) -> -1   unexpected
 [2] mprotect RW->RX          -> -1   unexpected
```

⇒ **JVM 的 JIT 无法启动**，所以卡在 `JNI_CreateJavaVM` 里。

⚠️ **两个可能的原因我们还没分离开**：① 平台版本太老；② 该设备运行的是**应用市场签名（release）**的包，
而我们平时在真机上装的都是**调试签名**的包。两者都能解释现有全部观测。

⚠️ 另外本应用声明的最低版本是 `compatibleSdkVersion 6.1.1(24)`，**而这个声明没有得到实测支持** ——
所有"能跑"的证据都来自 API 26。修好之前，在 API 24 设备上可能出现"装得上、跑不起来"。


## ⚠️ 在 HarmonyOS 7 以下的手机上会明显变慢（兼容模式）

**为什么**：详见上一节。为了让应用能在这些设备上启动，Java 运行时改成了「解释执行」
而不是即时编译。

**实测代价**（HarmonyOS 7 平板，人工开启该模式）：

| | 加载时间 |
| --- | --- |
| 正常（JIT） | 约 5~6 秒 |
| 兼容模式 | **约 21 秒** |

**游戏内的表现不是均匀变慢，而是随【视野范围】放大**：

- **窗口缩小**（约手机大小）：高负载下**基本能玩**
- **全屏**：高负载下**掉帧严重，基本不能玩**

⇒ 原因是「渲染」是原生的（不受影响），而「单位与瓦片的模拟」跑在 Java 上：
屏幕越大，每帧要更新的东西越多，而帧预算不变。

⚠️ 汇总：兼容模式只影响「模拟」这部分（渲染不受影响），
且代价随**视野面积**放大 —— 屏幕越大越吃力。


## ⚠️「下载」目录：文件夹在，但有些机型上应用**够不到它**

⚠️ **说清楚一件事**：这台手机的**「下载」目录是存在且正常的**（用户确认）——
**不是**「这个机型没有下载目录」。缺的是**应用拿到它路径的那条路**。

**现象**：在 **Mate 80 Pro 手机**上，应用申请「下载目录」权限时**不弹窗**，
权限列表里也看不到它，而且**「Download/MindustryMods/」这个入口用不了**。
**在 MatePad Pro 平板上一切正常。**

**依据（同一份 HAP、同一个签名 —— `appId` 逐字符相同，两台设备实测）**：

| | 权限状态 |
| --- | --- |
| 平板 MatePad Pro | `[0, 0]` 两个都**已授予** |
| 手机 Mate 80 Pro | `[0, -1]` 下载权限**未授予** |

手机上应用自己记录的原文：

```text
mods: no Downloads directory (The device doesn't support this api)
permission request: ....READ_WRITE_DOWNLOAD_DIRECTORY -> auth=2 dialogShown=true errorReason=0
```

⚠️ **这三个值互相矛盾，所以这里只报事实、不解释原因**：

| 字段 | 值 | SDK 的说法 |
| --- | --- | --- |
| `authResults` | `2` | 「无效请求」（未声明 / 名字无效 / 申请条件不满足）|
| `dialogShownResults` | `true` | 「系统**弹了**授权弹窗」|
| `errorReasons` | `0` | 「**本次请求有效**」|

而且整个调用在发出后约 **170 毫秒**就返回了 —— 人不可能这么快看完并关掉一个弹窗。
**三个字段凑不出一个自洽的故事**，所以本文件不声称知道原因。

⭐ 这里曾经写过「`authResults = 2` 是无效请求，所以永远不会弹窗」—— 那是**从 SDK 的
字段说明推出来的**，而上面的实测组合**不支持**这个推断。已撤回。**能确定的是结果**：
**权限没授予，玩家看不到任何提示。**

⚠️ **但「设备能力差异」这句也被后续测量推翻了一半**：`atm dump --definition` 在两台设备上
给出的定义**逐字相同** ——

```text
permissionName : ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
grantMode      : USER_GRANT      <- 普通用户授权，不是 ACL
availableLevel : NORMAL
provisionEnable: true
```

⇒ 它**不是 ACL 权限、也不分设备类型**，**本来就该能在手机上授予**。两台设备的系统版本
也完全相同（`OpenHarmony-7.0.0.105`、API 26、同一 build）。
**所以「为什么手机上弹窗不出来」至今没有解释**，只知道结果。

⇒ 能确定的只有：**在这台手机上，这个权限拿不到，且用户看不到任何提示。**


**影响**：在这类机型上，
「存档从下载目录导入/导出」与「Downloads 文件夹放模组」**用不了**。

**不受影响**：悬浮球菜单里的**「导入模组」走系统文件选择器，不需要任何权限**，
在这些机型上照常可用 —— 这也是当初做两个入口的原因。

---

## ⚠️ 模组：导入后要重启，文件在沙箱内

**模组文件放在**（应用沙箱内）：
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**格式**：`.jar` 或 `.zip`。
（游戏也接受「内含 `mod.json` 的文件夹」，但那种没法用文件选择器选。）

**三个入口**：

| 方式 | 怎么用 |
| --- | --- |
| **游戏自带的「导入模组」** | 游戏模组界面里那个按钮。✅ **可用**（设备上实测过）。⚠️ 它会先弹一个**取不到社区模组列表**的提示 —— 那是它在联网，平台层的网络已经通了，取不到是服务端/链路的问题（实测是 `Connection refused`），关掉提示继续即可 |
| **悬浮球菜单 → 导入模组** | 在**系统文件选择器**里选 `.jar` / `.zip`。**不需要任何权限** |
| **Download 文件夹** | 把模组放进 `Download/MindustryMods/`，**下次启动自动**搬进去 |

⚠️ **后两个入口导入之后必须重启应用才生效** —— 这**不是偷懒**：游戏**只在启动时扫一次**
`mods/` 目录（在 `Vars.load()` 里），之后再也不看。文件确实躺在那儿，但游戏看不见它。
（**游戏自带的那个不用重启**，它自己会触发重载。）

📌 顺带说明一个容易混的点（我自己在这里搞错过一次）：游戏**自己**那套文件浏览器
（`mindustry/ui/FileChooser` / `FileChooserDialog`）是**纯 Java、画在游戏界面里**的，
和**原生**文件对话框是两回事。后者（`libarc-filedialogsarm64.so`，实为 tinyfiledialogs）
是个 glibc 桌面库、本平台加载不了 —— **但本平台没有任何代码路径会走到它**，
所以不影响上面任何一个入口。

⚠️ 开发时注意：用 `deploy.sh` 重新部署会**清空沙箱**，模组和存档一起没。


# English

- **Text entry, and what each route can do.** Touch a text field inside the game
  (a save name, a schematic name, the export filename) and the app puts up its
  own text field, wired to the system input method — so the on-screen keyboard
  appears and composed input works, Chinese included. A physical keyboard works
  too, and what it can type depends on where the focus is:
    - while the app's field is up, the keyboard goes through the system input
      method as well, so Chinese works from a physical keyboard too;
    - when it is not up, the keyboard goes straight to the game through SDL's
      key-to-character path, which has no input method behind it — ASCII only.
  Focus is singular, so those are the only two states there can be.
  - **Both routes exist because SDL's own IME path cannot work here.** This
    process maps `libSDL3.so` twice, ArkTS hands the IME controller to the copy
    that is *not* running the game, and a `napi_ref` cannot be moved between
    them — so SDL can never show a keyboard. What replaced it: the app watches
    for the game asking for text (a file), shows an ArkUI `TextInput`, and feeds
    what the user types back into SDL's text event queue. The code is in
    `SDL_openharmony.c`, `SDL_openharmonyevents.c` and `ets/pages/Index.ets`.
  - **One rough edge, stated plainly:** the app cannot read the game field's
    cursor, so it sends the *difference* from what it believes the field holds.
    Typing and backspacing at the end of a name are exact. Inserting or editing
    in the *middle* is repaired by retracting and resending — the result is
    correct, but that text is retyped on screen.
- **Desktop/mobile mode cannot be switched at runtime.** The mode is fixed at
  launch. Mindustry has an in-game "mouse + keyboard control" toggle that covers
  most of the same ground. For how to switch, see [FAQ.md](FAQ.md).
- `libarc-filedialogsarm64.so` is linked against glibc and cannot load here, so
  Arc falls back to Mindustry's own in-game file browser. This is why the
  browser path had to be redirected to Download.
- Importing game data makes the game exit on purpose (`Core.app.exit()`), so
  that it restarts with the new data. This looks like a crash and is not one.
- Verified on two devices so far: a HUAWEI MatePad Pro 12.2" 2025 tablet and a
  HUAWEI Mate 80 Pro phone, both HarmonyOS 7 / API 26. Anything else is
  untested — the platform's policy on executable memory is what this depends on,
  and a device that enforces it differently would fail in ways this project has
  no way to predict.
- **Immersive mode does not apply on `2in1` (PC)** — the taskbar and window title
  bar stay. That is a platform limit, not something left undone. **Measured, not
  assumed.** Nothing is broken by it: the floating ball **does** hide normally on PC.
- **`hiview/AppKilledReporter` logs `reason: CppCrash` every time the app exits
  normally. It is not a crash, and it is not attributable to this app.** Measured
  on a normal in-game Quit, in one 5 ms window:

  | Component | Verdict, with attribution |
  |---|---|
  | `AppMS` | `Kill Reason: app exit`, `pid=… processName=com.haohandc.mindustryark` |
  | `sceneboard` | `onProcessDied, uid: …, bundleName: com.haohandc.mindustryark, pid: …` |
  | `aidataservice` | `process died, bundleName: com.haohandc.mindustryark` |
  | `hiview` | `uid: 0, bundleName: ` **empty**, `reason: CppCrash` |

  The one component with no attribution is the one calling it a crash, and it is
  contradicted by the other three. Nothing is produced for it either: no
  `faultlog`, no `cppcrash` directory, no core dump, no non-zero exit signal, and
  `crash.txt` (which the launcher writes when it *does* see a fatal signal) stays
  empty. If you are reading `hiview` lines and wondering, that is what you are
  looking at. See `EntryAbility.ets` for the exit handshake that produces the
  three attributed lines.

The reasoning behind each of those is in the source comments where the code is, rather than here -- `entry/src/main/cpp/launcher.c` is the place to start.

## ⚠️ One LAN server can be listed twice

**What happens**: with a server running, another device's LAN list in "Join game"
shows **two entries** for the same machine.

**The cause is in ArcNet itself** (the game's networking library, not our layer):
`Client.discoverHosts()` fires **two independent probes** -- one **UDP
broadcast**, one **multicast** -- each on its own socket, each calling the
callback once per reply, with **no de-duplication by address anywhere**. A server
that answers *both* probes is therefore reported twice and drawn twice.

🔶 **The inferred part**: that both probes do succeed here is **not measured** --
it is inferred from this platform's network probe (socket/epoll/broadcast all
pass). What is certain is that **the code contains no de-duplication**.

⇒ **Harmless**: both entries point at the same server and either one connects.
⚠️ This is **upstream behaviour**, not something this port introduced; it can
happen on phones and tablets alike.

## ⚠️ On some devices it installs and will not start

**Symptom**: it installs, you tap it, it exits -- with **no crash report at all**.

**Known condition** (measured 2026-09-22): on a **Huawei-supplied self-check device**
(**HarmonyOS 6.1.1 / API 24**) the launcher prints the JVM options, calls
`JNI_CreateJavaVM`, and then produces **no further output ever**; the process
disappears. The same package runs to the main menu on **HarmonyOS 7 / API 26**.

**Cause (measured)**: that device **refuses all anonymous executable memory**:

```
!! mmap(RWX) FAILED: errno=22 (Invalid argument)
 [1] clear_cache   (CONTROL) -> -1   unexpected
 [2] mprotect RW->RX          -> -1   unexpected
```

⇒ **the JVM's JIT cannot start**, so it stops inside `JNI_CreateJavaVM`.

⚠️ **Two possible causes are not yet separated**: ① the platform is too old;
② that device runs the **release-signed** (store) package while everything we
install on our own hardware is **debug-signed**. Both explain every observation so far.

⚠️ The app declares a minimum of `compatibleSdkVersion 6.1.1(24)` and **that claim has
no measurement behind it** -- every "it works" observation is from API 26. Until this
is settled, an API 24 device may install the app and be unable to run it.

## ⚠️ Noticeably slower on phones below HarmonyOS 7 (compatibility mode)

**Why**: see the section above. To let the app start at all on those devices, the
Java runtime runs **interpreted** instead of just-in-time compiled.

**Measured cost** (HarmonyOS 7 tablet, mode forced on by hand):

| | load time |
| --- | --- |
| normal (JIT) | about 5-6 s |
| compatibility mode | **about 21 s** |

**In game it does not slow down uniformly -- it scales with the VISIBLE AREA**:

- **window shrunk** (roughly phone-sized): high load is **playable**
- **full screen**: high load **drops frames badly, effectively unplayable**

⇒ because rendering is native (unaffected) while the unit and tile simulation is
Java: a larger viewport means more work per frame at the same frame budget.

⚠️ In summary: compatibility mode affects the simulation only -- rendering is
untouched -- and its cost grows with the VISIBLE AREA, so a larger screen suffers
more.


## ⚠️ The Download folder is there; on some devices the app cannot reach it

⚠️ **One thing to be precise about**: on that phone the **Download folder exists
and is perfectly normal** (confirmed by the user) -- it is **not** a device
without a Downloads folder. What is missing is the **app's route to its path**.

**What happens**: on the **Mate 80 Pro phone**, requesting the Download-directory
permission shows **no dialog**, the permission does not appear in the permission
list, and **the `Download/MindustryMods/` entry point does not work**. On the
**MatePad Pro tablet** all of it works.

**Evidence** (one HAP, one signature -- identical `appId` -- measured on both):

| | permission state |
| --- | --- |
| tablet, MatePad Pro | `[0, 0]` -- both granted |
| phone, Mate 80 Pro | `[0, -1]` -- the Download one **not granted** |

The app's own log from the phone:

```text
mods: no Downloads directory (The device doesn't support this api)
permission request: ....READ_WRITE_DOWNLOAD_DIRECTORY -> auth=2 dialogShown=true errorReason=0
```

⚠️ **Those three values contradict each other, so this file reports the facts and
claims no cause**:

| field | value | what the SDK says |
| --- | --- | --- |
| `authResults` | `2` | "invalid request" (not declared / bad name / conditions unmet) |
| `dialogShownResults` | `true` | "the system **has shown** the authorization dialog" |
| `errorReasons` | `0` | "this request **is valid**" |

and the whole call returns about **170 ms** after it is made -- far too fast for
a person to have read and dismissed a dialog. **The three fields do not add up to
one story**, so no explanation is offered here.

⭐ An earlier version of this section said "`authResults = 2` means invalid
request, so no dialog will ever appear". That was **inferred from the SDK's field
description**, and the measured combination above does not support it.
Withdrawn. **What is certain is the outcome**: the permission is not granted and
the player sees no prompt.

⚠️ **But "a device capability difference" was itself half-refuted by a later
measurement**: `atm dump --definition` returns a **byte-identical** definition on
both devices --

```text
permissionName : ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
grantMode      : USER_GRANT      <- an ordinary user grant, not an ACL
availableLevel : NORMAL
provisionEnable: true
```

⇒ it is **not an ACL permission and not device-type restricted**, so it *should*
be grantable on the phone. The two devices also run the **same OS build**
(`OpenHarmony-7.0.0.105`, API 26). **Why the dialog fails to appear on the phone
is therefore still unexplained**; only the outcome is known.

⇒ What is certain: **on this phone the permission cannot be obtained, and the
player is shown nothing.**


**What it costs**: on such a device, "import/export a save via the Download
folder" and "drop mods in the Downloads folder" **do not work**.

**What is unaffected**: **导入模组 in the ball's menu uses the system file
picker and needs no permission at all**, so it keeps working on those devices --
which is the reason there are two entry points.

---

## ⚠️ Mods: a restart applies them, and the files live in the sandbox

**Where the mod files are** (inside the app sandbox):
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**Format**: `.jar` or `.zip`. (The game also accepts a *folder* containing
`mod.json`, but a picker cannot hand a folder over.)

**Three ways in**:

| Way | How |
| --- | --- |
| **The game's own "import mod"** | the button in the game's mods screen. ✅ **Works** (confirmed on the device). ⚠️ It shows a **cannot-reach-the-community-mod-list** notice first -- it is going online, and the platform-level network path works; failing to fetch is a server/route condition (measured: `Connection refused`). Dismiss it and carry on |
| **导入模组 in the ball's menu** | pick a `.jar` / `.zip` in the **system file picker**. **Needs no permission** |
| **Downloads folder** | drop the file in `Download/MindustryMods/` and it is taken in **automatically on the next launch** |

⚠️ **The last two need a restart to take effect** -- and that is not laziness:
the game scans the `mods/` directory exactly **once**, inside `Vars.load()`, and
never looks again. The file really is sitting there; the game just cannot see it.
(The game's own button does not need one -- it triggers the reload itself.)

📌 One thing that is easy to confuse -- and that this project got wrong once:
the game's **own** file browser (`mindustry/ui/FileChooser` /
`FileChooserDialog`) is **pure Java, drawn inside the game**, and is a different
thing from the **native** file dialog. The latter
(`libarc-filedialogsarm64.so`, really tinyfiledialogs) is a glibc desktop
library that does not load here -- but **no code path on this platform ever
reaches it**, so none of the entries above is affected by it.

⚠️ For developers: re-deploying with `deploy.sh` **wipes the sandbox**, mods and
saves together.
