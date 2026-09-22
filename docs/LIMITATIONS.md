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


## ✅「下载」目录：手机上走的是**应用自己创建的那个文件夹**

⚠️ **这一节原来写的是「手机够不到下载目录」，那个结论已被推翻** —— 够得到，只是**换了一条路**。

**两条路，名字很像，机制完全不同**：

| | `Environment.getUserDownloadDir()` | `DocumentPickerMode.DOWNLOAD` |
| --- | --- | --- |
| 官方说法 | 需要 `SystemCapability.FileManagement.File.Environment.FolderObtain`，**仅支持 2in1 设备** | **自动创建在 `Download/包名/` 目录**；跳过选择界面；返回的 URI 已具备持久化权限 |
| 手机上的结果 | ⛔ 抛「The device doesn't support this api」 | ✅ **可用** |
| 要不要权限 | 要 `READ_WRITE_DOWNLOAD_DIRECTORY` | **不要任何权限** |

⇒ **手机上用的是第二条。** 应用在「下载」里创建一个**以包名命名的文件夹**
（`Download/com.haohandc.mindustryark`），玩家用任何文件管理器把模组丢进去即可。

**怎么用**：**不需要你做什么** —— 应用**每次启动都会检查并在缺失时重建**它。
⚠️ **没有对应的菜单项**（早先有过一个，已删除：建文件夹不该让玩家去点）。

**依据（设备实测）**：toast 出现、「文件管理」里能看到那个包名文件夹；
`user_dirs.txt` 里 `mods=/storage/Users/currentUser/Download/com.haohandc.mindustryark`，
启动器日志 `file browser will open at (mod folder): ...`。

⚠️ **仍未验证**：游戏的**文件浏览器**（走 libc，不是走 URI）能否读那个路径 ——
应用的授权是**按 URI** 持有的，而浏览器用**路径**。这是下一步要在设备上看的。

⚠️ **顺带**：`READ_WRITE_DOWNLOAD_DIRECTORY` 在本项目里**从来没有过一次成功**
（见下），已**于 2026-09-22 移除**。⇒ **本应用现在是【零文件权限】。**

### ⭐⭐ 逐设备的精确实测（2026-09-22，两台机器都测了）

| | 平板 MatePad | 手机 M80P |
| --- | --- | --- |
| `Environment.getUserDownloadDir()` | 返回 `/storage/Users/currentUser/Download` | **抛「The device doesn't support this api」** |
| 往那里 `mkdir` 我们的子目录 | **EPERM 被拒**（`13900001`） | 走不到 —— 上一行就抛了 |
| `DocumentPickerMode.DOWNLOAD` | ✅ **成功**（修好窗口问题后，见下） | ✅ **成功** |
| **实际生效的是哪条** | **选择器模式** | **选择器模式** |

⚠️ **并且它不需要任何权限** —— 平板上的权限**是被用户拒绝的**，选择器模式照样建出了文件夹。

⇒ ⭐ **`READ_WRITE_DOWNLOAD_DIRECTORY` 对本应用【完全没有用】**：
路线 A **从来没有成功过一次**（手机上是 API 不支持，平板上是权限被拒 + `mkdir` EPERM）。
✅ **已于 2026-09-22 移除** —— 随之取消的还有它那条 **ACL 受限权限申请流程**，
⇒ **上架审核少一个障碍**。见 [PERMISSIONS.md](PERMISSIONS.md)。

⚠️ **平板上那个 EPERM 的原因，用户确认了：权限是【他手动拒绝】的。**
⇒ 不是平台故障，也不是解不开的矛盾。但**留下一个有用的发现**：

**平板的 `reqPermissionStates` 显示 `[0, 0]`（都「已授予」），而权限实际是被拒的。**
⇒ ⭐ **那个字段不能用来判断权限到底给没给。**
（这和另一处记录呼应：权限请求返回的三个字段互相矛盾 —— 见上文。
**鸿蒙的权限状态字段在本项目上两次都不可靠。**）

### ✅ 所以：文件夹**每次启动都会检查**，缺失就重建

