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