行为是「**每次启动检查在不在，不在就重建**」（这正是其他应用的做法，也是用户要求的）。
✅ **两台设备（平板 + 手机）实测都能建出来**，且**都不需要任何权限**。
⇒ 玩家把文件丢进去、重启应用即可。

### ⭐ `13900042` 是「**现在没有可用的 UI 窗口**」

**实测（同一台手机、同一个包、同一天）**：

| 从哪调用 `DocumentPickerMode.DOWNLOAD` | 结果 |
| --- | --- |
| **悬浮球菜单**（点一下，窗口在手） | ✅ **成功** |
| `EntryAbility.onCreate`（窗口可能还没建） | ❌ **`13900042`** |
| **页面的 `aboutToAppear`**（窗口已存在） | ✅ **成功** |

⇒ **DOWNLOAD 模式虽然不显示任何对话框，但仍然需要一个 UI 窗口。**
⚠️ 这个失败的**表现是「静默」** —— 因为该模式本来就不弹界面，所以「没建出来」
看起来和「建好了」一模一样。**这一点让前面几轮都误判了。**

⇒ **所以创建放在页面里，不放在 ability 的 `onCreate`。** 读取仍留在 `onCreate`
（不涉及选择器，随便哪里都行）。

### ⭐ 存下来的**路径**可用，**URI 不可用**

`DOWNLOAD` 模式返回一个 URI，把它解成路径后，实测在手机上：

```text
/storage/Users/currentUser/Download/<包名>         列表正常   ← 可用
file://docs/storage/Users/currentUser/Download/...  No such file or directory
```

⇒ 那个 URI**不是能直接喂给 `fs.listFileSync` 的形式** —— 官方示例也是先
`new fileUri.FileUri(uri).path` 再用的。**所以路径优先、URI 只做兜底。**

## ⚠️ 模组：文件在沙箱内，只有悬浮球那个入口需要重启

**模组文件放在**（应用沙箱内）：
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**格式**：`.jar` 或 `.zip`。
（游戏也接受「内含 `mod.json` 的文件夹」，但那种没法用文件选择器选。）

**三个入口**：

| 方式 | 怎么用 |
| --- | --- |
| **游戏自带的「导入模组」** | 游戏模组界面里那个按钮。✅ **可用**（设备上实测过）。⚠️ 它会先弹一个**取不到社区模组列表**的提示 —— 那是它在联网，平台层的网络已经通了，取不到是服务端/链路的问题（实测是 `Connection refused`），关掉提示继续即可 |
| **悬浮球菜单 → 导入模组** | 在**系统文件选择器**里选 `.jar` / `.zip`。**不需要任何权限** |
| **Download 里的包名文件夹** | 把模组放进 `Download/com.haohandc.mindustryark/`，**下次启动自动**搬进去。**两台设备都可用**，见上一节 |

⚠️ **只有「悬浮球菜单 → 导入模组」需要重启才生效**，另外两个不用：

| 入口 | 要不要重启 | 为什么 |
| --- | --- | --- |
| 游戏自带的导入 | **不用** | 它自己会触发重载 |
| **Download 里的包名文件夹** | **不用** | 它在**启动时**搬进去，早于游戏扫描 |
| **悬浮球菜单 → 导入模组** | ⚠️ **要** | 它在**游戏运行中**落地，而游戏**只在启动时扫一次** `mods/`（`Vars.load()` 里），之后再也不看 |

⇒ 悬浮球那条要重启**不是偷懒**，是游戏机制：文件确实躺在那儿，但游戏看不见它。

📌 顺带说明一个容易混的点（我自己在这里搞错过一次）：游戏**自己**那套文件浏览器
（`mindustry/ui/FileChooser` / `FileChooserDialog`）是**纯 Java、画在游戏界面里**的，
和**原生**文件对话框是两回事。后者（`libarc-filedialogsarm64.so`，实为 tinyfiledialogs）
是个 glibc 桌面库、本平台加载不了 —— **但本平台没有任何代码路径会走到它**，
所以不影响上面任何一个入口。

### ⚠️ 内置导入会把文件**改名成 `<名字>.zip`**

不是缺陷，是游戏写死的。`Mods.importMod` 算目标名用的是：

```java
file.nameWithoutExtension().replace(' ', '_') + ".zip"
```

⇒ 同一个 `.jar` 分别走「游戏内置导入」和「悬浮球 / Download」，会在 `mods/` 里
**留下两个文件**（一份 `.jar` 一份 `.zip`），**内容逐字节相同**。

实测：把 `MindustryToolMod - 复制 .jar` 放进 Download，落地成
`MindustryToolMod_-_复制_.zip` —— 空格变下划线、后缀变 `.zip`，与上面那个式子逐字相符。

⚠️ **无害**，但容易让人以为装了两遍。只想留一份的话，删掉任意一个即可
（**在游戏内的模组列表里删** —— `mods/` 在应用沙箱内，文件管理器打不开）。

### ⚠️ 模组可能被**游戏自己**禁用，而且**不报错**

游戏有一条**崩溃安全阀**。若上一次启动没能起来（`Vars.failedToLaunch`），下一次启动它会
**对每一个模组**做：

```java
settings.put("mod-" + 名字 + "-enabled", false);      // 关掉
settings.put("mod-" + 名字 + "-failed",  <旧enabled>); // 记一笔，给界面看
```

之后 `Mods.load()` 读 `-enabled`，是 false 就把状态设成 `disabled` ⇒ **模组不生效**。

⚠️⚠️ **最容易骗人的一点**：`Loading mod: <名字>` 这行日志是在**判定之前**打的
（在 `loadMod` 里，而状态改写发生在之后的 `load()`）⇒ **这行日志出现 ≠ 模组生效**。
判断有没有生效要看模组**本身的功能**，不要看这行。

**恢复办法**：游戏 → 模组 → 把模组**重新启用**。那是唯一能改回来的地方。

⚠️ **悬浮球和 Download 这两个入口不会重新启用模组。** 游戏自己的导入会顺手写
`-enabled = true`，**我们的没有** ⇒ 一个被禁用过的模组，用我们的入口重装
**装进去了但不生效**，而且**没有任何提示**。

之所以不去补：那两个标志位在 `settings.bin`（游戏的 Java 序列化设置文件）里，
**游戏运行时改它会被游戏覆盖**；而且键名用的是模组的**内部名字**（`mod.json` 里的
`name`），不是文件名，得先解析 jar 才知道。为一个窄场景去动玩家的设置文件，
风险与收益不成比例 —— 所以**如实记在这里**，而不是悄悄绕过。

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


## ✅ The Download folder: on phones the route is the folder the app creates itself

⚠️ **This section used to say the phone cannot reach Downloads. That is refuted**
-- it can, by a different route.

**Two routes, similar names, entirely different mechanisms**:

| | `Environment.getUserDownloadDir()` | `DocumentPickerMode.DOWNLOAD` |
| --- | --- | --- |
| The documentation | needs `SystemCapability.FileManagement.File.Environment.FolderObtain`, **"currently 2in1 devices only"** | **creates `Download/<bundle name>/` automatically**; skips the picker UI; the URI it returns already carries persistent permission |
| On a phone | ⛔ throws "The device doesn't support this api" | ✅ **works** |
| Permission needed | `READ_WRITE_DOWNLOAD_DIRECTORY` | **none at all** |

⇒ **Phones use the second one.** The app creates a folder named after the bundle
inside Downloads (`Download/com.haohandc.mindustryark`) and the player drops mod
files into it with any file manager.

**How to use it**: floating ball menu -> **"模组文件夹"**. ⚠️ **No picker appears** --
DOWNLOAD mode skips its UI entirely.

**Evidence (measured on the device)**: the toast appeared and the bundle-name
folder is visible in the file manager; `user_dirs.txt` carries
`mods=/storage/Users/currentUser/Download/com.haohandc.mindustryark`, and the
launcher logs `file browser will open at (mod folder): ...`.

⚠️ **Still unverified**: whether the game's own **file browser** (which goes
through libc, not through the URI) can read that path -- the app's grant is held
**per URI** while the browser uses a **path**. That is the next thing to check on
the device.

⚠️ **Also**: `READ_WRITE_DOWNLOAD_DIRECTORY` has **never once succeeded** in this
project (see below), and was **removed on 2026-09-22**. ⇒ **this app now has ZERO
file permissions.**

### ⭐⭐ Precise, per device (2026-09-22, both machines measured)

| | Tablet (MatePad) | Phone (M80P) |
| --- | --- | --- |
| `Environment.getUserDownloadDir()` | returns `/storage/Users/currentUser/Download` | **throws "The device doesn't support this api"** |
| `mkdir` our subdirectory there | **refused, EPERM** (`13900001`) | never reached -- the line above throws |
| `DocumentPickerMode.DOWNLOAD` | ✅ **works** (once the window problem was fixed) | ✅ **works** |
| **which one actually does the work** | **the picker mode** | **the picker mode** |

⚠️ **And it needs no permission at all** -- the tablet's permission is **denied by
the user**, and the picker mode still created the folder.

⇒ ⭐ **`READ_WRITE_DOWNLOAD_DIRECTORY` has NO use in this app**: route A has never
succeeded once (on the phone the API does not exist, on the tablet the permission is
denied and `mkdir` returns EPERM). ✅ **Removed on 2026-09-22** -- which also cancels
the **ACL restricted-permission route** it required, so **store review has one less
obstacle**. See [PERMISSIONS.md](PERMISSIONS.md).

⚠️ **That EPERM on the tablet is now explained -- the user DENIED the permission
by hand.** So it is not a platform fault and not a contradiction. But it leaves a
useful finding:

**The tablet's `reqPermissionStates` reads `[0, 0]` ("both granted") while the
permission is in fact denied.** ⇒ ⭐ **That field cannot be used to tell whether a
permission was granted.** This is the second time on this project that a Huawei
permission-status field has disagreed with reality -- see the three contradictory
fields on the request result above. **Do not trust them; test the operation.**

### ✅ So: the folder is CHECKED every launch, and recreated if missing

The behaviour is "check on every launch whether it is there, and recreate it if not"
-- what other apps do, and what the user asked for. ✅ **Both devices (tablet and
phone) create it**, and **neither needs any permission**. The player drops files in
and restarts the app.

### ⭐ `13900042` is "there is no usable UI window right now"

**Measured on one phone, one package, one day**:

| called from | result |
| --- | --- |
| **the floating ball's menu** (a tap, window present) | ✅ **works** |
| `EntryAbility.onCreate` (the window may not exist yet) | ❌ **`13900042`** |
| **the page's `aboutToAppear`** (window exists) | ✅ **works** |

⇒ **DOWNLOAD mode needs a UI window even though it shows no dialog.**
⚠️ And the failure is **silent in effect** -- the mode shows no UI at all, so "it did
not create the folder" looks exactly like "it created the folder". That is what
made the earlier rounds misread it.

⇒ **So creation lives on the page, not in the ability's `onCreate`.** Reading stays
in `onCreate`, where no picker is involved.

### ⭐ The stored **path** works; the **URI** does not

DOWNLOAD mode returns a URI. Resolved to a path, measured on the phone:

```text
/storage/Users/currentUser/Download/<bundle>          lists fine   <- usable
file://docs/storage/Users/currentUser/Download/...    No such file or directory
```

⇒ the URI **is not something `fs.listFileSync` accepts as-is** -- the guide's own
example resolves it with `new fileUri.FileUri(uri).path` first. **So the path is
tried first and the URI is only a fallback.**

## ⚠️ Mods: the files live in the sandbox, and only the picker needs a restart

**Where the mod files are** (inside the app sandbox):
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**Format**: `.jar` or `.zip`. (The game also accepts a *folder* containing
`mod.json`, but a picker cannot hand a folder over.)

**Three ways in**:

| Way | How |
| --- | --- |
| **The game's own "import mod"** | the button in the game's mods screen. ✅ **Works** (confirmed on the device). ⚠️ It shows a **cannot-reach-the-community-mod-list** notice first -- it is going online, and the platform-level network path works; failing to fetch is a server/route condition (measured: `Connection refused`). Dismiss it and carry on |
| **导入模组 in the ball's menu** | pick a `.jar` / `.zip` in the **system file picker**. **Needs no permission** |
| **The bundle-name folder in Downloads** | drop the file in `Download/com.haohandc.mindustryark/` and it is taken in **automatically on the next launch**. **Both devices work** -- see the section above |

⚠️ **Only the ball's picker needs a restart**; the other two do not:

| Way in | Restart? | Why |
| --- | --- | --- |
| the game's own import | **no** | it triggers the reload itself |
| **the bundle-name folder in Downloads** | **no** | it is taken in **at startup**, before the game scans |
| **导入模组 in the ball's menu** | ⚠️ **yes** | it lands files **while the game is running**, and the game scans `mods/` exactly **once**, inside `Vars.load()`, and never looks again |

⇒ the picker needing a restart is not laziness, it is the game's mechanism: the file really
is sitting there, the game just cannot see it.

📌 One thing that is easy to confuse -- and that this project got wrong once:
the game's **own** file browser (`mindustry/ui/FileChooser` /
`FileChooserDialog`) is **pure Java, drawn inside the game**, and is a different
thing from the **native** file dialog. The latter
(`libarc-filedialogsarm64.so`, really tinyfiledialogs) is a glibc desktop
library that does not load here -- but **no code path on this platform ever
reaches it**, so none of the entries above is affected by it.

### ⚠️ The game's own import **renames the file to `<name>.zip`**

Not a defect -- it is hard-coded. `Mods.importMod` derives its destination as:

```java
file.nameWithoutExtension().replace(' ', '_') + ".zip"
```

⇒ the same `.jar` taken in through **the game's import** and through the ball's picker
or Downloads leaves **two files** in `mods/` (one `.jar`, one `.zip`) with **byte-identical
contents**.

Measured: dropping in `MindustryToolMod - 复制 .jar` landed as
`MindustryToolMod_-_复制_.zip` -- spaces became underscores and the suffix became `.zip`,
matching that expression exactly.

⚠️ **Harmless**, but it reads as though the mod were installed twice. To keep one copy,
delete either one -- **from the game's own mods list**, since `mods/` lives in the app
sandbox and a file manager cannot open it.

### ⚠️ The game may disable a mod **by itself**, and it **says nothing**

Mindustry has a **crash safety valve**. If the previous launch failed to start
(`Vars.failedToLaunch`), the next launch does this **to every mod**:

```java
settings.put("mod-" + name + "-enabled", false);        // switch it off
settings.put("mod-" + name + "-failed",  <old enabled>); // and note it for the UI
```

`Mods.load()` then reads `-enabled`, and when it is false it sets the mod's state to
`disabled` ⇒ **the mod does not take effect**.

⚠️⚠️ **The part that misleads:** the `Loading mod: <name>` line is printed *before* that
decision (inside `loadMod`; the state is rewritten later, in `load()`) ⇒ **that line
appearing does NOT mean the mod took effect.** Judge that by the mod's own behaviour, not
by that line.

**To recover**: game → mods → **enable the mod again**. That is the only place that can
change it back.

⚠️ **Neither the ball's picker nor the Downloads folder re-enables a mod.** The game's own
import also writes `-enabled = true`; **ours does not** ⇒ a mod that has been disabled is
re-installed by our entries **and still does not take effect**, with **no message at all**.

Why it was left alone: those flags live in `settings.bin`, the game's Java-serialised
settings file. Writing it while the game is running gets overwritten by the game, and the
key is the mod's **internal name** (the `name` in `mod.json`) rather than the file name, so
the jar would have to be parsed first. Rewriting a player's settings file for a narrow case
is a bad trade -- so it is recorded here rather than quietly worked around.

⚠️ For developers: re-deploying with `deploy.sh` **wipes the sandbox**, mods and
saves together.
